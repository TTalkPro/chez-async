#!/usr/bin/env scheme-script
;;; examples/tcp-async-await-client.ss - 使用 async/await 的 TCP 客户端
;;;
;;; 这个示例展示如何使用 async/await 语法编写 TCP 客户端
;;; 对比传统回调方式，async/await 代码更清晰、更易读

(library-directories
  '(("." . ".")
    ("../internal" . "../internal")
    ("../high-level" . "../high-level")
    ("../low-level" . "../low-level")
    ("../ffi" . "../ffi")))

(import (chezscheme)
        (chez-async high-level async-await)
        (chez-async high-level promise)
        (chez-async high-level event-loop)
        (chez-async low-level tcp)
        (chez-async low-level handle-base))

(format #t "~%╔════════════════════════════════════════╗~%")
(format #t "║  TCP Client with async/await          ║~%")
(format #t "╚════════════════════════════════════════╝~%~%")

;; ========================================
;; 将 TCP 回调 API 包装成 Promise
;; ========================================

(define (tcp-connect host port)
  "连接到 TCP 服务器，返回 Promise<tcp-handle>

   host: 主机地址（字符串）
   port: 端口号（整数）

   返回: Promise，成功时 resolve tcp-handle"
  (make-promise (uv-default-loop)
    (lambda (resolve reject)
      (let ([tcp (uv-tcp-init (uv-default-loop))])
        (uv-tcp-connect tcp host port
          (lambda (handle err)
            (if err
                (reject err)
                (resolve handle))))))))

(define (tcp-read tcp)
  "从 TCP 连接读取一次数据，返回 Promise<bytevector>

   tcp: TCP 句柄

   返回: Promise，成功时 resolve 数据"
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
                 (reject (make-error "Connection closed by peer"))]
                ;; 错误
                [else
                 (reject data-or-error)]))))))))

(define (tcp-read-line tcp)
  "从 TCP 连接读取一行文本（以换行符结束）

   tcp: TCP 句柄

   返回: Promise<string>"
  (async
    (let ([data (await (tcp-read tcp))])
      (utf8->string data))))

