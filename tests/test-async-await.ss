;;; tests/test-async-await.ss - async/await 简化版测试
;;;
;;; 测试 async-await-simple（轻量级实现）

(import (chezscheme)
        (chez-async high-level event-loop)
        (chez-async low-level timer)
        (chez-async high-level promise)
        (chez-async high-level async-await-simple))

;; ========================================
;; 测试辅助函数
;; ========================================

(define test-count 0)
(define pass-count 0)

(define (assert-promise-value promise expected msg)
  (set! test-count (+ test-count 1))
  (let ([actual (promise-wait promise)])
    (if (equal? actual expected)
        (begin
          (set! pass-count (+ pass-count 1))
          (format #t "✓ Test ~a: ~a~%" test-count msg))
        (format #t "✗ Test ~a: ~a (FAILED: expected ~a, got ~a)~%"
                test-count msg expected actual))))

;; ========================================
;; 测试用例
;; ========================================

(define (run-all-tests)
  (format #t "~%=== async/await 语法糖测试 ===~%")
  (format #t "~%注意：当前为基础版本，仅测试核心功能~%~%")

  ;; 测试 1: 简单的 async 块
  (format #t "测试 1: 简单的 async 块~%")
  (let ([p (async 42)])
    (assert-promise-value p 42 "简单值"))

  ;; 测试 2: await 简单 Promise
  (format #t "~%测试 2: await 简单 Promise~%")
  (let ([p (async (await (promise-resolved 100)))])
    (assert-promise-value p 100 "await resolved promise"))

  ;; 测试 3: async 中的复杂表达式
  (format #t "~%测试 3: async 中的复杂表达式~%")
  (let ([p (async (* 6 7))])
    (assert-promise-value p 42 "complex expression"))

  ;; 测试 4: async* 带参数的异步函数
  (format #t "~%测试 4: async* 带参数的异步函数~%")
  (let* ([double-it (async* (x)
                           (await (promise-resolved (* x 2))))])
    (assert-promise-value (double-it 5) 10 "async* with parameter"))

  ;; 测试 5: async* 多个参数
  (format #t "~%测试 5: async* 多个参数~%")
  (let* ([add-them (async* (x y)
                           (await (promise-resolved (+ x y))))])
    (assert-promise-value (add-them 10 20) 30 "async* with multiple parameters"))

  ;; 测试 6: async 中的表达式计算
  (format #t "~%测试 6: async 中的表达式计算~%")
  (let ([p (async (+ 10 20 30))])
    (assert-promise-value p 60 "expression evaluation"))

  ;; 测试 7: async 中的函数调用
  (format #t "~%测试 7: async 中的函数调用~%")
  (let ([p (async (string-append "Hello, " "World!"))])
    (assert-promise-value p "Hello, World!" "function call"))

  ;; ========================================
  ;; 输出结果
  ;; ========================================

  (format #t "~%========================================~%")
  (format #t "测试结果: ~%")
  (format #t "  Total:  ~a~%" test-count)
  (format #t "  Passed: ~a~%" pass-count)
  (format #t "  Failed: ~a~%" (- test-count pass-count))
  (format #t "========================================~%")

  (when (= pass-count test-count)
    (format #t "~%✓ All tests passed!~%")
    (exit 0))

  (format #t "~%✗ Some tests failed~%")
  (exit 1))

;; ========================================
;; 运行测试
;; ========================================

(run-all-tests)
