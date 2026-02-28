;;; tests/basic-timer-test.ss - 测试基本的定时器功能

(import (chezscheme)
        (chez-async high-level event-loop)
        (chez-async low-level timer)
        (chez-async low-level handle-base))

(format #t "~%=== 基本定时器测试 ===~%~%")

;; 测试 1: 0ms 定时器（类似 schedule-microtask）
(format #t "测试 1: 0ms 定时器~%")
(let* ([loop (uv-default-loop)]
       [called? #f])

  (format #t "  创建定时器...~%")
  (let ([timer (uv-timer-init loop)])
    (format #t "  启动定时器（0ms）...~%")
    (uv-timer-start! timer 0 0
      (lambda (t)
        (format #t "  定时器回调被触发！~%")
        (set! called? #t)
        (uv-handle-close! t))))

  (format #t "  运行事件循环...~%")
  (do ([i 0 (+ i 1)])
      ((or (> i 5) called?))
    (format #t "    迭代 ~a: called?=~a~%" i called?)
    (uv-run loop 'once))

  (format #t "  最终: called?=~a~%~%" called?))

;; 测试 2: 50ms 定时器
(format #t "测试 2: 50ms 定时器~%")
(let* ([loop (uv-default-loop)]
       [called? #f])

  (format #t "  创建定时器...~%")
  (let ([timer (uv-timer-init loop)])
    (format #t "  启动定时器（50ms）...~%")
    (uv-timer-start! timer 50 0
      (lambda (t)
        (format #t "  定时器回调被触发！~%")
        (set! called? #t)
        (uv-handle-close! t))))

  (format #t "  运行事件循环...~%")
  (do ([i 0 (+ i 1)])
      ((or (> i 10) called?))
    (format #t "    迭代 ~a: called?=~a~%" i called?)
    (uv-run loop 'once))

  (format #t "  最终: called?=~a~%~%" called?))

(format #t "=== 测试完成 ===~%")
