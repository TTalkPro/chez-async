#!/usr/bin/env scheme-script
;;; tests/test-tcp.ss - TCP 功能测试

(import (chezscheme)
        (chez-async tests framework)
        (chez-async high-level event-loop)
        (chez-async low-level tcp)
        (chez-async low-level handle-base)
        (chez-async low-level sockaddr)
        (chez-async ffi types))

(test-group "TCP Tests"

  (test "tcp-init"
    (let* ([loop (uv-loop-init)]
           [tcp (uv-tcp-init loop)])
      ;; 验证 TCP 句柄创建成功
      (assert-true (handle? tcp) "should be a handle")
      (assert-equal 'tcp (handle-type tcp) "should be tcp type")
      ;; 清理
      (uv-handle-close! tcp)
      (uv-run loop 'default)
      (uv-loop-close loop)))

  (test "tcp-bind"
    (let* ([loop (uv-loop-init)]
           [tcp (uv-tcp-init loop)])
      ;; 绑定到本地地址
      (uv-tcp-bind tcp "127.0.0.1" 0)  ; 端口 0 让系统选择
      ;; 获取绑定的地址
      (let ([addr (uv-tcp-getsockname tcp)])
        (assert-equal "127.0.0.1" (car addr) "should be bound to 127.0.0.1")
        (assert-true (> (cdr addr) 0) "should have a valid port"))
      ;; 清理
      (uv-handle-close! tcp)
      (uv-run loop 'default)
      (uv-loop-close loop)))

  (test "tcp-echo-server"
    (let* ([loop (uv-loop-init)]
           [server (uv-tcp-init loop)]
           [client (uv-tcp-init loop)]
           [server-port 0]
           [received-data #f]
           [test-message "Hello, TCP!"])
      ;; 绑定服务器
      (uv-tcp-bind server "127.0.0.1" 0)
      (let ([addr (uv-tcp-getsockname server)])
        (set! server-port (cdr addr)))
      ;; 监听连接
      (uv-tcp-listen server 128
        (lambda (srv err)
          (if err
              (printf "Listen error: ~a~n" err)
              ;; 接受连接
              (let ([client-conn (uv-tcp-accept srv)])
                ;; 开始读取数据
                (uv-read-start! client-conn
                  (lambda (stream data-or-err)
                    (cond
                      [(bytevector? data-or-err)
                       ;; 收到数据，回显
                       (set! received-data (utf8->string data-or-err))
                       (uv-write! client-conn data-or-err
                         (lambda (err)
                           (when err
                             (printf "Write error: ~a~n" err))
                           ;; 关闭连接
                           (uv-handle-close! client-conn)))]
                      [(not data-or-err)
                       ;; EOF
                       (uv-handle-close! client-conn)]
                      [else
                       ;; 错误
                       (printf "Read error: ~a~n" data-or-err)
                       (uv-handle-close! client-conn)])))))))
      ;; 客户端连接
      (uv-tcp-connect client "127.0.0.1" server-port
        (lambda (tcp err)
          (if err
              (begin
                (printf "Connect error: ~a~n" err)
                (uv-handle-close! tcp))
              ;; 连接成功，发送数据
              (begin
                (uv-write! tcp test-message
                  (lambda (err)
                    (when err
                      (printf "Client write error: ~a~n" err))))
                ;; 读取回显
                (uv-read-start! tcp
                  (lambda (stream data-or-err)
                    (cond
                      [(bytevector? data-or-err)
                       ;; 收到回显，验证
                       (let ([echo (utf8->string data-or-err)])
                         (assert-equal test-message echo "echo should match"))
                       ;; 关闭客户端
                       (uv-handle-close! tcp)
                       ;; 关闭服务器
                       (uv-handle-close! server)]
                      [(not data-or-err)
                       ;; EOF
                       (uv-handle-close! tcp)
                       (uv-handle-close! server)]
                      [else
                       (printf "Client read error: ~a~n" data-or-err)
                       (uv-handle-close! tcp)
                       (uv-handle-close! server)])))))))
      ;; 运行事件循环
      (uv-run loop 'default)
      ;; 验证
      (assert-equal test-message received-data "server should receive the message")
      ;; 清理
      (uv-loop-close loop)))

  (test "tcp-options"
    (let* ([loop (uv-loop-init)]
           [tcp (uv-tcp-init loop)])
      ;; 设置 TCP 选项
      (uv-tcp-nodelay! tcp #t)
      (uv-tcp-keepalive! tcp #t 60)
      ;; 这些设置不会抛出错误就算成功
      ;; 清理
      (uv-handle-close! tcp)
      (uv-run loop 'default)
      (uv-loop-close loop)))

  (test "tcp-connect-error"
    (let* ([loop (uv-loop-init)]
           [tcp (uv-tcp-init loop)]
           [got-error? #f])
      ;; 尝试连接到一个应该不可达的地址
      (uv-tcp-connect tcp "127.0.0.1" 1  ; 端口 1 通常不可用
        (lambda (tcp err)
          (when err
            (set! got-error? #t))
          (uv-handle-close! tcp)))
      ;; 运行事件循环
      (uv-run loop 'default)
      ;; 验证收到错误
      (assert-true got-error? "should get connection error")
      ;; 清理
      (uv-loop-close loop)))

  (test "tcp-multiple-clients"
    (let* ([loop (uv-loop-init)]
           [server (uv-tcp-init loop)]
           [client1 (uv-tcp-init loop)]
           [client2 (uv-tcp-init loop)]
           [server-port 0]
           [connections 0]
           [responses 0])
      ;; 绑定服务器
      (uv-tcp-bind server "127.0.0.1" 0)
      (let ([addr (uv-tcp-getsockname server)])
        (set! server-port (cdr addr)))
      ;; 监听连接
      (uv-tcp-listen server 128
        (lambda (srv err)
          (unless err
            (let ([client-conn (uv-tcp-accept srv)])
              (set! connections (+ connections 1))
              ;; 立即关闭连接
              (uv-write! client-conn "OK"
                (lambda (err)
                  (uv-handle-close! client-conn)
                  ;; 当两个客户端都连接后关闭服务器
                  (when (= connections 2)
                    (uv-handle-close! server))))))))
      ;; 客户端处理函数
      (letrec ([handle-client
                (lambda (tcp)
                  (lambda (tcp err)
                    (if err
                        (uv-handle-close! tcp)
                        (uv-read-start! tcp
                          (lambda (stream data-or-err)
                            (when (bytevector? data-or-err)
                              (set! responses (+ responses 1)))
                            (uv-handle-close! tcp))))))])
        ;; 两个客户端连接
        (uv-tcp-connect client1 "127.0.0.1" server-port
          (handle-client client1))
        (uv-tcp-connect client2 "127.0.0.1" server-port
          (handle-client client2)))
      ;; 运行事件循环
      (uv-run loop 'default)
      ;; 验证
      (assert-equal 2 connections "should have 2 connections")
      (assert-equal 2 responses "should have 2 responses")
      ;; 清理
      (uv-loop-close loop)))

) ; end test-group

;; 地址转换测试
(test-group "Address Tests"

  (test "sockaddr-in-create"
    (let ([addr (make-sockaddr-in "192.168.1.1" 8080)])
      (assert-true (not (= addr 0)) "should create valid sockaddr")
      (assert-equal 8080 (sockaddr-in-port addr) "port should be 8080")
      (assert-equal "192.168.1.1" (sockaddr-in-addr addr) "addr should match")
      (free-sockaddr addr)))

  (test "parse-address-ipv4"
    (let ([addr (parse-address "10.0.0.1" 3000)])
      (assert-true (not (= addr 0)) "should create valid sockaddr")
      (free-sockaddr addr)))

) ; end test-group

(run-tests)
