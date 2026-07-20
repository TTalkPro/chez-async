;;; tests/test-framework.ss - 简单的测试框架
;;;
;;; 提供基础测试功能

(library (chez-async tests framework)
  (export
    test
    test-group
    assert-true
    assert-false
    assert-equal
    assert-error
    run-tests
    )
  (import (chezscheme))

  ;; ========================================
  ;; 测试状态（使用 box 实现可变状态）
  ;; ========================================

  (define *test-count* (box 0))
  (define *test-passed* (box 0))
  (define *test-failed* (box 0))
  (define *current-group* (box #f))

  ;; ========================================
  ;; 断言
  ;; ========================================

  (define (assert-true expr message)
    "断言表达式为真"
    (unless expr
      (error 'assert-true message)))

  (define (assert-false expr message)
    "断言表达式为假"
    (when expr
      (error 'assert-false message)))

  (define (assert-equal expected actual message)
    "断言值相等"
    (unless (equal? expected actual)
      (error 'assert-equal
             (format "~a: expected ~s, got ~s" message expected actual))))

  (define (assert-error thunk message)
    "断言会抛出异常"
    (guard (e [else #t])
      (thunk)
      (error 'assert-error (format "~a: no error raised" message))))

  ;; ========================================
  ;; 测试运行
  ;; ========================================

  (define-syntax test
    (syntax-rules ()
      [(_ name body ...)
       (begin
         (set-box! *test-count* (+ (unbox *test-count*) 1))
         (let ([test-name (if (unbox *current-group*)
                              (format "~a / ~a" (unbox *current-group*) name)
                              name)])
           (guard (e [else
                      (set-box! *test-failed* (+ (unbox *test-failed*) 1))
                      (fprintf (current-error-port)
                               "✗ FAIL: ~a~n  ~a~n"
                               test-name
                               (if (condition? e)
                                   (call-with-string-output-port
                                     (lambda (p) (display-condition e p)))
                                   e))])
             (begin body ...)
             (set-box! *test-passed* (+ (unbox *test-passed*) 1))
             (printf "✓ PASS: ~a~n" test-name))))]))

  (define-syntax test-group
    (syntax-rules ()
      [(_ name body ...)
       (let ([old-group (unbox *current-group*)])
         (set-box! *current-group* name)
         (printf "~n=== ~a ===~n" name)
         body ...
         (set-box! *current-group* old-group))]))

  (define (run-tests)
    "运行所有测试并显示结果"
    (printf "~n~n========================================~n")
    (printf "Test Results:~n")
    (printf "  Total:  ~a~n" (unbox *test-count*))
    (printf "  Passed: ~a~n" (unbox *test-passed*))
    (printf "  Failed: ~a~n" (unbox *test-failed*))
    (printf "========================================~n")
    (if (= (unbox *test-failed*) 0)
        (begin
          (printf "~nAll tests passed! ✓~n")
          (exit 0))
        (begin
          (printf "~nSome tests failed. ✗~n")
          (exit 1))))

) ; end library
