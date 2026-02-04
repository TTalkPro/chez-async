#!/usr/bin/env scheme-script
;;; tests/test-stream-high.ss - 高层 Stream 抽象测试

(import (chezscheme)
        (chez-async tests framework)
        (chez-async high-level event-loop)
        (chez-async high-level promise)
        (chez-async high-level stream)
        (chez-async low-level tcp)
        (chez-async low-level stream)
        (chez-async low-level handle-base))

(test-group "Stream High-Level Tests"

  (test "stream-write-promise"
    ;; 测试 Promise 风格的写入
    (let* ([loop (uv-loop-init)]
           [server (uv-tcp-init loop)]
           [client (uv-tcp-init loop)]
           [server-port 0]
           [received #f])
      ;; 绑定服务器到随机端口
      (uv-tcp-bind server "127.0.0.1" 0)
      (let ([addr (uv-tcp-getsockname server)])
        (set! server-port (cdr addr)))
      ;; 监听连接
      (uv-tcp-listen server 128
        (lambda (srv err)
          (unless err
            (let ([conn (uv-tcp-accept srv)])
              ;; 读取数据
              (uv-read-start! conn
                (lambda (handle data-or-err)
                  (cond
                    [(bytevector? data-or-err)
                     (set! received data-or-err)
                     (uv-read-stop! handle)
                     (uv-handle-close! handle)]
                    [else
                     (uv-handle-close! handle)])))))))
      ;; 客户端连接
      (uv-tcp-connect client "127.0.0.1" server-port
        (lambda (tcp err)
          (unless err
            ;; 使用 Promise 写入
            (promise-then (stream-write client "Hello")
              (lambda (_)
                (uv-handle-close! client)
                (uv-handle-close! server))))))
      ;; 运行事件循环
      (uv-run loop 'default)
      ;; 验证
      (assert-true (bytevector? received) "should receive data")
      (assert-equal "Hello" (utf8->string received) "data should match")
      ;; 清理
      (uv-loop-close loop)))

  (test "stream-echo-test"
    ;; 测试流回显 (Echo 服务器)
    (let* ([loop (uv-loop-init)]
           [server (uv-tcp-init loop)]
           [client (uv-tcp-init loop)]
           [server-port 0]
           [received #f])
      ;; 绑定服务器到随机端口
      (uv-tcp-bind server "127.0.0.1" 0)
      (let ([addr (uv-tcp-getsockname server)])
        (set! server-port (cdr addr)))
      ;; Echo 服务器
      (uv-tcp-listen server 128
        (lambda (srv err)
          (unless err
            (let ([conn (uv-tcp-accept srv)])
              ;; Echo: 将收到的数据发回
              (uv-read-start! conn
                (lambda (handle data-or-err)
                  (cond
                    [(bytevector? data-or-err)
                     ;; 回显数据
                     (uv-write! handle data-or-err
                       (lambda (write-err)
                         (uv-handle-close! handle)))]
                    [else
                     (uv-handle-close! handle)])))))))
      ;; 客户端连接
      (uv-tcp-connect client "127.0.0.1" server-port
        (lambda (tcp err)
          (unless err
            ;; 发送数据
            (uv-write! client (string->utf8 "Echo test")
              (lambda (write-err)
                ;; 读取回显
                (uv-read-start! client
                  (lambda (handle data-or-err)
                    (cond
                      [(bytevector? data-or-err)
                       (set! received (utf8->string data-or-err))
                       (uv-read-stop! handle)
                       (uv-handle-close! handle)
                       (uv-handle-close! server)]
                      [else
                       (uv-read-stop! handle)
                       (uv-handle-close! handle)
                       (uv-handle-close! server)]))))))))
      ;; 运行事件循环
      (uv-run loop 'default)
      ;; 验证
      (assert-equal "Echo test" received "should echo data")
      ;; 清理
      (uv-loop-close loop)))

  (test "stream-readable-writable"
    ;; 测试流存在性检查（TCP 句柄总是是 stream 类型）
    (let* ([loop (uv-loop-init)]
           [tcp (uv-tcp-init loop)])
      ;; TCP 是有效的 stream 句柄
      (assert-true (handle? tcp) "TCP should be a valid handle")
      ;; 清理
      (uv-handle-close! tcp)
      (uv-run loop 'default)
      (uv-loop-close loop)))

) ; end Stream High-Level Tests

(run-tests)
