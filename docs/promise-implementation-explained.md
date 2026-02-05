# Promise 实现原理详解

**文档版本：** 1.0
**日期：** 2026-02-04

---

## 📚 概述

本文档详细解释 `make-promise` 的实现原理，包括数据结构、状态管理、回调机制等。

---

## 🏗️ 核心数据结构

### Promise 记录类型

```scheme
(define-record-type promise-record
  (fields
    (mutable state)           ; 状态：'pending | 'fulfilled | 'rejected
    (mutable value)           ; 成功时的值
    (mutable reason)          ; 失败时的原因
    (mutable on-fulfilled)    ; 成功回调列表
    (mutable on-rejected)     ; 失败回调列表
    (mutable loop))           ; 关联的事件循环
  (protocol
    (lambda (new)
      (lambda (loop)
        (new 'pending #f #f '() '() loop)))))
```

**字段说明：**

1. **state**：Promise 的当前状态
   - `'pending`：初始状态，等待中
   - `'fulfilled`：成功完成
   - `'rejected`：失败

2. **value**：成功时的结果值

3. **reason**：失败时的原因（错误）

4. **on-fulfilled**：成功回调函数列表
   - 存储所有通过 `promise-then` 注册的成功回调
   - 当 Promise fulfill 时，依次调用这些回调

5. **on-rejected**：失败回调函数列表
   - 存储所有通过 `promise-then` 注册的失败回调
   - 当 Promise reject 时，依次调用这些回调

6. **loop**：关联的 libuv 事件循环
   - 用于调度回调执行

---

## 🔧 make-promise 实现

### 完整实现

```scheme
(define make-promise
  (case-lambda
    [(executor)
     ;; 使用默认事件循环
     (make-promise (uv-default-loop) executor)]
    [(loop executor)
     "创建新的 Promise
      loop: 事件循环
      executor: (lambda (resolve reject) ...) 执行器函数"
     (let* ([promise (make-promise-record loop)]
            [resolve (lambda (value)
                       (if (promise? value)
                           ;; 如果 resolve 的值是另一个 promise，等待它
                           (promise-then value
                             (lambda (v) (fulfill-promise! promise v))
                             (lambda (r) (reject-promise! promise r)))
                           (fulfill-promise! promise value)))]
            [reject (lambda (reason)
                      (reject-promise! promise reason))])
       ;; 立即执行 executor
       (guard (e [else (reject e)])
         (executor resolve reject))
       promise)]))
```

### 执行步骤分解

#### 步骤 1：创建 Promise 记录

```scheme
[promise (make-promise-record loop)]
```

创建一个新的 Promise 对象，初始状态为 `'pending`。

#### 步骤 2：创建 resolve 函数

```scheme
[resolve (lambda (value)
           (if (promise? value)
               ;; Promise 解析：如果 value 是 Promise，等待它
               (promise-then value
                 (lambda (v) (fulfill-promise! promise v))
                 (lambda (r) (reject-promise! promise r)))
               ;; 直接值：立即 fulfill
               (fulfill-promise! promise value)))]
```

**关键特性：** Promise 解析（Promise Resolution）

- 如果 `resolve` 的值是另一个 Promise，会等待那个 Promise 完成
- 这就是为什么可以写 `resolve(anotherPromise)` 的原因

#### 步骤 3：创建 reject 函数

```scheme
[reject (lambda (reason)
          (reject-promise! promise reason))]
```

简单地将 Promise 标记为 rejected。

#### 步骤 4：执行 executor

```scheme
(guard (e [else (reject e)])
  (executor resolve reject))
```

- 立即执行用户提供的 executor 函数
- 如果 executor 抛出异常，自动 reject Promise
- 这就是为什么不需要 try-catch 的原因

#### 步骤 5：返回 Promise

```scheme
promise
```

返回创建的 Promise 对象。

---

## ⚙️ 内部机制

### 1. fulfill-promise! - 成功完成

