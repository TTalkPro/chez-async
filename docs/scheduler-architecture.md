# Loop、Scheduler 和 Pending 队列的关联架构

**创建日期**: 2026-02-05

本文档详细解释 chez-async 中事件循环（Loop）、协程调度器（Scheduler）和等待队列（Pending）之间的关联关系。

---

## 📊 核心架构图

```
┌─────────────────────────────────────────────────────────────┐
│                      uv-loop (事件循环)                      │
│  ┌────────────────────────────────────────────────────────┐ │
│  │ • ptr: uv_loop_t* (libuv C 指针)                       │ │
│  │ • ptr-registry: hashtable (C指针 -> Scheme对象)       │ │
│  │ • threadpool: 线程池                                   │ │
│  │ • temp-buffers: 临时缓冲区                             │ │
│  └────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
                            │
                            │ 1:1 映射
                            ↓
┌─────────────────────────────────────────────────────────────┐
│              Scheduler State (协程调度器状态)                │
│  ┌────────────────────────────────────────────────────────┐ │
│  │ • runnable: queue<coroutine>  (可运行协程队列)         │ │
│  │ • pending: hashtable<promise -> coroutine> (等待表)   │ │
│  │ • current: coroutine (当前运行的协程)                  │ │
│  │ • scheduler-k: continuation (调度器 continuation)      │ │
│  │ • loop: uv-loop (关联的事件循环)                       │ │
│  └────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
          │                          │
          │ runnable queue           │ pending table
          ↓                          ↓
    ┌──────────┐            ┌────────────────┐
    │ Coro 1   │            │ Promise -> Coro│
    │ Coro 2   │            │ Promise -> Coro│
    │ Coro 3   │            │ Promise -> Coro│
    └──────────┘            └────────────────┘
      准备执行                  等待 Promise
```

---

## 🔗 关联关系详解

### 1. Loop ↔ Scheduler（1对1关系）

**存储方式**：全局弱引用哈希表
```scheme
;; 文件：internal/scheduler.ss
(define scheduler-table (make-weak-eq-hashtable))

(define (get-scheduler loop)
  "获取或创建事件循环的调度器"
  (or (hashtable-ref scheduler-table loop #f)
      (let ([sched (make-scheduler-state loop)])
        (hashtable-set! scheduler-table loop sched)
        sched)))
```

**关键点**：
- 每个 `uv-loop` 对应唯一一个 `scheduler-state`
- 使用弱引用表，当 loop 被 GC 时，scheduler 也会被回收
- 惰性创建：首次使用时才创建 scheduler

### 2. Scheduler → Runnable Queue（1对1关系）

**数据结构**：FIFO 队列
```scheme
;; scheduler-state 定义
(define-record-type scheduler-state
  (fields
    (mutable runnable)      ; queue<coroutine> - 可运行协程队列
    (mutable pending)       ; hashtable<promise -> coroutine>
    (mutable current)       ; 当前运行的协程
    (mutable scheduler-k)   ; 调度器 continuation
    (immutable loop)))      ; 关联的事件循环
```

**Runnable Queue 的作用**：
```
┌─────────────────────────────────────┐
│      Runnable Queue (可运行队列)     │
├─────────────────────────────────────┤
│ [Coro 1] → [Coro 2] → [Coro 3]     │
│   ↑ 出队                   ↑ 入队   │
└─────────────────────────────────────┘
       │
       ↓ 取出并执行
  run-coroutine!
```

**操作流程**：
1. **入队**（spawn-coroutine!）
   ```scheme
   (define (spawn-coroutine! loop thunk)
     (let* ([sched (get-scheduler loop)]
            [coro (make-coroutine loop)])
       ;; 加入可运行队列
       (queue-enqueue! (scheduler-state-runnable sched) coro)
       coro))
   ```

2. **出队并执行**（run-scheduler）
   ```scheme
   (cond
     [(queue-not-empty? (scheduler-state-runnable sched))
      (let ([coro (queue-dequeue! (scheduler-state-runnable sched))])
        (run-coroutine! sched coro)
        (scheduler-loop))])
   ```

