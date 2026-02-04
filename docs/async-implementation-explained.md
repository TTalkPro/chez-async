# async 宏的实现原理详解

**创建日期：** 2026-02-05
**核心文件：** `high-level/async-await.ss`, `internal/scheduler.ss`, `internal/coroutine.ss`

---

## 🎯 核心概念

`async` 宏将同步风格的代码转换为异步执行的协程，返回一个 Promise。它使用 **call/cc**（call-with-current-continuation）实现真正的协程暂停和恢复。

### 关键机制

```
async 宏 → Promise → 协程 → call/cc → 调度器 → libuv 事件循环
```

---

## 📋 完整实现分析

### 1. async 宏的定义

**位置：** `high-level/async-await.ss:65-83`

```scheme
(define-syntax async
  (syntax-rules ()
    [(async body ...)
     (let ([loop (uv-default-loop)])
       ;; 创建 Promise 包装协程
       (make-promise loop
         (lambda (resolve reject)
           ;; 生成协程
           (spawn-coroutine! loop
             (lambda ()
               ;; 捕获异常
               (guard (ex
                       [else
                        ;; 拒绝 Promise
                        (reject ex)])
                 ;; 执行 body
                 (let ([result (begin body ...)])
                   ;; 解决 Promise
                   (resolve result))))))))]))
```

### 实现步骤解析

#### 步骤 1：获取事件循环
```scheme
(let ([loop (uv-default-loop)])
  ...)
```

#### 步骤 2：创建 Promise 包装
```scheme
(make-promise loop
  (lambda (resolve reject)
    ...))
```
- 返回一个 Promise 给调用者
- `resolve` 函数用于返回成功结果
- `reject` 函数用于返回错误

#### 步骤 3：生成协程
```scheme
(spawn-coroutine! loop
  (lambda ()
    ...))
```
- 创建新协程并加入可运行队列
- 协程内部执行 `body ...`

#### 步骤 4：异常处理
```scheme
(guard (ex
        [else (reject ex)])
  (let ([result (begin body ...)])
    (resolve result)))
```
- 捕获 body 中的任何异常
- 异常自动 reject Promise
- 正常结果 resolve Promise

---

## 🔄 协程生命周期

### spawn-coroutine! 实现

**位置：** `internal/scheduler.ss:138-178`

```scheme
(define (spawn-coroutine! loop thunk)
  "创建新协程并加入可运行队列"
  (let* ([sched (get-scheduler loop)]
         [coro (make-coroutine loop)])

    ;; 包装 thunk，设置当前协程并处理错误
    (let ([wrapped-thunk
           (lambda ()
             (parameterize ([current-coroutine coro])
               (guard (ex
                       [else
                        ;; 捕获未处理的异常
                        (coroutine-state-set! coro 'failed)
                        (coroutine-result-set! coro ex)
                        ...])
                 (let ([result (thunk)])
                   (coroutine-state-set! coro 'completed)
                   (coroutine-result-set! coro result)
                   result))))])

      ;; 保存 thunk 作为初始 continuation
      (coroutine-continuation-set! coro wrapped-thunk)

      ;; 加入可运行队列
      (queue-enqueue! (scheduler-state-runnable sched) coro)

      coro)))
```

### 协程状态机

```
created → running → suspended → running → completed/failed
   ↑                    ↓           ↑
   └────────────────────┴───────────┘
          (通过 call/cc 实现)
```

**状态说明：**
- `created`: 已创建，尚未运行
- `running`: 正在运行
- `suspended`: 已暂停（在 await 时）
- `completed`: 成功完成
- `failed`: 执行失败

---

## ⏸️ await 的实现

### await 宏定义

**位置：** `high-level/async-await.ss:47-56`

```scheme
(define-syntax await
  (syntax-rules ()
    [(await promise-expr)
     (let ([promise promise-expr])
       ;; 检查是否在协程中
       (if (current-coroutine)
           ;; 在协程中，暂停等待
           (suspend-for-promise! promise)
           ;; 不在协程中，报错
           (error 'await "await can only be used inside async block")))]))
```

### suspend-for-promise! 实现

**位置：** `internal/scheduler.ss:184-229`

