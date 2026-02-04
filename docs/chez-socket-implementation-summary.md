# Chez-Socket Call/CC 实现核心要点

基于 chez-socket 项目的实现分析，提炼关键技术要点。

## 核心模式：挂起-恢复循环

### 基本结构

```scheme
(define (async-read fd buf len)
  (let loop ()
    (or (try-read fd buf len)         ; 尝试非阻塞操作
        (begin
          (call/cc                     ; 失败则挂起
            (lambda (k)
              (register-wait! fd k)    ; 注册 continuation
              (scheduler-yield!)))     ; 让出控制权
          (loop)))))                   ; 恢复后重试
```

### 关键点

1. **外层循环**：`let loop ()` 确保 I/O 就绪后能重试操作
2. **非阻塞尝试**：先尝试操作，成功则直接返回
3. **挂起点**：`call/cc` 捕获当前执行状态
4. **注册等待**：将 (fd, continuation) 存入调度器
5. **让出控制**：跳转到调度器主循环
6. **自动恢复**：调度器检测到 fd 就绪时调用 `(k #t)`
7. **重试操作**：从 call/cc 返回后执行 `(loop)`

## 调度器主循环

### 三段式结构

```scheme
(define (run-loop sched)
  (let loop ()
    (cond
      ;; 1. 有可运行任务 -> 执行
      [(has-runnable-tasks? sched)
       (run-next-task! sched)
       (loop)]

      ;; 2. 无任务但有 I/O 等待 -> 等待事件
      [(has-pending-io? sched)
       (wait-for-io! sched)
       (loop)]

      ;; 3. 什么都没有 -> 退出或等待停止信号
      [else
       (handle-idle-or-exit! sched)])))
```

### I/O 等待逻辑

```scheme
(define (wait-for-io! sched)
  ;; 1. 调用 epoll_wait / kevent / poll
  (let ([ready-fds (backend-wait (scheduler-io-backend sched)
                                 timeout
                                 get-pending-fds)])
    ;; 2. 对每个就绪的 fd
    (for-each
      (lambda (fd)
        ;; 3. 从 pending 表取出 continuation
        (let ([k (hashtable-ref (scheduler-pending sched) fd #f)])
          (when k
            ;; 4. 从 pending 表删除
            (hashtable-delete! (scheduler-pending sched) fd)
            ;; 5. 加入可运行队列
            (enqueue-runnable! sched k))))
      ready-fds)))
```

## 数据结构设计

### 最小化调度器状态

```scheme
(define-record-type scheduler
  (fields
    (mutable runnable)    ; list: thunk 队列
    (mutable pending)     ; hashtable: fd -> continuation
    (immutable io-backend) ; I/O 多路复用抽象
    (mutable timers)))    ; list: 定时器列表（可选）
```

### Continuation 的存储

```scheme
;; 注册 I/O 等待
(define (register-wait! sched fd cont)
  (hashtable-set! (scheduler-pending sched) fd cont)
  (backend-register! (scheduler-io-backend sched) fd 'read))

;; 恢复执行
(define (resume-continuation! sched fd)
  (let ([cont (hashtable-ref (scheduler-pending sched) fd #f)])
    (when cont
      (hashtable-delete! (scheduler-pending sched) fd)
      (backend-unregister! (scheduler-io-backend sched) fd)
      ;; 将 continuation 封装为 thunk 加入队列
      (enqueue-runnable! sched (lambda () (cont #t))))))
```

## I/O Backend 抽象

### Vtable 模式

```scheme
;; 定义统一接口
(define-record-type backend-vtable
  (fields
    (immutable init)        ; () -> fd
    (immutable register)    ; (fd sock io-type) -> void
    (immutable unregister)  ; (fd sock) -> void
    (immutable wait)        ; (fd timeout get-pending) -> (list sock)
    (immutable shutdown)))  ; (fd) -> void

;; Epoll 实现
(define (make-epoll-backend)
  (%make-backend 'epoll
                 (make-backend-vtable
                   epoll-init
                   epoll-register
                   epoll-unregister
                   epoll-wait
                   epoll-shutdown)
                 #f))

;; 自动选择最佳后端
(define (make-default-backend)
  (cond
    [epoll-available?  (make-epoll-backend)]
    [kqueue-available? (make-kqueue-backend)]
    [else              (make-poll-backend)]))
```

## 定时器集成

### 有序定时器列表

```scheme
;; 定时器结构
(define-record-type timer
  (fields
    deadline    ; 到期时间（纳秒）
    callback))  ; thunk 或 continuation

;; 插入保持有序
(define (timer-insert timers new-timer)
  (cond
    [(null? timers)
     (list new-timer)]
    [(<= (timer-deadline new-timer) (timer-deadline (car timers)))
     (cons new-timer timers)]
    [else
     (cons (car timers) (timer-insert (cdr timers) new-timer))]))
```

