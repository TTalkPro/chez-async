#!/usr/bin/env scheme-script
;;; tests/test-cancellation.ss - 取消功能测试

(import (chezscheme)
        (chez-async tests framework)
        (chez-async)
        (chez-async high-level promise))

(test-group "Cancellation Tests"

  (test "cancel-source-create"
    (let ([cs (make-cancel-source)])
      (assert-true (cancel-source? cs) "make-cancel-source should return cancel-source")
      (assert-false (cancel-source-cancelled? cs) "should not be cancelled initially")))

  (test "cancel-source-cancel"
    (let ([cs (make-cancel-source)])
      (cancel-source-cancel! cs)
      (assert-true (cancel-source-cancelled? cs) "should be cancelled after cancel!")))

  (test "cancel-token-from-source"
    (let ([cs (make-cancel-source)])
      (let ([token (cancel-source-token cs)])
        (assert-true (cancel-token? token) "cancel-source-token should return cancel-token")
        (assert-false (cancel-token-cancelled? token) "token should not be cancelled initially")
        (cancel-source-cancel! cs)
        (assert-true (cancel-token-cancelled? token) "token should be cancelled after source cancelled"))))

  (test "async-cancellable-resolves"
    (let ([result #f])
      (let ([cs (make-cancel-source)])
        (let ([token (cancel-source-token cs)])
          (promise-then
            (async-cancellable token (promise-resolved 42))
            (lambda (v)
              (set! result v)
              (uv-stop (uv-default-loop)))
            (lambda (e)
              (uv-stop (uv-default-loop))))))
      (uv-run (uv-default-loop) 'default)
      (assert-equal 42 result "async-cancellable should resolve normally")))

  (test "operation-cancelled-predicate"
    (assert-true (operation-cancelled? (make-cancelled-error))
                 "operation-cancelled? should return true for cancelled"))

)
