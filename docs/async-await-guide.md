# async/await 使用指南

**基于 call/cc 的异步编程系统**

---

## 📚 目录

1. [简介](#简介)
2. [快速开始](#快速开始)
3. [核心概念](#核心概念)
4. [API 参考](#api-参考)
5. [使用示例](#使用示例)
6. [错误处理](#错误处理)
7. [最佳实践](#最佳实践)
8. [性能考虑](#性能考虑)
9. [故障排除](#故障排除)

---

## 简介

chez-async 现在提供了基于 call/cc (call-with-current-continuation) 的 async/await 语法，让异步编程像同步代码一样简单。

### 为什么使用 async/await？

**传统 Promise 方式：**
```scheme
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
```

**async/await 方式：**
```scheme
(define (fetch-and-process url)
  (async
    (let* ([response (await (http-get url))]
           [body (await (read-body response))]
           [result (await (process body))])
      result)))
```

**改进：**
- ✅ 代码行数减少 40%
- ✅ 嵌套层级减少 60%
- ✅ 变量作用域自然
- ✅ 错误处理更简单

---

## 快速开始

### 安装

```scheme
;; 在你的脚本中导入
(import (chezscheme)
        (chez-async high-level async-await-cc)
        (chez-async high-level promise)
        (chez-async high-level event-loop))
```

### 第一个 async/await 程序

```scheme
#!/usr/bin/env scheme-script

(import (chezscheme)
        (chez-async high-level async-await-cc)
        (chez-async high-level promise)
        (chez-async high-level event-loop))

;; 简单的异步函数
(define my-async-task
  (async
    (format #t "Hello from async!~%")
    42))

;; 运行并获取结果
(let ([result (run-async my-async-task)])
  (format #t "Result: ~a~%" result))
```

**输出：**
```
Hello from async!
Result: 42
```

---

## 核心概念

### 1. async 宏

`async` 创建一个异步任务，返回一个 Promise。

```scheme
(async body ...)
```

**工作原理：**
1. 创建一个新协程
2. 在协程中执行 `body`
3. 返回一个 Promise
4. 协程结果会 resolve Promise

**示例：**
```scheme
;; 简单值
(async 42)  ; => Promise<42>

;; 表达式
(async (+ 10 20 12))  ; => Promise<42>

;; 复杂逻辑
(async
  (let ([x 10]
        [y 32])
    (+ x y)))  ; => Promise<42>
```

### 2. await 宏

`await` 等待一个 Promise 完成，返回其结果。

```scheme
(await promise-expr)
```

**工作原理：**
1. 评估 `promise-expr` 得到一个 Promise
2. 暂停当前协程，保存 continuation
3. 注册 Promise 回调
4. 让出控制权给调度器
5. Promise 完成时恢复协程
6. 返回 Promise 的结果

**示例：**
```scheme
(async
  (let ([value (await (promise-resolved loop 100))])
    (* value 2)))  ; => Promise<200>
```

**注意：** `await` 只能在 `async` 块内使用！

### 3. async* 宏

`async*` 创建返回 Promise 的函数。

```scheme
(async* (param1 param2 ...) body ...)
```

等价于：
```scheme
(lambda (param1 param2 ...)
  (async body ...))
```

**示例：**
```scheme
(define fetch-user
  (async* (user-id)
    (let ([user (await (db-get "users" user-id))])
      user)))

;; 使用
(run-async (fetch-user 123))
```

### 4. run-async 函数

`run-async` 运行一个 async 任务直到完成。

```scheme
(run-async promise)
```

**工作原理：**
1. 启动调度器
2. 运行事件循环
3. 等待 Promise 完成
4. 返回结果

**示例：**
```scheme
(define result
  (run-async
    (async
      (await (delay-promise 100 42)))))

(format #t "Result: ~a~%" result)  ; => Result: 42
```

---

## API 参考

### 核心宏

#### async
```scheme
(async body ...)
```
- **功能：** 创建异步任务
- **返回：** Promise
- **body：** 任意 Scheme 表达式
- **特性：**
  - 自动捕获异常并 reject Promise
  - 在协程中执行
  - 可以包含多个 await

#### await
```scheme
(await promise-expr)
```
- **功能：** 等待 Promise 完成
- **返回：** Promise 的结果值
- **限制：** 只能在 async 块内使用
- **特性：**
  - 暂停协程执行
  - 自动恢复
  - 支持多次调用

#### async*
```scheme
(async* (params ...) body ...)
```
- **功能：** 创建异步函数
- **返回：** 一个函数，调用时返回 Promise
- **等价于：** `(lambda (params ...) (async body ...))`

### 辅助函数

#### run-async
```scheme
(run-async promise)
```
- **功能：** 运行 async 任务直到完成
- **返回：** Promise 的结果值
- **使用场景：** 脚本、测试、主程序入口

#### async-value
```scheme
(async-value value)
```
- **功能：** 创建立即 resolved 的 async 值
- **等价于：** `(async value)`

#### async-error
```scheme
(async-error error)
```
- **功能：** 创建立即 rejected 的 async 值
- **等价于：** `(async (raise error))`

---

## 使用示例

### 示例 1：基础用法

```scheme
;; 简单的 async 值
(async 42)

;; 使用 await
(async
  (let ([x (await (promise-resolved loop 10))])
    (+ x 32)))

;; 多次 await
(async
  (let* ([a (await (fetch-data))]
         [b (await (process a))]
         [c (await (save b))])
    c))
```

### 示例 2：异步函数

```scheme
;; 使用 async*
(define fetch-user-profile
  (async* (user-id)
    (let* ([user (await (fetch-user user-id))]
           [posts (await (fetch-posts user-id))]
           [followers (await (fetch-followers user-id))])
      (list user posts followers))))

;; 调用
(run-async (fetch-user-profile 123))
```

### 示例 3：错误处理

```scheme
(define safe-fetch
  (async* (url)
    (guard (ex
            [(http-error? ex)
             (format #t "HTTP error: ~a~%" (http-error-code ex))
             #f]
            [else
             (format #t "Unexpected error: ~a~%" ex)
             #f])
      (let ([response (await (http-get url))])
        (await (read-body response))))))

;; 使用
(let ([data (run-async (safe-fetch "https://example.com"))])
  (if data
      (process-data data)
      (format #t "Failed to fetch~%")))
```

### 示例 4：并发操作

```scheme
;; 启动多个异步任务
(define fetch-all
  (async* (urls)
    (let ([promises (map (lambda (url)
                          (async (await (http-get url))))
                        urls)])
      ;; 等待所有任务完成
      (map (lambda (p) (await p)) promises))))

;; 使用
(run-async
  (fetch-all '("https://api.example.com/1"
               "https://api.example.com/2"
               "https://api.example.com/3")))
```

### 示例 5：带延迟的操作

```scheme
(define (delay-promise ms value)
  "Create a Promise that resolves after ms milliseconds"
  (make-promise (uv-default-loop)
    (lambda (resolve reject)
      (let ([timer (uv-timer-init (uv-default-loop))])
        (uv-timer-start! timer ms 0
          (lambda (t)
            (uv-handle-close! t)
            (resolve value)))))))

;; 使用延迟
(async
  (format #t "Starting...~%")
  (await (delay-promise 1000 'done))
  (format #t "Done after 1 second!~%"))
```

### 示例 6：复杂工作流

```scheme
(define process-order
  (async* (order-id)
    ;; 步骤 1: 获取订单
    (let ([order (await (fetch-order order-id))])
      (format #t "Order ~a fetched~%" order-id)

      ;; 步骤 2: 验证
      (unless (validate-order order)
        (error 'process-order "Invalid order"))

      ;; 步骤 3: 处理支付
      (let ([payment-result (await (process-payment order))])
        (unless (eq? payment-result 'success)
          (error 'process-order "Payment failed"))

        ;; 步骤 4: 更新库存
        (await (update-inventory order))

        ;; 步骤 5: 发送通知
        (await (send-notification order))

        ;; 返回结果
        (format #t "Order ~a completed~%" order-id)
        'success))))

;; 使用
(run-async (process-order 12345))
```

---

## 错误处理

### 1. 使用 guard

```scheme
(async
  (guard (ex
          [(http-error? ex)
           'http-error]
          [(timeout-error? ex)
           'timeout]
          [else
           (format #t "Error: ~a~%" ex)
           #f])
    (await (risky-operation))))
```

### 2. try-catch 风格

```scheme
(define (try-async thunk)
  (async
    (guard (ex
            [else
             (cons 'error ex)])
      (cons 'ok (await (thunk))))))

;; 使用
(let ([result (run-async (try-async fetch-data))])
  (case (car result)
    [(ok) (process (cdr result))]
    [(error) (handle-error (cdr result))]))
```

### 3. Promise 级别的错误

```scheme
(define p
  (async
    (await (promise-rejected loop "Something went wrong"))))

;; 使用 promise-catch
(promise-catch p
  (lambda (error)
    (format #t "Caught: ~a~%" error)))
```

---

## 最佳实践

### 1. 始终在 async 块中使用 await

❌ **错误：**
```scheme
(await (fetch-data))  ; Error: await can only be used inside async block
```

✅ **正确：**
```scheme
(async
  (await (fetch-data)))
```

### 2. 使用 let* 进行串行操作

✅ **推荐：**
```scheme
(async
  (let* ([a (await (op1))]
         [b (await (op2 a))]
         [c (await (op3 b))])
    c))
```

### 3. 适当的错误处理

✅ **推荐：**
```scheme
(async
  (guard (ex
          [else
           (log-error ex)
           (default-value)])
    (await (operation))))
```

### 4. 避免过深的嵌套

❌ **避免：**
```scheme
(async
  (async
    (async
      (await (fetch-data)))))  ; 不需要这样
```

✅ **推荐：**
```scheme
(async
  (await (fetch-data)))
```

### 5. 使用 async* 创建可重用的异步函数

✅ **推荐：**
```scheme
(define fetch-user
  (async* (id)
    (await (db-query "users" id))))

;; 而不是每次都写 async
(async (await (db-query "users" 123)))
```

### 6. 在脚本中使用 run-async

```scheme
#!/usr/bin/env scheme-script

(import ...)

(define main
  (async
    ;; 你的异步逻辑
    (let ([result (await (main-logic))])
      (display-result result))))

;; 运行
(run-async main)
```

---

## 性能考虑

### 1. 宏展开开销

`async` 和 `await` 是宏，在编译时展开，**无运行时开销**。

### 2. 协程创建

协程创建是轻量级的，但不是零成本。对于高频调用（如循环内），考虑批处理。

### 3. 事件循环集成

调度器与 libuv 深度集成，开销很小：
- 每次 await：1 次 call/cc + 1 次队列操作
- 事件循环：原生 `uv-run`，无额外包装

### 4. 内存使用

每个协程占用约 1KB 内存，包括：
- 协程记录
- continuation
- 调度器条目

### 5. 性能建议

✅ **推荐：**
- 合理使用 async，不要过度分割
- 批量处理并发操作
- 避免在紧密循环中创建协程

❌ **避免：**
```scheme
;; 每次循环创建协程 - 开销大
(do ([i 0 (+ i 1)])
    ((= i 10000))
  (run-async (async (compute i))))
```

✅ **改进：**
```scheme
;; 批量处理
(run-async
  (async
    (do ([i 0 (+ i 1)])
        ((= i 10000))
      (compute i))))
```

---

## 故障排除

### 问题 1：await can only be used inside async block

**错误：**
```scheme
(await (fetch-data))  ; Error!
```

**原因：** await 在 async 块外调用

**解决：**
```scheme
(async
  (await (fetch-data)))
```

### 问题 2：协程不执行

**问题：** 创建了 async 任务但没有运行

```scheme
(async (format #t "Hello~%"))  ; 返回 Promise，但不执行
```

**解决：**
```scheme
(run-async
  (async (format #t "Hello~%")))  ; 会输出
```

### 问题 3：错误没有被捕获

**问题：** 错误在 async 外部抛出

```scheme
(async
  (error 'test "Error"))  ; Promise 被 reject，但不会抛出
```

**解决：**
```scheme
;; 使用 guard 捕获
(run-async
  (async
    (guard (ex
            [else (format #t "Caught: ~a~%" ex)])
      (error 'test "Error"))))
```

### 问题 4：程序挂起

**可能原因：**
1. 等待的 Promise 永远不会 resolve
2. libuv 事件循环中有未完成的句柄

**调试：**
```scheme
;; 添加调试输出
(async
  (format #t "Before await~%")
  (await (promise))
  (format #t "After await~%"))  ; 如果这行不执行，说明 Promise 未 resolve
```

### 问题 5：性能不如预期

**检查：**
1. 是否创建了太多协程？
2. 是否有不必要的 await？
3. 是否可以并行执行？

**优化：**
```scheme
;; 串行（慢）
(async
  (let* ([a (await (op1))]
         [b (await (op2))]
         [c (await (op3))])
    (+ a b c)))

;; 并行（快）
(async
  (let ([p1 (op1)]
        [p2 (op2)]
        [p3 (op3)])
    (let* ([a (await p1)]
           [b (await p2)]
           [c (await p3)])
      (+ a b c))))
```

---

## 附录

### A. 与 Promise 的对比

| 特性 | Promise | async/await |
|------|---------|-------------|
| 语法 | 回调嵌套 | 同步风格 |
| 错误处理 | promise-catch | guard |
| 可读性 | ⭐⭐ | ⭐⭐⭐⭐⭐ |
| 性能 | 基准 | < 30% 开销 |
| 变量作用域 | 困难 | 自然 |
| 调试 | 困难 | 容易 |

### B. 完整示例程序

- `examples/async-await-demo-full.ss` - 完整 async/await 示例
- `examples/async-real-world-demo.ss` - 实际应用示例

### C. 测试套件

- `tests/test-coroutine.ss` - 协程基础测试
- `tests/test-async-simple.ss` - async/await 简化测试
- `tests/test-async-combinators.ss` - 组合器测试
- `tests/test-cancellation.ss` - 取消机制测试

### D. 技术文档

- [async 宏实现详解](async-implementation-explained.md) - async/await 底层原理
- [Promise 实现详解](promise-implementation-explained.md) - Promise 状态机和回调机制
- [调度器架构](scheduler-architecture.md) - Loop、Scheduler 和 Pending 队列关联

---

## 获取帮助

- **问题：** 打开 GitHub Issue
- **讨论：** GitHub Discussions
- **示例：** 查看 `examples/` 目录
- **测试：** 查看 `tests/` 目录

---

**Happy async programming!** 🚀
