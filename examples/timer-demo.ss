#!/usr/bin/env scheme-script
;;; examples/timer-demo.ss - Timer 使用示例（展示简化 API）

(import (chezscheme)
        (chez-async))

(printf "=== chez-async: Timer Demo ===~n")
(printf "libuv version: ~a~n~n" (uv-version-string))

;; ========================================
;; 示例 1: 单次定时器
;; ========================================

(printf "=== Example 1: Single-shot timer ===~n")
(let ([loop (uv-loop-init)]
      [timer (uv-timer-init loop)])
  (printf "Timer created~n")
  (printf "  - Type: ~a~n" (handle-type timer))
  (printf "  - Closed?: ~a~n" (handle-closed? timer))

  (printf "Starting 1 second timer...~n")
  (uv-timer-start! timer 1000 0
    (lambda (t)
      (printf "Timer fired after 1 second!~n")
      (uv-handle-close! t)))
  (uv-run loop 'default)
  (uv-loop-close loop))

(printf "~n")

;; ========================================
;; 示例 2: 重复定时器
;; ========================================

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

;; ========================================
;; 示例 3: 多个定时器
;; ========================================

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

;; ========================================
;; 示例 4: 使用简化 API 操作句柄
;; ========================================

(printf "=== Example 4: Simplified handle API ===~n")
(let ([loop (uv-loop-init)]
      [timer (uv-timer-init loop)])

  ;; 展示简化的访问器
  (printf "Handle information:~n")
  (printf "  - handle?: ~a~n" (handle? timer))
  (printf "  - handle-type: ~a~n" (handle-type timer))
  (printf "  - handle-closed?: ~a~n" (handle-closed? timer))

  ;; 使用 handle-data 存储自定义数据
  (printf "~nStoring custom data...~n")
  (define custom-data '(name "MyTimer" count 0))
  (handle-data-set! timer custom-data)
  (printf "  - Stored: ~s~n" (handle-data timer))

  ;; 启动定时器
  (uv-timer-start! timer 500 0
    (lambda (t)
      (let ([data (handle-data t)])
        (printf "Timer callback with data: ~s~n" data))
      (uv-handle-close! t)))

  (uv-run loop 'default)
  (uv-loop-close loop))

(printf "~n")

;; ========================================
;; 示例 5: Timer 控制
;; ========================================

(printf "=== Example 5: Timer control (set-repeat, again) ===~n")
(let ([loop (uv-loop-init)]
      [timer (uv-timer-init loop)]
      [ticks 0])

  ;; 启动重复定时器
  (uv-timer-start! timer 0 200
    (lambda (t)
      (set! ticks (+ ticks 1))
      (printf "Tick ~a~n" ticks)

      (cond
        [(= ticks 3)
         (printf "  -> Changing repeat to 400ms~n")
         (uv-timer-set-repeat! t 400)
         (uv-timer-again! t)]
        [(= ticks 6)
         (printf "  -> Stopping~n")
         (uv-timer-stop! t)
         (uv-handle-close! t)])))

  (printf "Initial repeat: ~ams~n" (uv-timer-get-repeat timer))
  (uv-run loop 'default)
  (uv-loop-close loop))

(printf "~n")

(printf "=== All timer examples completed! ===~n")