```scheme
(define (fulfill-promise! promise value)
  "将 promise 标记为成功完成"
  (when (eq? (promise-record-state promise) 'pending)
    ;; 1. 更新状态
    (promise-record-state-set! promise 'fulfilled)
    (promise-record-value-set! promise value)

    ;; 2. 调度所有成功回调
    (let ([loop (promise-record-loop promise)])
      (for-each
        (lambda (callback)
          (schedule-microtask loop
            (lambda () (callback value))))
        (promise-record-on-fulfilled promise)))

    ;; 3. 清空回调列表
    (promise-record-on-fulfilled-set! promise '())
    (promise-record-on-rejected-set! promise '())))
```

**关键点：**

1. **状态检查**：只有 pending 状态才能转换
   - 这确保了 Promise 的不可变性（一旦 settled 就不能改变）

2. **异步调度**：使用 `schedule-microtask`
   - 回调不是立即执行，而是在下一个事件循环迭代
   - 这符合 Promise/A+ 规范

3. **清空回调**：执行后清空列表
   - 防止内存泄漏
   - 已 settled 的 Promise 不再需要保存回调

### 2. reject-promise! - 失败

```scheme
(define (reject-promise! promise reason)
  "将 promise 标记为失败"
  (when (eq? (promise-record-state promise) 'pending)
    ;; 1. 更新状态
    (promise-record-state-set! promise 'rejected)
    (promise-record-reason-set! promise reason)

    ;; 2. 调度所有失败回调
    (let ([loop (promise-record-loop promise)])
      (for-each
        (lambda (callback)
          (schedule-microtask loop
            (lambda () (callback reason))))
        (promise-record-on-rejected promise)))

    ;; 3. 清空回调列表
    (promise-record-on-fulfilled-set! promise '())
    (promise-record-on-rejected-set! promise '())))
```

工作原理与 `fulfill-promise!` 相同，只是处理的是失败情况。

### 3. schedule-microtask - 微任务调度

```scheme
(define (schedule-microtask loop thunk)
  "在下一个事件循环迭代中执行 thunk"
  ;; 使用 0ms 定时器模拟微任务
  (let ([timer (uv-timer-init loop)])
    (uv-timer-start! timer 0 0
      (lambda (t)
        (uv-handle-close! t)
        (thunk)))))
```

**实现原理：**

1. 创建一个 0ms 的定时器
2. 定时器在下一个事件循环迭代触发
3. 执行回调后关闭定时器

**为什么需要微任务？**

- 确保回调异步执行
- 避免栈溢出
- 符合 Promise 规范

---

## 🔄 promise-then 实现

### 完整实现

```scheme
(define promise-then
  (case-lambda
    [(promise on-fulfilled)
     (promise-then promise on-fulfilled #f)]
    [(promise on-fulfilled on-rejected)
     (let* ([loop (promise-record-loop promise)]
            [new-promise (make-promise-record loop)])
       (letrec
         ([handle-fulfilled
            (lambda (value)
              (if on-fulfilled
                  (guard (e [else (reject-promise! new-promise e)])
                    (let ([result (on-fulfilled value)])
                      (if (promise? result)
                          ;; 返回值是 Promise，等待它
                          (promise-then result
                            (lambda (v) (fulfill-promise! new-promise v))
                            (lambda (r) (reject-promise! new-promise r)))
                          ;; 普通值，直接 fulfill
                          (fulfill-promise! new-promise result))))
                  ;; 没有回调，传递值
                  (fulfill-promise! new-promise value)))]
          [handle-rejected
            (lambda (reason)
              (if on-rejected
                  (guard (e [else (reject-promise! new-promise e)])
                    (let ([result (on-rejected reason)])
                      (if (promise? result)
                          (promise-then result
                            (lambda (v) (fulfill-promise! new-promise v))
                            (lambda (r) (reject-promise! new-promise r)))
                          (fulfill-promise! new-promise result))))
                  ;; 没有回调，传递错误
                  (reject-promise! new-promise reason)))])

         ;; 根据当前状态处理
         (case (promise-record-state promise)
           [(fulfilled)
            ;; 已完成，立即调度回调
            (schedule-microtask loop
              (lambda () (handle-fulfilled (promise-record-value promise))))]
           [(rejected)
            ;; 已失败，立即调度回调
            (schedule-microtask loop
              (lambda () (handle-rejected (promise-record-reason promise))))]
           [(pending)
            ;; 还在等待，注册回调
            (promise-record-on-fulfilled-set! promise
              (cons handle-fulfilled (promise-record-on-fulfilled promise)))
            (promise-record-on-rejected-set! promise
              (cons handle-rejected (promise-record-on-rejected promise)))]))
       new-promise)]))
```

