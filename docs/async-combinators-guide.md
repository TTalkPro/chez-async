# async/await 组合器使用指南

**创建日期：** 2026-02-05
**状态：** ✅ Phase 4 部分完成

---

## 📋 概述

async 组合器提供了常用的异步操作模式，类似于 JavaScript 的 Promise.all、Promise.race 等，让并发异步编程更简单。

### 核心功能

```scheme
(import (chez-async high-level async-combinators))

;; 时间控制
(async-sleep ms)              ; 延迟执行
(async-timeout promise ms)    ; 添加超时
(async-delay ms thunk)        ; 延迟操作

;; 并发控制
(async-all promises)          ; 等待所有完成
(async-race promises)         ; 返回最快的
(async-any promises)          ; 返回第一个成功的

;; 错误处理
(async-catch promise handler)     ; 捕获错误
(async-finally promise finalizer) ; 清理操作
```

---

## ⏰ 时间控制

### async-sleep - 延迟执行

```scheme
(define (async-sleep ms) → Promise<void>)
```

延迟指定毫秒数后继续执行。

**示例 1：简单延迟**

```scheme
(async
  (format #t "Starting...~%")
  (await (async-sleep 1000))
  (format #t "1 second passed~%"))
```

**示例 2：定时任务**

```scheme
(define (periodic-task)
  (async
    (let loop ([count 0])
      (when (< count 5)
        (format #t "Task ~a~%" count)
        (await (async-sleep 500))
        (loop (+ count 1))))))
```

**示例 3：动画效果**

```scheme
(define (animate-progress)
  (async
    (let ([progress 0])
      (let loop ()
        (format #t "\rProgress: ~a%~c" progress #\return)
        (flush-output-port)
        (set! progress (+ progress 10))
        (when (<= progress 100)
          (await (async-sleep 100))
          (loop))))))
```

---

### async-timeout - 超时控制

```scheme
(define (async-timeout promise timeout-ms) → Promise<any>)
```

为异步操作添加超时限制。

**示例 1：HTTP 请求超时**

```scheme
(async
  (guard (ex
          [(timeout-error? ex)
           (format #t "Request timed out~%")
           'timeout])
    (let ([response (await (async-timeout
                             (http-get "https://slow-api.com")
                             5000))])
      (format #t "Got response: ~a~%" response))))
```

**示例 2：数据库查询超时**

```scheme
(define (query-with-timeout query timeout)
  (async
    (guard (ex
            [(timeout-error? ex)
             (format #t "Query timeout after ~a ms~%"
                     (timeout-error-timeout-ms ex))
             #f])
      (await (async-timeout
               (db-query query)
               timeout)))))
```

**示例 3：用户输入超时**

```scheme
(define (wait-for-user-input timeout-sec)
  (async
    (guard (ex
            [(timeout-error? ex)
             (format #t "No input received~%")
             'no-input])
      (await (async-timeout
               (read-user-input)
               (* timeout-sec 1000))))))
```

---

### async-delay - 延迟操作

```scheme
(define (async-delay ms thunk) → Promise<any>)
```

延迟指定时间后执行异步操作。

**示例 1：延迟启动**

```scheme
(async-delay 2000
  (lambda ()
    (async
      (format #t "Starting after 2 seconds~%")
      (start-server))))
```

**示例 2：重试机制**

```scheme
(define (retry-with-backoff operation max-retries)
  (async
    (let loop ([attempt 1])
      (guard (ex
              [else
               (if (< attempt max-retries)
                   (begin
                     (format #t "Attempt ~a failed, retrying...~%" attempt)
                     (await (async-delay (* attempt 1000)
                              (lambda () (loop (+ attempt 1))))))
                   (raise ex))])
        (await (operation))))))
```

**示例 3：批处理延迟**

```scheme
(define (process-batch-with-delay items delay-ms)
  (async
    (for-each
      (lambda (item)
        (await (async-delay delay-ms
                 (lambda ()
                   (async (process-item item))))))
      items)))
```

