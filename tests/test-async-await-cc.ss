;;; tests/test-async-await-cc.ss - async/await (call/cc 版本) 测试

(import (chezscheme)
        (chez-async high-level async-await-cc)
        (chez-async high-level promise)
        (chez-async high-level event-loop)
        (chez-async low-level timer)
        (chez-async low-level handle-base))

;; ========================================
;; 测试框架
;; ========================================

(define test-count 0)
(define test-passed 0)
(define test-failed 0)

(define (test-case name thunk)
  "运行单个测试用例"
  (set! test-count (+ test-count 1))
  (format #t "~%Test ~a: ~a~%" test-count name)
  (guard (ex
          [else
           (set! test-failed (+ test-failed 1))
           (format #t "  ✗ FAILED: ~a~%" ex)
           (when (condition? ex)
             (format #t "    Message: ~a~%"
                     (if (message-condition? ex)
                         (condition-message ex)
                         "No message")))
           #f])
    (thunk)
    (set! test-passed (+ test-passed 1))
    (format #t "  ✓ PASSED~%")
    #t))

(define (check-equal? expected actual)
  "检查两个值是否相等"
  (unless (equal? expected actual)
    (error 'check-equal?
           (format "Expected ~a, got ~a" expected actual))))

(define (check-true condition)
  "检查条件是否为真"
  (unless condition
    (error 'check-true "Condition is false")))

(define (test-summary)
  "打印测试总结"
  (format #t "~%~%========================================~%")
  (format #t "Test Summary~%")
  (format #t "========================================~%")
  (format #t "Total:  ~a~%" test-count)
  (format #t "Passed: ~a~%" test-passed)
  (format #t "Failed: ~a~%" test-failed)
  (format #t "========================================~%"))

;; ========================================
;; 测试用例：基本 async
;; ========================================

(format #t "~%=== 基本 async 测试 ===~%")

(test-case "简单的 async 值"
  (lambda ()
    (let ([p (async 42)])
      (check-true (promise? p))
      (let ([result (run-async p)])
        (check-equal? 42 result)))))

(test-case "async 中的表达式"
  (lambda ()
    (let ([p (async (+ 10 20 12))])
      (let ([result (run-async p)])
        (check-equal? 42 result)))))

(test-case "async 中的多个表达式"
  (lambda ()
    (let ([p (async
               (let ([x 10]
                     [y 20])
                 (+ x y 12)))])
      (let ([result (run-async p)])
        (check-equal? 42 result)))))

;; ========================================
;; 测试用例：await
;; ========================================

(format #t "~%=== await 测试 ===~%")

(test-case "await 已解决的 Promise"
  (lambda ()
    (let ([p (async
               (let ([value (await (promise-resolved (uv-default-loop) 42))])
                 value))])
      (let ([result (run-async p)])
        (check-equal? 42 result)))))

(test-case "await 异步 Promise"
  (lambda ()
    (let ([loop (uv-default-loop)]
          [p (async
               (let ([value (await
                              (make-promise (uv-default-loop)
                                (lambda (resolve reject)
                                  (let ([timer (uv-timer-init (uv-default-loop))])
                                    (uv-timer-start! timer 50 0
                                      (lambda (t)
                                        (uv-handle-close! t)
                                        (resolve 100)))))))])
                 value))])
      (let ([result (run-async p)])
        (check-equal? 100 result)))))

(test-case "多次 await"
  (lambda ()
    (let ([p (async
               (let* ([a (await (promise-resolved (uv-default-loop) 10))]
                      [b (await (promise-resolved (uv-default-loop) 20))]
                      [c (await (promise-resolved (uv-default-loop) 12))])
                 (+ a b c)))])
      (let ([result (run-async p)])
        (check-equal? 42 result)))))

(test-case "嵌套的 async/await"
  (lambda ()
    (let ([inner (async
                   (await (promise-resolved (uv-default-loop) 21)))]
          [outer (async
                   (let ([x (await inner)])
                     (* x 2)))])
      (let ([result (run-async outer)])
        (check-equal? 42 result)))))

;; ========================================
;; 测试用例：async*
;; ========================================

(format #t "~%=== async* 测试 ===~%")

(test-case "简单的 async* 函数"
  (lambda ()
    (define double
      (async* (x)
        (* x 2)))
    (let ([p (double 21)])
      (check-true (promise? p))
      (let ([result (run-async p)])
        (check-equal? 42 result)))))

(test-case "async* 中使用 await"
  (lambda ()
    (define fetch-and-double
      (async* (x)
        (let ([value (await (promise-resolved (uv-default-loop) x))])
          (* value 2))))
    (let ([result (run-async (fetch-and-double 21))])
      (check-equal? 42 result)))))

(test-case "async* 多个参数"
  (lambda ()
    (define add
      (async* (x y z)
        (+ x y z)))
    (let ([result (run-async (add 10 20 12))])
      (check-equal? 42 result)))))

;; ========================================
;; 测试用例：错误处理
;; ========================================

(format #t "~%=== 错误处理测试 ===~%")

(test-case "async 中的异常"
  (lambda ()
    (let ([p (async
               (error 'test "Test error"))])
      (guard (ex
              [else
               (check-true (condition? ex))])
        (run-async p)
        (error 'test-case "Should have thrown")))))

(test-case "async 中使用 guard"
  (lambda ()
    (let ([p (async
               (guard (ex
                       [else 'caught])
                 (error 'test "Test error")))])
      (let ([result (run-async p)])
        (check-equal? 'caught result)))))

(test-case "await 拒绝的 Promise"
  (lambda ()
    (let ([p (async
               (guard (ex
                       [else 'caught])
                 (await (promise-rejected (uv-default-loop) "Error!"))))])
      (let ([result (run-async p)])
        (check-equal? 'caught result)))))

;; ========================================
;; 测试用例：实际场景
;; ========================================

(format #t "~%=== 实际场景测试 ===~%")

(test-case "模拟 HTTP 请求"
  (lambda ()
    ;; 模拟异步 HTTP 请求
    (define (http-get url)
      (make-promise (uv-default-loop)
        (lambda (resolve reject)
          (let ([timer (uv-timer-init (uv-default-loop))])
            (uv-timer-start! timer 10 0
              (lambda (t)
                (uv-handle-close! t)
                (resolve (format "Response from ~a" url))))))))

    ;; 使用 async/await
    (define (fetch-data url)
      (async
        (let ([response (await (http-get url))])
          response)))

    (let ([result (run-async (fetch-data "https://example.com"))])
      (check-equal? "Response from https://example.com" result)))))

(test-case "串行执行多个异步操作"
  (lambda ()
    ;; 模拟延迟函数
    (define (delay-value ms value)
      (make-promise (uv-default-loop)
        (lambda (resolve reject)
          (let ([timer (uv-timer-init (uv-default-loop))])
            (uv-timer-start! timer ms 0
              (lambda (t)
                (uv-handle-close! t)
                (resolve value)))))))

    ;; 串行执行
    (define (fetch-all)
      (async
        (let* ([a (await (delay-value 10 1))]
               [b (await (delay-value 10 2))]
               [c (await (delay-value 10 3))])
          (+ a b c))))

    (let ([result (run-async (fetch-all))])
      (check-equal? 6 result)))))

;; ========================================
;; 测试用例：工具函数
;; ========================================

(format #t "~%=== 工具函数测试 ===~%")

(test-case "async-value"
  (lambda ()
    (let ([p (async-value 42)])
      (check-true (promise? p))
      (let ([result (run-async p)])
        (check-equal? 42 result)))))

(test-case "async-error"
  (lambda ()
    (let ([p (async-error "Test error")])
      (guard (ex
              [else
               (check-true #t)])
        (run-async p)
        (error 'test-case "Should have thrown")))))

;; ========================================
;; 测试总结
;; ========================================

(test-summary)

(format #t "~%测试完成！~%")