### 关键特性

#### 1. 返回新 Promise

```scheme
[new-promise (make-promise-record loop)]
```

- `promise-then` 总是返回一个新的 Promise
- 这使得链式调用成为可能

#### 2. Promise 链

```scheme
(let ([result (on-fulfilled value)])
  (if (promise? result)
      ;; 等待返回的 Promise
      (promise-then result
        (lambda (v) (fulfill-promise! new-promise v))
        (lambda (r) (reject-promise! new-promise r)))
      ;; 直接使用返回值
      (fulfill-promise! new-promise result)))
```

**这就是 Promise 链的核心！**

- 如果回调返回 Promise，等待它完成
- 如果回调返回普通值，直接 fulfill

#### 3. 错误传播

```scheme
(guard (e [else (reject-promise! new-promise e)])
  (let ([result (on-fulfilled value)])
    ...))
```

- 回调中的异常会自动 reject 新 Promise
- 这就是为什么错误会自动传播的原因

#### 4. 值传递

```scheme
(if on-fulfilled
    ;; 有回调，执行它
    ...
    ;; 没有回调，直接传递值
    (fulfill-promise! new-promise value))
```

- 如果没有提供回调，值/错误会自动传递到下一个 Promise
- 这使得 `.then(null)` 可以工作

---

## 📊 状态转换图

```
        ┌─────────────┐
        │   pending   │  ← 初始状态
        └─────────────┘
              │
              │ resolve(value)
              ├──────────────────┐
              │                  │ reject(reason)
              ▼                  ▼
     ┌──────────────┐   ┌──────────────┐
     │  fulfilled   │   │   rejected   │
     └──────────────┘   └──────────────┘
           终态                终态
```

**规则：**
- 只能从 `pending` 转换到 `fulfilled` 或 `rejected`
- 一旦 settled（fulfilled 或 rejected），状态不可改变
- 这保证了 Promise 的不可变性

---

## 🎯 使用示例

### 示例 1：基础创建

```scheme
(define p
  (make-promise
    (lambda (resolve reject)
      ;; 异步操作
      (uv-timer-start! timer 1000 0
        (lambda (t)
          (resolve "完成！"))))))

;; Promise 立即返回，处于 pending 状态
;; 1 秒后变为 fulfilled，值为 "完成！"
```

### 示例 2：立即 resolve

```scheme
(define p
  (make-promise
    (lambda (resolve reject)
      ;; 立即 resolve
      (resolve 42))))

;; Promise 立即变为 fulfilled（异步调度回调）
```

### 示例 3：错误处理

```scheme
(define p
  (make-promise
    (lambda (resolve reject)
      ;; executor 中抛出错误
      (error "出错了"))))

;; Promise 自动变为 rejected
```

### 示例 4：Promise 解析

```scheme
(define p1 (make-promise (lambda (r _) (r 42))))
(define p2
  (make-promise
    (lambda (resolve reject)
      ;; resolve 另一个 Promise
      (resolve p1))))

;; p2 会等待 p1 完成
;; 最终 p2 的值也是 42
```

### 示例 5：链式调用

```scheme
(promise-then
  (make-promise (lambda (r _) (r 10)))
  (lambda (x)
    (format #t "第一个 then: ~a~%" x)
    (* x 2)))

;; 返回新的 Promise，值为 20
```

---

## 🔬 内部执行流程

### 场景：创建并 resolve 一个 Promise

```scheme
(define p
  (make-promise
    (lambda (resolve reject)
      (resolve 42))))

(promise-then p
  (lambda (value)
    (format #t "Value: ~a~%" value)))

(uv-run loop 'default)
```

**执行流程：**

1. **T0** - 创建 Promise
   ```
   promise = {
     state: 'pending,
     value: #f,
     on-fulfilled: [],
     on-rejected: []
   }
   ```

2. **T1** - 执行 executor
   ```
   executor 调用 resolve(42)
   ```

3. **T2** - fulfill-promise! 被调用
   ```
   promise.state = 'fulfilled
   promise.value = 42
   on-fulfilled = []  (暂时没有回调)
   ```