---

## 🔀 并发控制

### async-all - 等待所有完成

```scheme
(define (async-all promises) → Promise<list>)
```

并发执行多个 Promise，等待全部完成。

**行为：**
- 所有成功 → 返回结果列表（按顺序）
- 任一失败 → 立即 reject

**示例 1：并发 HTTP 请求**

```scheme
(async
  (let ([urls '("url1" "url2" "url3")]
        [results (await (async-all
                          (map http-get urls)))])
    (format #t "All responses: ~a~%" results)))
```

**示例 2：批量数据库操作**

```scheme
(define (save-users users)
  (async
    (let ([save-promises
           (map (lambda (user)
                  (db-save "users" user))
                users)])
      (await (async-all save-promises))
      (format #t "Saved ~a users~%" (length users)))))
```

**示例 3：并行计算**

```scheme
(define (parallel-compute tasks)
  (async
    (let ([promises
           (map (lambda (task)
                  (async-work loop task))
                tasks)])
      (await (async-all promises)))))
```

**示例 4：依赖数据加载**

```scheme
(async
  ;; 并发加载用户、订单、产品
  (let* ([data (await (async-all
                        (list (load-users)
                              (load-orders)
                              (load-products))))]
         [users (list-ref data 0)]
         [orders (list-ref data 1)]
         [products (list-ref data 2)])
    (build-dashboard users orders products)))
```

---

### async-race - 返回最快的

```scheme
(define (async-race promises) → Promise<any>)
```

并发执行多个 Promise，返回第一个完成的（无论成功或失败）。

**行为：**
- 返回第一个 settled 的 Promise
- 其他 Promise 继续执行但结果被忽略

**示例 1：多服务器竞速**

```scheme
(async
  (let ([servers '("server1.com" "server2.com" "server3.com")]
        [response (await (async-race
                           (map http-get servers)))])
    (format #t "Fastest server responded: ~a~%" response)))
```

**示例 2：缓存 + 数据库**

```scheme
(define (get-user-data user-id)
  (async
    ;; 同时查询缓存和数据库，谁快用谁的
    (await (async-race
             (list (cache-get user-id)
                   (db-query "users" user-id))))))
```

**示例 3：超时实现（手动）**

```scheme
(define (manual-timeout operation timeout-ms)
  (async
    (await (async-race
             (list operation
                   (async
                     (await (async-sleep timeout-ms))
                     (raise 'timeout)))))))
```

**示例 4：用户操作 vs 自动操作**

```scheme
(async
  ;; 用户可以点击跳过，或等待自动继续
  (let ([action (await (async-race
                         (list (wait-for-user-click)
                               (async
                                 (await (async-sleep 5000))
                                 'auto-continue))))])
    (next-step action)))
```

---

### async-any - 返回第一个成功的

```scheme
(define (async-any promises) → Promise<any>)
```

并发执行多个 Promise，返回第一个成功的。

**行为：**
- 返回第一个 fulfilled 的 Promise
- 所有失败 → reject 并附带所有错误

**示例 1：镜像站点**

```scheme
(async
  (guard (ex
          [else
           (format #t "All mirrors failed~%")])
    (let ([mirrors '("mirror1.com" "mirror2.com" "mirror3.com")]
          [data (await (async-any
                         (map http-get mirrors)))])
      (format #t "Got data from mirror: ~a~%" data))))
```

**示例 2：多种认证方式**

```scheme
(define (authenticate credentials)
  (async
    (await (async-any
             (list (oauth-login credentials)
                   (password-login credentials)
                   (token-login credentials))))))
```

**示例 3：多数据源查询**

```scheme
(define (find-product product-id)
  (async
    ;; 尝试多个数据源，第一个找到的就返回
    (await (async-any
             (list (local-db-query product-id)
                   (cache-query product-id)
                   (remote-api-query product-id))))))
```

**示例 4：智能重试**