### 3. Scheduler → Pending Table（1对1关系）

**数据结构**：哈希表（Promise → Coroutine）
```scheme
(mutable pending)  ; hashtable: promise -> coroutine
```

**Pending Table 的作用**：
```
┌──────────────────────────────────────────┐
│    Pending Table (等待表)                 │
├──────────────────────────────────────────┤
│ Promise-A  ────→  Coroutine-1           │
│ Promise-B  ────→  Coroutine-2           │
│ Promise-C  ────→  Coroutine-3           │
└──────────────────────────────────────────┘
       │                      ↑
       │ Promise 完成         │
       └──────────────────────┘
           resume-coroutine!
```

**操作流程**：

1. **协程挂起，加入 Pending Table**（suspend-for-promise!）
   ```scheme
   (define (suspend-for-promise! promise)
     (let ([coro (current-coroutine)])
       (call/cc
         (lambda (k)
           ;; 1. 保存 continuation
           (coroutine-continuation-set! coro k)

           ;; 2. 注册到 pending 表
           (hashtable-set! (scheduler-state-pending sched) promise coro)

           ;; 3. 注册 Promise 回调
           (promise-then promise
             (lambda (value)
               (resume-coroutine! sched coro value #f))
             (lambda (error)
               (resume-coroutine! sched coro error #t)))

           ;; 4. 跳回调度器
           (scheduler-k (void))))))
   ```

2. **Promise 完成，从 Pending Table 移除**（resume-coroutine!）
   ```scheme
   (define (resume-coroutine! sched coro value-or-error is-error?)
     ;; 1. 从 pending 表中移除
     (let ([pending (scheduler-state-pending sched)])
       (hashtable-delete! pending promise))

     ;; 2. 设置结果
     (coroutine-result-set! coro value-or-error)

     ;; 3. 加入可运行队列
     (queue-enqueue! (scheduler-state-runnable sched) coro))
   ```

---

## 🔄 完整执行流程

### 场景：两个协程并发执行

```scheme
;; 用户代码
(define loop (uv-default-loop))

(spawn-coroutine! loop
  (lambda ()
    (printf "Coro 1: Start~n")
    (await (async-sleep loop 1000))
    (printf "Coro 1: Done~n")))

(spawn-coroutine! loop
  (lambda ()
    (printf "Coro 2: Start~n")
    (await (async-sleep loop 500))
    (printf "Coro 2: Done~n")))

(run-scheduler loop)
```

### 执行时间线