```scheme
(define (suspend-for-promise! promise)
  "暂停当前协程，等待 Promise 完成"
  (let ([coro (current-coroutine)])
    (unless coro
      (error 'suspend-for-promise! "No current coroutine"))

    (let* ([loop (coroutine-loop coro)]
           [sched (get-scheduler loop)])

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
              (let ([error-wrapper (cons 'promise-error error)])
                (resume-coroutine! sched coro error-wrapper #t))))

          ;; 4. 跳回调度器
          (let ([scheduler-k (scheduler-state-scheduler-k sched)])
            (if scheduler-k
                (scheduler-k (void))  ; 跳回调度器
                (error 'suspend-for-promise!
                       "No scheduler continuation available"))))))))
```

### call/cc 工作原理

**call/cc 捕获执行点：**

```scheme
;; 执行流程示例
(async
  (let ([x (await promise1)])   ; ← call/cc 在这里捕获 continuation
    (+ x 10)))                   ; ← 这是 continuation k 的内容

;; 当 Promise 完成时：
;; (k result) 会恢复执行，result 成为 x 的值
```

**continuation k 的含义：**
- k 是"当前执行点之后的所有代码"
- 调用 `(k value)` 相当于"从这里继续执行，并且让 await 表达式返回 value"

---

## 🎮 调度器工作流程

### run-scheduler 实现

**位置：** `internal/scheduler.ss:311-349`

```scheme
(define (run-scheduler loop)
  "运行调度器直到所有协程完成"
  (let ([sched (get-scheduler loop)])
    (let scheduler-loop ()
      ;; 保存调度器 continuation（供 suspend-for-promise! 跳回）
      (call/cc
        (lambda (k)
          (scheduler-state-scheduler-k-set! sched k)))

      (cond
        ;; 情况 1: 有可运行的协程
        [(queue-not-empty? (scheduler-state-runnable sched))
         (let ([coro (queue-dequeue! (scheduler-state-runnable sched))])
           (guard (ex
                   [else
                    (format #t "[Scheduler] Error: ~a~%" ex)
                    (coroutine-state-set! coro 'failed)
                    (coroutine-result-set! coro ex)])
             (run-coroutine! sched coro))
           (scheduler-loop))]

        ;; 情况 2: 有等待中的协程，运行事件循环
        [(> (hashtable-size (scheduler-state-pending sched)) 0)
         (uv-run loop 'once)  ; 处理 I/O 事件
         (scheduler-loop)]

        ;; 情况 3: 所有协程完成
        [else
         (values)]))))
```

### 调度循环图解

```
┌─────────────────────────────────────┐
│     run-scheduler 开始              │
│   (保存调度器 continuation)          │
└───────────────┬─────────────────────┘
                ↓
        ┌───────────────┐
        │ 队列有协程？   │
        └───────┬───────┘
                ↓ 是
        ┌───────────────┐
        │ 取出一个协程   │
        └───────┬───────┘
                ↓
        ┌───────────────┐
        │ run-coroutine! │
        └───────┬───────┘
                ↓
        ┌───────────────────┐
        │ 协程遇到 await？   │
        └───────┬───────────┘
                ↓ 是
        ┌──────────────────────┐
        │ suspend-for-promise! │
        │  (call/cc 保存点)    │
        └───────┬──────────────┘
                ↓
        ┌───────────────────────┐
        │ 跳回调度器 (scheduler-k)│
        └───────┬───────────────┘
                ↓
        ┌───────────────┐
        │ 检查队列...    │← 循环回去
        └───────────────┘
                ↓ 队列空但有 pending
        ┌───────────────┐
        │ uv-run 'once   │  处理 I/O
        └───────┬───────┘
                ↓ Promise 完成时
        ┌────────────────────┐
        │ resume-coroutine!  │
        │ (加入可运行队列)    │
        └───────┬────────────┘
                ↓
        回到"队列有协程？"
```

---

## 📊 数据结构

### 协程记录

**位置：** `internal/coroutine.ss:61-73`

