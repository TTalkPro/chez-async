;;; tests/simple-async-promise-test.ss - 简单的异步 Promise 测试

(import (chezscheme)
        (chez-async high-level event-loop)
        (chez-async high-level promise)
        (chez-async low-level timer)
        (chez-async low-level handle-base))

(format #t "~%=== 简单异步 Promise 测试 ===~%~%")

(define test-loop (uv-default-loop))

;; 测试：使用定时器的异步 Promise
(format #t "测试：异步 Promise（50ms定时器）~%")
(let ([callback-called? #f]
      [result-value #f])

  (define promise
    (make-promise test-loop
      (lambda (resolve reject)
        (format #t "  [Executor] 创建定时器...~%")
        (let ([timer (uv-timer-init test-loop)])
          (format #t "  [Executor] 启动定时器...~%")
          (uv-timer-start! timer 50 0
            (lambda (t)
              (format #t "  [Timer] 定时器触发！~%")
              (uv-handle-close! t)
              (format #t "  [Timer] 解决 Promise~%")
              (resolve 999)))))))

  (format #t "  Promise 初始状态: ~a~%" (promise-state promise))

  ;; 注册回调
  (promise-then promise
    (lambda (value)
      (format #t "  [Then] 成功回调！值=~a~%" value)
      (set! callback-called? #t)
      (set! result-value value))
    (lambda (error)
      (format #t "  [Catch] 错误回调！错误=~a~%" error)))

  (format #t "  回调已注册，开始事件循环~%")

  ;; 运行事件循环
  (do ([i 0 (+ i 1)])
      ((or (> i 20) callback-called?))
    (when (< i 3)
      (format #t "    迭代 ~a: state=~a, called?=~a~%"
              i (promise-state promise) callback-called?))
    (uv-run test-loop 'once))

  (format #t "  最终结果:~%")
  (format #t "    callback-called? = ~a~%" callback-called?)
  (format #t "    result-value = ~a~%" result-value)
  (format #t "    Promise 状态 = ~a~%~%" (promise-state promise)))

(format #t "=== 测试完成 ===~%")
