# 使用 async/await 进行 TCP 编程

**指南版本：** 1.0
**日期：** 2026-02-04

---

## 📚 概述

本指南展示如何使用 async/await 语法编写 TCP 客户端和服务器，替代传统的回调方式。

---

## 🔄 从回调到 async/await

### 传统回调方式

```scheme
;; 回调地狱示例
(define (fetch-data)
  (let ([tcp (uv-tcp-init loop)])
    (uv-tcp-connect tcp "127.0.0.1" 8080
      (lambda (handle err)
        (if err
            (handle-error err)
            (uv-write! handle "GET /data\n"
              (lambda (err)
                (if err
                    (handle-error err)
                    (uv-read-start! handle
                      (lambda (stream data)
                        (if data
                            (process-data data)
                            (handle-eof))))))))))))
```

**问题：**
- 嵌套层级深
- 错误处理分散
- 难以理解控制流
- 变量作用域混乱

### async/await 方式

```scheme
;; 清晰的同步风格代码
(define (fetch-data)
  (async
    (guard (ex
            [else (handle-error ex)])
      ;; 1. 连接
      (let ([tcp (await (tcp-connect "127.0.0.1" 8080))])
        ;; 2. 发送请求
        (await (tcp-write tcp "GET /data\n"))
        ;; 3. 读取响应
        (let ([data (await (tcp-read tcp))])
          ;; 4. 处理数据
          (process-data data))))))
```

**优势：**
- ✅ 扁平化代码结构
- ✅ 统一的错误处理
- ✅ 清晰的控制流
- ✅ 自然的变量作用域

---

## 🔧 核心：将回调 API 包装成 Promise

### 1. TCP 连接

```scheme
(define (tcp-connect host port)
  "连接到 TCP 服务器，返回 Promise<tcp-handle>"
  (make-promise (uv-default-loop)
    (lambda (resolve reject)
      (let ([tcp (uv-tcp-init (uv-default-loop))])
        (uv-tcp-connect tcp host port
          (lambda (handle err)
            (if err
                (reject err)      ; 连接失败
                (resolve handle)  ; 连接成功
                )))))))
```

**使用：**
```scheme
(async
  (let ([tcp (await (tcp-connect "127.0.0.1" 8080))])
    (format #t "Connected!~%")
    tcp))
```

### 2. TCP 读取

```scheme
(define (tcp-read tcp)
  "从 TCP 连接读取数据，返回 Promise<bytevector>"
  (make-promise (uv-default-loop)
    (lambda (resolve reject)
      (let ([resolved? #f])
        (uv-read-start! tcp
          (lambda (stream data-or-error)
            (unless resolved?
              (set! resolved? #t)
              (uv-read-stop! stream)
              (cond
                ;; 收到数据
                [(bytevector? data-or-error)
                 (resolve data-or-error)]
                ;; EOF
                [(not data-or-error)
                 (reject (make-error "Connection closed"))]
                ;; 错误
                [else
                 (reject data-or-error)]))))))))
```

**使用：**
```scheme
(async
  (let ([data (await (tcp-read tcp))])
    (format #t "Received: ~a~%" (utf8->string data))
    data))
```

### 3. TCP 写入

```scheme
(define (tcp-write tcp data)
  "向 TCP 连接写入数据，返回 Promise"
  (make-promise (uv-default-loop)
    (lambda (resolve reject)
      (let ([buf (if (string? data)
                     (string->utf8 data)
                     data)])
        (uv-write! tcp buf
          (lambda (err)
            (if err
                (reject err)
                (resolve #t))))))))
```

**使用：**
```scheme
(async
  (await (tcp-write tcp "Hello, Server!\n"))
  (format #t "Message sent!~%"))
```

---

## 📖 完整示例

### 示例 1：简单的请求-响应

