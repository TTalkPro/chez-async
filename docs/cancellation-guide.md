# 取消令牌使用指南

**创建日期：** 2026-02-05
**状态：** ✅ 已完成

---

## 📋 概述

取消令牌（Cancellation Token）提供了一种优雅的方式来取消正在进行的异步操作。类似于 C# 的 CancellationToken 和 JavaScript 的 AbortController。

### 核心概念

```scheme
(import (chez-async high-level cancellation))

;; 创建取消令牌源
(define cts (make-cancellation-token-source))

;; 获取令牌
(define token (cts-token cts))

;; 将操作与令牌关联
(async-with-cancellation token
  (long-running-operation))

;; 取消操作
(cts-cancel! cts)
```

---

## 🔑 核心 API

### CancellationTokenSource

**创建：**
```scheme
(make-cancellation-token-source) → cts
```

**操作：**
```scheme
(cts-token cts) → token          ; 获取关联的令牌
(cts-cancel! cts) → void          ; 取消令牌
(cts-cancelled? cts) → boolean    ; 检查是否已取消
```

### CancellationToken

```scheme
(token-cancelled? token) → boolean            ; 检查是否已取消
(token-register! token callback) → void       ; 注册取消回调
```

### 组合器

```scheme
(async-with-cancellation token promise) → promise  ; 可取消的异步操作
(linked-token-source token ...) → cts              ; 链接多个令牌
```

---

## 💡 使用示例

### 示例 1：基本使用

```scheme
(define cts (make-cancellation-token-source))

;; 启动长时间操作
(run-async
  (async
    (guard (ex
            [(operation-cancelled? ex)
             (format #t "Operation cancelled~%")])
      (await (async-with-cancellation (cts-token cts)
               (long-operation))))))

;; 用户点击取消按钮
(cts-cancel! cts)
```

### 示例 2：可取消的下载

```scheme
(define (cancellable-download url cts-token)
  "可取消的文件下载"
  (async
    (format #t "Downloading: ~a~%" url)

    ;; 将下载操作与令牌关联
    (await (async-with-cancellation cts-token
             (async
               ;; 模拟分块下载
               (let loop ([progress 0])
                 (when (< progress 100)
                   (format #t "Progress: ~a%~%" progress)
                   (await (async-sleep 100))
                   (loop (+ progress 10))))
               'download-complete)))

    (format #t "Download completed!~%")))

;; 使用
(let ([cts (make-cancellation-token-source)])
  ;; 启动下载
  (spawn-task
    (guard (ex
            [(operation-cancelled? ex)
             (format #t "Download cancelled by user~%")])
      (cancellable-download "http://example.com/file.zip"
                           (cts-token cts))))

  ;; 5 秒后自动取消
  (spawn-task
    (async
      (await (async-sleep 5000))
      (format #t "Timeout, cancelling...~%")
      (cts-cancel! cts))))
```

### 示例 3：带超时的操作

```scheme
(define (with-timeout-cancellation operation timeout-ms)
  "为操作添加超时取消"
  (async
    (let ([cts (make-cancellation-token-source)])
      ;; 设置超时
      (spawn-task
        (async
          (await (async-sleep timeout-ms))
          (cts-cancel! cts)))

      ;; 执行操作
      (await (async-with-cancellation (cts-token cts)
               operation)))))

;; 使用
(guard (ex
        [(operation-cancelled? ex)
         (format #t "Operation timed out~%")])
  (run-async
    (with-timeout-cancellation
      (slow-database-query)
      5000)))  ; 5 秒超时
```

### 示例 4：链接令牌

```scheme
(define (composite-operation user-cts-token timeout-ms)
  "组合用户取消和超时"
  (async
    (let* ([timeout-cts (make-cancellation-token-source)]
           [linked-cts (linked-token-source
                         user-cts-token
                         (cts-token timeout-cts))])

      ;; 设置超时
      (spawn-task
        (async
          (await (async-sleep timeout-ms))
          (cts-cancel! timeout-cts)))

      ;; 执行操作（用户取消或超时都会中止）
      (await (async-with-cancellation (cts-token linked-cts)
               (operation))))))

;; 使用
(let ([user-cts (make-cancellation-token-source)])
  (spawn-task
    (composite-operation (cts-token user-cts) 10000))

  ;; 用户可以随时取消
  (when user-wants-to-cancel?
    (cts-cancel! user-cts)))
```

### 示例 5：取消回调

```scheme
(define cts (make-cancellation-token-source))
(define token (cts-token cts))

;; 注册取消回调
(token-register! token
  (lambda ()
    (format #t "Cleaning up resources...~%")
    (close-file file-handle)
    (disconnect-socket socket)))

;; 稍后取消
(cts-cancel! cts)  ; → 触发清理回调
```

### 示例 6：批量操作的取消

```scheme
(define (process-batch-cancellable items cts-token)
  "可取消的批量处理"
  (async
    (let loop ([remaining items] [results '()])
      (if (null? remaining)
          (reverse results)
          (begin
            ;; 检查是否已取消
            (if (token-cancelled? cts-token)
                (begin
                  (format #t "Batch processing cancelled~%")
                  (raise (make-operation-cancelled-error)))
                (let ([item (car remaining)])
                  ;; 处理单个项目
                  (let ([result (await (process-item item))])
                    (loop (cdr remaining)
                          (cons result results))))))))))

;; 使用
(let ([cts (make-cancellation-token-source)])
  (spawn-task
    (guard (ex
            [(operation-cancelled? ex)
             (format #t "Cancelled at ~a items~%" processed-count)])
      (process-batch-cancellable items (cts-token cts))))

  ;; 用户取消
  (cts-cancel! cts))
```