```scheme
(define (resilient-fetch url)
  (async
    ;; 同时尝试直连和通过代理
    (await (async-any
             (list (http-get url)
                   (http-get-via-proxy url "proxy1")
                   (http-get-via-proxy url "proxy2"))))))
```

---

## 🛡️ 错误处理

### async-catch - 捕获错误

```scheme
(define (async-catch promise handler) → Promise<any>)
```

为 Promise 添加错误处理器。

**示例 1：提供默认值**

```scheme
(async-catch
  (load-config "config.json")
  (lambda (error)
    (format #t "Failed to load config, using defaults~%")
    '((port . 8080) (host . "localhost"))))
```

**示例 2：错误分类处理**

```scheme
(async-catch
  (http-get "https://api.com/data")
  (lambda (error)
    (cond
      [(network-error? error)
       (format #t "Network error, will retry~%")
       (retry-operation)]
      [(auth-error? error)
       (format #t "Auth failed, please login~%")
       (redirect-to-login)]
      [else
       (format #t "Unknown error: ~a~%" error)
       #f])))
```

---

### async-finally - 清理操作

```scheme
(define (async-finally promise finalizer) → Promise<any>)
```

添加清理操作（无论成功或失败都执行）。

**示例 1：资源清理**

```scheme
(async
  (let ([file (open-file "data.txt")])
    (await
      (async-finally
        (async (process-file file))
        (lambda ()
          (close-file file)
          (format #t "File closed~%"))))))
```

**示例 2：加载状态**

```scheme
(async
  (set! loading? #t)
  (await
    (async-finally
      (fetch-data)
      (lambda ()
        (set! loading? #f)
        (update-ui)))))
```

---

## 🎯 实战场景

### 场景 1：并发下载文件

```scheme
(define (download-files urls output-dir)
  (async
    (format #t "Downloading ~a files...~%" (length urls))

    (let ([download-promises
           (map (lambda (url)
                  (async-catch
                    (async
                      (let ([data (await (http-get url))])
                        (save-file output-dir url data)
                        'success))
                    (lambda (error)
                      (format #t "Failed to download ~a: ~a~%" url error)
                      'failed)))
                urls)])

      (let ([results (await (async-all download-promises))])
        (let ([success-count (count (lambda (r) (eq? r 'success)) results)])
          (format #t "Downloaded ~a/~a files~%"
                  success-count
                  (length urls)))))))
```

### 场景 2：健康检查

```scheme
(define (health-check services timeout-ms)
  (async
    (let ([check-promises
           (map (lambda (service)
                  (async-timeout
                    (async-catch
                      (ping-service service)
                      (lambda (error) 'unhealthy))
                    timeout-ms))
                services)])

      (let ([statuses (await (async-all check-promises))])
        (map cons services statuses)))))
```

### 场景 3：智能加载

```scheme
(define (smart-load resources)
  "快速资源优先加载，慢的资源后台加载"
  (async
    ;; 先尝试快速加载（100ms 超时）
    (let ([quick-result
           (await
             (async-catch
               (async-timeout
                 (async-any (map load-resource resources))
                 100)
               (lambda (error) #f)))])

      (if quick-result
          quick-result
          ;; 快速加载失败，正常加载（5s 超时）
          (await (async-timeout
                   (async-any (map load-resource resources))
                   5000))))))
```

### 场景 4：批量处理限流

```scheme
(define (process-batch-with-limit items concurrency)
  "限制并发数的批量处理"
  (async
    (let loop ([remaining items]
               [results '()])
      (if (null? remaining)
          (reverse results)
          (let* ([batch (take-upto remaining concurrency)]
                 [rest (drop-upto remaining concurrency)]
                 [batch-results (await (async-all
                                         (map process-item batch)))])
            (loop rest (append (reverse batch-results) results)))))))

(define (take-upto lst n)
  (if (or (null? lst) (<= n 0))
      '()
      (cons (car lst) (take-upto (cdr lst) (- n 1)))))

(define (drop-upto lst n)
  (if (or (null? lst) (<= n 0))
      lst
      (drop-upto (cdr lst) (- n 1))))
```

