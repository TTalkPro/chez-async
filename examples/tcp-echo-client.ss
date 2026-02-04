#!/usr/bin/env scheme-script
;;; examples/tcp-echo-client.ss - TCP Echo 客户端示例
;;;
;;; 这个示例展示了如何使用 chez-async 构建一个简单的 TCP 客户端。
;;; 客户端连接到 Echo 服务器，发送消息并接收回显。

(import (chezscheme)
        (chez-async high-level event-loop)
        (chez-async low-level tcp)
        (chez-async low-level handle-base))

;; ========================================
;; 配置
;; ========================================

(define *host* "127.0.0.1")
(define *port* 8080)
(define *messages*
  '("Hello, Server!"
    "How are you?"
    "This is a test message."
    "Goodbye!"))

;; ========================================
;; 客户端逻辑
;; ========================================

(define (run-client loop host port messages)
  "运行 TCP 客户端"
  (let ([client (uv-tcp-init loop)]
        [pending-messages messages]
        [responses '()])

    ;; 发送下一条消息
    (define (send-next-message)
      (if (null? pending-messages)
          ;; 所有消息已发送，关闭连接
          (begin
            (printf "~nAll messages sent, closing connection...~n")
            (uv-shutdown! client
              (lambda (err)
                (when err
                  (printf "[ERROR] Shutdown error: ~a~n" err)))))
          ;; 发送下一条消息
          (let ([msg (car pending-messages)])
            (set! pending-messages (cdr pending-messages))
            (printf "Sending: ~a~n" msg)
            (uv-write! client (string-append msg "\n")
              (lambda (err)
                (when err
                  (printf "[ERROR] Write error: ~a~n" err)
                  (uv-handle-close! client)))))))

    ;; 处理读取
    (define (handle-read stream data-or-error)
      (cond
        ;; 收到数据
        [(bytevector? data-or-error)
         (let ([response (utf8->string data-or-error)])
           (printf "Received: ~a" response)  ; response 已包含换行符
           (set! responses (cons response responses))
           ;; 发送下一条消息
           (send-next-message))]

        ;; EOF
        [(not data-or-error)
         (printf "Server closed connection~n")
         (uv-handle-close! stream)]

        ;; 错误
        [else
         (printf "[ERROR] Read error: ~a~n" data-or-error)
         (uv-handle-close! stream)]))

    ;; 连接到服务器
    (printf "Connecting to ~a:~a...~n" host port)
    (uv-tcp-connect client host port
      (lambda (tcp err)
        (if err
            (begin
              (printf "[ERROR] Connect error: ~a~n" err)
              (uv-handle-close! tcp))
            (begin
              (printf "Connected!~n~n")
              ;; 开始读取响应
              (uv-read-start! tcp handle-read)
              ;; 发送第一条消息
              (send-next-message)))))

    client))

;; ========================================
;; 主程序
;; ========================================

(define (main)
  (printf "=== chez-async: TCP Echo Client ===~n")
  (printf "libuv version: ~a~n~n" (uv-version-string))

  (let ([loop (uv-loop-init)])
    ;; 运行客户端
    (run-client loop *host* *port* *messages*)

    ;; 运行事件循环
    (uv-run loop 'default)

    ;; 清理
    (uv-loop-close loop))

  (printf "~nClient finished.~n"))

;; 运行
(main)