---

## 🎯 实战场景

### 场景 1：搜索建议

```scheme
(define current-search-cts #f)

(define (search-suggestions query)
  "搜索建议，取消之前的搜索"
  (async
    ;; 取消之前的搜索
    (when current-search-cts
      (cts-cancel! current-search-cts))

    ;; 创建新的取消令牌
    (set! current-search-cts (make-cancellation-token-source))

    ;; 执行搜索
    (guard (ex
            [(operation-cancelled? ex)
             '()])  ; 返回空结果
      (await (async-with-cancellation (cts-token current-search-cts)
               (api-search query))))))

;; 用户输入时
(on-input
  (lambda (text)
    (run-async (search-suggestions text))))
```

### 场景 2：页面导航取消

```scheme
(define page-load-cts #f)

(define (load-page url)
  "加载页面，自动取消之前的加载"
  (async
    ;; 取消之前的页面加载
    (when page-load-cts
      (format #t "Cancelling previous page load~%")
      (cts-cancel! page-load-cts))

    ;; 创建新的令牌
    (set! page-load-cts (make-cancellation-token-source))

    ;; 加载页面资源
    (guard (ex
            [(operation-cancelled? ex)
             (format #t "Page load cancelled~%")
             #f])
      (let ([resources (await (async-with-cancellation
                                 (cts-token page-load-cts)
                                 (load-page-resources url)))])
        (render-page resources)))))
```

### 场景 3：WebSocket 连接

```scheme
(define (websocket-connection url cts-token)
  "可取消的 WebSocket 连接"
  (async
    (let ([socket (await (connect-websocket url))])
      ;; 注册取消回调以关闭连接
      (token-register! cts-token
        (lambda ()
          (format #t "Closing WebSocket...~%")
          (close-socket socket)))

      ;; 消息循环
      (let loop ()
        (unless (token-cancelled? cts-token)
          (let ([msg (await (receive-message socket))])
            (process-message msg)
            (loop)))))))

;; 使用
(let ([cts (make-cancellation-token-source)])
  (spawn-task
    (websocket-connection "ws://example.com" (cts-token cts)))

  ;; 页面卸载时取消
  (on-page-unload
    (lambda ()
      (cts-cancel! cts))))
```

---

## ⚠️ 注意事项

### 1. 取消是合作式的

取消令牌不会强制终止操作，操作需要主动检查取消状态：

```scheme
;; ❌ 不会被取消
(async-with-cancellation token
  (async
    (infinite-loop)))  ; 没有检查 token

;; ✅ 可以被取消
(async-with-cancellation token
  (async
    (let loop ()
      (unless (token-cancelled? token)
        (do-work)
        (loop)))))
```

### 2. 资源清理

使用取消回调确保资源被正确清理：

```scheme
(define token (cts-token cts))

;; 注册清理回调
(token-register! token
  (lambda ()
    (cleanup-resources)))

;; 执行操作
(async-with-cancellation token
  (use-resources))
```

### 3. 取消传播

取消不会自动传播到嵌套操作，需要显式传递令牌：

```scheme
;; ✅ 正确：传递令牌
(define (outer-operation token)
  (async
    (await (async-with-cancellation token
             (inner-operation-1 token)))
    (await (async-with-cancellation token
             (inner-operation-2 token)))))

(define (inner-operation-1 token)
  (async
    ;; 可以检查令牌
    ...))
```

---

## 📊 与其他语言对比

| 特性 | chez-async | C# | JavaScript |
|------|-----------|----|-----------||
| 令牌源 | `make-cancellation-token-source` | `new CancellationTokenSource()` | `new AbortController()` |
| 获取令牌 | `(cts-token cts)` | `cts.Token` | `controller.signal` |
| 取消 | `(cts-cancel! cts)` | `cts.Cancel()` | `controller.abort()` |
| 检查状态 | `(token-cancelled? token)` | `token.IsCancellationRequested` | `signal.aborted` |
| 注册回调 | `(token-register! token fn)` | `token.Register(fn)` | `signal.addEventListener()` |

---

## 🧪 测试结果

```
✓ Create and cancel
✓ Callback registration
✓ Immediate callback (already cancelled)
✓ async-with-cancellation (completes)
✓ linked-token-source
```

**通过率：** 5/5 (100%)

---

## 📝 总结

### 核心优势

1. **优雅的取消机制** - 合作式取消，不强制终止
2. **回调支持** - 注册清理回调，确保资源释放
3. **链接令牌** - 组合多个取消条件
4. **与 async/await 集成** - 无缝集成到异步流程

### 使用场景

- ✅ 用户主动取消（下载、搜索等）
- ✅ 超时控制
- ✅ 页面导航取消前一个请求
- ✅ 资源清理
- ✅ 长时间操作的中止

### 最佳实践

1. 总是在长时间操作中支持取消
2. 使用 `token-register!` 注册清理回调
3. 合理使用 `linked-token-source` 组合取消条件
4. 在循环中定期检查 `token-cancelled?`

---

**文档创建：** 2026-02-05
**实现文件：** `high-level/cancellation.ss`
**测试文件：** `tests/test-cancellation-simple.ss`

**取消功能完成！** ✅