```
时间 0ms:
┌─────────────────────────────────────┐
│ Scheduler State                     │
├─────────────────────────────────────┤
│ runnable: [Coro-1, Coro-2]         │
│ pending:  {}                        │
│ current:  nil                       │
└─────────────────────────────────────┘

调度器：取出 Coro-1 执行
↓

时间 1ms: Coro-1 运行到 await
┌─────────────────────────────────────┐
│ Scheduler State                     │
├─────────────────────────────────────┤
│ runnable: [Coro-2]                 │  ← Coro-1 移除
│ pending:  {Promise-1 -> Coro-1}    │  ← Coro-1 加入 pending
│ current:  nil                       │
└─────────────────────────────────────┘
│
│ Promise-1 = async-sleep 1000ms
│ Timer 启动，1000ms 后触发
│
调度器：取出 Coro-2 执行
↓

时间 2ms: Coro-2 运行到 await
┌─────────────────────────────────────┐
│ Scheduler State                     │
├─────────────────────────────────────┤
│ runnable: []                        │  ← Coro-2 移除
│ pending:  {Promise-1 -> Coro-1      │  ← Coro-2 加入 pending
│            Promise-2 -> Coro-2}     │
│ current:  nil                       │
└─────────────────────────────────────┘
│
│ Promise-2 = async-sleep 500ms
│ Timer 启动，500ms 后触发
│
调度器：runnable 空，pending 非空
       → 运行 libuv 事件循环 (uv-run loop 'once)
↓

时间 500ms: Timer-2 触发
┌─────────────────────────────────────┐
│ 事件：Timer-2 触发                   │
│  ↓                                  │
│ Promise-2 完成                       │
│  ↓                                  │
│ 调用 resume-coroutine!(Coro-2)      │
└─────────────────────────────────────┘
↓
┌─────────────────────────────────────┐
│ Scheduler State                     │
├─────────────────────────────────────┤
│ runnable: [Coro-2]                 │  ← Coro-2 重新加入
│ pending:  {Promise-1 -> Coro-1}    │  ← Coro-2 移除
│ current:  nil                       │
└─────────────────────────────────────┘

调度器：取出 Coro-2 继续执行
↓
Coro-2 执行完毕，打印 "Coro 2: Done"

时间 501ms:
┌─────────────────────────────────────┐
│ Scheduler State                     │
├─────────────────────────────────────┤
│ runnable: []                        │  ← Coro-2 完成
│ pending:  {Promise-1 -> Coro-1}    │
│ current:  nil                       │
└─────────────────────────────────────┘

调度器：继续运行 libuv 事件循环
↓

时间 1000ms: Timer-1 触发
┌─────────────────────────────────────┐
│ 事件：Timer-1 触发                   │
│  ↓                                  │
│ Promise-1 完成                       │
│  ↓                                  │
│ 调用 resume-coroutine!(Coro-1)      │
└─────────────────────────────────────┘
↓
┌─────────────────────────────────────┐
│ Scheduler State                     │
├─────────────────────────────────────┤
│ runnable: [Coro-1]                 │  ← Coro-1 重新加入
│ pending:  {}                        │  ← Coro-1 移除
│ current:  nil                       │
└─────────────────────────────────────┘

调度器：取出 Coro-1 继续执行
↓
Coro-1 执行完毕，打印 "Coro 1: Done"

时间 1001ms:
┌─────────────────────────────────────┐
│ Scheduler State                     │
├─────────────────────────────────────┤
│ runnable: []                        │  ← 空
│ pending:  {}                        │  ← 空
│ current:  nil                       │
└─────────────────────────────────────┘

调度器：runnable 和 pending 都为空，退出
```

---

## 🎯 关键设计要点

### 1. Per-Loop 架构

**为什么每个 loop 有自己的 scheduler？**

```scheme
;; 可以创建多个独立的事件循环
(define loop1 (uv-loop-init))
(define loop2 (uv-loop-init))

;; 每个 loop 有独立的调度器和协程队列
(spawn-coroutine! loop1 task1)  ; 在 loop1 的 scheduler 中
(spawn-coroutine! loop2 task2)  ; 在 loop2 的 scheduler 中

;; 互不干扰
(thread
  (lambda () (run-scheduler loop1)))
(thread
  (lambda () (run-scheduler loop2)))
```

**优点**：
- 无全局状态，易于测试
- 支持多线程（每个线程一个 loop）
- 符合 libuv 的设计哲学

### 2. 两个队列的职责分离

**Runnable Queue（可运行队列）**：
- 存储**可以立即执行**的协程
- FIFO 顺序执行
- 协程在这里排队等待 CPU

**Pending Table（等待表）**：
- 存储**等待 I/O 完成**的协程
- 按 Promise 索引
- 协程在这里等待事件

**为什么分开？**
```
CPU 密集型任务 → Runnable Queue → 立即执行
I/O 操作       → Pending Table  → 等待事件 → Runnable Queue
```

### 3. Call/CC 和 Scheduler-K 的协作

**Scheduler-K 的作用**：
```scheme
(define (run-scheduler loop)
  (let scheduler-loop ()
    ;; 设置调度器 continuation
    (call/cc
      (lambda (k)
        (scheduler-state-scheduler-k-set! sched k)))

    ;; ... 执行协程 ...
    (scheduler-loop)))
```

