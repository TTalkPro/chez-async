#!/usr/bin/env scheme-script
;;; examples/timer-demo.ss - Timer 使用示例

(import (chezscheme)
        (chez-async high-level event-loop)
        (chez-async low-level timer)
        (chez-async low-level handle-base))

(printf "libuv version: ~a~n" (uv-version-string))
(printf "~n")

;; 示例 1: 单次定时器
(printf "=== Example 1: Single-shot timer ===~n")
(let ([loop (uv-loop-init)]
      [timer (uv-timer-init loop)])
  (printf "Starting 1 second timer...~n")
  (uv-timer-start! timer 1000 0
    (lambda (t)
      (printf "Timer fired after 1 second!~n")
      (uv-handle-close! t)))
  (uv-run loop 'default)
  (uv-loop-close loop))

(printf "~n")

;; 示例 2: 重复定时器
(printf "=== Example 2: Repeating timer ===~n")
(let ([loop (uv-loop-init)]
      [timer (uv-timer-init loop)]
      [count 0])
  (printf "Starting repeating timer (every 500ms)...~n")
  (uv-timer-start! timer 500 500
    (lambda (t)
      (set! count (+ count 1))
      (printf "Tick ~a~n" count)
      (when (= count 5)
        (printf "Stopping timer after 5 ticks~n")
        (uv-timer-stop! t)
        (uv-handle-close! t))))
  (uv-run loop 'default)
  (uv-loop-close loop))

(printf "~n")

;; 示例 3: 多个定时器
(printf "=== Example 3: Multiple timers ===~n")
(let ([loop (uv-loop-init)]
      [timer1 (uv-timer-init loop)]
      [timer2 (uv-timer-init loop)]
      [timer3 (uv-timer-init loop)])
  (printf "Starting 3 timers with different delays...~n")
  (uv-timer-start! timer1 1000 0
    (lambda (t)
      (printf "Timer 1: 1 second~n")
      (uv-handle-close! t)))
  (uv-timer-start! timer2 500 0
    (lambda (t)
      (printf "Timer 2: 500ms~n")
      (uv-handle-close! t)))
  (uv-timer-start! timer3 1500 0
    (lambda (t)
      (printf "Timer 3: 1.5 seconds~n")
      (uv-handle-close! t)))
  (uv-run loop 'default)
  (uv-loop-close loop))

(printf "~n")

;; 示例 4: 倒计时
(printf "=== Example 4: Countdown ===~n")
(let ([loop (uv-loop-init)]
      [timer (uv-timer-init loop)]
      [count 10])
  (printf "Starting countdown from 10...~n")
  (uv-timer-start! timer 0 1000
    (lambda (t)
      (printf "~a... " count)
      (flush-output-port (current-output-port))
      (set! count (- count 1))
      (when (< count 0)
        (printf "~nBlastoff!~n")
        (uv-timer-stop! t)
        (uv-handle-close! t))))
  (uv-run loop 'default)
  (uv-loop-close loop))

(printf "~nAll examples completed!~n")
