;;; tests/suspend-resume-test.ss - 测试暂停和恢复

(import (chezscheme)
        (chez-async internal coroutine)
        (chez-async internal scheduler)
        (chez-async high-level event-loop)
        (chez-async high-level promise)
        (chez-async low-level timer)
        (chez-async low-level handle-base))

(format #t "~%=== 暂停/恢复测试 ===~%~%")

;; 测试 1: 等待已解决的 Promise
(format #t "测试 1: 等待已解决的 Promise~%")
(let* ([loop (uv-default-loop)]
       [result #f]
       [coro (spawn-coroutine! loop
               (lambda ()
                 (format #t "  协程：准备等待 Promise...~%")
                 (let ([value (suspend-for-promise!
                                (promise-resolved loop 42))])
                   (format #t "  协程：收到值 ~a~%" value)
                   (set! result value)
                   value)))])
  (format #t "  开始运行调度器...~%")
  (run-scheduler loop)
  (format #t "  result = ~a~%" result)
  (format #t "  协程状态: ~a~%" (coroutine-state coro))
  (format #t "  ~a~%~%" (if (equal? result 42) "✓ 成功" "✗ 失败")))

;; 测试 2: 等待异步 Promise（使用定时器）
(format #t "测试 2: 等待异步 Promise~%")
(let* ([loop (uv-default-loop)]
       [result #f]
       [promise (make-promise loop
                  (lambda (resolve reject)
                    (format #t "  Promise：启动定时器...~%")
                    (let ([timer (uv-timer-init loop)])
                      (uv-timer-start! timer 50 0
                        (lambda (t)
                          (format #t "  Promise：定时器到期，解决 Promise~%")
                          (uv-handle-close! t)
                          (resolve 100))))))]
       [coro (spawn-coroutine! loop
               (lambda ()
                 (format #t "  协程：准备等待 Promise...~%")
                 (let ([value (suspend-for-promise! promise)])
                   (format #t "  协程：收到值 ~a~%" value)
                   (set! result value)
                   value)))])
  (format #t "  开始运行调度器...~%")
  (run-scheduler loop)
  (format #t "  result = ~a~%" result)
  (format #t "  协程状态: ~a~%" (coroutine-state coro))
  (format #t "  ~a~%~%" (if (equal? result 100) "✓ 成功" "✗ 失败")))

(format #t "=== 测试完成 ===~%")
