;;; tests/test-coroutine.ss - 协程单元测试
;;;
;;; 测试协程的基本功能：创建、状态管理、暂停/恢复

(import (chezscheme)
        (chez-async internal coroutine)
        (chez-async internal scheduler)
        (chez-async high-level event-loop)
        (chez-async high-level promise)
        (chez-async low-level timer)
        (chez-async low-level handle-base))

;; ========================================
;; 测试框架辅助函数
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
             (format #t "    Condition message: ~a~%" (condition-message ex))
             (when (irritants-condition? ex)
               (format #t "    Irritants: ~a~%" (condition-irritants ex))))
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

(define (check-false condition)
  "检查条件是否为假"
  (when condition
    (error 'check-false "Condition is true")))

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
;; 测试用例：协程创建
;; ========================================

(format #t "~%=== 协程基础测试 ===~%")

(test-case "创建协程"
  (lambda ()
    (let* ([loop (uv-default-loop)]
           [coro (make-coroutine loop)])
      (check-true (coroutine? coro))
      (check-equal? 'created (coroutine-state coro))
      (check-equal? loop (coroutine-loop coro))
      (check-false (coroutine-continuation coro))
      (check-false (coroutine-result coro)))))

(test-case "协程 ID 生成"
  (lambda ()
    (let* ([loop (uv-default-loop)]
           [coro1 (make-coroutine loop)]
           [coro2 (make-coroutine loop)])
      ;; 每个协程应该有唯一的 ID
      (check-true (symbol? (coroutine-id coro1)))
      (check-true (symbol? (coroutine-id coro2)))
      (check-false (eq? (coroutine-id coro1) (coroutine-id coro2))))))

(test-case "协程状态查询"
  (lambda ()
    (let* ([loop (uv-default-loop)]
           [coro (make-coroutine loop)])
      (check-true (coroutine-created? coro))
      (check-false (coroutine-running? coro))
      (check-false (coroutine-suspended? coro))
      (check-false (coroutine-completed? coro))
      (check-false (coroutine-failed? coro)))))

(test-case "当前协程参数"
  (lambda ()
    (check-false (current-coroutine))
    (let* ([loop (uv-default-loop)]
           [coro (make-coroutine loop)])
      (parameterize ([current-coroutine coro])
        (check-equal? coro (current-coroutine)))
      (check-false (current-coroutine)))))

;; ========================================
;; 测试用例：调度器
;; ========================================

(format #t "~%=== 调度器测试 ===~%")

(test-case "创建调度器"
  (lambda ()
    (let* ([loop (uv-default-loop)]
           [sched (get-scheduler loop)])
      (check-true (scheduler-state? sched))
      (check-equal? loop (scheduler-state-loop sched))
      ;; 应该是同一个调度器实例
      (check-equal? sched (get-scheduler loop)))))

(test-case "spawn 协程"
  (lambda ()
    (let* ([loop (uv-default-loop)]
           [executed? #f]
           [result #f]
           [coro (spawn-coroutine! loop
                   (lambda ()
                     (set! executed? #t)
                     (set! result 42)
                     42))])
      (check-true (coroutine? coro))
      (check-equal? 'created (coroutine-state coro))

      ;; 运行调度器
      (run-scheduler loop)

      ;; 检查协程已执行
      (check-true executed?)
      (check-equal? 42 result)
      (check-equal? 'completed (coroutine-state coro))
      (check-equal? 42 (coroutine-result coro)))))

(test-case "spawn 多个协程"
  (lambda ()
    (let* ([loop (uv-default-loop)]
           [results '()]
           [coro1 (spawn-coroutine! loop
                    (lambda ()
                      (set! results (cons 1 results))
                      1))]
           [coro2 (spawn-coroutine! loop
                    (lambda ()
                      (set! results (cons 2 results))
                      2))]
           [coro3 (spawn-coroutine! loop
                    (lambda ()
                      (set! results (cons 3 results))
                      3))])

      ;; 运行调度器
      (run-scheduler loop)

      ;; 所有协程都应该执行
      (check-equal? 3 (length results))
      (check-true (member 1 results))
      (check-true (member 2 results))
      (check-true (member 3 results))

      ;; 所有协程都应该完成
      (check-equal? 'completed (coroutine-state coro1))
      (check-equal? 'completed (coroutine-state coro2))
      (check-equal? 'completed (coroutine-state coro3)))))

;; ========================================
;; 测试用例：暂停和恢复
;; ========================================

(format #t "~%=== 暂停/恢复测试 ===~%")

(test-case "暂停并恢复协程"
  (lambda ()
    (let* ([loop (uv-default-loop)]
           [result #f]
           [coro (spawn-coroutine! loop
                   (lambda ()
                     ;; 等待一个已解决的 Promise
                     (let ([value (suspend-for-promise!
                                    (promise-resolved loop 42))])
                       (set! result value)
                       value)))])

      ;; 运行调度器
      (run-scheduler loop)

      ;; 检查结果
      (check-equal? 42 result)
      (check-equal? 'completed (coroutine-state coro))
      (check-equal? 42 (coroutine-result coro)))))

(test-case "等待异步 Promise"
  (lambda ()
    (let* ([loop (uv-default-loop)]
           [result #f]
           [promise (make-promise loop
                      (lambda (resolve reject)
                        ;; 使用定时器异步解决
                        (let ([timer (uv-timer-init loop)])
                          (uv-timer-start! timer 10 0
                            (lambda (t)
                              (uv-handle-close! t)
                              (resolve 100))))))]
           [coro (spawn-coroutine! loop
                   (lambda ()
                     (let ([value (suspend-for-promise! promise)])
                       (set! result value)
                       value)))])

      ;; 运行调度器
      (run-scheduler loop)

      ;; 检查结果
      (check-equal? 100 result)
      (check-equal? 'completed (coroutine-state coro)))))

(test-case "多个协程等待不同 Promise"
  (lambda ()
    (let* ([loop (uv-default-loop)]
           [results '()]
           [p1 (make-promise loop
                 (lambda (resolve reject)
                   (let ([timer (uv-timer-init loop)])
                     (uv-timer-start! timer 20 0
                       (lambda (t)
                         (uv-handle-close! t)
                         (resolve 10))))))]
           [p2 (make-promise loop
                 (lambda (resolve reject)
                   (let ([timer (uv-timer-init loop)])
                     (uv-timer-start! timer 10 0
                       (lambda (t)
                         (uv-handle-close! t)
                         (resolve 20))))))])

      ;; 创建两个协程
      (spawn-coroutine! loop
        (lambda ()
          (let ([v (suspend-for-promise! p1)])
            (set! results (cons v results)))))

      (spawn-coroutine! loop
        (lambda ()
          (let ([v (suspend-for-promise! p2)])
            (set! results (cons v results)))))

      ;; 运行调度器
      (run-scheduler loop)

      ;; 检查结果
      (check-equal? 2 (length results))
      (check-true (member 10 results))
      (check-true (member 20 results)))))

;; ========================================
;; 测试用例：错误处理
;; ========================================

(format #t "~%=== 错误处理测试 ===~%")

(test-case "协程中的异常"
  (lambda ()
    (let* ([loop (uv-default-loop)]
           [coro (spawn-coroutine! loop
                   (lambda ()
                     (error 'test "Test error")))])

      ;; 运行调度器（不应该崩溃）
      (run-scheduler loop)

      ;; 协程应该标记为失败
      (check-equal? 'failed (coroutine-state coro))
      (check-true (condition? (coroutine-result coro))))))

(test-case "Promise 拒绝"
  (lambda ()
    (let* ([loop (uv-default-loop)]
           [result #f]
           [promise (promise-rejected loop "Error!")]
           [coro (spawn-coroutine! loop
                   (lambda ()
                     (guard (ex
                             [else
                              (set! result 'caught)
                              'recovered])
                       (suspend-for-promise! promise))))])

      ;; 运行调度器
      (run-scheduler loop)

      ;; 错误应该被传播，但协程可以捕获它
      (check-equal? 'completed (coroutine-state coro)))))

;; ========================================
;; 测试总结
;; ========================================

(test-summary)

(format #t "~%测试完成！~%")
