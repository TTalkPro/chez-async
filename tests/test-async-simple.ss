;;; tests/test-async-simple.ss - 简化的 async/await 测试

(import (chezscheme)
        (chez-async high-level async-await-cc)
        (chez-async high-level promise)
        (chez-async high-level event-loop))

(format #t "~%=== 简化的 async/await 测试 ===~%~%")

;; 测试 1: 简单值
(format #t "测试 1: 简单值~%")
(let ([p (async 42)])
  (format #t "  结果: ~a~%~%" (run-async p)))

;; 测试 2: 表达式
(format #t "测试 2: 表达式~%")
(let ([p (async (+ 10 20 12))])
  (format #t "  结果: ~a~%~%" (run-async p)))

;; 测试 3: await 已解决的 Promise
(format #t "测试 3: await 已解决的 Promise~%")
(let ([p (async
           (await (promise-resolved (uv-default-loop) 99)))])
  (format #t "  结果: ~a~%~%" (run-async p)))

;; 测试 4: 多次 await
(format #t "测试 4: 多次 await~%")
(let ([p (async
           (let* ([a (await (promise-resolved (uv-default-loop) 10))]
                  [b (await (promise-resolved (uv-default-loop) 20))]
                  [c (await (promise-resolved (uv-default-loop) 12))])
             (+ a b c)))])
  (format #t "  结果: ~a~%~%" (run-async p)))

;; 测试 5: async*
(format #t "测试 5: async*~%")
(define double
  (async* (x)
    (* x 2)))
(let ([result (run-async (double 21))])
  (format #t "  结果: ~a~%~%" result))

(format #t "=== 所有测试完成 ===~%")
