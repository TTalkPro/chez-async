;;; tests/test-promise-resolved.ss - 测试 promise-resolved

(import (chezscheme)
        (chez-async high-level promise)
        (chez-async high-level event-loop))

(format #t "~%=== 测试 promise-resolved ===~%~%")

(define loop (uv-default-loop))

;; 测试 1: 第一个promise-resolved
(format #t "测试 1: 第一个 promise-resolved~%")
(let ([p1 (promise-resolved loop 10)])
  (format #t "  Promise 状态: ~a~%" (promise-state p1))
  (promise-then p1
    (lambda (v)
      (format #t "  Success callback: ~a~%" v))
    (lambda (e)
      (format #t "  Error callback: ~a~%" e))))

(uv-run loop 'once)
(format #t "~%")

;; 测试 2: 第二个 promise-resolved
(format #t "测试 2: 第二个 promise-resolved~%")
(let ([p2 (promise-resolved loop 20)])
  (format #t "  Promise 状态: ~a~%" (promise-state p2))
  (promise-then p2
    (lambda (v)
      (format #t "  Success callback: ~a~%" v))
    (lambda (e)
      (format #t "  Error callback: ~a~%" e))))

(uv-run loop 'once)
(format #t "~%")

;; 测试 3: 串行创建两个
(format #t "测试 3: 串行创建和使用两个 promise-resolved~%")
(let ([p1 (promise-resolved loop 100)]
      [p2 (promise-resolved loop 200)])
  (format #t "  p1 状态: ~a~%" (promise-state p1))
  (format #t "  p2 状态: ~a~%" (promise-state p2))

  (promise-then p1
    (lambda (v) (format #t "  p1 success: ~a~%" v))
    (lambda (e) (format #t "  p1 error: ~a~%" e)))

  (promise-then p2
    (lambda (v) (format #t "  p2 success: ~a~%" v))
    (lambda (e) (format #t "  p2 error: ~a~%" e)))

  (uv-run loop 'once)
  (uv-run loop 'once))

(format #t "~%=== 测试完成 ===~%")