### 超时计算

```scheme
(define (compute-wait-timeout sched)
  (let ([next-timer-deadline (and (pair? (scheduler-timers sched))
                                  (timer-deadline (car (scheduler-timers sched))))])
    (cond
      ;; 有定时器：计算到下一个定时器的时间
      [next-timer-deadline
       (max 0 (quotient (- next-timer-deadline (current-time-ns))
                        1000000))]  ; ns -> ms
      ;; 有 pending I/O：短超时轮询
      [(> (hashtable-size (scheduler-pending sched)) 0)
       100]
      ;; 什么都没有：无限等待或立即返回
      [else -1])))
```

### async-sleep 实现

```scheme
(define (async-sleep ms)
  (let ([sched (current-scheduler)])
    (call/cc
      (lambda (k)
        ;; 添加定时器，回调是 continuation
        (add-timer! sched ms (lambda () (k (void))))
        ;; 让出控制权
        (scheduler-yield! sched)))))
```

## 异步 Port 封装

### Custom Port 回调中调用异步 I/O

```scheme
(define (make-async-input-port fd)
  (let ([buf (foreign-alloc 4096)])
    ;; read! 回调
    (define (read! bv start count)
      ;; 关键：在回调中调用 async-read
      (let ([n (async-read fd buf (min count 4096))])
        (when (and n (> n 0))
          ;; 复制数据到 bytevector
          (do ([i 0 (+ i 1)]) ((= i n))
            (bytevector-u8-set! bv (+ start i)
                                (foreign-ref 'unsigned-8 buf i))))
        n))

    (define (close!)
      (foreign-free buf)
      (close-fd fd))

    (make-custom-binary-input-port "async-in" read! #f #f close!)))
```

### 工作原理

1. 用户调用 `(get-line port)`
2. Port 调用 `read!` 回调
3. `read!` 调用 `async-read`
4. `async-read` 内部可能 `call/cc` 挂起
5. 调度器切换到其他任务
6. I/O 就绪后恢复 `async-read`
7. `read!` 返回数据
8. `get-line` 继续执行

## 唤醒机制（显式停止）

### 跨平台实现

```scheme
;; Linux: eventfd
(define (make-eventfd-wakeup)
  (let ([fd (eventfd 0 (bitwise-ior EFD_NONBLOCK EFD_CLOEXEC))])
    (make-wakeup-fd 'eventfd fd fd)))

;; BSD/macOS: pipe
(define (make-pipe-wakeup)
  (let ([fds (pipe)])
    (set-nonblocking! (car fds))
    (set-nonblocking! (cdr fds))
    (make-wakeup-fd 'pipe (car fds) (cdr fds))))

;; 自动选择
(define (make-wakeup-fd)
  (if eventfd-available?
      (make-eventfd-wakeup)
      (make-pipe-wakeup)))
```

### 停止流程

```scheme
(define (scheduler-stop! sched)
  ;; 1. 设置停止标志
  (scheduler-running?-set! sched #f)
  ;; 2. 发送唤醒信号
  (signal-wakeup! (scheduler-wakeup sched)))

(define (scheduler-run! sched)
  ;; 将 wakeup-fd 注册到 I/O backend
  (backend-register! (scheduler-io-backend sched)
                     (wakeup-read-fd (scheduler-wakeup sched))
                     'read)
  ;; 主循环
  (call/cc
    (lambda (exit)
      (scheduler-exit-k exit)  ; 保存 exit continuation
      (run-loop sched)))
  ;; 清理资源
  (scheduler-cleanup! sched))

(define (handle-stop! sched)
  ;; 清空 wakeup-fd
  (clear-wakeup! (scheduler-wakeup sched))
  ;; 使用 exit continuation 跳出循环
  (let ([exit (scheduler-exit-k)])
    (when exit
      (exit (void)))))
```

## 完整示例

### 异步 Echo 服务器

```scheme
(import (async scheduler)
        (async port))

;; 处理单个客户端
(define (handle-client in out)
  (let loop ()
    (let ([line (get-line in)])
      (unless (eof-object? line)
        (put-string out line)
        (newline out)
        (flush-output-port out)
        (loop)))))

;; 接受连接循环
(define (accept-loop sched server-fd)
  (let-values ([(in out host port) (async-tcp-accept/text server-fd)])
    (printf "Client connected: ~a:~a~n" host port)
    ;; 为每个客户端启动新任务
    (spawn (lambda () (handle-client in out)))
    ;; 继续接受下一个连接
    (accept-loop sched server-fd)))

;; 主函数
(define (main)
  (let ([sched (make-scheduler)]
        [server-fd (tcp-listen 8080)])
    (set-fd-nonblocking! server-fd)
    (printf "Listening on port 8080~n")
    ;; 启动接受循环
    (spawn (lambda () (accept-loop sched server-fd)))
    ;; 运行调度器
    (scheduler-run! sched)))
```