4. **T3** - 注册回调（通过 promise-then）
   ```
   因为 Promise 已经 fulfilled，
   立即调度回调到下一个事件循环迭代
   ```

5. **T4** - 下一个事件循环迭代
   ```
   执行回调：(lambda (value) ...)
   输出：Value: 42
   ```

### 场景：Promise 链

```scheme
(promise-then
  (promise-then
    (make-promise (lambda (r _) (r 10)))
    (lambda (x) (* x 2)))
  (lambda (x) (+ x 5)))
```

**执行流程：**

1. **创建 p1**
   ```scheme
   p1 = make-promise(...)  ; resolve(10)
   ```

2. **第一个 then**
   ```scheme
   p2 = promise-then p1 (lambda (x) (* x 2))
   ; p2 等待 p1
   ```

3. **第二个 then**
   ```scheme
   p3 = promise-then p2 (lambda (x) (+ x 5))
   ; p3 等待 p2
   ```

4. **p1 完成**
   ```
   p1.state = 'fulfilled
   p1.value = 10
   触发 p2 的回调
   ```

5. **p2 回调执行**
   ```scheme
   result = (* 10 2)  ; 20
   p2.state = 'fulfilled
   p2.value = 20
   触发 p3 的回调
   ```

6. **p3 回调执行**
   ```scheme
   result = (+ 20 5)  ; 25
   p3.state = 'fulfilled
   p3.value = 25
   ```

### 场景：Promise resolve 与协程调度器的完整链路

这是 `await` 背后最关键的流程——从 libuv I/O 事件到协程恢复的完整链路。

以 `async-sleep` 为例：

```scheme
(async
  (await (async-sleep 1000))
  (printf "Done~n"))
```

**阶段 1：创建 Promise，executor 把 resolve 藏在 libuv 回调里**

```scheme
;; async-sleep 内部
(make-promise loop
  (lambda (resolve reject)
    (let ([timer (uv-timer-init loop)])
      (uv-timer-start! timer 1000 0
        (lambda (t)                    ; ← libuv 定时器回调
          (uv-handle-close! t)
          (resolve (void)))))))        ; ← resolve 被藏在这里
```

此时 Promise 处于 pending 状态，`resolve` 闭包捕获了这个 Promise 对象。

**阶段 2：await 注册 on-fulfilled 回调**

`suspend-for-promise!` 调用 `promise-then` 注册回调：

```scheme
(promise-then promise
  (lambda (value)
    (resume-coroutine! sched coro value #f))    ; ← on-fulfilled 回调
  (lambda (error)
    (resume-coroutine! sched coro ... #t)))
```

因为 Promise 还是 pending，回调被追加到 `on-fulfilled` 列表：

```
promise = {
  state: 'pending,
  on-fulfilled: [resume-coroutine!-wrapper],
  on-rejected:  [resume-coroutine!-wrapper]
}
```

**阶段 3：协程挂起，跳回调度器**

```scheme
(scheduler-k (void))   ; 跳回调度器主循环
```

调度器继续执行其他协程，或者运行 `(uv-run loop 'once)` 等待 I/O。

**阶段 4：libuv 定时器到期，触发 resolve**

1000ms 后，`uv-run` 执行定时器回调：

```
libuv 定时器到期
  → 回调: (lambda (t) ... (resolve (void)))
    → resolve 调用 fulfill-promise!
```

**阶段 5：fulfill-promise! 调度已注册的回调**

```scheme
(fulfill-promise! promise (void))
  ;; 状态: pending → fulfilled
  ;; 遍历 on-fulfilled 列表，每个回调用 schedule-microtask 调度
  (schedule-microtask loop
    (lambda () (resume-coroutine! sched coro (void) #f)))
```

注意这里用了 `schedule-microtask`（0ms 定时器），不是直接调用。

**阶段 6：0ms 定时器触发 resume-coroutine!**

下一次 `uv-run` 迭代执行 0ms 定时器：

```scheme
(resume-coroutine! sched coro (void) #f)
  ;; 从 pending 表移除协程
  ;; 协程放入 runnable 队列
```

**阶段 7：调度器取出协程，恢复执行**