```scheme
(define (simple-echo-client)
  (async
    ;; 1. 连接到服务器
    (format #t "Connecting...~%")
    (let ([tcp (await (tcp-connect "127.0.0.1" 8080))])

      (guard (ex
              [else
               (format #t "Error: ~a~%" ex)
               (tcp-close tcp)])

        ;; 2. 发送消息
        (format #t "Sending message...~%")
        (await (tcp-write tcp "Hello, Server!\n"))

        ;; 3. 读取响应
        (format #t "Waiting for response...~%")
        (let ([response (await (tcp-read tcp))])
          (format #t "Received: ~a~%" (utf8->string response)))

        ;; 4. 关闭连接
        (tcp-close tcp)
        (format #t "Done!~%")))))

;; 运行
(run-async (simple-echo-client))
```

### 示例 2：发送多条消息

```scheme
(define (multi-message-client messages)
  (async
    (let ([tcp (await (tcp-connect "127.0.0.1" 8080))])

      (guard (ex
              [else
               (tcp-close tcp)
               (raise ex)])

        ;; 发送并接收每条消息
        (for-each
          (lambda (msg)
            ;; 发送
            (format #t "Sending: ~a~%" msg)
            (await (tcp-write tcp (string-append msg "\n")))

            ;; 接收
            (let ([response (await (tcp-read tcp))])
              (format #t "Received: ~a~%" (utf8->string response))))
          messages)

        (tcp-close tcp)
        'done))))

;; 使用
(run-async
  (multi-message-client
    '("Message 1"
      "Message 2"
      "Message 3")))
```

### 示例 3：带重试的连接

```scheme
(define (connect-with-retry host port max-retries delay-ms)
  (async
    (let loop ([attempt 1])
      (guard (ex
              [else
               (if (< attempt max-retries)
                   (begin
                     (format #t "Attempt ~a failed, retrying in ~ams...~%"
                             attempt delay-ms)
                     ;; 等待后重试
                     (await (delay-promise delay-ms #t))
                     (loop (+ attempt 1)))
                   (begin
                     (format #t "All ~a attempts failed~%" max-retries)
                     (raise ex)))])

        (format #t "Attempt ~a: Connecting to ~a:~a...~%" attempt host port)
        (await (tcp-connect host port))))))

;; 使用
(run-async
  (async
    (let ([tcp (await (connect-with-retry "127.0.0.1" 8080 3 1000))])
      (format #t "Connected successfully!~%")
      (tcp-close tcp))))
```

### 示例 4：HTTP 请求

```scheme
(define (http-get host port path)
  "发送 HTTP GET 请求"
  (async
    ;; 1. 连接
    (let ([tcp (await (tcp-connect host port))])

      (guard (ex
              [else
               (tcp-close tcp)
               (raise ex)])

        ;; 2. 构造 HTTP 请求
        (let ([request
               (format "GET ~a HTTP/1.1\r\n~
                        Host: ~a\r\n~
                        Connection: close\r\n~
                        \r\n"
                       path host)])

          ;; 3. 发送请求
          (format #t "Sending HTTP request...~%")
          (await (tcp-write tcp request))

          ;; 4. 读取响应
          (format #t "Reading HTTP response...~%")
          (let ([response (await (tcp-read tcp))])
            (tcp-close tcp)
            (utf8->string response)))))))

;; 使用
(run-async
  (async
    (let ([response (await (http-get "httpbin.org" 80 "/get"))])
      (format #t "Response:~%~a~%" response))))
```

### 示例 5：数据管道处理