## 关键优化技巧

### 1. 减少 Continuation 创建

```scheme
;; ✗ 差：每次都创建新 continuation
(define (async-read fd buf len)
  (call/cc (lambda (k) ...)))

;; ✓ 好：只在真正需要时创建
(define (async-read fd buf len)
  (let loop ()
    (or (try-read fd buf len)  ; 先尝试，成功则无需 call/cc
        (begin
          (call/cc (lambda (k) ...))
          (loop)))))
```

### 2. 批量处理就绪 fd

```scheme
;; epoll_wait 一次返回多个就绪 fd
(let ([ready-fds (epoll-wait epfd timeout)])
  ;; 批量处理，减少调度开销
  (for-each
    (lambda (fd)
      (resume-continuation! sched fd))
    ready-fds))
```

### 3. 使用外部缓冲区

```scheme
;; 复用 C 缓冲区，避免频繁分配
(let ([buf (foreign-alloc 4096)])
  (define (read! bv start count)
    (let ([n (async-read fd buf (min count 4096))])
      ...
      n))
  (make-custom-binary-input-port "async" read! #f #f
    (lambda () (foreign-free buf))))
```

## 常见陷阱

### 1. 忘记外层循环

```scheme
;; ✗ 错误：call/cc 返回后没有重试
(define (async-read fd buf len)
  (or (try-read fd buf len)
      (call/cc
        (lambda (k)
          (register-wait! fd k)
          (scheduler-yield!)))))

;; ✓ 正确：需要重试
(define (async-read fd buf len)
  (let loop ()
    (or (try-read fd buf len)
        (begin
          (call/cc ...)
          (loop)))))  ; ← 重要！
```

### 2. 在非调度器上下文中使用

```scheme
;; ✗ 错误：没有调度器
(define (main)
  (async-read fd buf len))  ; 崩溃！

;; ✓ 正确：在 spawn 中使用
(define (main)
  (let ([sched (make-scheduler)])
    (spawn (lambda ()
             (async-read fd buf len)))
    (scheduler-run! sched)))
```

### 3. 忘记从 pending 表删除

```scheme
;; ✗ 错误：内存泄漏
(define (resume-continuation! sched fd)
  (let ([k (hashtable-ref pending fd #f)])
    (when k
      (enqueue-runnable! sched k))))

;; ✓ 正确：及时清理
(define (resume-continuation! sched fd)
  (let ([k (hashtable-ref pending fd #f)])
    (when k
      (hashtable-delete! pending fd)  ; ← 清理
      (enqueue-runnable! sched k))))
```

## 性能特性

| 操作 | 时间复杂度 | 说明 |
|------|-----------|------|
| spawn | O(1) | 追加到列表尾部 |
| 取任务 | O(1) | 列表头部 |
| 注册 I/O | O(1) | hashtable 插入 + epoll_ctl |
| I/O 等待 | O(ready) | epoll_wait 只返回就绪的 fd |
| 定时器插入 | O(n) | 有序列表插入 |
| 定时器触发 | O(k) | k 为到期定时器数量 |

## 内存使用

- **Continuation**：约 200-500 字节（取决于调用栈深度）
- **任务队列**：每个任务一个 cons cell（16 字节）
- **Pending 表**：每个等待的 fd 一个 hashtable 条目（约 24 字节）
- **定时器**：每个定时器约 32 字节

## 总结

实现 call/cc 异步 I/O 的核心要点：

1. **挂起-恢复循环**：外层循环 + call/cc + 重试
2. **三段式调度器**：运行任务、等待 I/O、处理空闲
3. **Continuation 管理**：注册到 pending 表，I/O 就绪时恢复
4. **I/O Backend 抽象**：vtable 模式封装平台差异
5. **定时器集成**：有序列表 + 超时计算
6. **Port 封装**：在 custom port 回调中调用异步 I/O
7. **唤醒机制**：eventfd/pipe 实现显式停止

这种设计实现了：
- 简洁的用户 API（spawn、async-read、async-sleep）
- 高效的事件调度（epoll O(1)、批量处理）
- 透明的异步化（通过 Port 接口）
- 良好的可扩展性（Backend vtable、定时器）
