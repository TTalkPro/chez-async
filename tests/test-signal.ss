#!/usr/bin/env scheme-script
;;; tests/test-signal.ss - Signal 功能测试
;;;
;;; 注意：Signal 测试需要直接使用 POSIX 系统调用（kill, getpid）
;;; 在不支持直接 libc 链接的平台（如 FreeBSD）上，这些测试会被跳过

(import (chezscheme)
        (chez-async tests framework)
        (chez-async high-level event-loop)
        (chez-async low-level signal)
        (chez-async low-level timer)
        (chez-async low-level handle-base)
        (chez-async internal posix-ffi))

;; Check if we can use direct system calls
(define %can-use-posix-ffi?
  (posix-ffi-available?))

;; 辅助函数：发送信号给当前进程
(define (send-signal signum)
  "向当前进程发送信号"
  (let ([pid (posix-getpid)])
    (posix-kill pid signum)))

;; Skip entire test group if POSIX FFI is not available
(unless %can-use-posix-ffi?
  (printf "=== Signal Tests ===~n")
  (printf "Note: Signal tests skipped - POSIX FFI not available on this platform~n")
  (printf "This is expected on some platforms (e.g., FreeBSD) that don't automatically link libc~n")
  (exit 0))

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
           [signal-received? #f]
           [received-signum #f])
      ;; 开始监听 SIGUSR1
      (uv-signal-start! sig SIGUSR1
        (lambda (s signum)
          (set! signal-received? #t)
          (set! received-signum signum)
          (uv-signal-stop! s)
          (uv-handle-close! s)))
      ;; 使用定时器延迟发送信号
      (uv-timer-start! timer 10 0
        (lambda (t)
          (send-signal SIGUSR1)
          (uv-handle-close! t)))
      ;; 运行事件循环
      (uv-run loop 'default)
      ;; 验证
      (assert-true signal-received? "should receive signal")
      (assert-equal SIGUSR1 received-signum "should receive SIGUSR1")
      ;; 清理
      (uv-loop-close loop)))

  (test "signal-one-shot"
    (let* ([loop (uv-loop-init)]
           [sig (uv-signal-init loop)]
           [timer (uv-timer-init loop)]
           [signal-count 0])
      ;; 开始监听 SIGUSR2（单次）
      (uv-signal-start! sig SIGUSR2
        (lambda (s signum)
          (set! signal-count (+ signal-count 1))
          (uv-signal-stop! s)
          (uv-handle-close! s)))
      ;; 发送两次信号
      (uv-timer-start! timer 10 0
        (lambda (t)
          (send-signal SIGUSR2)
          (send-signal SIGUSR2)
          (uv-handle-close! t)))
      ;; 运行事件循环
      (uv-run loop 'default)
      ;; 验证只触发了一次
      (assert-equal 1 signal-count "should only trigger once")
      ;; 清理
      (uv-loop-close loop)))

  (test "signal-multiple-handlers"
    (let* ([loop (uv-loop-init)]
           [sig1 (uv-signal-init loop)]
           [sig2 (uv-signal-init loop)]
           [timer (uv-timer-init loop)]
           [count1 0]
           [count2 0])
      ;; 两个句柄监听同一信号
      (uv-signal-start! sig1 SIGUSR1
        (lambda (s signum)
          (set! count1 (+ count1 1))
          (uv-signal-stop! s)
          (uv-handle-close! s)))
      (uv-signal-start! sig2 SIGUSR1
        (lambda (s signum)
          (set! count2 (+ count2 1))
          (uv-signal-stop! s)
          (uv-handle-close! s)))
      ;; 发送信号
      (uv-timer-start! timer 10 0
        (lambda (t)
          (send-signal SIGUSR1)
          (uv-handle-close! t)))
      ;; 运行事件循环
      (uv-run loop 'default)
      ;; 验证两个句柄都收到了信号
      (assert-true (= count1 1) "first handler should receive signal")
      (assert-true (= count2 1) "second handler should receive signal")
      ;; 清理
      (uv-loop-close loop)))

  ) ; end test-group

(run-tests)
