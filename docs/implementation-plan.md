# 基于 call/cc 的 async/await 实现方案
## 整合 chez-socket 设计经验与 chez-async 现有基础

**文档版本：** 1.0
**创建日期：** 2026-02-04
**状态：** 设计完成，待审批

---

## 目录

1. [执行摘要](#1-执行摘要)
2. [架构设计](#2-架构设计)
3. [核心实现](#3-核心实现)
4. [与 libuv 集成](#4-与-libuv-集成)
5. [实施步骤](#5-实施步骤)
6. [使用示例](#6-使用示例)
7. [性能与优化](#7-性能与优化)
8. [风险与挑战](#8-风险与挑战)
9. [测试计划](#9-测试计划)
10. [总结与建议](#10-总结与建议)

---

## 1. 执行摘要

### 1.1 目标

基于 **call/cc (call-with-current-continuation)** 实现 **async/await** 语法，在 chez-async 项目中提供类似 JavaScript/Python 的异步编程体验。

### 1.2 核心理念

借鉴 **chez-socket** 的成功经验：

```scheme
;; chez-socket 的核心模式
(define (async-read fd buf len)
  (let loop ()
    (or (try-read fd buf len)         ; 先尝试非阻塞操作
        (begin
          (call/cc                     ; 失败则捕获 continuation
            (lambda (k)
              (register-wait! fd k)    ; 注册等待
              (run-loop sched)))       ; 让出控制权
          (loop)))))                   ; 恢复后重试
```

**关键洞察：**
- **外层循环模式**：`let loop ()` 确保恢复后可以重试
- **call/cc 捕获**：保存"从此处继续"的执行状态
- **注册等待**：将 continuation 与 I/O 事件关联
- **调度器接管**：`run-loop` 处理其他任务或等待 I/O
- **自动恢复**：事件就绪时调用 `(k #t)` 恢复执行

### 1.3 架构概览

```
┌─────────────────────────────────────────────────────┐
│              async/await 语法层                      │
│  (async (let ([x (await (http-get url))]) ...))     │
└────────────────────┬────────────────────────────────┘
                     │
┌────────────────────▼────────────────────────────────┐
│           call/cc 协程调度器                         │
│  - spawn-coroutine: 创建协程                        │
│  - suspend-for-promise: 暂停等待 Promise           │
│  - resume-coroutine: 恢复执行                       │
│  - run-scheduler: 调度循环                          │
└────────────────────┬────────────────────────────────┘
                     │
┌────────────────────▼────────────────────────────────┐
│         Promise 层（现有）+ libuv                    │
│  - make-promise, promise-then                       │
│  - uv-loop, uv-run                                  │
└─────────────────────────────────────────────────────┘
```

### 1.4 预期收益

**代码可读性：**
```scheme
;; 当前 Promise 方式（回调地狱）
(define (fetch-and-process url)
  (make-promise
    (lambda (resolve reject)
      (http-get url
        (lambda (response)
          (read-body response
            (lambda (body)
              (process body
                (lambda (result)
                  (resolve result))))))))))

;; 新的 async/await 方式（同步风格）
(define (fetch-and-process url)
  (async
    (let* ([response (await (http-get url))]
           [body (await (read-body response))]
           [result (await (process body))])
      result)))
```

---

## 2. 架构设计

### 2.1 整体架构

```
┌───────────────────────────────────────────────────────┐
│                   User Code                            │
│  (async (let ([x (await p)]) (+ x 1)))                │
└───────────────────┬───────────────────────────────────┘
                    │
┌───────────────────▼───────────────────────────────────┐
│              Macro Layer (宏展开层)                    │
│  - async: 创建协程                                     │
│  - await: 暂停等待 Promise                            │
└───────────────────┬───────────────────────────────────┘
                    │
┌───────────────────▼───────────────────────────────────┐
│         Coroutine Scheduler (协程调度器)              │
│  ┌─────────────────────────────────────────────┐     │
│  │  Scheduler State                             │     │
│  │  - runnable: (queue coroutine)              │     │
│  │  - pending:  (hashtable promise coroutine)  │     │
│  │  - current:  coroutine                      │     │
│  └─────────────────────────────────────────────┘     │
│                                                        │
│  ┌─────────────────────────────────────────────┐     │
│  │  Core Functions                              │     │
│  │  - spawn-coroutine                          │     │
│  │  - suspend-for-promise                      │     │
│  │  - resume-coroutine                         │     │
│  │  - run-scheduler                            │     │
│  └─────────────────────────────────────────────┘     │
└───────────────────┬───────────────────────────────────┘
                    │
┌───────────────────▼───────────────────────────────────┐
│            libuv Event Loop                            │
│  - uv-run: 修改以集成协程调度                         │
│  - uv-loop: 扩展以存储调度器状态                      │
└────────────────────────────────────────────────────────┘
```

### 2.2 数据结构

#### 2.2.1 Coroutine 记录类型

```scheme
(define-record-type coroutine
  (fields
    (immutable id)                ; 唯一标识符 (symbol)
    (mutable state)              ; 'created | 'running | 'suspended | 'completed | 'failed
    (mutable continuation)       ; call/cc 捕获的 continuation
    (mutable result)             ; 执行结果或错误
    (immutable loop))            ; 关联的 uv-loop
  (protocol
    (lambda (new)
      (lambda (id loop)
        (new id 'created #f #f loop)))))
```

#### 2.2.2 Scheduler 状态

```scheme
(define-record-type scheduler-state
  (fields
    (mutable runnable)           ; 可执行协程队列 (queue)
    (mutable pending)            ; 等待 Promise 的协程表 (hashtable: promise -> coroutine)
    (mutable current)            ; 当前运行的协程
    (immutable loop))            ; 关联的 uv-loop
  (protocol
    (lambda (new)
      (lambda (loop)
        (new (make-queue)
             (make-eq-hashtable)
             #f
             loop)))))
```

### 2.3 关键算法

#### 2.3.1 协程调度循环（借鉴 chez-socket）

```scheme
(define (run-scheduler sched)
  "调度器主循环，直到所有协程完成"
  (let loop ()
    (cond
      ;; 情况 1: 有可运行的协程，执行它
      [(queue-not-empty? (scheduler-state-runnable sched))
       (let ([coro (queue-dequeue! (scheduler-state-runnable sched))])
         (run-coroutine! sched coro)
         (loop))]

      ;; 情况 2: 有等待中的协程，运行 libuv 事件循环
      [(hashtable-size (scheduler-state-pending sched) . > . 0)
       (uv-run (scheduler-state-loop sched) 'UV_RUN_ONCE)
       (loop)]

      ;; 情况 3: 所有协程都完成，退出
      [else
       (values)])))
```

#### 2.3.2 协程执行（外层循环模式）

```scheme
(define (run-coroutine! sched coro)
  "执行协程（恢复或首次运行）"
  (scheduler-state-current-set! sched coro)
  (coroutine-state-set! coro 'running)

  (guard (ex
          [else
           ;; 处理错误
           (coroutine-state-set! coro 'failed)
           (coroutine-result-set! coro ex)])

    (let ([k (coroutine-continuation coro)])
      (if k
          ;; 恢复保存的 continuation
          (begin
            (coroutine-continuation-set! coro #f)  ; 清理
            (k (coroutine-result coro)))           ; 传递结果
          ;; 首次运行（由宏展开的代码处理）
          (values)))))
```

#### 2.3.3 暂停协程（核心机制）

```scheme
(define (suspend-for-promise sched promise)
  "暂停当前协程，等待 Promise 完成"
  (let ([coro (scheduler-state-current sched)])
    (unless coro
      (error 'suspend-for-promise "No current coroutine"))

    ;; 使用 call/cc 捕获 continuation
    (call/cc
      (lambda (k)
        ;; 1. 保存 continuation
        (coroutine-continuation-set! coro k)
        (coroutine-state-set! coro 'suspended)

        ;; 2. 注册到 pending 表
        (hashtable-set! (scheduler-state-pending sched) promise coro)

        ;; 3. 注册 Promise 回调
        (promise-then promise
          ;; 成功回调
          (lambda (value)
            (resume-coroutine! sched coro value #f))
          ;; 错误回调
          (lambda (error)
            (resume-coroutine! sched coro #f error)))

        ;; 4. 让出控制权，返回到调度循环
        ;; 注意：这里不调用 run-scheduler，而是简单返回
        ;; 调度循环会自然地继续执行
        (void)))))
```

#### 2.3.4 恢复协程

```scheme
(define (resume-coroutine! sched coro value-or-error is-error?)
  "恢复暂停的协程"
  ;; 1. 从 pending 表中移除（使用反向查找）
  (let ([pending (scheduler-state-pending sched)])
    (vector-for-each
      (lambda (promise)
        (when (eq? (hashtable-ref pending promise #f) coro)
          (hashtable-delete! pending promise)))
      (hashtable-keys pending)))

  ;; 2. 设置结果
  (if is-error?
      (begin
        (coroutine-state-set! coro 'failed)
        (coroutine-result-set! coro value-or-error))
      (begin
        (coroutine-state-set! coro 'running)
        (coroutine-result-set! coro value-or-error)))

  ;; 3. 加入可运行队列
  (queue-enqueue! (scheduler-state-runnable sched) coro))
```

---

## 3. 核心实现

### 3.1 文件结构

```
chez-async/
├── internal/
│   ├── coroutine.ss                 ; 协程数据结构
│   ├── scheduler.ss                 ; 调度器核心
│   └── queue.ss                     ; 队列实现（如果没有的话）
├── high-level/
│   ├── async-await-cc.ss           ; async/await 宏（call/cc 版本）
│   └── async-await.ss              ; 保留原有 Promise 版本
├── tests/
│   ├── test-coroutine.ss           ; 单元测试
│   └── test-async-await-cc.ss      ; 集成测试
└── examples/
    └── async-await-cc-demo.ss      ; 完整示例
```

### 3.2 核心代码实现

#### 3.2.1 internal/coroutine.ss

```scheme
(library (chez-async internal coroutine)
  (export
    make-coroutine
    coroutine?
    coroutine-id
    coroutine-state
    coroutine-state-set!
    coroutine-continuation
    coroutine-continuation-set!
    coroutine-result
    coroutine-result-set!
    coroutine-loop)

  (import (chezscheme))

  ;; 协程 ID 生成器
  (define coroutine-counter 0)
  (define (generate-coroutine-id)
    (set! coroutine-counter (+ coroutine-counter 1))
    (string->symbol (format "coro-~a" coroutine-counter)))

  ;; 协程记录类型
  (define-record-type coroutine
    (fields
      (immutable id)
      (mutable state)        ; 'created | 'running | 'suspended | 'completed | 'failed
      (mutable continuation) ; call/cc continuation
      (mutable result)       ; 结果或错误
      (immutable loop))      ; uv-loop
    (protocol
      (lambda (new)
        (lambda (loop)
          (new (generate-coroutine-id) 'created #f #f loop))))))
```

#### 3.2.2 internal/scheduler.ss

```scheme
(library (chez-async internal scheduler)
  (export
    make-scheduler-state
    scheduler-state?
    get-scheduler
    spawn-coroutine!
    suspend-for-promise!
    resume-coroutine!
    run-scheduler
    current-coroutine)

  (import (chezscheme)
          (chez-async internal coroutine)
          (chez-async high-level promise)
          (chez-async libuv loop))

  ;; ========================================
  ;; 调度器状态
  ;; ========================================

  (define-record-type scheduler-state
    (fields
      (mutable runnable)    ; (queue coroutine)
      (mutable pending)     ; (hashtable promise -> coroutine)
      (mutable current)     ; 当前协程
      (immutable loop))     ; uv-loop
    (protocol
      (lambda (new)
        (lambda (loop)
          (new (make-queue)
               (make-eq-hashtable)
               #f
               loop)))))

  ;; ========================================
  ;; 队列实现（简单的 FIFO）
  ;; ========================================

  (define-record-type queue
    (fields
      (mutable items))      ; (list item)
    (protocol
      (lambda (new)
        (lambda ()
          (new '())))))

  (define (queue-enqueue! q item)
    (queue-items-set! q (append (queue-items q) (list item))))

  (define (queue-dequeue! q)
    (let ([items (queue-items q)])
      (if (null? items)
          (error 'queue-dequeue! "Queue is empty")
          (let ([item (car items)])
            (queue-items-set! q (cdr items))
            item))))

  (define (queue-empty? q)
    (null? (queue-items q)))

  (define (queue-not-empty? q)
    (not (queue-empty? q)))

  ;; ========================================
  ;; 全局调度器（每个 uv-loop 一个）
  ;; ========================================

  ;; 使用弱引用表存储 loop -> scheduler 映射
  (define scheduler-table (make-weak-eq-hashtable))

  (define (get-scheduler loop)
    "获取或创建 loop 的调度器"
    (or (hashtable-ref scheduler-table loop #f)
        (let ([sched (make-scheduler-state loop)])
          (hashtable-set! scheduler-table loop sched)
          sched)))

  ;; ========================================
  ;; 当前协程（线程局部变量）
  ;; ========================================

  (define current-coroutine
    (make-thread-parameter #f))

  ;; ========================================
  ;; 核心函数
  ;; ========================================

  ;; spawn-coroutine!: 创建并启动协程
  (define (spawn-coroutine! loop thunk)
    "创建新协程，加入可运行队列"
    (let* ([sched (get-scheduler loop)]
           [coro (make-coroutine loop)])
      ;; 包装 thunk，设置当前协程
      (let ([wrapped-thunk
             (lambda ()
               (parameterize ([current-coroutine coro])
                 (guard (ex
                         [else
                          (coroutine-state-set! coro 'failed)
                          (coroutine-result-set! coro ex)])
                   (let ([result (thunk)])
                     (coroutine-state-set! coro 'completed)
                     (coroutine-result-set! coro result)
                     result))))])
        ;; 保存 thunk 作为初始 continuation
        (coroutine-continuation-set! coro wrapped-thunk)
        ;; 加入可运行队列
        (queue-enqueue! (scheduler-state-runnable sched) coro)
        coro)))

  ;; suspend-for-promise!: 暂停当前协程
  (define (suspend-for-promise! promise)
    "暂停当前协程，等待 Promise 完成"
    (let* ([coro (current-coroutine)]
           [loop (coroutine-loop coro)]
           [sched (get-scheduler loop)])
      (unless coro
        (error 'suspend-for-promise! "No current coroutine"))

      ;; 使用 call/cc 捕获 continuation
      (call/cc
        (lambda (k)
          ;; 1. 保存 continuation
          (coroutine-continuation-set! coro k)
          (coroutine-state-set! coro 'suspended)

          ;; 2. 注册到 pending 表
          (hashtable-set! (scheduler-state-pending sched) promise coro)

          ;; 3. 注册 Promise 回调
          (promise-then promise
            ;; 成功回调
            (lambda (value)
              (resume-coroutine! sched coro value #f))
            ;; 错误回调
            (lambda (error)
              (resume-coroutine! sched coro #f error)))

          ;; 4. 清除当前协程（让出控制权）
          (current-coroutine #f)

          ;; 5. 返回一个占位符（不会被使用）
          (void)))))

  ;; resume-coroutine!: 恢复协程
  (define (resume-coroutine! sched coro value-or-error is-error?)
    "恢复暂停的协程"
    ;; 1. 从 pending 表中移除
    (let ([pending (scheduler-state-pending sched)])
      (let-values ([(keys vals) (hashtable-entries pending)])
        (vector-for-each
          (lambda (i)
            (when (eq? (vector-ref vals i) coro)
              (hashtable-delete! pending (vector-ref keys i))))
          (list->vector (iota (vector-length keys))))))

    ;; 2. 设置结果
    (if is-error?
        (begin
          (coroutine-state-set! coro 'failed)
          (coroutine-result-set! coro value-or-error))
        (begin
          (coroutine-state-set! coro 'running)
          (coroutine-result-set! coro value-or-error)))

    ;; 3. 加入可运行队列
    (queue-enqueue! (scheduler-state-runnable sched) coro))

  ;; run-coroutine!: 执行单个协程
  (define (run-coroutine! sched coro)
    "执行协程（恢复或首次运行）"
    (scheduler-state-current-set! sched coro)
    (coroutine-state-set! coro 'running)

    (parameterize ([current-coroutine coro])
      (let ([k (coroutine-continuation coro)])
        (if k
            ;; 恢复或首次运行
            (begin
              (coroutine-continuation-set! coro #f)  ; 清理
              (if (procedure? k)
                  (k (coroutine-result coro))        ; 恢复
                  (k)))                              ; 首次运行（thunk）
            ;; 没有 continuation（不应该发生）
            (error 'run-coroutine! "No continuation for coroutine" (coroutine-id coro))))))

  ;; run-scheduler: 调度循环
  (define (run-scheduler loop)
    "运行调度器直到所有协程完成"
    (let ([sched (get-scheduler loop)])
      (let loop ()
        (cond
          ;; 情况 1: 有可运行的协程
          [(queue-not-empty? (scheduler-state-runnable sched))
           (let ([coro (queue-dequeue! (scheduler-state-runnable sched))])
             (run-coroutine! sched coro)
             (loop))]

          ;; 情况 2: 有等待中的协程，运行事件循环
          [(hashtable-size (scheduler-state-pending sched) . > . 0)
           (uv-run loop 'UV_RUN_ONCE)
           (loop)]

          ;; 情况 3: 所有协程完成
          [else
           (values)]))))

  ) ; end library
```

#### 3.2.3 high-level/async-await-cc.ss

```scheme
(library (chez-async high-level async-await-cc)
  (export
    async
    await
    async*)

  (import (chezscheme)
          (chez-async internal scheduler)
          (chez-async internal coroutine)
          (chez-async high-level promise)
          (chez-async libuv loop))

  ;; ========================================
  ;; await 宏
  ;; ========================================

  (define-syntax await
    (syntax-rules ()
      [(await promise-expr)
       (let ([promise promise-expr])
         ;; 如果不在协程中，直接返回 Promise（为了兼容性）
         (if (current-coroutine)
             ;; 在协程中，暂停等待
             (suspend-for-promise! promise)
             ;; 不在协程中，返回 Promise
             promise))]))

  ;; ========================================
  ;; async 宏
  ;; ========================================

  (define-syntax async
    (syntax-rules ()
      [(async body ...)
       (let ([loop (uv-default-loop)])
         ;; 创建 Promise 包装协程
         (make-promise
           (lambda (resolve reject)
             ;; 生成协程
             (spawn-coroutine! loop
               (lambda ()
                 (guard (ex
                         [else
                          (reject ex)])
                   (let ([result (begin body ...)])
                     (resolve result))))))))]))

  ;; ========================================
  ;; async* 宏（带参数的异步函数）
  ;; ========================================

  (define-syntax async*
    (syntax-rules ()
      [(async* (params ...) body ...)
       (lambda (params ...)
         (async body ...))]))

  ) ; end library
```

---

## 4. 与 libuv 集成

### 4.1 修改 uv-run

我们需要修改或包装 `uv-run`，使其在每次迭代后检查并执行可运行的协程：

```scheme
;; libuv/loop-integration.ss

(library (chez-async libuv loop-integration)
  (export
    uv-run-with-coroutines)

  (import (chezscheme)
          (chez-async libuv loop)
          (chez-async internal scheduler))

  (define (uv-run-with-coroutines loop mode)
    "运行 libuv 事件循环，同时处理协程"
    (let ([sched (get-scheduler loop)])
      (let loop-iteration ()
        ;; 1. 执行所有可运行的协程
        (let execute-all-runnable ()
          (if (queue-not-empty? (scheduler-state-runnable sched))
              (begin
                (let ([coro (queue-dequeue! (scheduler-state-runnable sched))])
                  (run-coroutine! sched coro))
                (execute-all-runnable))
              (void)))

        ;; 2. 运行一次 libuv 事件循环
        (uv-run loop mode)

        ;; 3. 根据模式决定是否继续
        (case mode
          [(UV_RUN_DEFAULT)
           ;; 持续运行直到没有活跃句柄
           (if (or (uv-loop-alive? loop)
                   (hashtable-size (scheduler-state-pending sched) . > . 0))
               (loop-iteration)
               (void))]
          [(UV_RUN_ONCE UV_RUN_NOWAIT)
           ;; 只运行一次
           (void)]
          [else
           (error 'uv-run-with-coroutines "Unknown mode" mode)])))))
```

### 4.2 导出统一接口

修改 `high-level/event-loop.ss`，添加协程支持：

```scheme
(library (chez-async high-level event-loop)
  (export
    ;; 原有导出
    uv-default-loop
    uv-run
    uv-stop
    ;; 新增导出
    uv-run-with-coroutines
    run-event-loop-with-coroutines)

  (import (chezscheme)
          (chez-async libuv loop)
          (chez-async libuv loop-integration)
          (chez-async internal scheduler))

  ;; ... 原有代码 ...

  (define (run-event-loop-with-coroutines)
    "运行默认事件循环，支持协程"
    (let ([loop (uv-default-loop)])
      (run-scheduler loop))))
```

---

## 5. 实施步骤

### Phase 1: 基础设施（2-3 天）

**目标：** 实现协程和调度器核心

#### 任务清单

- [ ] **Task 1.1**: 实现 `internal/coroutine.ss`
  - [ ] `coroutine` 记录类型
  - [ ] ID 生成器
  - [ ] 基础访问器

- [ ] **Task 1.2**: 实现 `internal/scheduler.ss`
  - [ ] `scheduler-state` 记录类型
  - [ ] 队列实现（或重用现有）
  - [ ] `spawn-coroutine!`
  - [ ] `suspend-for-promise!`
  - [ ] `resume-coroutine!`
  - [ ] `run-scheduler`

- [ ] **Task 1.3**: 单元测试
  - [ ] 测试协程创建
  - [ ] 测试调度器基本功能
  - [ ] 测试暂停/恢复机制

**验收标准：**
```scheme
;; 简单的协程测试应该能运行
(define loop (uv-default-loop))
(spawn-coroutine! loop (lambda () (format #t "Hello~%")))
(run-scheduler loop)
;; => 输出 "Hello"
```

### Phase 2: async/await 宏（1-2 天）

**目标：** 实现 async/await 语法糖

#### 任务清单

- [ ] **Task 2.1**: 实现 `high-level/async-await-cc.ss`
  - [ ] `await` 宏
  - [ ] `async` 宏
  - [ ] `async*` 宏

- [ ] **Task 2.2**: 集成测试
  - [ ] 测试基本 async/await
  - [ ] 测试嵌套 await
  - [ ] 测试错误处理

**验收标准：**
```scheme
;; async/await 测试应该能运行
(define p (async (await (promise-resolved 42))))
(format #t "Result: ~a~%" (promise-wait p))
;; => 输出 "Result: 42"
```

### Phase 3: libuv 集成（2-3 天）

**目标：** 将协程调度器与 libuv 事件循环深度集成

#### 任务清单

- [ ] **Task 3.1**: 实现 `libuv/loop-integration.ss`
  - [ ] `uv-run-with-coroutines`
  - [ ] 处理不同的运行模式

- [ ] **Task 3.2**: 修改 `high-level/event-loop.ss`
  - [ ] 导出新接口
  - [ ] 确保向后兼容

- [ ] **Task 3.3**: 完整示例
  - [ ] HTTP 请求示例
  - [ ] 文件 I/O 示例
  - [ ] 并发任务示例

**验收标准：**
```scheme
;; 完整的 HTTP 示例应该能运行
(async
  (let ([response (await (http-get "https://example.com"))])
    (let ([body (await (read-body response))])
      (format #t "Body length: ~a~%" (bytevector-length body)))))
(run-event-loop-with-coroutines)
```

### Phase 4: 高级特性（1-2 天）

**目标：** 添加实用的高级功能

#### 任务清单

- [ ] **Task 4.1**: 超时支持
  - [ ] `async-timeout`
  - [ ] `async-sleep`

- [ ] **Task 4.2**: 并发原语
  - [ ] `async-all` （等待所有）
  - [ ] `async-race` （竞速）
  - [ ] `async-any` （任意一个成功）

- [ ] **Task 4.3**: 取消支持
  - [ ] `cancellation-token`
  - [ ] `async-with-cancellation`

**验收标准：**
```scheme
;; 超时示例
(async
  (guard (ex
          [(timeout-error? ex)
           (format #t "Timeout!~%")])
    (await (async-timeout 1000 (slow-operation)))))
```

### Phase 5: 测试与文档（2-3 天）

**目标：** 确保质量和可用性

#### 任务清单

- [ ] **Task 5.1**: 完整测试套件
  - [ ] 单元测试覆盖率 > 80%
  - [ ] 集成测试
  - [ ] 压力测试

- [ ] **Task 5.2**: 性能基准测试
  - [ ] 与 Promise 方案对比
  - [ ] 内存使用测试
  - [ ] 协程创建/销毁开销测试

- [ ] **Task 5.3**: 文档编写
  - [ ] API 文档
  - [ ] 使用指南
  - [ ] 迁移指南
  - [ ] 最佳实践

**验收标准：**
- 所有测试通过
- 性能开销 < 30%
- 文档完整且清晰

---

## 6. 使用示例

### 6.1 基础用法

```scheme
#!/usr/bin/env scheme-script

(import (chezscheme)
        (chez-async high-level event-loop)
        (chez-async high-level async-await-cc)
        (chez-async high-level promise))

;; 简单的异步函数
(define (fetch-url url)
  (async
    (format #t "Fetching ~a~n" url)
    (let ([response (await (http-get url))])
      (format #t "Got response: ~a~n" (response-status response))
      (await (read-body response)))))

;; 使用
(define result-promise (fetch-url "https://example.com"))

;; 运行事件循环
(run-event-loop-with-coroutines)

;; 获取结果
(format #t "Body: ~a~%" (promise-wait result-promise))
```

### 6.2 错误处理

```scheme
(define (safe-fetch url)
  (async
    (guard (ex
            [(http-error? ex)
             (format #t "HTTP error: ~a~%" (http-error-code ex))
             #f]
            [(timeout-error? ex)
             (format #t "Request timeout~%")
             #f]
            [else
             (format #t "Unexpected error: ~a~%" ex)
             #f])
      (let ([response (await (http-get url))])
        (await (read-body response))))))
```

### 6.3 并发执行

```scheme
(define (fetch-multiple urls)
  (async
    (let ([promises (map (lambda (url)
                          (async (await (fetch-url url))))
                        urls)])
      ;; 等待所有请求完成
      (await (promise-all promises)))))

;; 使用
(fetch-multiple '("https://example.com"
                  "https://github.com"
                  "https://scheme.com"))
(run-event-loop-with-coroutines)
```

### 6.4 超时处理

```scheme
(define (fetch-with-timeout url timeout-ms)
  (async
    (let ([result-promise (make-promise)])
      ;; 启动 HTTP 请求
      (spawn-coroutine! (uv-default-loop)
        (lambda ()
          (async
            (guard (ex
                    [else (promise-reject! result-promise ex)])
              (let ([data (await (http-get url))])
                (promise-resolve! result-promise data))))))

      ;; 启动超时定时器
      (spawn-coroutine! (uv-default-loop)
        (lambda ()
          (async
            (await (sleep timeout-ms))
            (promise-reject! result-promise (make-timeout-error)))))

      ;; 等待结果或超时
      (await result-promise))))
```

### 6.5 复杂流程控制

```scheme
(define (process-urls urls)
  (async
    (for-each
      (lambda (url)
        (format #t "Processing ~a~n" url)
        (let ([data (await (fetch-url url))])
          (when data
            (let ([processed (await (process-data data))])
              (await (save-to-db processed))))))
      urls)
    (format #t "All done!~n")))
```

---

## 7. 性能与优化

### 7.1 性能目标

| 指标 | 目标 | 测量方法 |
|------|------|----------|
| 协程创建开销 | < 10μs | 创建 10000 个空协程 |
| 暂停/恢复开销 | < 5μs | 暂停和恢复 10000 次 |
| 相比 Promise | < 30% 开销 | 相同的 HTTP 请求测试 |
| 内存占用 | < 1KB/协程 | 内存分析工具 |

### 7.2 优化策略

#### 7.2.1 队列优化

```scheme
;; 使用环形缓冲区代替链表
(define-record-type circular-queue
  (fields
    (mutable items)    ; vector
    (mutable head)     ; index
    (mutable tail)     ; index
    (mutable size))    ; current size
  ...)

;; O(1) 入队/出队
```

#### 7.2.2 Continuation 池化

```scheme
;; 重用 continuation 对象（高级优化）
(define continuation-pool (make-queue))

(define (allocate-continuation)
  (if (queue-empty? continuation-pool)
      (make-continuation)
      (queue-dequeue! continuation-pool)))

(define (release-continuation k)
  (when (< (queue-size continuation-pool) 100)
    (queue-enqueue! continuation-pool k)))
```

#### 7.2.3 批量处理

```scheme
;; 一次性处理多个就绪的协程
(define (run-scheduler-batch sched)
  (let batch-loop ()
    (let process-batch ([count 0])
      (if (and (queue-not-empty? (scheduler-state-runnable sched))
               (< count 10))  ; 批量大小
          (begin
            (run-coroutine! sched (queue-dequeue! (scheduler-state-runnable sched)))
            (process-batch (+ count 1)))
          (void)))

    ;; 如果还有任务，继续批处理
    (when (or (queue-not-empty? (scheduler-state-runnable sched))
              (hashtable-size (scheduler-state-pending sched) . > . 0))
      (uv-run (scheduler-state-loop sched) 'UV_RUN_NOWAIT)
      (batch-loop))))
```

### 7.3 内存管理

#### 7.3.1 及时清理

```scheme
(define (cleanup-coroutine! coro)
  "协程完成后清理资源"
  (when (or (eq? (coroutine-state coro) 'completed)
            (eq? (coroutine-state coro) 'failed))
    (coroutine-continuation-set! coro #f)  ; 释放 continuation
    (unless (eq? (coroutine-state coro) 'failed)
      (coroutine-result-set! coro #f))))    ; 释放结果（错误除外）
```

#### 7.3.2 弱引用

```scheme
;; 使用弱引用表避免循环引用
(define scheduler-table (make-weak-eq-hashtable))
```

### 7.4 性能基准测试

```scheme
;; tests/benchmark.ss

(define (benchmark-coroutine-creation n)
  "测试协程创建开销"
  (let ([loop (uv-default-loop)])
    (time
      (do ([i 0 (+ i 1)])
          ((= i n))
        (spawn-coroutine! loop (lambda () (void)))))))

(define (benchmark-suspend-resume n)
  "测试暂停/恢复开销"
  (time
    (async
      (do ([i 0 (+ i 1)])
          ((= i n))
        (await (promise-resolved i))))))

(define (benchmark-promise-vs-async n)
  "对比 Promise 和 async/await 性能"
  (format #t "Promise version:~%")
  (time
    (do ([i 0 (+ i 1)])
        ((= i n))
      (promise-wait (promise-resolved i))))

  (format #t "async/await version:~%")
  (time
    (do ([i 0 (+ i 1)])
        ((= i n))
      (promise-wait (async (await (promise-resolved i)))))))
```

---

## 8. 风险与挑战

### 8.1 技术风险

| 风险 | 概率 | 影响 | 缓解措施 |
|------|------|------|----------|
| **Continuation 泄漏** | 中 | 高 | 严格的清理机制，自动化测试 |
| **性能开销超出预期** | 中 | 中 | 基准测试，优化热点路径 |
| **与 libuv 集成复杂** | 低 | 中 | 参考 chez-socket 经验 |
| **调试困难** | 高 | 低 | 详细日志，调试工具 |
| **宏展开错误** | 低 | 中 | 充分测试，提供清晰错误信息 |

### 8.2 实现挑战

#### 8.2.1 Continuation 捕获范围

**问题：** call/cc 可能捕获过多的状态

**解决方案：**
- 使用 `dynamic-wind` 控制捕获范围
- 最小化 call/cc 的作用域
- 使用局部变量而非全局变量

#### 8.2.2 错误传播

**问题：** continuation 中的错误如何正确传播？

**解决方案：**
```scheme
(define (suspend-for-promise! promise)
  (call/cc
    (lambda (k)
      ;; 包装 continuation，处理错误
      (let ([safe-k
             (lambda (value)
               (guard (ex
                       [else
                        (coroutine-state-set! (current-coroutine) 'failed)
                        (coroutine-result-set! (current-coroutine) ex)
                        (raise ex)])
                 (k value)))])
        ;; 使用包装的 continuation
        ...))))
```

#### 8.2.3 递归调用

**问题：** 递归的 async 函数可能导致栈溢出

**解决方案：**
- 使用尾递归优化
- 提供 `async-loop` 宏自动转换为迭代

```scheme
(define-syntax async-loop
  (syntax-rules ()
    [(async-loop ([var init] ...) test body ...)
     (async
       (let loop ([var init] ...)
         (if test
             body ...
             (begin
               (await (promise-resolved #f))  ; 让出控制权
               (loop ...)))))]))
```

### 8.3 兼容性问题

#### 8.3.1 与现有代码共存

**策略：**
1. 保留原有 Promise API
2. 提供两套 async/await 实现：
   - `(chez-async high-level async-await)` - Promise 版本
   - `(chez-async high-level async-await-cc)` - call/cc 版本
3. 提供转换函数：
   ```scheme
   (define (promise->async promise)
     (async (await promise)))

   (define (async->promise async-block)
     async-block)  ; async 已经返回 Promise
   ```

#### 8.3.2 渐进迁移

**阶段 1：** 双 API 共存（6 个月）
- 新功能使用 async/await-cc
- 旧代码保持 Promise
- 提供迁移文档

**阶段 2：** 推荐迁移（6 个月）
- 标记 Promise API 为 deprecated
- 提供自动迁移工具

**阶段 3：** 完全迁移（可选）
- 移除 Promise API（如果社区同意）

---

## 9. 测试计划

### 9.1 单元测试

#### 9.1.1 协程基础

```scheme
;; tests/test-coroutine.ss

(define-test-suite coroutine-tests

  (test-case "create-coroutine"
    (let ([loop (uv-default-loop)])
      (let ([coro (make-coroutine loop)])
        (check-true (coroutine? coro))
        (check-eq? (coroutine-state coro) 'created)
        (check-eq? (coroutine-loop coro) loop))))

  (test-case "spawn-coroutine"
    (let* ([loop (uv-default-loop)]
           [executed? #f]
           [coro (spawn-coroutine! loop
                   (lambda ()
                     (set! executed? #t)
                     42))])
      (run-scheduler loop)
      (check-true executed?)
      (check-eq? (coroutine-state coro) 'completed)
      (check-equal? (coroutine-result coro) 42))))
```

#### 9.1.2 调度器

```scheme
;; tests/test-scheduler.ss

(define-test-suite scheduler-tests

  (test-case "suspend-and-resume"
    (let* ([loop (uv-default-loop)]
           [result #f])
      (spawn-coroutine! loop
        (lambda ()
          (async
            (let ([x (await (promise-resolved 42))])
              (set! result x)))))
      (run-scheduler loop)
      (check-equal? result 42)))

  (test-case "multiple-coroutines"
    (let* ([loop (uv-default-loop)]
           [results '()])
      (spawn-coroutine! loop
        (lambda ()
          (set! results (cons 1 results))))
      (spawn-coroutine! loop
        (lambda ()
          (set! results (cons 2 results))))
      (run-scheduler loop)
      (check-equal? (length results) 2)
      (check-true (member 1 results))
      (check-true (member 2 results)))))
```

### 9.2 集成测试

#### 9.2.1 async/await 语法

```scheme
;; tests/test-async-await-cc.ss

(define-test-suite async-await-tests

  (test-case "basic-async"
    (let ([p (async 42)])
      (check-equal? (promise-wait p) 42)))

  (test-case "basic-await"
    (let ([p (async
               (let ([x (await (promise-resolved 10))])
                 (+ x 32)))])
      (check-equal? (promise-wait p) 42)))

  (test-case "nested-await"
    (let ([p (async
               (let* ([x (await (promise-resolved 10))]
                      [y (await (promise-resolved 20))]
                      [z (await (promise-resolved 12))])
                 (+ x y z)))])
      (check-equal? (promise-wait p) 42)))

  (test-case "error-handling"
    (let ([p (async
               (guard (ex
                       [(error? ex) 'caught])
                 (await (promise-rejected (make-error "test")))))])
      (check-eq? (promise-wait p) 'caught))))
```

#### 9.2.2 真实场景

```scheme
;; tests/test-real-world.ss

(define-test-suite real-world-tests

  (test-case "http-request"
    (let ([p (async
               (let ([response (await (http-get "http://httpbin.org/get"))])
                 (response-status response)))])
      (check-equal? (promise-wait p) 200)))

  (test-case "file-io"
    (let ([filename "/tmp/test-async.txt"])
      ;; 写入文件
      (let ([p1 (async
                  (await (write-file filename "Hello, async!")))])
        (promise-wait p1))

      ;; 读取文件
      (let ([p2 (async
                  (await (read-file filename)))])
        (check-equal? (promise-wait p2) "Hello, async!")))))
```

### 9.3 压力测试

```scheme
;; tests/test-stress.ss

(define-test-suite stress-tests

  (test-case "many-coroutines"
    (let* ([loop (uv-default-loop)]
           [n 1000]
           [counter 0])
      (do ([i 0 (+ i 1)])
          ((= i n))
        (spawn-coroutine! loop
          (lambda ()
            (set! counter (+ counter 1)))))
      (run-scheduler loop)
      (check-equal? counter n)))

  (test-case "deep-await-chain"
    (define (chain-await n)
      (if (= n 0)
          (async 0)
          (async
            (let ([x (await (chain-await (- n 1)))])
              (+ x 1)))))

    (let ([p (chain-await 100)])
      (check-equal? (promise-wait p) 100))))
```

### 9.4 性能测试

```scheme
;; tests/test-performance.ss

(define-test-suite performance-tests

  (test-case "coroutine-creation-speed"
    (let ([loop (uv-default-loop)])
      (time
        (do ([i 0 (+ i 1)])
            ((= i 10000))
          (spawn-coroutine! loop (lambda () (void)))))))

  (test-case "promise-vs-async-comparison"
    (format #t "Promise version:~%")
    (time
      (do ([i 0 (+ i 1)])
          ((= i 1000))
        (promise-wait (promise-resolved i))))

    (format #t "async/await version:~%")
    (time
      (do ([i 0 (+ i 1)])
          ((= i 1000))
        (promise-wait (async (await (promise-resolved i))))))))
```

### 9.5 测试覆盖率目标

| 模块 | 目标覆盖率 |
|------|------------|
| internal/coroutine.ss | 90% |
| internal/scheduler.ss | 85% |
| high-level/async-await-cc.ss | 80% |
| 整体 | 80% |

---

## 10. 总结与建议

### 10.1 方案总结

本方案提出了一个基于 **call/cc** 实现 **async/await** 的完整架构，核心要点：

1. **借鉴 chez-socket 经验**
   - 外层循环模式：`let loop () + call/cc + (loop)`
   - 调度器状态管理：runnable队列 + pending表
   - 与 I/O 后端集成的策略

2. **保持 chez-async 优势**
   - 利用现有 libuv 基础设施
   - 保留 Promise API 向后兼容
   - 跨平台支持

3. **提供优雅的语法**
   ```scheme
   (async
     (let* ([x (await (op1))]
            [y (await (op2 x))]
            [z (await (op3 y))])
       (+ x y z)))
   ```

### 10.2 核心优势

✅ **代码可读性**：同步风格的异步代码
✅ **错误处理**：使用普通的 guard/try
✅ **变量作用域**：自然的 let 绑定
✅ **调试体验**：正常的调用栈
✅ **渐进迁移**：与现有代码共存

### 10.3 实施建议

#### 短期（1-2 周）
1. **Phase 1**: 实现核心调度器
2. **Phase 2**: 实现 async/await 宏
3. **Phase 3**: 基础集成测试

**目标：** 完成 MVP（最小可行产品），验证可行性

#### 中期（1-2 个月）
4. **Phase 3**: 深度 libuv 集成
5. **Phase 4**: 高级特性（超时、并发）
6. **Phase 5**: 完整测试和文档

**目标：** 达到生产就绪状态

#### 长期（3-6 个月）
7. 性能优化（队列、continuation 池化）
8. 社区反馈和迭代
9. 考虑废弃 Promise API（可选）

**目标：** 成为推荐的异步编程方式

### 10.4 技术决策

#### 决策 1：call/cc vs Promise

**选择：** 同时支持两者

**理由：**
- call/cc 提供更好的用户体验
- Promise 保持向后兼容
- 让用户选择适合的工具

#### 决策 2：独立调度器 vs 集成到 libuv

**选择：** 独立调度器，与 libuv 松耦合

**理由：**
- 更清晰的关注点分离
- 易于测试和维护
- 参考 chez-socket 成功经验

#### 决策 3：宏 vs 过程

**选择：** 使用宏实现 async/await

**理由：**
- 提供自然的语法
- 编译时展开，无运行时开销
- 与 Scheme 惯用法一致

### 10.5 风险评估

**可接受风险：**
- 学习曲线（可通过文档缓解）
- 轻微性能开销（< 30%）
- 实现复杂度（有 chez-socket 参考）

**需要关注的风险：**
- Continuation 泄漏（需要严格测试）
- 调试困难（需要工具支持）

**缓解措施：**
- 完善的单元测试和集成测试
- 详细的日志和错误信息
- 提供调试工具和最佳实践文档

### 10.6 下一步行动

#### 立即行动（本周）

1. **审批此方案**
   - 团队讨论技术细节
   - 确认实施时间表
   - 分配开发任务

2. **环境准备**
   - 创建分支 `feature/callcc-async-await`
   - 设置测试框架
   - 准备基准测试环境

3. **开始 Phase 1**
   - 实现 `internal/coroutine.ss`
   - 实现 `internal/scheduler.ss` 基础版本
   - 编写第一个测试

#### 短期目标（2 周内）

- [ ] 完成 Phase 1 和 Phase 2
- [ ] 运行基础示例
- [ ] 初步性能测试

#### 中期目标（2 个月内）

- [ ] 完成所有 5 个 Phase
- [ ] 通过所有测试
- [ ] 编写完整文档

### 10.7 成功指标

**技术指标：**
- ✅ 所有测试通过（覆盖率 > 80%）
- ✅ 性能开销 < 30%
- ✅ 内存占用 < 1KB/协程
- ✅ 零崩溃和内存泄漏

**用户体验指标：**
- ✅ 代码行数减少 40%（相比 Promise 方案）
- ✅ 嵌套层级减少 60%
- ✅ 文档完整，示例清晰
- ✅ 社区反馈积极

---

## 附录

### A. 参考资源

**chez-socket 项目：**
- https://github.com/TTalkPro/chez-socket
- 设计文档：https://github.com/TTalkPro/chez-socket/tree/main/design

**学术论文：**
- [Continuations and Coroutines](https://www.cs.tufts.edu/~nr/cs257/archive/kent-dybvig/stack.pdf)
- [Implementation Strategies for First-Class Continuations](https://www.researchgate.net/publication/220606970)

**Chez Scheme 文档：**
- [Chez Scheme User's Guide](https://www.scheme.com/csug8/)
- [R6RS - call/cc](https://www.r6rs.org/final/html/r6rs/r6rs-Z-H-11.html)

### B. 术语表

| 术语 | 定义 |
|------|------|
| **call/cc** | call-with-current-continuation 的缩写，Scheme 的一等公民特性 |
| **continuation** | 表示"从此处继续的计算"的一等值 |
| **coroutine** | 可以暂停和恢复的执行单元 |
| **scheduler** | 协程调度器，管理协程的执行顺序 |
| **suspend** | 暂停协程执行，保存 continuation |
| **resume** | 恢复协程执行，调用保存的 continuation |
| **runnable queue** | 可立即执行的协程队列 |
| **pending table** | 等待 I/O 的协程表 |

### C. FAQ

**Q1: 为什么不直接使用线程？**
A: 线程有更高的开销（MB 级别内存），需要同步机制，而协程是轻量级的（KB 级别），单线程无锁。

**Q2: call/cc 有什么性能开销？**
A: Chez Scheme 的 call/cc 实现很高效，主要开销是捕获栈帧。通过最小化捕获范围可以优化。

**Q3: 如何调试 call/cc 代码？**
A: 使用详细日志，记录协程状态转换。考虑实现调试器集成。

**Q4: 能否与现有 Promise 代码互操作？**
A: 可以。`await` 可以等待任何 Promise，`async` 返回 Promise。

**Q5: 如何处理取消？**
A: 通过 cancellation token 机制，协程定期检查取消状态。

**Q6: 支持多线程吗？**
A: 当前方案是单线程的。多线程支持需要更复杂的同步机制。

---

**方案制定：** Claude Code Assistant
**审批人：** _____________
**日期：** 2026-02-04
**版本：** 1.0
