#!/usr/bin/env scheme-script
;;; examples/udp-echo-server.ss - UDP Echo 服务器示例
;;;
;;; 这个示例展示了如何使用 chez-async 构建一个简单的 UDP Echo 服务器。
;;; 服务器监听指定端口，将收到的数据报原样返回给发送方。
;;;
;;; 用法：
;;;   scheme --libdirs .:.. --program examples/udp-echo-server.ss
;;;
;;; 测试：
;;;   echo "Hello" | nc -u 127.0.0.1 8081

(import (chezscheme)
        (chez-async high-level event-loop)
        (chez-async low-level udp)
        (chez-async low-level handle-base))

;; ========================================
;; 配置
;; ========================================

(define *host* "0.0.0.0")
(define *port* 8081)

;; ========================================
;; 数据报处理
;; ========================================

(define (handle-datagram udp data sender-addr flags)
  "处理接收到的 UDP 数据报"
  (let ([data-str (utf8->string data)]
        [sender-ip (car sender-addr)]
        [sender-port (cdr sender-addr)])
    (printf "[~a:~a] Received (~a bytes): ~a~n"
            sender-ip sender-port
            (bytevector-length data)
            (string-trim-right data-str))
    ;; 检查是否有截断标志
    (when (not (= (bitwise-and flags 2) 0))  ; UV_UDP_PARTIAL
      (printf "  [Warning] Datagram was truncated~n"))
    ;; 回显数据给发送方
    (uv-udp-send! udp data sender-ip sender-port
      (lambda (err)
        (if err
            (printf "[ERROR] Send error: ~a~n" err)
            (printf "[~a:~a] Echo sent~n" sender-ip sender-port))))))

;; ========================================
;; 服务器
;; ========================================

(define (start-server loop host port)
  "启动 UDP Echo 服务器"
  (let ([server (uv-udp-init loop)])

    ;; 绑定地址
    (printf "Binding to ~a:~a...~n" host port)
    (uv-udp-bind server host port)

    ;; 获取实际绑定的端口
    (let ([addr (uv-udp-getsockname server)])
      (printf "Server listening on ~a:~a (UDP)~n" (car addr) (cdr addr)))

    ;; 开始接收数据
    (uv-udp-recv-start! server
      (lambda (udp data-or-error sender-addr flags)
        (cond
          ;; 成功接收数据
          [(bytevector? data-or-error)
           (handle-datagram udp data-or-error sender-addr flags)]
          ;; 无数据（空数据报）
          [(and (not data-or-error) sender-addr)
           (printf "[~a:~a] Empty datagram received~n"
                   (car sender-addr) (cdr sender-addr))]
          ;; 无更多数据
          [(not data-or-error)
           (void)]
          ;; 错误
          [else
           (printf "[ERROR] Recv error: ~a~n" data-or-error)])))

    server))

;; ========================================
;; 主程序
;; ========================================

(define (main)
  (printf "=== chez-async: UDP Echo Server ===~n")
  (printf "libuv version: ~a~n~n" (uv-version-string))

  (let ([loop (uv-loop-init)])
    ;; 启动服务器
    (let ([server (start-server loop *host* *port*)])

      (printf "~nPress Ctrl+C to stop the server~n")
      (printf "Test with: echo \"Hello\" | nc -u 127.0.0.1 ~a~n~n" *port*)

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
