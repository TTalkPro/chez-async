#!/usr/bin/env scheme-script
;;; tests/test-udp.ss - UDP 功能测试

(import (chezscheme)
        (chez-async tests framework)
        (chez-async high-level event-loop)
        (chez-async low-level udp)
        (chez-async low-level handle-base)
        (chez-async low-level sockaddr)
        (chez-async ffi types))

(test-group "UDP Tests"

  (test "udp-init"
    (let* ([loop (uv-loop-init)]
           [udp (uv-udp-init loop)])
      ;; 验证 UDP 句柄创建成功
      (assert-true (handle? udp) "should be a handle")
      (assert-equal 'udp (handle-type udp) "should be udp type")
      ;; 清理
      (uv-handle-close! udp)
      (uv-run loop 'default)
      (uv-loop-close loop)))

  (test "udp-bind"
    (let* ([loop (uv-loop-init)]
           [udp (uv-udp-init loop)])
      ;; 绑定到本地地址
      (uv-udp-bind udp "127.0.0.1" 0)  ; 端口 0 让系统选择
      ;; 获取绑定的地址
      (let ([addr (uv-udp-getsockname udp)])
        (assert-equal "127.0.0.1" (car addr) "should be bound to 127.0.0.1")
        (assert-true (> (cdr addr) 0) "should have a valid port"))
      ;; 清理
      (uv-handle-close! udp)
      (uv-run loop 'default)
      (uv-loop-close loop)))

  (test "udp-echo"
    (let* ([loop (uv-loop-init)]
           [server (uv-udp-init loop)]
           [client (uv-udp-init loop)]
           [server-port 0]
           [received-data #f]
           [received-from #f]
           [echo-received #f]
           [test-message "Hello, UDP!"])
      ;; 绑定服务器
      (uv-udp-bind server "127.0.0.1" 0)
      (let ([addr (uv-udp-getsockname server)])
        (set! server-port (cdr addr)))
      ;; 开始接收（服务器）
      (uv-udp-recv-start! server
        (lambda (udp data-or-error sender-addr flags)
          (cond
            [(bytevector? data-or-error)
             ;; 收到数据，记录并回显
             (set! received-data (utf8->string data-or-error))
             (set! received-from sender-addr)
             ;; 回显数据给发送方
             (uv-udp-send! udp data-or-error
                           (car sender-addr)
                           (cdr sender-addr)
               (lambda (err)
                 (when err
                   (printf "Server send error: ~a~n" err))
                 ;; 停止接收并关闭服务器
                 (uv-udp-recv-stop! udp)
                 (uv-handle-close! udp)))]
            [(not data-or-error)
             ;; 无数据
             (void)]
            [else
             ;; 错误
             (printf "Server recv error: ~a~n" data-or-error)
             (uv-udp-recv-stop! udp)
             (uv-handle-close! udp)])))
      ;; 绑定客户端（以便接收回显）
      (uv-udp-bind client "127.0.0.1" 0)
      ;; 发送数据到服务器
      (uv-udp-send! client (string->utf8 test-message)
                    "127.0.0.1" server-port
        (lambda (err)
          (when err
            (printf "Client send error: ~a~n" err))))
      ;; 开始接收回显（客户端）
      (uv-udp-recv-start! client
        (lambda (udp data-or-error sender-addr flags)
          (cond
            [(bytevector? data-or-error)
             ;; 收到回显
             (set! echo-received (utf8->string data-or-error))
             ;; 关闭客户端
             (uv-udp-recv-stop! udp)
             (uv-handle-close! udp)]
            [(not data-or-error)
             (void)]
            [else
             (printf "Client recv error: ~a~n" data-or-error)
             (uv-udp-recv-stop! udp)
             (uv-handle-close! udp)])))
      ;; 运行事件循环
      (uv-run loop 'default)
      ;; 验证
      (assert-equal test-message received-data "server should receive the message")
      (assert-equal test-message echo-received "client should receive the echo")
      (assert-true (pair? received-from) "should have sender address")
      (assert-equal "127.0.0.1" (car received-from) "sender should be 127.0.0.1")
      ;; 清理
      (uv-loop-close loop)))

  (test "udp-broadcast-option"
    (let* ([loop (uv-loop-init)]
           [udp (uv-udp-init loop)])
      ;; 绑定后才能设置广播选项
      (uv-udp-bind udp "0.0.0.0" 0)
      ;; 设置广播选项
      (uv-udp-set-broadcast! udp #t)
      (uv-udp-set-broadcast! udp #f)
      ;; 这些设置不会抛出错误就算成功
      ;; 清理
      (uv-handle-close! udp)
      (uv-run loop 'default)
      (uv-loop-close loop)))

  (test "udp-ttl-option"
    (let* ([loop (uv-loop-init)]
           [udp (uv-udp-init loop)])
      ;; 绑定后才能设置 TTL
      (uv-udp-bind udp "127.0.0.1" 0)
      ;; 设置 TTL 选项
      (uv-udp-set-ttl! udp 64)
      (uv-udp-set-ttl! udp 128)
      ;; 清理
      (uv-handle-close! udp)
      (uv-run loop 'default)
      (uv-loop-close loop)))

  (test "udp-multicast-options"
    (let* ([loop (uv-loop-init)]
           [udp (uv-udp-init loop)])
      ;; 绑定后才能设置多播选项
      (uv-udp-bind udp "0.0.0.0" 0)
      ;; 设置多播选项
      (uv-udp-set-multicast-loop! udp #t)
      (uv-udp-set-multicast-ttl! udp 32)
      ;; 清理
      (uv-handle-close! udp)
      (uv-run loop 'default)
      (uv-loop-close loop)))

  (test "udp-connect-disconnect"
    (let* ([loop (uv-loop-init)]
           [server (uv-udp-init loop)]
           [client (uv-udp-init loop)]
           [server-port 0]
           [received-count 0]
           [test-message "Connected UDP!"])
      ;; 绑定服务器
      (uv-udp-bind server "127.0.0.1" 0)
      (let ([addr (uv-udp-getsockname server)])
        (set! server-port (cdr addr)))
      ;; 开始接收（服务器）
      (uv-udp-recv-start! server
        (lambda (udp data-or-error sender-addr flags)
          (when (bytevector? data-or-error)
            (set! received-count (+ received-count 1))
            ;; 只接收一个就关闭
            (uv-udp-recv-stop! udp)
            (uv-handle-close! udp))))
      ;; 客户端连接到服务器
      (uv-udp-connect client "127.0.0.1" server-port)
      ;; 验证 getpeername
      (let ([peer (uv-udp-getpeername client)])
        (assert-equal "127.0.0.1" (car peer) "should be connected to 127.0.0.1")
        (assert-equal server-port (cdr peer) "should be connected to server port"))
      ;; 使用无地址的发送（因为已连接）
      (uv-udp-send! client (string->utf8 test-message)
        (lambda (err)
          (when err
            (printf "Connected send error: ~a~n" err))
          ;; 断开连接
          (uv-udp-disconnect client)
          ;; 关闭客户端
          (uv-handle-close! client)))
      ;; 运行事件循环
      (uv-run loop 'default)
      ;; 验证
      (assert-equal 1 received-count "server should receive 1 message")
      ;; 清理
      (uv-loop-close loop)))

  (test "udp-send-queue"
    (let* ([loop (uv-loop-init)]
           [udp (uv-udp-init loop)])
      ;; 初始队列应该为空
      (assert-equal 0 (uv-udp-send-queue-size udp) "initial queue size should be 0")
      (assert-equal 0 (uv-udp-send-queue-count udp) "initial queue count should be 0")
      ;; 清理
      (uv-handle-close! udp)
      (uv-run loop 'default)
      (uv-loop-close loop)))

) ; end test-group

(run-tests)
