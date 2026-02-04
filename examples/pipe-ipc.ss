#!/usr/bin/env scheme-script
;;; examples/pipe-ipc.ss - Pipe IPC 示例
;;;
;;; 这个示例展示了如何使用 chez-async 构建一个基于 Unix domain socket
;;; 的 IPC Echo 服务器和客户端。
;;;
;;; 用法：
;;;   # 启动服务器
;;;   scheme --libdirs .:.. --program examples/pipe-ipc.ss server
;;;
;;;   # 在另一个终端启动客户端
;;;   scheme --libdirs .:.. --program examples/pipe-ipc.ss client
;;;
;;;   # 或使用 socat 测试
;;;   echo "Hello" | socat - UNIX-CONNECT:/tmp/chez-async-echo.sock

(import (chezscheme)
        (chez-async high-level event-loop)
        (chez-async low-level pipe)
        (chez-async low-level signal)
        (chez-async low-level handle-base)
        (chez-async ffi types))

;; ========================================
;; 配置
;; ========================================

(define *pipe-path* "/tmp/chez-async-echo.sock")
(define *backlog* 128)

;; ========================================
;; 服务器实现
;; ========================================

(define (handle-client client)
  "处理单个客户端连接"
  (printf "[Server] Client connected~n")

  ;; 开始读取数据
  (uv-read-start! client
    (lambda (stream data-or-error)
      (cond
        ;; 成功读取数据
        [(bytevector? data-or-error)
         (let ([data-str (utf8->string data-or-error)])
           (printf "[Server] Received: ~a~n" (string-trim-right data-str))
           ;; 回显数据
           (uv-write! stream data-or-error
             (lambda (err)
               (when err
                 (printf "[Server] Write error: ~a~n" err)
                 (uv-handle-close! stream)))))]

        ;; EOF - 客户端关闭连接
        [(not data-or-error)
         (printf "[Server] Client disconnected~n")
         (uv-handle-close! stream)]

        ;; 错误
        [else
         (printf "[Server] Read error: ~a~n" data-or-error)
         (uv-handle-close! stream)]))))

(define (run-server)
  "运行 Pipe Echo 服务器"
  (printf "=== chez-async: Pipe IPC Server ===~n")
  (printf "libuv version: ~a~n~n" (uv-version-string))

  ;; 删除旧的 socket 文件
  (when (file-exists? *pipe-path*)
    (delete-file *pipe-path*))

  (let* ([loop (uv-loop-init)]
         [server (uv-pipe-init loop)]
         [sigint (uv-signal-init loop)])

    ;; 绑定到路径
    (printf "Binding to ~a...~n" *pipe-path*)
    (uv-pipe-bind server *pipe-path*)

    ;; 设置权限（允许所有用户连接）
    (uv-pipe-chmod! server (bitwise-ior UV_READABLE UV_WRITABLE))

    (printf "Server listening on ~a~n" *pipe-path*)
    (printf "Test with: echo \"Hello\" | socat - UNIX-CONNECT:~a~n~n" *pipe-path*)

    ;; 设置 SIGINT 处理器
    (uv-signal-start! sigint SIGINT
      (lambda (sig signum)
        (printf "~n[Server] Received SIGINT, shutting down...~n")
        (uv-signal-stop! sig)
        (uv-handle-close! sig)
        (uv-handle-close! server)))

    ;; 开始监听
    (uv-pipe-listen server *backlog*
      (lambda (srv err)
        (if err
            (printf "[Server] Listen error: ~a~n" err)
            ;; 接受新连接
            (let ([client (uv-pipe-accept srv)])
              (handle-client client)))))

    (printf "Press Ctrl+C to stop the server~n~n")

    ;; 运行事件循环
    (uv-run loop 'default)

    ;; 清理
    (uv-loop-close loop)

    ;; 删除 socket 文件
    (when (file-exists? *pipe-path*)
      (delete-file *pipe-path*)))

  (printf "Server stopped.~n"))

;; ========================================
;; 客户端实现
;; ========================================

(define (run-client)
  "运行 Pipe 客户端"
  (printf "=== chez-async: Pipe IPC Client ===~n~n")

  (let* ([loop (uv-loop-init)]
         [client (uv-pipe-init loop)]
         [message "Hello from Chez Scheme!"])

    (printf "Connecting to ~a...~n" *pipe-path*)

    ;; 连接到服务器
    (uv-pipe-connect client *pipe-path*
      (lambda (pipe err)
        (if err
            (begin
              (printf "[Client] Connect error: ~a~n" err)
              (uv-handle-close! pipe))
            (begin
              (printf "[Client] Connected!~n")

              ;; 发送消息
              (printf "[Client] Sending: ~a~n" message)
              (uv-write! pipe (string->utf8 (string-append message "\n"))
                (lambda (err)
                  (when err
                    (printf "[Client] Write error: ~a~n" err))))

              ;; 读取响应
              (uv-read-start! pipe
                (lambda (stream data-or-err)
                  (cond
                    [(bytevector? data-or-err)
                     (printf "[Client] Received echo: ~a~n"
                             (string-trim-right (utf8->string data-or-err)))
                     (uv-handle-close! stream)]
                    [(not data-or-err)
                     (printf "[Client] Server closed connection~n")
                     (uv-handle-close! stream)]
                    [else
                     (printf "[Client] Read error: ~a~n" data-or-err)
                     (uv-handle-close! stream)])))))))

    ;; 运行事件循环
    (uv-run loop 'default)

    ;; 清理
    (uv-loop-close loop))

  (printf "Client done.~n"))

;; ========================================
;; 辅助函数
;; ========================================

(define (string-trim-right str)
  "移除字符串末尾的空白字符"
  (let loop ([chars (reverse (string->list str))])
    (cond
      [(null? chars) ""]
      [(char-whitespace? (car chars))
       (loop (cdr chars))]
      [else
       (list->string (reverse chars))])))

;; ========================================
;; 主程序
;; ========================================

(define (main args)
  (cond
    [(or (null? args)
         (string=? (car args) "server"))
     (run-server)]
    [(string=? (car args) "client")
     (run-client)]
    [else
     (printf "Usage: pipe-ipc.ss [server|client]~n")
     (exit 1)]))

;; 获取命令行参数并运行
(main (cdr (command-line)))