```scheme
(run-coroutine! sched coro)
  ;; 调用保存的 continuation: (k (void))
  ;; 协程从 await 处恢复，(void) 成为 await 的返回值
  ;; 继续执行 (printf "Done~n")
```

**完整链路图**：

```
用户代码: (await (async-sleep 1000))
  │
  ├─ make-promise: resolve 闭包 → 藏在 timer 回调里
  ├─ promise-then: resume-coroutine! → 注册到 on-fulfilled 列表
  ├─ call/cc: 保存协程 continuation
  └─ scheduler-k: 跳回调度器
       │
       └─ (uv-run loop 'once) × N 次
            │
            └─ 1000ms 后 timer 到期
                 │
                 └─ (resolve (void))
                      │
                      └─ fulfill-promise!
                           │
                           ├─ state: pending → fulfilled
                           └─ schedule-microtask: resume-coroutine!
                                │
                                └─ 0ms timer 触发
                                     │
                                     └─ resume-coroutine!
                                          │
                                          ├─ pending 表移除
                                          └─ runnable 队列入队
                                               │
                                               └─ run-coroutine!
                                                    │
                                                    └─ (k (void))
                                                         │
                                                         └─ await 返回，继续执行
```

---

## 💡 设计亮点

### 1. 状态机设计

Promise 的三种状态和转换规则确保了：
- 不可变性
- 可预测性
- 线程安全（单线程环境）

### 2. 回调队列

使用列表存储回调：
```scheme
on-fulfilled: '(callback1 callback2 callback3)
```

好处：
- 支持多个监听者
- 按注册顺序执行
- 内存高效（settled 后清空）

### 3. 微任务机制

使用 0ms 定时器模拟微任务：
- 确保异步执行
- 避免栈溢出
- 与事件循环集成

### 4. Promise 解析

支持 `resolve(anotherPromise)`：
- 自动等待嵌套 Promise
- 扁平化 Promise 链
- 避免 Promise 包装 Promise

### 5. 自动错误传播

异常自动 reject Promise：
```scheme
(guard (e [else (reject e)])
  (executor resolve reject))
```

- 无需手动 try-catch
- 错误自动传播到链的末端
- 符合"fail fast"原则

---

## 📈 性能考虑

### 内存使用

**每个 Promise 占用：**
- 1 个记录结构（固定大小）
- 2 个回调列表（动态大小）
- 1 个状态值
- 1-2 个结果值

**优化：**
- settled 后清空回调列表
- 使用列表而非向量（节省内存）

### 执行开销

**创建 Promise：** O(1)
- 分配记录
- 执行 executor

**注册回调：** O(1)
- cons 到列表头部

**fulfill/reject：** O(n)
- n = 回调数量
- 遍历并调度所有回调

**总体：** 对于大多数使用场景，开销可忽略不计

---

## 🎓 与 JavaScript Promise 的对比

### 相同点

✅ 三种状态（pending/fulfilled/rejected）
✅ 状态不可变
✅ 链式调用
✅ 自动错误传播
✅ Promise 解析

### 不同点

| 特性 | JavaScript | chez-async |
|------|-----------|------------|
| 微任务 | 原生微任务队列 | 0ms 定时器模拟 |
| 错误处理 | UnhandledRejection | 需要 catch 或等待时处理 |
| 执行时机 | 立即（同步） | 立即（同步） |
| then 返回 | 新 Promise | 新 Promise |

---

## 📝 总结

### make-promise 的核心

1. **数据结构**：记录类型保存状态和回调
2. **状态管理**：pending → fulfilled/rejected
3. **回调机制**：队列 + 微任务调度
4. **链式调用**：每个 then 返回新 Promise
5. **错误处理**：自动捕获和传播

### 为什么这样设计？

- ✅ **简单**：清晰的状态机
- ✅ **可靠**：不可变状态
- ✅ **高效**：最小化内存和开销
- ✅ **标准**：符合 Promise/A+ 规范
- ✅ **可组合**：支持链式和组合器

### 关键技术

- 闭包（capture resolve/reject）
- 列表（回调队列）
- 定时器（微任务模拟）
- 递归（Promise 解析）
- 状态机（状态转换）

---

**实现文件：** `high-level/promise.ss`
**相关文档：** `docs/async-await-guide.md`