**Suspend 时的跳转**：
```scheme
(define (suspend-for-promise! promise)
  (call/cc
    (lambda (k)
      ;; 保存协程 continuation
      (coroutine-continuation-set! coro k)

      ;; 跳回调度器
      (let ([scheduler-k (scheduler-state-scheduler-k sched)])
        (scheduler-k (void))))))  ; 直接跳回调度器循环
```

**效果**：
```
用户代码 (await promise)
    ↓ call/cc 捕获 k
保存 k 到协程
    ↓ scheduler-k 跳转
调度器循环 (scheduler-loop)
    ↓ 取下一个协程
继续执行其他协程
```

### 4. 两层 Call/CC 的完整协作机制

`scheduler-k` 是整个协程调度的核心——它让协程在 `await` 时能够**让出控制权**回到调度器主循环。整个机制依赖两层 `call/cc` 的配合。

#### 第一层：调度器 continuation（scheduler-k）

每次调度循环迭代开始时，`run-scheduler` 用 `call/cc` 捕获当前位置：

```scheme
;; internal/scheduler.ss:322-326
(call/cc
  (lambda (k)
    (scheduler-state-scheduler-k-set! sched k)))
```

此时 `scheduler-k` 代表的含义是："回到调度循环的顶部，重新检查 runnable/pending 状态"。

#### 第二层：协程 continuation（coroutine-continuation）

当协程执行到 `await` 时，`suspend-for-promise!` 用 `call/cc` 捕获协程当前执行位置：

```scheme
;; internal/scheduler.ss:201-229
(call/cc
  (lambda (k)
    ;; 1. 保存协程 continuation（"从 await 处继续"）
    (coroutine-continuation-set! coro k)
    (coroutine-state-set! coro 'suspended)

    ;; 2. 注册到 pending 表
    (hashtable-set! pending promise coro)

    ;; 3. 注册 Promise 回调（Promise 完成时恢复协程）
    (promise-then promise
      (lambda (value)
        (resume-coroutine! sched coro value #f))
      (lambda (error)
        (resume-coroutine! sched coro (cons 'promise-error error) #t)))

    ;; 4. 用 scheduler-k 跳回调度器
    (let ([scheduler-k (scheduler-state-scheduler-k sched)])
      (scheduler-k (void)))))
```

#### 两层 continuation 的交互流程

```
run-scheduler
  │
  ├─ call/cc ──→ 保存 scheduler-k（"回到调度循环顶部"）
  │
  ├─ 取出协程 → run-coroutine!
  │     │
  │     └─ 协程执行用户代码
  │           │
  │           └─ (await promise) → suspend-for-promise!
  │                 │
  │                 ├─ call/cc ──→ 保存 coroutine-k（"从 await 处继续"）
  │                 ├─ 注册 Promise 回调
  │                 └─ (scheduler-k (void)) ──→ 跳回调度循环顶部
  │                                               │
  ├─ 调度循环继续 ←─────────────────────────────────┘
  │
  ├─ 没有可运行协程？→ (uv-run loop 'once) 等待 I/O 事件
  │     │
  │     └─ Timer/IO 事件触发 → Promise 完成
  │           │
  │           └─ resume-coroutine! → 协程放回 runnable 队列
  │
  ├─ 取出协程 → run-coroutine!
  │     │
  │     └─ (k result) ──→ 调用保存的 coroutine-k
  │                        协程从 await 处恢复，result 作为返回值
  │
  └─ runnable 和 pending 都空 → 退出
```

#### 恢复时的值传递

当 Promise 完成后，`run-coroutine!` 通过调用保存的 continuation 将结果传回：

```scheme
;; internal/scheduler.ss:294-304
(if is-first-run?
    (k)                    ; 首次运行：调用 thunk
    (let ([result (coroutine-result coro)])
      (if (and (pair? result) (eq? (car result) 'promise-error))
          (raise (cdr result))   ; Promise 拒绝：在协程内抛出异常
          (k result))))          ; Promise 完成：result 成为 await 的返回值
```

这就是 `(await promise)` 能够"返回" Promise 结果值的原因——`call/cc` 捕获的 continuation `k` 被调用时，传入的 `result` 就成为了 `call/cc` 表达式的返回值。

