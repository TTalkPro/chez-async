#!/usr/bin/env scheme-script
;;; tests/test-pipe.ss - Pipe 功能测试

(import (chezscheme)
        (chez-async tests framework)
        (chez-async high-level event-loop)
        (chez-async low-level pipe)
        (chez-async low-level handle-base)
        (chez-async ffi types))

;; 辅助函数：生成唯一的管道路径
(define (make-pipe-path prefix)
  (format "/tmp/chez-async-test-~a-~a.sock" prefix (random 1000000)))

;; 辅助函数：删除管道文件
(define (delete-pipe-file path)
  (when (file-exists? path)
    (delete-file path)))

(test-group "Pipe Tests"

  (test "pipe-init"
    (let* ([loop (uv-loop-init)]
           [pipe (uv-pipe-init loop)])
      ;; 验证 Pipe 句柄创建成功
      (assert-true (handle? pipe) "should be a handle")
      (assert-equal 'pipe (handle-type pipe) "should be pipe type")
      ;; 清理
      (uv-handle-close! pipe)
      (uv-run loop 'default)
      (uv-loop-close loop)))

  (test "pipe-init-ipc"
    (let* ([loop (uv-loop-init)]
           [pipe (uv-pipe-init loop #t)])  ; IPC 模式
      ;; 验证 IPC Pipe 句柄创建成功
      (assert-true (handle? pipe) "should be a handle")
      (assert-equal 'pipe (handle-type pipe) "should be pipe type")
      ;; 清理
      (uv-handle-close! pipe)
      (uv-run loop 'default)
      (uv-loop-close loop)))

  (test "pipe-bind"
    (let* ([loop (uv-loop-init)]
           [pipe (uv-pipe-init loop)]
           [path (make-pipe-path "bind")])
      ;; 确保路径不存在
      (delete-pipe-file path)
      ;; 绑定到路径
      (uv-pipe-bind pipe path)
      ;; 获取绑定的路径
      (let ([name (uv-pipe-getsockname pipe)])
        (assert-equal path name "should be bound to the path"))
      ;; 清理
      (uv-handle-close! pipe)
      (uv-run loop 'default)
      (uv-loop-close loop)
      (delete-pipe-file path)))

  (test "pipe-echo"
    (let* ([loop (uv-loop-init)]
           [server (uv-pipe-init loop)]
           [client (uv-pipe-init loop)]
           [path (make-pipe-path "echo")]
           [received-data #f]
           [test-message "Hello, Pipe!"])
      ;; 确保路径不存在
      (delete-pipe-file path)
      ;; 绑定服务器
      (uv-pipe-bind server path)
      ;; 监听连接
      (uv-pipe-listen server 128
        (lambda (srv err)
          (if err
              (printf "Listen error: ~a~n" err)
              ;; 接受连接
              (let ([client-conn (uv-pipe-accept srv)])
                ;; 开始读取数据
                (uv-read-start! client-conn
                  (lambda (stream data-or-err)
                    (cond
                      [(bytevector? data-or-err)
                       ;; 收到数据，记录并回显
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
      (uv-pipe-connect client path
        (lambda (pipe err)
          (if err
              (begin
                (printf "Connect error: ~a~n" err)
                (uv-handle-close! pipe))
              ;; 连接成功，发送数据
              (begin
                (uv-write! pipe test-message
                  (lambda (err)
                    (when err
                      (printf "Client write error: ~a~n" err))))
                ;; 读取回显
                (uv-read-start! pipe
                  (lambda (stream data-or-err)
                    (cond
                      [(bytevector? data-or-err)
                       ;; 收到回显，验证
                       (let ([echo (utf8->string data-or-err)])
                         (assert-equal test-message echo "echo should match"))
                       ;; 关闭客户端
                       (uv-handle-close! pipe)
                       ;; 关闭服务器
                       (uv-handle-close! server)]
                      [(not data-or-err)
                       ;; EOF
                       (uv-handle-close! pipe)
                       (uv-handle-close! server)]
                      [else
                       (printf "Client read error: ~a~n" data-or-err)
                       (uv-handle-close! pipe)
                       (uv-handle-close! server)])))))))
      ;; 运行事件循环
      (uv-run loop 'default)
      ;; 验证
      (assert-equal test-message received-data "server should receive the message")
      ;; 清理
      (uv-loop-close loop)
      (delete-pipe-file path)))

  (test "pipe-connect-error"
    (let* ([loop (uv-loop-init)]
           [pipe (uv-pipe-init loop)]
           [path "/tmp/nonexistent-pipe-12345.sock"]
           [got-error? #f])
      ;; 确保路径不存在
      (delete-pipe-file path)
      ;; 尝试连接到不存在的路径
      (uv-pipe-connect pipe path
        (lambda (pipe err)
          (when err
            (set! got-error? #t))
          (uv-handle-close! pipe)))
      ;; 运行事件循环
      (uv-run loop 'default)
      ;; 验证收到错误
      (assert-true got-error? "should get connection error")
      ;; 清理
      (uv-loop-close loop)))

  (test "pipe-chmod"
    (let* ([loop (uv-loop-init)]
           [pipe (uv-pipe-init loop)]
           [path (make-pipe-path "chmod")])
      ;; 确保路径不存在
      (delete-pipe-file path)
      ;; 绑定到路径
      (uv-pipe-bind pipe path)
      ;; 设置权限（可读可写）
      (uv-pipe-chmod! pipe (bitwise-ior UV_READABLE UV_WRITABLE))
      ;; 清理
      (uv-handle-close! pipe)
      (uv-run loop 'default)
      (uv-loop-close loop)
      (delete-pipe-file path)))

  (test "pipe-pending-count"
    (let* ([loop (uv-loop-init)]
           [pipe (uv-pipe-init loop #t)])  ; IPC 模式
      ;; 初始时没有待处理的句柄
      (assert-equal 0 (uv-pipe-pending-count pipe) "should have no pending handles")
      ;; 清理
      (uv-handle-close! pipe)
      (uv-run loop 'default)
      (uv-loop-close loop)))

) ; end test-group

(run-tests)
