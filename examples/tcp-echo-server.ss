#!/usr/bin/env scheme-script
;;; examples/tcp-echo-server.ss - TCP Echo 服务器示例
;;;
;;; 这个示例展示了如何使用 chez-async 构建一个简单的 TCP Echo 服务器。
;;; 服务器监听指定端口，将收到的数据原样返回给客户端。

(import (chezscheme)
        (chez-async high-level event-loop)
        (chez-async low-level tcp)
        (chez-async low-level handle-base))

;; ========================================
;; 配置
;; ========================================

(define *host* "127.0.0.1")
(define *port* 8080)
(define *backlog* 128)

;; ========================================
;; 客户端处理
;; ========================================

(define (handle-client client)
  "处理单个客户端连接"
  (let ([peer (uv-tcp-getpeername client)])
    (printf "[~a:~a] Client connected~n" (car peer) (cdr peer)))

  ;; 开始读取数据
  (uv-read-start! client
    (lambda (stream data-or-error)
      (cond
        ;; 成功读取数据
        [(bytevector? data-or-error)
         (let ([data-str (utf8->string data-or-error)]
               [peer (uv-tcp-getpeername stream)])
           (printf "[~a:~a] Received: ~a~n"
                   (car peer) (cdr peer)
                   (string-trim-right data-str))
           ;; 回显数据
           (uv-write! stream data-or-error
             (lambda (err)
               (when err
                 (printf "[ERROR] Write error: ~a~n" err)
                 (uv-handle-close! stream)))))]

        ;; EOF - 客户端关闭连接
        [(not data-or-error)
         (let ([peer (guard (e [else '("?" . "?")])
                       (uv-tcp-getpeername stream))])
           (printf "[~a:~a] Client disconnected~n"
                   (car peer) (cdr peer)))
         (uv-handle-close! stream)]

        ;; 错误
        [else
         (printf "[ERROR] Read error: ~a~n" data-or-error)
         (uv-handle-close! stream)]))))

;; ========================================
;; 服务器
;; ========================================

(define (start-server loop host port)
  "启动 TCP Echo 服务器"
  (let ([server (uv-tcp-init loop)])

    ;; 绑定地址
    (printf "Binding to ~a:~a...~n" host port)
    (uv-tcp-bind server host port)

    ;; 获取实际绑定的端口
    (let ([addr (uv-tcp-getsockname server)])
      (printf "Server listening on ~a:~a~n" (car addr) (cdr addr)))

    ;; 开始监听
    (uv-tcp-listen server *backlog*
      (lambda (srv err)
        (if err
            (printf "[ERROR] Listen error: ~a~n" err)
            ;; 接受新连接
            (let ([client (uv-tcp-accept srv)])
              (handle-client client)))))

    server))

;; ========================================
;; 主程序
;; ========================================

(define (main)
  (printf "=== chez-async: TCP Echo Server ===~n")
  (printf "libuv version: ~a~n~n" (uv-version-string))

  (let ([loop (uv-loop-init)])
    ;; 启动服务器
    (let ([server (start-server loop *host* *port*)])

      (printf "~nPress Ctrl+C to stop the server~n~n")

      ;; 运行事件循环
      (uv-run loop 'default)

      ;; 清理
      (uv-loop-close loop)))

  (printf "Server stopped.~n"))

;; 辅助函数
(define (string-trim-right str)
  "移除字符串末尾的空白字符"
  (let loop ([chars (reverse (string->list str))])
    (cond
      [(null? chars) ""]
      [(char-whitespace? (car chars))
       (loop (cdr chars))]
      [else
       (list->string (reverse chars))])))

;; 运行
(main)