```scheme
(define-record-type coroutine
  (fields
    (immutable id)          ; 唯一标识符 (symbol)
    (mutable state)         ; 协程状态 ('created | 'running | 'suspended | 'completed | 'failed)
    (mutable continuation)  ; call/cc 捕获的 continuation
    (mutable result)        ; 执行结果或错误
    (immutable loop))       ; 关联的 uv-loop
  ...)
```

### 调度器状态

**位置：** `internal/scheduler.ss:87-102`

```scheme
(define-record-type scheduler-state
  (fields
    (mutable runnable)      ; (queue coroutine) - 可运行协程队列
    (mutable pending)       ; (hashtable promise -> coroutine) - 等待中的协程
    (mutable current)       ; coroutine - 当前运行的协程
    (mutable scheduler-k)   ; continuation - 调度器 continuation（用于逃逸）
    (immutable loop))       ; uv-loop - 关联的事件循环
  ...)
```

---

## 🔍 完整执行流程示例

### 示例代码

```scheme
(define (fetch-user id)
  (async
    (let* ([user (await (db-query id))]
           [posts (await (db-query-posts user))])
      (list user posts))))

(run-async (fetch-user 123))
```

### 详细执行步骤

#### 1. async 宏展开

```scheme
(make-promise (uv-default-loop)
  (lambda (resolve reject)
    (spawn-coroutine! (uv-default-loop)
      (lambda ()
        (guard (ex [else (reject ex)])
          (let ([result (begin
                          (let* ([user (await (db-query id))]
                                 [posts (await (db-query-posts user))])
                            (list user posts)))])
            (resolve result)))))))
```

#### 2. spawn-coroutine! 创建协程

```
协程 coro-1:
  - state: created
  - continuation: wrapped-thunk
  - 加入 runnable 队列
```

#### 3. run-async 启动调度器

```scheme
(run-scheduler loop)  ; 开始调度循环
```

#### 4. 调度器执行协程

```
run-scheduler:
  → run-coroutine! coro-1
  → 执行 wrapped-thunk
  → 开始执行 body
```

#### 5. 第一个 await

```scheme
(await (db-query id))
  ↓
suspend-for-promise!:
  1. call/cc 捕获 continuation k1
  2. k1 = (lambda (user) (let* ([posts (await ...)] ...) ...))
  3. coro-1.state = suspended
  4. coro-1.continuation = k1
  5. pending[promise1] = coro-1
  6. promise-then promise1 success→(resume-coroutine! ... user #f)
  7. scheduler-k (void)  ; 跳回调度器
```

#### 6. 调度器检查队列

```
runnable 队列: 空
pending 表: {promise1 → coro-1}
  → uv-run loop 'once  ; 等待 I/O
```

#### 7. Promise 完成触发回调

```
promise1 完成，值为 {name: "Alice"}:
  → (resume-coroutine! sched coro-1 {name: "Alice"} #f)
  → coro-1.state = running
  → coro-1.result = {name: "Alice"}
  → 加入 runnable 队列
```

#### 8. 调度器恢复协程

```
run-coroutine! coro-1:
  → k1 = coro-1.continuation
  → (k1 {name: "Alice"})  ; 恢复执行
  → user 绑定为 {name: "Alice"}
  → 继续执行到第二个 await
```

#### 9. 第二个 await（重复步骤 5-8）

```scheme
(await (db-query-posts user))
  → suspend-for-promise!
  → 捕获 k2 = (lambda (posts) (list user posts))
  → 跳回调度器
  → 等待 promise2
  → promise2 完成
  → 恢复，posts 绑定
```

#### 10. 协程完成

```scheme
(list user posts)
  → [{name: "Alice"}, [...]]
  → (resolve [{name: "Alice"}, [...]])
  → Promise 被 fulfill
  → coro-1.state = completed
```

#### 11. run-async 返回结果

```scheme
(promise-wait promise)
  → [{name: "Alice"}, [...]]
```

---

## 🎯 关键设计点

### 1. call/cc 实现协程暂停

```scheme
;; 暂停点
(call/cc (lambda (k) ...))

;; k 是"从这里继续执行"的函数
;; 保存 k，稍后调用 (k value) 恢复执行
```

### 2. 两个 continuation

- **协程 continuation (k)**：await 点之后的代码
- **调度器 continuation (scheduler-k)**：调度器循环的入口