### 场景 5：重试策略

```scheme
(define (retry-with-strategy operation strategy)
  "使用指定策略重试操作

   strategy: '(max-retries . delay-ms-list)
   例如: '(3 . (1000 2000 4000)) 表示3次重试，递增延迟"
  (async
    (let ([max-retries (car strategy)]
          [delays (cdr strategy)])
      (let loop ([attempt 1])
        (guard (ex
                [else
                 (if (< attempt max-retries)
                     (let ([delay (list-ref delays (- attempt 1))])
                       (format #t "Attempt ~a failed, retrying in ~a ms...~%"
                               attempt delay)
                       (await (async-sleep delay))
                       (loop (+ attempt 1)))
                     (begin
                       (format #t "All ~a attempts failed~%" max-retries)
                       (raise ex)))])
          (await (operation)))))))

;; 使用
(retry-with-strategy
  (lambda () (http-get "unstable-api"))
  '(5 . (1000 2000 4000 8000 16000)))  ; 指数退避
```

---

## 📊 性能考虑

### 1. 并发数控制

```scheme
;; ❌ 不好：无限并发
(async-all (map process-item items))

;; ✅ 好：限制并发数
(process-batch-with-limit items 10)
```

### 2. 超时设置

```scheme
;; ✅ 根据操作类型设置合理超时
(async-timeout (local-db-query) 1000)    ; 本地查询 1s
(async-timeout (remote-api-call) 5000)   ; 远程调用 5s
(async-timeout (file-download) 30000)    ; 文件下载 30s
```

### 3. 错误恢复

```scheme
;; ✅ 提供降级方案
(async-catch
  (load-from-remote)
  (lambda (error)
    (load-from-cache)))
```

---

## 🎓 最佳实践

### 1. 使用 async-all 加载独立资源

```scheme
(async
  ;; ✅ 并发加载独立资源
  (let* ([data (await (async-all
                        (list (load-users)
                              (load-settings)
                              (load-preferences))))]
         [users (list-ref data 0)]
         [settings (list-ref data 1)]
         [prefs (list-ref data 2)])
    ...))
```

### 2. 使用 async-race 实现快速响应

```scheme
;; ✅ 同时查询多个数据源，谁快用谁的
(async-race (list (cache-get key)
                  (db-get key)))
```

### 3. 使用 async-any 实现容错

```scheme
;; ✅ 多个备选方案，任一成功即可
(async-any (list (primary-service)
                 (backup-service)
                 (fallback-service)))
```

### 4. 组合使用

```scheme
;; ✅ 超时 + 重试 + 降级
(async
  (guard (ex [else (use-cached-data)])
    (await (retry-with-strategy
             (lambda ()
               (async-timeout (fetch-data) 5000))
             '(3 . (1000 2000 4000))))))
```

---

## 📝 总结

### 已实现功能

| 函数 | 用途 | 类似于 |
|------|------|--------|
| `async-sleep` | 延迟执行 | `setTimeout` |
| `async-all` | 等待所有完成 | `Promise.all` |
| `async-race` | 返回最快的 | `Promise.race` |
| `async-any` | 返回第一个成功的 | `Promise.any` |
| `async-timeout` | 超时控制 | 无直接对应 |
| `async-delay` | 延迟操作 | 无直接对应 |
| `async-catch` | 错误处理 | `.catch()` |
| `async-finally` | 清理操作 | `.finally()` |

### 使用场景

- **并发加载**: 使用 `async-all`
- **多源竞速**: 使用 `async-race`
- **容错降级**: 使用 `async-any`
- **超时保护**: 使用 `async-timeout`
- **延迟重试**: 使用 `async-delay`

### 下一步

查看完整示例：
- `tests/test-async-combinators.ss` - 完整测试套件
- `examples/async-patterns.ss` - 实战模式示例（待创建）

---

**文档创建：** 2026-02-05
**Phase 4 进度：** 并发原语已完成 ✅