```scheme
(define (data-pipeline host port)
  "演示管道式处理"
  (async
    ;; 定义处理步骤
    (define (fetch-raw-data)
      (async
        (let ([tcp (await (tcp-connect host port))])
          (await (tcp-write tcp "GET_DATA\n"))
          (let ([data (await (tcp-read tcp))])
            (tcp-close tcp)
            data))))

    (define (parse-data raw-data)
      (async
        (format #t "Parsing data...~%")
        ;; 解析逻辑
        (utf8->string raw-data)))

    (define (validate-data parsed-data)
      (async
        (format #t "Validating data...~%")
        (if (string? parsed-data)
            parsed-data
            (error "Invalid data format"))))

    (define (process-data validated-data)
      (async
        (format #t "Processing data...~%")
        (string-upcase validated-data)))

    ;; 执行管道
    (let* ([raw (await (fetch-raw-data))]
           [parsed (await (parse-data raw))]
           [validated (await (validate-data parsed))]
           [processed (await (process-data validated))])

      (format #t "Final result: ~a~%" processed)
      processed)))

;; 运行
(run-async (data-pipeline "127.0.0.1" 8080))
```

---

## 🎯 常见模式

### 1. 并发连接

```scheme
(define (connect-to-multiple servers)
  (async
    ;; 启动多个连接
    (let ([connections
           (map (lambda (server)
                  (tcp-connect (car server) (cdr server)))
                servers)])

      ;; 等待所有连接完成
      (let ([tcps (map (lambda (conn) (await conn))
                      connections)])

        (format #t "All ~a connections established~%" (length tcps))
        tcps))))

;; 使用
(run-async
  (connect-to-multiple
    '(("server1.com" . 8080)
      ("server2.com" . 8080)
      ("server3.com" . 8080))))
```

### 2. 超时处理

```scheme
(define (tcp-connect-with-timeout host port timeout-ms)
  (async
    (let ([connect-promise (tcp-connect host port)]
          [timeout-promise
           (async
             (await (delay-promise timeout-ms #t))
             (error 'timeout "Connection timeout"))])

      ;; 竞速：连接 vs 超时
      (await (promise-race (list connect-promise timeout-promise))))))

;; 使用
(run-async
  (async
    (guard (ex
            [(eq? (car ex) 'timeout)
             (format #t "Connection timed out~%")]
            [else
             (format #t "Connection failed: ~a~%" ex)])

      (let ([tcp (await (tcp-connect-with-timeout "slow-server.com" 8080 5000))])
        (format #t "Connected!~%")
        tcp))))
```

### 3. 流式读取

```scheme
(define (tcp-read-all tcp)
  "读取所有数据直到 EOF"
  (async
    (let loop ([chunks '()])
      (guard (ex
              [else
               ;; EOF 或错误，返回收集的数据
               (apply bytevector-append (reverse chunks))])

        (let ([chunk (await (tcp-read tcp))])
          (loop (cons chunk chunks)))))))

;; 使用
(run-async
  (async
    (let ([tcp (await (tcp-connect "127.0.0.1" 8080))])
      (await (tcp-write tcp "GET_ALL_DATA\n"))
      (let ([all-data (await (tcp-read-all tcp))])
        (format #t "Received total: ~a bytes~%"
                (bytevector-length all-data))
        (tcp-close tcp)))))
```

### 4. 心跳保活

```scheme
(define (keep-alive-connection host port)
  (async
    (let ([tcp (await (tcp-connect host port))])

      ;; 启动心跳
      (define (heartbeat)
        (async
          (let loop ()
            (guard (ex
                    [else
                     (format #t "Heartbeat failed, reconnecting...~%")
                     #f])

              ;; 发送心跳
              (await (tcp-write tcp "PING\n"))
              (let ([response (await (tcp-read tcp))])
                (format #t "Heartbeat: ~a~%" (utf8->string response)))

              ;; 等待 30 秒
              (await (delay-promise 30000 #t))
              (loop)))))

      ;; 启动心跳（后台）
      (heartbeat)

      ;; 返回连接
      tcp)))
```

---

## 🐛 错误处理

### 1. 基础错误处理

```scheme
(async
  (guard (ex
          [else
           (format #t "Error: ~a~%" ex)
           #f])

    (let ([tcp (await (tcp-connect "127.0.0.1" 8080))])
      (await (tcp-write tcp "DATA\n"))
      (await (tcp-read tcp)))))
```