#### 关键不变量

- **scheduler-k 在每次调度循环迭代时更新**：确保协程总是跳回最新的调度点
- **coroutine-continuation 在挂起时设置，恢复后清除**：`run-coroutine!` 执行前先置 `#f`（第291行），防止重复执行
- **如果 scheduler-k 为 `#f`，说明不在调度器上下文中**：此时调用 `await` 会报错

---

## 📝 代码关键位置

### 创建关联

```scheme
;; 文件：internal/scheduler.ss:111-116
(define (get-scheduler loop)
  (or (hashtable-ref scheduler-table loop #f)
      (let ([sched (make-scheduler-state loop)])
        (hashtable-set! scheduler-table loop sched)
        sched)))
```

### 加入 Runnable Queue

```scheme
;; 文件：internal/scheduler.ss:176
(queue-enqueue! (scheduler-state-runnable sched) coro)
```

### 加入 Pending Table

```scheme
;; 文件：internal/scheduler.ss:208
(hashtable-set! (scheduler-state-pending sched) promise coro)
```

### 从 Pending 移到 Runnable

```scheme
;; 文件：internal/scheduler.ss:243-264
(define (resume-coroutine! sched coro value-or-error is-error?)
  ;; 1. 从 pending 移除
  (hashtable-delete! pending promise)
  ;; 2. 设置结果
  (coroutine-result-set! coro value-or-error)
  ;; 3. 加入 runnable
  (queue-enqueue! (scheduler-state-runnable sched) coro))
```

### 调度循环

```scheme
;; 文件：internal/scheduler.ss:311-349
(define (run-scheduler loop)
  (let scheduler-loop ()
    (cond
      ;; 情况 1: 执行可运行的协程
      [(queue-not-empty? runnable)
       (run-coroutine! sched (queue-dequeue! runnable))
       (scheduler-loop)]

      ;; 情况 2: 等待 I/O 事件
      [(> (hashtable-size pending) 0)
       (uv-run loop 'once)
       (scheduler-loop)]

      ;; 情况 3: 所有完成
      [else (values)])))
```

#### Named Let 语法说明

`(let scheduler-loop () ...)` 是 Scheme 的 **named let**，不是普通的变量绑定。它等价于：

```scheme
(letrec ([scheduler-loop (lambda () body ...)])
  (scheduler-loop))
```

即定义一个名为 `scheduler-loop` 的无参递归函数并立即调用。`()` 是空的绑定列表，表示没有循环变量。Chez Scheme 会将尾位置的递归调用优化为真正的循环（不会栈溢出）。

#### run-scheduler 的退出条件

`run-scheduler` 在 **runnable 队列为空 且 pending 表也为空** 时退出——即所有协程都已完成或失败，没有任何协程在等待 I/O。

**典型的生命周期**：

```
spawn 2 个协程 → runnable: [C1, C2], pending: {}

执行 C1 → C1 遇到 await → runnable: [C2], pending: {P1→C1}
执行 C2 → C2 遇到 await → runnable: [],  pending: {P1→C1, P2→C2}

runnable 空，pending 非空 → uv-run 'once（等 I/O）

P2 完成 → runnable: [C2], pending: {P1→C1}
执行 C2 → C2 完成        → runnable: [],  pending: {P1→C1}

runnable 空，pending 非空 → uv-run 'once（等 I/O）

P1 完成 → runnable: [C1], pending: {}
执行 C1 → C1 完成        → runnable: [],  pending: {}

两个都空 → (values) → 退出
```

**会卡住的情况**：如果某个 Promise 永远不完成（比如等待一个永远不来的网络包），`run-scheduler` 会一直卡在情况 2 的 `(uv-run loop 'once)` 里无限循环。这也是为什么需要 `async-timeout` 之类的机制来防止永久挂起。

---

## 🔍 调试技巧

### 查看 Scheduler 状态