```
协程 ──(suspend)──> scheduler-k ──> 调度器继续
  ↑                                    │
  └────────(resume via k)───── Promise 完成
```

### 3. parameterize 管理当前协程

```scheme
(parameterize ([current-coroutine coro])
  ...)
```
- 自动设置/恢复线程局部变量
- await 可以访问 (current-coroutine)

### 4. Promise 与协程的桥接

```scheme
;; Promise 完成 → 恢复协程
(promise-then promise
  (lambda (value)
    (resume-coroutine! sched coro value #f)))
```

---

## 🔧 async* 宏

**位置：** `high-level/async-await.ss:98-102`

```scheme
(define-syntax async*
  (syntax-rules ()
    [(async* (params ...) body ...)
     (lambda (params ...)
       (async body ...))]))
```

### 展开示例

```scheme
;; 源代码
(define fetch-url
  (async* (url)
    (await (http-get url))))

;; 展开为
(define fetch-url
  (lambda (url)
    (async
      (await (http-get url)))))
```

---

## ⚡ 性能特性

### 1. 零开销抽象（相对于手写 CPS）

- call/cc 是 Chez Scheme 原生支持
- 没有额外的闭包分配（在 async 边界处）

### 2. 协程调度开销

- 队列操作：O(1) enqueue，O(1) dequeue
- 哈希表查找：O(1) 平均
- 每次暂停/恢复：~2 次 call/cc 调用

### 3. 内存使用

- 每个协程：~200 字节（记录 + continuation）
- Continuation 大小：取决于调用栈深度
- Pending 表：按活跃 Promise 数量线性增长

---

## 🆚 与 JavaScript async/await 对比

| 特性 | Chez Scheme (本实现) | JavaScript |
|------|---------------------|------------|
| 暂停机制 | call/cc | Generator (内部) |
| 返回值 | Promise (自实现) | Promise (原生) |
| 错误处理 | guard / Promise reject | try-catch / Promise reject |
| 调度器 | 显式 (run-scheduler) | 隐式 (事件循环) |
| 事件循环 | libuv (显式集成) | 浏览器/Node.js (内置) |
| 协程可见性 | 暴露协程对象 | 完全隐藏 |

---

## 🎓 总结

### async 宏做了什么

1. **包装代码为 Promise**
   ```scheme
   (async body) → (make-promise loop (lambda (resolve reject) ...))
   ```

2. **在协程中执行**
   ```scheme
   (spawn-coroutine! loop (lambda () body))
   ```

3. **自动处理异常**
   ```scheme
   (guard (ex [else (reject ex)]) ...)
   ```

4. **resolve 结果**
   ```scheme
   (resolve result)
   ```

### await 宏做了什么

1. **检查协程上下文**
   ```scheme
   (current-coroutine) → coro 或 #f
   ```

2. **暂停协程**
   ```scheme
   (suspend-for-promise! promise)
     → call/cc 捕获 continuation
     → 跳回调度器
   ```

3. **等待 Promise**
   ```scheme
   (promise-then promise resume-callback error-callback)
   ```

4. **恢复时返回值**
   ```scheme
   (k value) → await 表达式的值
   ```

### 调度器做了什么

1. **管理协程生命周期**
   - Runnable 队列（待执行）
   - Pending 表（等待中）

2. **执行协程**
   ```scheme
   (run-coroutine! sched coro)
   ```

3. **处理 I/O 事件**
   ```scheme
   (uv-run loop 'once)
   ```

4. **恢复暂停的协程**
   ```scheme
   (resume-coroutine! sched coro value is-error?)
   ```

---

## 📚 相关文档

- **Promise 实现：** `docs/promise-implementation-explained.md`
- **使用指南：** `docs/async-await-guide.md`
- **TCP 示例：** `docs/tcp-with-async-await.md`
- **调度器源码：** `internal/scheduler.ss`
- **协程源码：** `internal/coroutine.ss`

---

**核心思想：** 使用 call/cc 捕获"执行的剩余部分"，将其保存起来，在 Promise 完成时恢复执行。这样就能用同步的代码风格写异步逻辑！

**创建完成：** 2026-02-05
**理解 async，掌握协程的精髓！** 🚀