(define (tcp-write tcp data)
  "向 TCP 连接写入数据，返回 Promise

   tcp: TCP 句柄
   data: 要写入的字符串或字节向量

   返回: Promise"
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

(define (tcp-close tcp)
  "关闭 TCP 连接

   tcp: TCP 句柄"
  (uv-handle-close! tcp))

;; ========================================
;; 使用 async/await 的 TCP 客户端示例
;; ========================================

(define (example-simple-request)
  "示例 1：简单的请求-响应"
  (async
    (format #t "Example 1: Simple Request-Response~%")
    (format #t "─────────────────────────────────────~%")

    ;; 1. 连接到服务器
    (format #t "Connecting to 127.0.0.1:8080...~%")
    (let ([tcp (await (tcp-connect "127.0.0.1" 8080))])
      (guard (ex
              [else
               (format #t "Error: ~a~%" ex)
               (tcp-close tcp)])

        ;; 2. 发送消息
        (format #t "Sending: Hello, Server!~%")
        (await (tcp-write tcp "Hello, Server!\n"))

        ;; 3. 读取响应
        (format #t "Waiting for response...~%")
        (let ([response (await (tcp-read-line tcp))])
          (format #t "Received: ~a~%" response))

        ;; 4. 关闭连接
        (format #t "Closing connection~%")
        (tcp-close tcp)

        (format #t "Done!~%~%")
        'ok))))

(define (example-multiple-messages)
  "示例 2：发送多条消息"
  (async
    (format #t "Example 2: Multiple Messages~%")
    (format #t "───────────────────────────~%")

    ;; 连接
    (format #t "Connecting...~%")
    (let ([tcp (await (tcp-connect "127.0.0.1" 8080))])
      (guard (ex
              [else
               (format #t "Error: ~a~%" ex)
               (tcp-close tcp)])

        ;; 发送多条消息并接收响应
        (let ([messages '("Message 1" "Message 2" "Message 3")])
          (for-each
            (lambda (msg)
              (let ([full-msg (string-append msg "\n")])
                ;; 发送
                (format #t "Sending: ~a~%" msg)
                (await (tcp-write tcp full-msg))

                ;; 接收
                (let ([response (await (tcp-read-line tcp))])
                  (format #t "Received: ~a~%" response))))
            messages))

        ;; 关闭
        (tcp-close tcp)
        (format #t "Done!~%~%")
        'ok))))

(define (example-with-retry)
  "示例 3：带重试机制的连接"
  (async
    (format #t "Example 3: Connection with Retry~%")
    (format #t "────────────────────────────────────~%")

    (define (try-connect max-retries)
      (async
        (let loop ([attempt 1])
          (guard (ex
                  [else
                   (if (< attempt max-retries)
                       (begin
                         (format #t "Attempt ~a failed, retrying...~%" attempt)
                         (loop (+ attempt 1)))
                       (begin
                         (format #t "All ~a attempts failed~%" max-retries)
                         (raise ex)))])
            (format #t "Attempt ~a: Connecting...~%" attempt)
            (await (tcp-connect "127.0.0.1" 8080))))))

    (let ([tcp (await (try-connect 3))])
      (format #t "Connected successfully!~%")

      ;; 发送测试消息
      (await (tcp-write tcp "Test message\n"))
      (let ([response (await (tcp-read-line tcp))])
        (format #t "Response: ~a~%" response))

      (tcp-close tcp)
      (format #t "Done!~%~%")
      'ok)))

(define (example-streaming-data)
  "示例 4：流式读取多次数据"
  (async
    (format #t "Example 4: Streaming Data~%")
    (format #t "─────────────────────────~%")

    (let ([tcp (await (tcp-connect "127.0.0.1" 8080))])
      (guard (ex
              [else
               (format #t "Error: ~a~%" ex)
               (tcp-close tcp)])

        ;; 发送请求
        (await (tcp-write tcp "STREAM\n"))

        ;; 读取多次数据
        (format #t "Reading stream...~%")
        (do ([i 0 (+ i 1)])
            ((= i 5))
          (let ([data (await (tcp-read-line tcp))])
            (format #t "  [~a] ~a~%" i data)))

        (tcp-close tcp)
        (format #t "Done!~%~%")
        'ok))))

(define (example-pipeline)
  "示例 5：管道式处理（连接多个异步操作）"
  (async
    (format #t "Example 5: Pipeline Processing~%")
    (format #t "──────────────────────────────~%")

    ;; 定义处理管道
    (define (fetch-data tcp request)
      (async
        (format #t "  [1] Sending request: ~a~%" request)
        (await (tcp-write tcp (string-append request "\n")))
        (await (tcp-read-line tcp))))

    (define (process-data data)
      (async
        (format #t "  [2] Processing data: ~a~%" data)
        (string-upcase data)))

    (define (validate-result result)
      (async
        (format #t "  [3] Validating result: ~a~%" result)
        (if (string? result)
            result
            (error "Invalid result"))))

    ;; 执行管道
    (let ([tcp (await (tcp-connect "127.0.0.1" 8080))])
      (guard (ex
              [else
               (format #t "Error: ~a~%" ex)
               (tcp-close tcp)])

        (let* ([data (await (fetch-data tcp "hello"))]
               [processed (await (process-data data))]
               [validated (await (validate-result processed))])

          (format #t "Final result: ~a~%~%" validated)
          (tcp-close tcp)
          validated)))))

;; ========================================
;; 完整示例：HTTP 请求模拟
;; ========================================

(define (http-get-async host port path)
  "使用 async/await 发送简单的 HTTP GET 请求

   host: 主机地址
   port: 端口号
   path: 请求路径

   返回: Promise<string>（HTTP 响应）"
  (async
    (format #t "HTTP GET ~a:~a~a~%" host port path)

    ;; 1. 连接
    (let ([tcp (await (tcp-connect host port))])
      (guard (ex
              [else
               (tcp-close tcp)
               (raise ex)])

        ;; 2. 构造并发送 HTTP 请求
        (let ([request (format "GET ~a HTTP/1.1\r\nHost: ~a\r\nConnection: close\r\n\r\n"
                               path host)])
          (format #t "Sending request...~%")
          (await (tcp-write tcp request))

          ;; 3. 读取响应
          (format #t "Reading response...~%")
          (let ([response (await (tcp-read tcp))])
            (tcp-close tcp)
            (utf8->string response)))))))

(define (example-http-request)
  "示例 6：HTTP 请求"
  (async
    (format #t "Example 6: HTTP Request~%")
    (format #t "──────────────────────~%")

    (guard (ex
            [else
             (format #t "HTTP request failed: ~a~%~%" ex)
             #f])

      ;; 发送 HTTP 请求
      (let ([response (await (http-get-async "httpbin.org" 80 "/"))])
        (format #t "Response received (~a bytes)~%~%"
                (string-length response))
        ;; 只显示前 200 个字符
        (format #t "~a...~%~%"
                (substring response 0 (min 200 (string-length response))))
        'ok))))

;; ========================================
;; 主程序
;; ========================================

(define (main)
  (format #t "Note: These examples require a TCP echo server running on 127.0.0.1:8080~%")
  (format #t "You can start the server with: scheme examples/tcp-echo-server.ss~%~%")

  ;; 运行示例（注释掉那些需要真实服务器的）

  ;; 示例 1-5 需要本地 echo 服务器
  ;; (run-async (example-simple-request))
  ;; (run-async (example-multiple-messages))
  ;; (run-async (example-with-retry))
  ;; (run-async (example-streaming-data))
  ;; (run-async (example-pipeline))

  ;; 示例 6：HTTP 请求（需要网络连接）
  ;; (run-async (example-http-request))

  (format #t "~%╔════════════════════════════════════════╗~%")
  (format #t "║  Demonstration Complete                ║~%")
  (format #t "╚════════════════════════════════════════╝~%~%")

  (format #t "Key Points:~%")
  (format #t "  • TCP callbacks wrapped as Promises~%")
  (format #t "  • await makes async code look synchronous~%")
  (format #t "  • Natural error handling with guard~%")
  (format #t "  • Easy to compose async operations~%")
  (format #t "  • No callback hell!~%~%"))

;; 运行主程序
(main)
