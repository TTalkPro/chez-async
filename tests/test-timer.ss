#!/usr/bin/env scheme-script
;;; tests/test-timer.ss - Timer 功能测试

(import (chezscheme)
        (chez-async tests framework)
        (chez-async high-level event-loop)
        (chez-async low-level timer)
        (chez-async low-level handle-base))

(test-group "Timer Tests"

  (test "timer-single-shot"
    (let* ([loop (uv-loop-init)]
           [timer (uv-timer-init loop)]
           [fired? #f]
           [fire-count 0])
      ;; 启动单次定时器（100ms 后触发）
      (uv-timer-start! timer 100 0
        (lambda (t)
          (set! fired? #t)
          (set! fire-count (+ fire-count 1))
          ;; 关闭 timer
          (uv-handle-close! t)))
      ;; 运行事件循环
      (uv-run loop 'default)
      ;; 验证
      (assert-true fired? "timer should have fired")
      (assert-equal 1 fire-count "timer should fire exactly once")
      ;; 清理
      (uv-loop-close loop)))

  (test "timer-repeat"
    (let* ([loop (uv-loop-init)]
           [timer (uv-timer-init loop)]
           [fire-count 0])
      ;; 启动重复定时器（100ms 后首次触发，然后每 50ms 触发一次）
      (uv-timer-start! timer 100 50
        (lambda (t)
          (set! fire-count (+ fire-count 1))
          ;; 触发 3 次后停止
          (when (= fire-count 3)
            (uv-timer-stop! t)
            (uv-handle-close! t))))
      ;; 运行事件循环
      (uv-run loop 'default)
      ;; 验证
      (assert-equal 3 fire-count "timer should fire exactly 3 times")
      ;; 清理
      (uv-loop-close loop)))

  (test "timer-stop"
    (let* ([loop (uv-loop-init)]
           [timer (uv-timer-init loop)]
           [fired? #f])
      ;; 启动定时器
      (uv-timer-start! timer 100 0
        (lambda (t)
          (set! fired? #t)))
      ;; 立即停止定时器
      (uv-timer-stop! timer)
      ;; 关闭 timer
      (uv-handle-close! timer)
      ;; 运行事件循环
      (uv-run loop 'default)
      ;; 验证定时器没有触发
      (assert-false fired? "timer should not have fired")
      ;; 清理
      (uv-loop-close loop)))

  (test "timer-again"
    (let* ([loop (uv-loop-init)]
           [timer (uv-timer-init loop)]
           [fire-count 0])
      ;; 设置重复间隔
      (uv-timer-set-repeat! timer 50)
      ;; 启动定时器
      (uv-timer-start! timer 100 50
        (lambda (t)
          (set! fire-count (+ fire-count 1))
          (cond
            [(= fire-count 1)
             ;; 第一次触发后，停止定时器
             (uv-timer-stop! t)]
            [(= fire-count 2)
             ;; 第二次触发后，关闭定时器
             (uv-handle-close! t)])))
      ;; 运行一次
      (uv-run loop 'default)
      ;; 此时应该触发 1 次
      (assert-equal 1 fire-count "timer should fire once")
      ;; 使用 again 重启定时器
      (uv-timer-again! timer)
      ;; 再次运行
      (uv-run loop 'default)
      ;; 此时应该触发 2 次
      (assert-equal 2 fire-count "timer should fire twice")
      ;; 清理
      (uv-loop-close loop)))

  (test "timer-get-repeat"
    (let* ([loop (uv-loop-init)]
           [timer (uv-timer-init loop)])
      ;; 设置重复间隔
      (uv-timer-set-repeat! timer 123)
      ;; 验证
      (assert-equal 123 (uv-timer-get-repeat timer) "repeat should be 123")
      ;; 清理
      (uv-handle-close! timer)
      (uv-run loop 'default)
      (uv-loop-close loop)))

  (test "multiple-timers"
    (let* ([loop (uv-loop-init)]
           [timer1 (uv-timer-init loop)]
           [timer2 (uv-timer-init loop)]
           [timer3 (uv-timer-init loop)]
           [results '()])
      ;; 启动 3 个不同延迟的定时器
      (uv-timer-start! timer1 150 0
        (lambda (t)
          (set! results (cons 'timer1 results))
          (uv-handle-close! t)))
      (uv-timer-start! timer2 50 0
        (lambda (t)
          (set! results (cons 'timer2 results))
          (uv-handle-close! t)))
      (uv-timer-start! timer3 100 0
        (lambda (t)
          (set! results (cons 'timer3 results))
          (uv-handle-close! t)))
      ;; 运行事件循环
      (uv-run loop 'default)
      ;; 验证触发顺序（应该是 timer2, timer3, timer1）
      (assert-equal '(timer1 timer3 timer2) results
                    "timers should fire in order")
      ;; 清理
      (uv-loop-close loop)))

) ; end test-group

(run-tests)