### 2. 分类错误处理

```scheme
(async
  (guard (ex
          [(connection-error? ex)
           (format #t "Connection error: ~a~%" ex)
           'connection-failed]
          [(timeout-error? ex)
           (format #t "Timeout: ~a~%" ex)
           'timeout]
          [(read-error? ex)
           (format #t "Read error: ~a~%" ex)
           'read-failed]
          [else
           (format #t "Unknown error: ~a~%" ex)
           'unknown-error])

    ;; 你的代码
    ...))
```

### 3. 清理资源

```scheme
(async
  (let ([tcp (await (tcp-connect "127.0.0.1" 8080))])
    ;; 确保资源清理
    (guard (ex
            [else
             (tcp-close tcp)  ; 无论如何都关闭
             (raise ex)])

      ;; 你的操作
      (await (tcp-write tcp "DATA\n"))
      (let ([response (await (tcp-read tcp))])
        (tcp-close tcp)
        response))))
```

---

## 📊 性能考虑

### 1. 避免过多的小写操作

❌ **不好：**
```scheme
(async
  (await (tcp-write tcp "H"))
  (await (tcp-write tcp "e"))
  (await (tcp-write tcp "l"))
  (await (tcp-write tcp "l"))
  (await (tcp-write tcp "o")))
```

✅ **好：**
```scheme
(async
  (await (tcp-write tcp "Hello")))
```

### 2. 批量处理

✅ **推荐：**
```scheme
(define (send-batch tcp messages)
  (async
    ;; 合并所有消息
    (let ([combined (string-join messages "\n")])
      (await (tcp-write tcp combined)))))
```

### 3. 使用 try-write 进行无阻塞写入

```scheme
;; 对于小数据，可以使用 try-write（无需 await）
(define (try-send tcp data)
  (let ([result (uv-try-write tcp data)])
    (if (< result 0)
        ;; 失败，使用 async 重试
        (async (await (tcp-write tcp data)))
        ;; 成功
        result)))
```

---

## 🎓 最佳实践

### 1. 始终关闭连接

```scheme
(async
  (let ([tcp (await (tcp-connect host port))])
    (guard (ex
            [else
             (tcp-close tcp)
             (raise ex)])

      ;; 使用连接
      ...

      ;; 正常关闭
      (tcp-close tcp))))
```

### 2. 使用超时

```scheme
;; 避免无限等待
(async
  (let ([tcp (await (tcp-connect-with-timeout host port 5000))])
    ...))
```

### 3. 记录日志

```scheme
(define (logged-tcp-write tcp data)
  (async
    (format #t "[TCP] Sending: ~a bytes~%" (bytevector-length data))
    (await (tcp-write tcp data))
    (format #t "[TCP] Sent successfully~%")))
```

### 4. 优雅降级

```scheme
(async
  (guard (ex
          [else
           ;; 失败时使用默认值
           (format #t "Failed, using cached data~%")
           *cached-data*])

    ;; 尝试从网络获取
    (let ([tcp (await (tcp-connect host port))])
      ...)))
```

---

## 📝 总结

### async/await 的优势

1. **可读性** - 同步风格的异步代码
2. **可维护性** - 扁平的代码结构
3. **错误处理** - 统一的 guard 机制
4. **组合性** - 易于组合多个异步操作
5. **调试性** - 清晰的调用栈

### 关键要点

- ✅ 将回调 API 包装成 Promise
- ✅ 使用 await 等待异步操作
- ✅ 用 guard 统一处理错误
- ✅ 记得关闭连接和清理资源
- ✅ 考虑超时和重试机制

---

**完整示例：** `examples/tcp-async-await-client.ss`

**相关文档：**
- `docs/async-await-guide.md` - async/await 使用指南
- `examples/tcp-echo-client.ss` - 传统回调方式（对比）
- `examples/tcp-echo-server.ss` - TCP 服务器示例
