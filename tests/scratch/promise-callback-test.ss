;;; tests/promise-callback-test.ss - 测试 Promise 回调是否触发

(import (chezscheme)
        (chez-async high-level event-loop)
        (chez-async high-level promise))

(format #t "~%=== Promise 回调测试 ===~%~%")

;; 测试 1: 已解决的 Promise 的回调
(format #t "测试 1: 已解决的 Promise~%")
(let* ([loop (uv-default-loop)]
       [callback-called? #f]
       [promise (promise-resolved loop 42)])

  (format #t "  Promise 状态: ~a~%" (promise-state promise))

  ;; 注册回调
  (promise-then promise
    (lambda (value)
      (format #t "  回调被触发！值=~a~%" value)
      (set! callback-called? #t)))

  (format #t "  回调注册完成~%")
  (format #t "  运行事件循环...~%")

  ;; 运行多次事件循环迭代
  (do ([i 0 (+ i 1)])
      ((or (> i 5) callback-called?))
    (format #t "    迭代 ~a: callback-called?=~a~%" i callback-called?)
    (uv-run loop 'once))

  (format #t "  最终: callback-called?=~a~%~%" callback-called?))

;; 测试 2: 异步 Promise 的回调
(format #t "测试 2: 异步 Promise（定时器）~%")
(let* ([loop (uv-default-loop)]
       [callback-called? #f]
       [error-callback-called? #f]
       [promise (make-promise loop
                  (lambda (resolve reject)
                    (guard (ex
                            [else
                             (format #t "  Executor error: ~a~%" ex)
                             (reject ex)])
                      (format #t "  创建定时器...~%")
                      (let ([timer (uv-timer-init loop)])
                        (uv-timer-start! timer 50 0
                          (lambda (t)
                            (format #t "  定时器触发，解决 Promise~%")
                            (uv-handle-close! t)
                            (resolve 100)))))))])

  (format #t "  Promise 状态: ~a~%" (promise-state promise))

  ;; 注册回调（成功和失败）
  (promise-then promise
    (lambda (value)
      (format #t "  成功回调被触发！值=~a~%" value)
      (set! callback-called? #t))
    (lambda (error)
      (format #t "  错误回调被触发！错误=~a~%" error)
      (set! error-callback-called? #t)))

  (format #t "  回调注册完成~%")
  (format #t "  运行事件循环...~%")

  ;; 运行多次事件循环迭代
  (do ([i 0 (+ i 1)])
      ((or (> i 10) callback-called? error-callback-called?))
    (format #t "    迭代 ~a: callback=~a, error=~a, state=~a~%"
            i callback-called? error-callback-called? (promise-state promise))
    (uv-run loop 'once)
    ;; 小延迟确保定时器有机会触发
    (when (= i 0) (uv-run loop 'nowait)))

  (format #t "  最终: callback-called?=~a, error-callback-called?=~a~%~%"
          callback-called? error-callback-called?))

(format #t "=== 测试完成 ===~%")
