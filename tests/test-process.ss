#!/usr/bin/env scheme-script
;;; tests/test-process.ss - 进程管理功能测试

(import (chezscheme)
        (chez-async tests framework)
        (chez-async high-level event-loop)
        (chez-async low-level process)
        (chez-async low-level handle-base)
        (chez-async low-level signal))

(test-group "Process Tests"

  (test "process-spawn-echo"
    ;; 测试启动简单命令
    (let* ([loop (uv-loop-init)]
           [exit-status #f]
           [term-signal #f]
           [pid #f])
      ;; 启动 echo 命令
      (let ([proc (uv-spawn loop "/bin/echo"
                    '("Hello" "World")
                    (lambda (process status signal)
                      (set! exit-status status)
                      (set! term-signal signal)))])
        ;; 获取 PID
        (set! pid (uv-process-get-pid proc))
        (assert-true (> pid 0) "should have valid PID"))
      ;; 运行事件循环
      (uv-run loop 'default)
      ;; 验证
      (assert-equal 0 exit-status "exit status should be 0")
      (assert-equal 0 term-signal "term signal should be 0")
      ;; 清理
      (uv-loop-close loop)))

  (test "process-spawn-with-exit-code"
    ;; 测试进程返回非零退出码
    (let* ([loop (uv-loop-init)]
           [exit-status #f]
           ;; 使用 sh -c 'exit 1' 替代 /bin/false，更具可移植性
           [false-cmd "/bin/sh"])
      (uv-spawn loop false-cmd
        '("-c" "exit 1")
        (lambda (process status signal)
          (set! exit-status status)))
      ;; 运行事件循环
      (uv-run loop 'default)
      ;; 验证
      (assert-equal 1 exit-status "exit status should be 1")
      ;; 清理
      (uv-loop-close loop)))

  (test "process-spawn-with-cwd"
    ;; 测试指定工作目录
    (let* ([loop (uv-loop-init)]
           [exit-status #f])
      ;; 启动 pwd 命令，在 /tmp 目录
      (uv-spawn loop "/bin/pwd"
        '()
        (lambda (process status signal)
          (set! exit-status status))
        "/tmp")  ; cwd
      ;; 运行事件循环
      (uv-run loop 'default)
      ;; 验证成功退出
      (assert-equal 0 exit-status "exit status should be 0")
      ;; 清理
      (uv-loop-close loop)))

  (test "process-spawn-nonexistent"
    ;; 测试启动不存在的命令
    (let* ([loop (uv-loop-init)]
           [error-caught #f])
      (guard (e [else (set! error-caught #t)])
        (uv-spawn loop "/nonexistent/command"
          '()
          (lambda (process status signal) #f)))
      ;; 验证
      (assert-true error-caught "should throw error for nonexistent command")
      ;; 运行一次事件循环（清理任何内部状态）
      (uv-run loop 'nowait)
      ;; 清理
      (uv-loop-close loop)))

  (test "process-kill"
    ;; 测试发送信号给进程
    (let* ([loop (uv-loop-init)]
           [exit-status #f]
           [term-signal #f])
      ;; 启动 sleep 命令
      (let ([proc (uv-spawn loop "/bin/sleep"
                    '("10")  ; sleep 10 seconds
                    (lambda (process status signal)
                      (set! exit-status status)
                      (set! term-signal signal)))])
        ;; 立即杀死进程
        (uv-process-kill! proc SIGTERM))
      ;; 运行事件循环
      (uv-run loop 'default)
      ;; 验证被信号终止
      (assert-equal SIGTERM term-signal "should be terminated by SIGTERM")
      ;; 清理
      (uv-loop-close loop)))

  (test "process-detached"
    ;; 测试分离进程
    (let* ([loop (uv-loop-init)]
           [pid #f]
           [proc #f])
      ;; 启动分离进程
      (set! proc (uv-spawn loop "/bin/sleep"
                    '("0.1")
                    (lambda (process status signal) #f)
                    #f #f UV_PROCESS_DETACHED))
      (set! pid (uv-process-get-pid proc))
      ;; 取消引用，让事件循环可以退出
      (uv-handle-unref! proc)
      ;; 验证 PID 有效
      (assert-true (> pid 0) "should have valid PID")
      ;; 关闭句柄（分离进程会继续运行，但我们释放句柄）
      (uv-handle-close! proc)
      ;; 运行事件循环以处理关闭回调
      (uv-run loop 'default)
      ;; 清理
      (uv-loop-close loop)))

) ; end test-group

(run-tests)
