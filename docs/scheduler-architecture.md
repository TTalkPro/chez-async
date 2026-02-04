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

**参考文件**：
- `internal/scheduler.ss` - 调度器实现
- `high-level/event-loop.ss` - 事件循环封装
- `internal/coroutine.ss` - 协程数据结构
- `high-level/promise.ss` - Promise 实现
