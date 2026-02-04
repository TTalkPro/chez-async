#!/usr/bin/env scheme-script
;;; tests/test-signal.ss - Signal 功能测试

(import (chezscheme)
        (chez-async tests framework)
        (chez-async high-level event-loop)
        (chez-async low-level signal)
        (chez-async low-level timer)
        (chez-async low-level handle-base))

;; 辅助函数：发送信号给当前进程
(define %kill
  (foreign-procedure "kill" (int int) int))

(define (send-signal signum)
  "向当前进程发送信号"
  (let ([pid ((foreign-procedure "getpid" () int))])
    (%kill pid signum)))

(test-group "Signal Tests"

  (test "signal-init"
    (let* ([loop (uv-loop-init)]
           [sig (uv-signal-init loop)])
      ;; 验证信号句柄创建成功
      (assert-true (handle? sig) "should be a handle")
      (assert-equal 'signal (handle-type sig) "should be signal type")
      ;; 清理
      (uv-handle-close! sig)
      (uv-run loop 'default)
      (uv-loop-close loop)))

  (test "signal-start-stop"
    (let* ([loop (uv-loop-init)]
           [sig (uv-signal-init loop)])
      ;; 开始监听 SIGUSR1
      (uv-signal-start! sig SIGUSR1
        (lambda (s signum)
          (void)))
      ;; 停止监听
      (uv-signal-stop! sig)
      ;; 清理
      (uv-handle-close! sig)
      (uv-run loop 'default)
      (uv-loop-close loop)))

  (test "signal-receive"
    (let* ([loop (uv-loop-init)]
           [sig (uv-signal-init loop)]
           [timer (uv-timer-init loop)]
           [received-signal #f]
           [signal-count 0])
      ;; 开始监听 SIGUSR1
      (uv-signal-start! sig SIGUSR1
        (lambda (s signum)
          (set! received-signal signum)
          (set! signal-count (+ signal-count 1))
          ;; 停止监听并关闭
          (uv-signal-stop! s)
          (uv-handle-close! s)))
      ;; 使用定时器延迟发送信号（让事件循环先启动）
      (uv-timer-start! timer 10 0
        (lambda (t)
          (send-signal SIGUSR1)
          (uv-handle-close! t)))
      ;; 运行事件循环
      (uv-run loop 'default)
      ;; 验证
      (assert-equal SIGUSR1 received-signal "should receive SIGUSR1")
      (assert-equal 1 signal-count "should receive exactly 1 signal")
      ;; 清理
      (uv-loop-close loop)))

  (test "signal-oneshot"
    (let* ([loop (uv-loop-init)]
           [sig (uv-signal-init loop)]
           [timer (uv-timer-init loop)]
           [signal-count 0])
      ;; 使用一次性监听
      (uv-signal-start-oneshot! sig SIGUSR2
        (lambda (s signum)
          (set! signal-count (+ signal-count 1))
          ;; oneshot 自动停止，只需关闭句柄
          (uv-handle-close! s)))
      ;; 使用定时器发送信号
      (uv-timer-start! timer 10 0
        (lambda (t)
          (send-signal SIGUSR2)
          (uv-handle-close! t)))
      ;; 运行事件循环
      (uv-run loop 'default)
      ;; 验证：oneshot 只触发一次
      (assert-equal 1 signal-count "oneshot should trigger exactly once")
      ;; 清理
      (uv-loop-close loop)))

  (test "signal-multiple-handlers"
    (let* ([loop (uv-loop-init)]
           [sig1 (uv-signal-init loop)]
           [sig2 (uv-signal-init loop)]
           [timer (uv-timer-init loop)]
           [handler1-count 0]
           [handler2-count 0])
      ;; 两个句柄监听同一个信号
      (uv-signal-start! sig1 SIGUSR1
        (lambda (s signum)
          (set! handler1-count (+ handler1-count 1))
          (uv-signal-stop! s)
          (uv-handle-close! s)))
      (uv-signal-start! sig2 SIGUSR1
        (lambda (s signum)
          (set! handler2-count (+ handler2-count 1))
          (uv-signal-stop! s)
          (uv-handle-close! s)))
      ;; 发送信号
      (uv-timer-start! timer 10 0
        (lambda (t)
          (send-signal SIGUSR1)
          (uv-handle-close! t)))
      ;; 运行事件循环
      (uv-run loop 'default)
      ;; 验证：两个处理器都应该收到信号
      (assert-equal 1 handler1-count "handler1 should receive signal")
      (assert-equal 1 handler2-count "handler2 should receive signal")
      ;; 清理
      (uv-loop-close loop)))

  (test "signum->name"
    (assert-equal "SIGINT" (signum->name SIGINT) "SIGINT name")
    (assert-equal "SIGTERM" (signum->name SIGTERM) "SIGTERM name")
    (assert-equal "SIGHUP" (signum->name SIGHUP) "SIGHUP name")
    (assert-equal "SIGUSR1" (signum->name SIGUSR1) "SIGUSR1 name")
    (assert-equal "SIGUSR2" (signum->name SIGUSR2) "SIGUSR2 name"))

) ; end test-group

(run-tests)
