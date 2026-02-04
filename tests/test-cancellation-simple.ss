#!/usr/bin/env scheme-script
;;; tests/test-cancellation-simple.ss - 取消令牌简单测试

(library-directories
  '(("." . ".")
    ("../internal" . "../internal")
    ("../high-level" . "../high-level")
    ("../low-level" . "../low-level")
    ("../ffi" . "../ffi")))

(import (chezscheme)
        (chez-async high-level async-await)
        (chez-async high-level async-combinators)
        (chez-async high-level cancellation)
        (chez-async high-level promise)
        (chez-async high-level event-loop))

(format #t "~%=== Cancellation Token Simple Tests ===~%~%")

;; Test 1: 基本创建和取消
(format #t "Test 1: Create and cancel ... ")
(let ([cts (make-cancellation-token-source)])
  (if (and (not (cts-cancelled? cts))
           (begin (cts-cancel! cts)
                  (cts-cancelled? cts)))
      (format #t "✓~%")
      (format #t "✗~%")))

;; Test 2: 回调注册
(format #t "Test 2: Callback registration ... ")
(let ([cts (make-cancellation-token-source)]
      [called? #f])
  (token-register! (cts-token cts)
    (lambda () (set! called? #t)))
  (cts-cancel! cts)
  (if called?
      (format #t "✓~%")
      (format #t "✗~%")))

;; Test 3: 立即回调（已取消的令牌）
(format #t "Test 3: Immediate callback ... ")
(let ([cts (make-cancellation-token-source)]
      [called? #f])
  (cts-cancel! cts)
  (token-register! (cts-token cts)
    (lambda () (set! called? #t)))
  (if called?
      (format #t "✓~%")
      (format #t "✗~%")))

;; Test 4: async-with-cancellation（完成）
(format #t "Test 4: async-with-cancellation (complete) ... ")
(let* ([cts (make-cancellation-token-source)]
       [result (run-async
                 (async-with-cancellation (cts-token cts)
                   (async 'success)))])
  (if (eq? result 'success)
      (format #t "✓~%")
      (format #t "✗~%")))

;; Test 5: linked-token-source
(format #t "Test 5: linked-token-source ... ")
(let* ([cts1 (make-cancellation-token-source)]
       [cts2 (make-cancellation-token-source)]
       [linked (linked-token-source (cts-token cts1) (cts-token cts2))])
  (cts-cancel! cts1)
  (if (cts-cancelled? linked)
      (format #t "✓~%")
      (format #t "✗~%")))

(format #t "~%=== All Simple Tests Completed ===~%")
