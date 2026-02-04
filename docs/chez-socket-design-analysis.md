# Chez-Socket 异步框架设计分析

本文档总结了 chez-socket 项目中基于 call/cc 的异步 I/O 框架的关键设计理念和实现技术。

## 目录

1. [核心设计理念](#核心设计理念)
2. [Call/CC 的使用方式](#callcc-的使用方式)
3. [协程调度器设计](#协程调度器设计)
4. [Event Loop 实现](#event-loop-实现)
5. [任务队列管理](#任务队列管理)
6. [I/O Backend 抽象](#io-backend-抽象)
7. [异步 Port 封装](#异步-port-封装)
8. [架构演进](#架构演进)

---

## 核心设计理念

### 1. 协作式协程调度

chez-socket 使用 **call/cc (call-with-current-continuation)** 实现协作式的协程调度，而非抢占式多线程：

- **主动让出控制权**：当 I/O 操作会阻塞时，任务通过 call/cc 捕获 continuation 并主动让出
- **单线程事件循环**：在协程式调度器中，所有任务在单线程中协作执行
- **零线程开销**：避免了操作系统线程的上下文切换和同步开销

### 2. 分层抽象设计

```
┌─────────────────────────────────────────────────────────────┐
│                      应用层代码                              │
│   (get-line in) (put-string out "hello")                   │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│              (async port)                                    │
│   make-async-socket-port                                    │
│   - 提供 Port 接口，内部调用 async-read/async-write         │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│              (async scheduler)                               │
│   async-read / async-write / spawn                          │
│   - call/cc 实现挂起/恢复                                    │
│   - 任务队列管理                                             │
│   - 定时器支持                                               │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│              (io-backend)                                    │
│   统一的 I/O 多路复用抽象                                    │
│   - Linux: epoll (O(1))                                     │
│   - macOS/BSD: kqueue (O(1))                                │
│   - 其他: poll (POSIX)                                      │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│              (socket ffi)                                    │
│   底层 FFI 绑定：socket, recv, send, epoll, kqueue          │
└─────────────────────────────────────────────────────────────┘
```

### 3. 关注点分离

- **调度器**：专注于任务调度、协程管理、定时器
- **I/O Backend**：专注于 I/O 多路复用机制的跨平台抽象
- **Port 层**：将异步 I/O 封装为 Scheme 标准 Port 接口

---

## Call/CC 的使用方式

### 基本原理

Call/cc (call-with-current-continuation) 是 Scheme 中捕获和操作控制流的强大机制。在异步框架中，它用于：

1. **捕获执行点**：当 I/O 操作会阻塞时，保存当前的执行状态
2. **让出控制权**：跳转到调度器主循环，执行其他任务
3. **恢复执行**：当 I/O 就绪时，调用保存的 continuation 恢复执行

### 核心流程

```scheme
;; async-read 的实现
(define (async-read fd buf len)
  (let ([sched (current-scheduler)])
    (let loop ()
      (or (try-read fd buf len)         ; 尝试非阻塞读取
          (begin
            (call/cc                     ; 如果会阻塞，捕获 continuation
              (lambda (k)
                (register-wait! sched 'read fd k)  ; 注册等待
                (run-loop sched)))       ; 让出控制权
            (loop))))))                  ; 恢复后重试
```

### Call/CC 流程图

```
async-read 被调用
      │
      ▼
┌─────────────────┐
│ 尝试非阻塞读取   │ (try-read)
└────────┬────────┘
         │
    有数据？
    ┌────┴────┐
    │ Yes     │ No
    ▼         ▼
  返回     call/cc 捕获 continuation (k)
  数据           │
                 ▼
         注册 (fd, k) 到 pending-table
                 │
                 ▼
         调用 run-loop (让出控制权)
                 │
                 ▼
         调度器执行其他任务...
         select/epoll 检测到 fd 可读
                 │
                 ▼
         从 pending-table 取出 (fd, k)
                 │
                 ▼
         调用 (k #t) 恢复执行
                 │
                 ▼
         从 call/cc 返回，执行 (loop)
                 │
                 ▼
         重新尝试 try-read，成功返回数据
```

### Continuation 的本质

**类比**：Continuation 就像一个"书签"

- **捕获时**：`call/cc` 在当前页面放置书签
- **保存时**：将书签存入任务队列
- **恢复时**：调用 `(k value)` 相当于翻回书签页，并假装函数返回了 `value`

**关键特性**：
- Continuation 包含完整的调用栈
- 包含所有局部变量的值
- 可以多次调用（可重入）
- 在协程式调度器中始终在同一线程执行

---

## 协程调度器设计

### 数据结构

```scheme
(define-record-type (coroutine-scheduler ...)
  (fields
    (mutable running?)        ; 是否运行中
    (immutable io-backend)    ; I/O backend 抽象
    (mutable pending)         ; hash-table: fd -> io-request
    (mutable runnable)        ; list: 可运行的 thunk
    (mutable timers)          ; list: 定时器列表（按 deadline 升序）
    (immutable mutex)         ; 保护共享状态
    (immutable wakeup)))      ; 唤醒机制（用于显式停止）

;; I/O 请求
(define-record-type io-request
  (fields
    type              ; 'read | 'write | 'accept | 'connect
    fd                ; 等待的文件描述符
    continuation))    ; 就绪时恢复的 continuation

;; 定时器
(define-record-type timer
  (fields
    deadline          ; 到期时间（纳秒，单调时钟）
    callback))        ; 到期时执行的 thunk 或 continuation
```

### 核心 API

```scheme
;; 创建调度器（自动选择最佳 I/O 后端）
(define (make-coroutine-scheduler)
  (let* ([backend (make-default-backend)]
         [wakeup (make-wakeup-fd)]
         [sched (%make-scheduler #f backend ...)])
    (backend-init! backend)
    (backend-register! backend (wakeup-read-fd wakeup) 'read)
    sched))

;; 提交任务
(define (spawn thunk)
  (let ([sched (current-scheduler)])
    (with-mutex (coroutine-scheduler-mutex sched)
      (coroutine-scheduler-runnable-set!
        sched
        (append (coroutine-scheduler-runnable sched) (list thunk))))))

;; 异步 I/O（阻塞当前协程，但不阻塞调度器）
(define (async-read fd buf len) ...)
(define (async-write fd buf len) ...)
(define (async-accept server-fd) ...)
(define (async-connect host port) ...)

;; 定时器（协作式休眠）
(define (async-sleep ms) ...)           ; 阻塞当前协程
(define (set-timeout thunk ms) ...)     ; 延迟执行
(define (set-interval thunk ms) ...)    ; 周期执行
```

### 状态转换

```
                  async-read 阻塞
     ┌─────────────────────────────────────┐
     │                                     ▼
 ┌───┴───┐     I/O 就绪              ┌─────────┐
 │PENDING│ ◄─────────────────────── │ READY   │
 │(等待IO)│                          │(可运行) │
 └───────┘                           └────┬────┘
     ▲                                    │
     │           run-loop                 │
     │       (调度器取出任务)               ▼
     │                              ┌─────────┐
     └───────── I/O 再次阻塞 ─────── │RUNNING │
                                    │(执行中) │
                                    └─────────┘
```

---

## Event Loop 实现

### 主循环结构

```scheme
(define (run-loop sched)
  "调度器主循环：运行直到收到停止信号"
  (let loop ()
    ;; 1. 处理到期的定时器
    (process-expired-timers! sched)

    (cond
      ;; 2. 检查是否停止
      [(scheduler-stopped? sched)
       (handle-stop! sched)]

      ;; 3. 执行可运行任务
      [(has-runnable-tasks? sched)
       ((pop-runnable-task! sched))
       (loop)]

      ;; 4. 等待 I/O 事件或定时器到期
      [else
       (wait-for-io sched (compute-wait-timeout sched))
       (loop)])))
```

### I/O 等待机制

```scheme
(define (wait-for-io sched timeout-ms)
  "等待 I/O 事件或停止信号"
  (let* ([pending (coroutine-scheduler-pending sched)]
         [backend (coroutine-scheduler-io-backend sched)]
         [wakeup-fd (wakeup-read-fd (coroutine-scheduler-wakeup sched))]
         ;; 调用 backend-wait，传入待监听的 fd 列表
         [ready-fds (backend-wait backend timeout-ms
                      (lambda () (build-pending-fds-list pending wakeup-fd)))])
    ;; 处理就绪的 fd
    (for-each
      (lambda (fd)
        (unless (= fd wakeup-fd)
          (handle-ready-fd! sched pending fd)))
      ready-fds)))

(define (handle-ready-fd! sched pending fd)
  "处理单个就绪的 fd"
  (let ([req (hashtable-ref pending fd #f)])
    (when req
      (hashtable-delete! pending fd)
      (unregister-fd! sched fd)
      ;; 将 continuation 加入可运行队列
      (enqueue-continuation! sched
                             (io-request-continuation req)
                             (io-request-type req)
                             fd))))
```

### 超时计算

```scheme
(define (compute-wait-timeout sched)
  "计算 I/O 等待超时时间，综合考虑 pending I/O 和定时器"
  (let ([pending (coroutine-scheduler-pending sched)]
        [timer-timeout (compute-timer-timeout sched)])
    (cond
      ;; 有定时器：使用定时器超时（可能为0）
      [timer-timeout timer-timeout]
      ;; 有 pending I/O：100ms 轮询
      [(> (hashtable-size pending) 0) 100]
      ;; 都没有：无限等待停止信号
      [else -1])))
```

### 定时器处理

```scheme
(define (process-expired-timers! sched)
  "处理所有到期的定时器，将回调加入可运行队列"
  (let ([expired (pop-expired-timers! sched (current-time-ns))])
    (for-each
      (lambda (t)
        (coroutine-scheduler-runnable-set!
          sched
          (append (coroutine-scheduler-runnable sched)
                  (list (timer-callback t)))))
      expired)))

(define (timer-insert timers new-timer)
  "将定时器插入有序列表，按 deadline 升序排列"
  (cond
    [(null? timers)
     (list new-timer)]
    [(<= (timer-deadline new-timer) (timer-deadline (car timers)))
     (cons new-timer timers)]
    [else
     (cons (car timers) (timer-insert (cdr timers) new-timer))]))
```

---

## 任务队列管理

### 队列结构

协程式调度器使用简单的列表作为任务队列：

```scheme
;; runnable: 可运行任务队列（FIFO）
(mutable runnable)  ; list of thunks

;; 入队
(define (enqueue-task! sched thunk)
  (coroutine-scheduler-runnable-set!
    sched
    (append (coroutine-scheduler-runnable sched) (list thunk))))

;; 出队
(define (pop-runnable-task! sched)
  (let ([task (car (coroutine-scheduler-runnable sched))])
    (coroutine-scheduler-runnable-set!
      sched (cdr (coroutine-scheduler-runnable sched)))
    task))
```

### 任务提交

```scheme
;; 用户提交任务
(spawn (lambda ()
  (printf "Task 1~n")
  (async-sleep 1000)
  (printf "Task 1 after sleep~n")))

(spawn (lambda ()
  (printf "Task 2~n")))
```

### Continuation 封装

```scheme
(define (enqueue-continuation! sched cont type fd)
  "将 continuation 封装后加入可运行队列"
  (let ([thunk (if (eq? type 'connect)
                   (lambda () (cont fd))      ; connect 传递 fd
                   (lambda () (cont #t)))])   ; 其他类型传递 #t
    (coroutine-scheduler-runnable-set!
      sched
      (append (coroutine-scheduler-runnable sched) (list thunk)))))
```

### 优先级

调度器的执行顺序：

1. **最高优先级**：到期的定时器
2. **中等优先级**：可运行任务（包括恢复的 continuation）
3. **最低优先级**：I/O 等待（只在没有其他任务时执行）

---

## I/O Backend 抽象

### 设计动机

消除三个 scheduler 实现（epoll/kqueue/poll）的代码重复：

- **之前**：每个 scheduler 都有自己的 I/O 多路复用实现
- **现在**：统一的调度器 + 可插拔的 I/O backend

### Vtable 模式

```scheme
;;; Backend Vtable (虚函数表)
(define-record-type backend-vtable
  (fields
    (immutable init)         ; () -> backend-fd
    (immutable register)     ; (backend-fd fd io-type) -> void
    (immutable unregister)   ; (backend-fd fd) -> void
    (immutable wait)         ; (backend-fd timeout get-pending) -> (list fd)
    (immutable shutdown)))   ; (backend-fd) -> void

;;; Backend 实例
(define-record-type backend
  (fields
    (immutable type)         ; 'epoll | 'kqueue | 'poll
    (immutable vtable)       ; backend-vtable
    (mutable fd)))           ; backend 文件描述符
```

### 统一接口

```scheme
;; 创建后端（自动选择最佳）
(define (make-default-backend)
  (cond
    [epoll-available?  (make-epoll-backend)]
    [kqueue-available? (make-kqueue-backend)]
    [else              (make-poll-backend)]))

;; 统一操作
(backend-init! backend)
(backend-register! backend fd 'read)
(backend-wait backend timeout get-pending-fds)
(backend-unregister! backend fd)
(backend-shutdown! backend)
```

### Epoll 实现示例

```scheme
(define (epoll-init)
  (let ([epfd (%ffi-epoll-create1 O_CLOEXEC)])
    (if (< epfd 0)
        (error 'epoll-init "failed")
        epfd)))

(define (epoll-register epfd sock io-type)
  (let ([events (case io-type
                  [(read accept) EPOLLIN]
                  [(write connect) EPOLLOUT])])
    (let ([ev (foreign-alloc 12)])
      (foreign-set! 'unsigned-32 ev 0 events)
      (foreign-set! 'int ev 4 sock)
      (%ffi-epoll-ctl epfd EPOLL_CTL_ADD sock ev)
      (foreign-free ev))))

(define (epoll-wait epfd timeout-ms get-pending-fds)
  (let* ([max-events 64]
         [events (foreign-alloc (* max-events 12))])
    (let ([n (%ffi-epoll-wait epfd events max-events timeout-ms)])
      (if (<= n 0)
          (begin (foreign-free events) '())
          (let ([ready-fds
                 (let loop ([i 0] [result '()])
                   (if (>= i n)
                       result
                       (let ([fd (foreign-ref 'int events (+ (* i 12) 4))])
                         (loop (+ i 1) (cons fd result)))))])
            (foreign-free events)
            ready-fds)))))

(define (make-epoll-backend)
  (%make-backend 'epoll
                 (make-backend-vtable
                   epoll-init
                   epoll-register
                   epoll-unregister
                   epoll-wait
                   epoll-shutdown)
                 #f))
```

### 优势

| 方面 | 之前 | 现在 |
|-----|------|------|
| 代码重复 | 3 个独立实现 | 1 个统一实现 + backend |
| 添加后端 | 修改多处 | 实现 1 个 vtable |
| 代码行数 | ~1280行 | ~400行（减少68%） |
| 可扩展性 | 低 | 高（插件化） |

---

## 异步 Port 封装

### 挑战

标准 Port 的 `read!`/`write!` 回调是**同步阻塞**的，而异步框架需要在 I/O 阻塞时**让出控制权**。

### 解决方案

在 `read!`/`write!` 回调内部调用 `async-read`/`async-write`：

```scheme
(define (make-async-input-port info)
  (let ([fd (async-port-info-fd info)]
        [buf (foreign-alloc 4096)])

    ;; read! 回调 - 核心异步读取逻辑
    (define (read! bv start count)
      (let ([n (async-read fd buf (min count 4096))])
        (cond
          [(and n (> n 0))
           ;; 将数据从 C 缓冲区复制到 bytevector
           (do ([i 0 (+ i 1)]) ((= i n))
             (bytevector-u8-set! bv (+ start i)
                                 (foreign-ref 'unsigned-8 buf i)))
           n]
          [else 0])))  ; EOF

    (define (close!)
      (foreign-free buf)
      (%ffi-close fd))

    (make-custom-binary-input-port "async-in" read! #f #f close!)))
```

### 工作流程

```
用户代码: (get-line in)
      │
      ▼
Custom Port 的 read! 回调
      │
      ▼
async-read fd buf len
      │
      ├──────────────────┐
      │ 有数据            │ 无数据
      ▼                   ▼
   返回数据          call/cc 捕获 k
                         │
                         ▼
                  注册 (fd, k) 到调度器
                         │
                         ▼
                  让出控制权给调度器
                         │
                         ▼
                  调度器执行其他任务...
                  select 检测到 fd 可读
                         │
                         ▼
                  调用 (k) 恢复执行
                         │
                         ▼
                  async-read 返回数据
                         │
                         ▼
                  read! 返回字节数
                         │
                         ▼
                  get-line 继续执行
```

### 使用示例

```scheme
;; 异步 HTTP 客户端
(define (async-http-get host path)
  (with-async-tcp-text-connection ((in out) host 80)
    (put-string out (format "GET ~a HTTP/1.1\r\n" path))
    (put-string out (format "Host: ~a\r\n" host))
    (put-string out "Connection: close\r\n\r\n")
    (flush-output-port out)
    (let loop ([lines '()])
      (let ([line (get-line in)])
        (if (eof-object? line)
            (reverse lines)
            (loop (cons line lines)))))))

;; 并发请求多个 URL
(define (main)
  (let ([sched (make-scheduler)]
        [completed 0])
    (for-each
      (lambda (url)
        (spawn
          (lambda ()
            (async-http-get (car url) (cdr url))
            (set! completed (+ completed 1))
            (when (= completed 3)
              (scheduler-stop! sched)))))
      '(("example.com" . "/")
        ("example.org" . "/")
        ("example.net" . "/")))
    (scheduler-run! sched)))
```

### 重要限制

异步 Port **必须在调度器上下文中使用**：

```scheme
;; ✓ 正确：在调度器上下文中使用
(spawn
  (lambda ()
    (with-async-tcp-connection ((in out) "example.com" 80)
      (get-line in))))

;; ✗ 错误：在普通同步代码中使用（会死锁或崩溃）
(with-async-tcp-connection ((in out) "example.com" 80)
  (get-line in))  ; 没有调度器，call/cc 无处返回
```

---

## 架构演进

### 重构 1：IO Backend 抽象

**问题**：epoll/kqueue/poll 三个 scheduler 实现有大量重复代码

**解决**：
- 创建 `io-backend.ss`，使用 vtable 模式封装 I/O 多路复用
- 三个后端共享相同的接口
- 自动选择最佳后端

**效果**：
- 代码减少 68%
- 添加新后端只需实现 vtable
- 更易测试和维护

### 重构 2：统一 Coroutine Scheduler

**问题**：三个 scheduler 只有 I/O 多路复用不同，其他逻辑完全相同

**解决**：
- 创建 `coroutine-scheduler.ss`，统一的协程式调度器
- 内部使用 `io-backend` 抽象
- 消除三个独立实现

**效果**：
- 从 1280 行减少到 400 行
- 消除 11 处 cond 分发
- 自动支持未来的 io_uring 等新后端

### 重构 3：统一 Scheduler 接口

**问题**：协程式和并行式调度器 API 不一致

**解决**：
- 创建 `scheduler.ss`，使用 vtable 模式统一接口
- 用户代码无需关心底层实现
- `scheduler-run!` 行为完全统一（阻塞直到显式停止）

**效果**：
```scheme
;; 统一的 API
(define sched (make-scheduler))          ; 默认协程式
;; 或
(define sched (make-scheduler 'parallel)) ; 并行式

(scheduler-run! sched)  ; 两者行为一致
```

### 唤醒机制

**问题**：如何让 `scheduler-run!` 能够显式停止？

**解决**：
- Linux：使用 `eventfd`（高效）
- BSD/macOS：使用 `pipe`（通用）
- 将 wakeup-fd 注册到 I/O backend
- `scheduler-stop!` 写入 wakeup-fd 唤醒等待

**实现**：
```scheme
(define (scheduler-stop! sched)
  (coroutine-scheduler-running?-set! sched #f)
  (signal-wakeup! (coroutine-scheduler-wakeup sched))
  (sleep (make-time 'time-duration 10000000 0)))  ; 等待信号处理

(define (handle-stop! sched)
  (clear-wakeup! (coroutine-scheduler-wakeup sched))
  ;; 使用 exit continuation 跳出所有嵌套的 run-loop
  (let ([exit (scheduler-exit-k)])
    (when exit
      (exit (void)))))
```

---

## 并行式调度器（混合模式）

除了协程式调度器，chez-socket 还提供并行式调度器，结合多线程和 call/cc：

### 架构

```
┌─────────────────────────────────────────────────────────────┐
│ Worker Thread Pool (CPU 密集型任务)                          │
│  - work-stealing 队列                                        │
│  - 每个 Worker 有独立的任务队列                               │
│  - 处理 I/O completion                                       │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│ Dispatcher Thread (任务分发)                                 │
│  - 从全局队列分发任务到 Worker                                │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│ I/O Thread Pool (I/O 密集型任务)                             │
│  - 每个线程独立的 epoll/kqueue/poll                          │
│  - 处理异步 I/O 请求                                         │
│  - 将 completion 发送回 Worker                               │
└─────────────────────────────────────────────────────────────┘
```

### Call/CC 的线程亲和性

**关键保证**：Continuation 始终在捕获它的 Worker 线程中恢复

```scheme
;; 在 async-read 中捕获 continuation 时：
(call/cc
  (lambda (k)
    (let ([req (make-io-request-entry
                'read
                fd
                (worker-id worker)  ; ← 记录当前 Worker ID
                k)])
      (submit-io-request req))))

;; I/O 完成后
(define (process-io-completions worker completion-queue)
  (let ([my-id (worker-id worker)])
    (let ([completion (queue-pop! completion-queue)])
      (when completion
        (let ([target-id (car completion)]
              [cont (cdr completion)])
          (if (= target-id my-id)
              ;; ✅ 只处理属于自己的 completion
              (enqueue-local-task! worker cont)
              ;; ❌ 不是自己的，放回队列
              (queue-push! completion-queue completion)))))))
```

---

## 关键技术总结

### 1. Call/CC 作为协程基础

- **捕获**：`(call/cc (lambda (k) ...))`
- **让出**：跳转到调度器主循环
- **恢复**：`(k value)` 从 call/cc 返回
- **线程安全**：在并行模式下保证线程亲和性

### 2. 事件驱动架构

- **非阻塞 I/O**：所有 socket 设置为非阻塞模式
- **I/O 多路复用**：epoll/kqueue/poll 统一抽象
- **主动轮询**：event loop 持续检查 I/O 事件和定时器

### 3. 零拷贝和高效调度

- **Continuation 复用**：无需分配新对象
- **列表操作**：队列使用简单列表，GC 友好
- **批量处理**：一次 epoll_wait 返回多个就绪 fd

### 4. 跨平台兼容

- **I/O Backend**：自动选择最佳机制
- **Wakeup 机制**：Linux 用 eventfd，BSD 用 pipe
- **FFI 抽象**：统一的 C 接口绑定

### 5. 可组合性

- **Port 抽象**：异步 I/O 封装为标准 Port
- **定时器集成**：与 I/O 事件统一调度
- **任务提交**：简单的 `spawn` 接口

---

## 性能特性

### 协程式调度器

| 特性 | 说明 |
|------|------|
| 内存开销 | 极低（单线程，无锁） |
| 上下文切换 | 零（只有函数调用） |
| 并发模型 | 协作式 I/O 并发 |
| 适用场景 | I/O 密集型，高并发连接 |

### 并行式调度器

| 特性 | 说明 |
|------|------|
| CPU 利用 | 多核并行 |
| Work Stealing | 动态负载均衡 |
| 并发模型 | 真正并行 + 协作式 I/O |
| 适用场景 | CPU 密集型 + I/O 混合 |

---

## 对 chez-async 项目的启示

### 1. 可借鉴的设计

- **Call/CC 的协程实现**：简洁高效
- **I/O Backend 抽象**：vtable 模式消除重复
- **定时器集成**：统一调度 I/O 事件和定时器
- **Port 封装**：将异步 I/O 透明化

### 2. 可改进的方向

- **异常处理**：添加更完善的错误恢复机制
- **调试支持**：Continuation 栈跟踪和性能分析
- **资源限制**：连接数、内存使用限制
- **优先级调度**：支持任务优先级

### 3. 实现建议

```scheme
;; 在 chez-async 中实现类似的协程调度器
(library (chez-async scheduler)
  (export
    make-scheduler
    spawn
    async-read
    async-write
    async-sleep)

  (import (chezscheme))

  ;; 使用 call/cc 实现协程
  (define (async-operation fd operation)
    (let loop ()
      (or (try-operation fd operation)
          (begin
            (call/cc
              (lambda (k)
                (register-wait! fd k)
                (scheduler-yield!)))
            (loop)))))

  ;; 事件循环
  (define (scheduler-run!)
    (let loop ()
      (cond
        [(has-runnable-tasks?)
         (run-next-task!)
         (loop)]
        [(has-pending-io?)
         (wait-for-io!)
         (loop)]
        [else
         (exit-scheduler)]))))
```

---

## 参考资源

### 设计文档
- `/tmp/chez-socket/design/scheduler-backend-abstraction.md`
- `/tmp/chez-socket/design/unified-scheduler-run-behavior.md`
- `/tmp/chez-socket/design/async-port.md`
- `/tmp/chez-socket/design/io-backend-abstraction.md`
- `/tmp/chez-socket/design/async-io/08-call-cc-flow.md`
- `/tmp/chez-socket/design/async-io/03-concepts-and-flow.md`

### 核心实现
- `/tmp/chez-socket/lib/async/coroutine-scheduler.ss` - 协程调度器
- `/tmp/chez-socket/lib/async/scheduler.ss` - 统一调度器接口
- `/tmp/chez-socket/lib/async/port.ss` - 异步 Port 封装
- `/tmp/chez-socket/lib/async/wakeup.ss` - 唤醒机制
- `/tmp/chez-socket/lib/async/parallel/io-backend.ss` - I/O Backend 抽象

### 项目地址
- GitHub: https://github.com/TTalkPro/chez-socket
