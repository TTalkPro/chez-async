;;; tests/debug-await-twice.ss - 调试连续两次 await

(import (chezscheme)
        (chez-async high-level async-await-cc)
        (chez-async high-level promise)
        (chez-async high-level event-loop))

(format #t "~%=== 调试连续两次 await ===~%~%")

;; 保存 loop 引用
(define test-loop (uv-default-loop))

(format #t "Loop: ~a~%" test-loop)
(format #t "~%")

;; 测试：连续两次 await
(define p
  (async
    (format #t "  [Async] 开始~%")
    (let ([a (await (promise-resolved test-loop 10))])
      (format #t "  [Async] 第1次await完成，a=~a~%" a)
      (format #t "  [Async] 准备第2次await~%")
      (let ([b (await (promise-resolved test-loop 20))])
        (format #t "  [Async] 第2次await完成，b=~a~%" b)
        (+ a b)))))

(format #t "开始运行...~%")

(guard (ex
        [else
         (format #t "~%错误: ~a~%" ex)
         (when (condition? ex)
           (format #t "  Message: ~a~%"
                   (if (message-condition? ex)
                       (condition-message ex)
                       "No message"))
           (when (irritants-condition? ex)
             (format #t "  Irritants: ~a~%"
                     (condition-irritants ex))))])
  (let ([result (run-async p)])
    (format #t "~%结果: ~a~%" result)))

(format #t "~%=== 测试完成 ===~%")
