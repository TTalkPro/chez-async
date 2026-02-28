;;; tests/new-loop-timer-test.ss - 使用新创建的 loop 测试

(import (chezscheme)
        (chez-async high-level event-loop)
        (chez-async low-level timer)
        (chez-async low-level handle-base))

(format #t "~%=== 新创建的 Loop 定时器测试 ===~%~%")

;; 创建新的 loop（不使用 default）
(define test-loop (uv-loop-init))

(format #t "使用 loop: ~a~%" test-loop)
(format #t "loop ptr: ~a~%~%" (uv-loop-ptr test-loop))

;; 测试 1: 简单的定时器
(format #t "测试 1: 100ms 定时器~%")
(let ([called? #f])

  (format #t "  创建定时器...~%")
  (let ([timer (uv-timer-init test-loop)])
    (format #t "  启动定时器（100ms）...~%")
    (uv-timer-start! timer 100 0
      (lambda (t)
        (format #t "  [回调] 定时器被触发！~%")
        (set! called? #t)
        (uv-handle-close! t))))

  (format #t "  loop-alive? = ~a~%" (uv-loop-alive? test-loop))
  (format #t "  运行事件循环（'default 模式）...~%")
  (uv-run test-loop 'default)

  (format #t "  最终: called?=~a~%~%" called?))

;; 清理
(uv-loop-close test-loop)

(format #t "=== 测试完成 ===~%")