```scheme
(define (debug-scheduler loop)
  (let ([sched (get-scheduler loop)])
    (printf "Runnable: ~a coroutines~n"
            (queue-size (scheduler-state-runnable sched)))
    (printf "Pending: ~a coroutines~n"
            (hashtable-size (scheduler-state-pending sched)))
    (printf "Current: ~a~n"
            (let ([c (scheduler-state-current sched)])
              (if c (coroutine-id c) "none")))))
```

### 追踪协程状态变化

```scheme
;; 在 spawn-coroutine! 中添加
(printf "[Spawn] Coroutine ~a created~n" (coroutine-id coro))

;; 在 suspend-for-promise! 中添加
(printf "[Suspend] Coroutine ~a waiting for promise~n" (coroutine-id coro))

;; 在 resume-coroutine! 中添加
(printf "[Resume] Coroutine ~a ready to run~n" (coroutine-id coro))
```

---

## 📚 总结

### 关系链

```
Loop (事件循环)
  ↕ 1:1
Scheduler (调度器)
  ├─→ Runnable Queue (可运行队列)
  │     ├─ Coroutine 1
  │     ├─ Coroutine 2
  │     └─ Coroutine 3
  │
  └─→ Pending Table (等待表)
        ├─ Promise A → Coroutine 4
        ├─ Promise B → Coroutine 5
        └─ Promise C → Coroutine 6
```

### 核心机制

1. **Per-Loop 隔离**：每个事件循环独立管理自己的协程
2. **两级队列**：Runnable（准备执行）+ Pending（等待 I/O）
3. **Call/CC 协作**：协程挂起/恢复通过 continuation 实现
4. **事件驱动**：Promise 完成触发协程恢复

### 优势

- ✅ 无全局状态，易于测试
- ✅ 支持多事件循环
- ✅ 高效的协程调度
- ✅ 自然的 async/await 语法

---

---

## 🔒 lock-object 与 GC 保护

### 为什么需要 lock-object

Scheme 的 GC 只追踪 Scheme 侧的引用。当回调函数通过 FFI 传给 libuv（C 代码）后，GC 看不到 C 侧的引用，可能会回收仍在使用的对象，导致野指针崩溃。

```
Scheme 侧                    C 侧 (libuv)

callback ─────FFI传递─────→ uv_timer_t.callback
    │                              │
    │ Scheme 不再引用               │ libuv 还在用
    │ GC 认为可以回收 ❌            │ 定时器到期要调它
    ↓                              ↓
  被 GC 回收                   野指针 → 崩溃
```

`lock-object` 告诉 GC："这个对象有外部引用，别回收"。

### 必须配对 unlock-object

否则内存泄漏——对象永远不会被回收。项目中的生命周期：

```
lock-object callback       ← start! 时锁住
  │
  │  libuv 持有引用，GC 不会回收
  │
unlock-object callback     ← close! 或下次 start! 时释放
  │
  │  GC 可以回收了
  ↓
```

### 在句柄操作中的模式

```scheme
;; start! 时：释放旧回调，锁住新回调
(define (uv-timer-start! timer timeout repeat callback)
  (let ([old-callback (handle-data timer)])
    (when old-callback
      (unlock-object old-callback)))     ; 释放旧的
  (handle-data-set! timer callback)
  (lock-object callback)                 ; 锁住新的
  (%ffi-uv-timer-start ...))

;; stop! 时：只停止，不动回调（回调保留以支持 again! 重启）
;; close! 时：cleanup-handle-wrapper! 统一 unlock 回调
```

### 相关 bug 修复

2026-02-05 修复了 timer/signal/poll 的 stop! 函数错误清除回调的问题。stop! 会 unlock 并清除回调，导致 again!/重新 start! 时回调为 `#f`，事件循环挂起。修复方式：stop! 只停止操作不动回调，close! 时统一清理。

---

**参考文件**：
- `internal/scheduler.ss` - 调度器实现
- `high-level/event-loop.ss` - 事件循环封装
- `internal/coroutine.ss` - 协程数据结构
- `high-level/promise.ss` - Promise 实现
