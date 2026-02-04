;;; tests/debug-multiple-await.ss - 调试多次 await

(import (chezscheme)
        (chez-async high-level async-await-cc)
        (chez-async high-level promise)
        (chez-async high-level event-loop)
        (chez-async internal scheduler)
        (chez-async internal coroutine))

(format #t "~%=== 调试多次 await ===~%~%")

;; 测试：串行 await 3 个 Promise
(format #t "测试：串行 await 3 个 Promise~%")

(let ([loop (uv-default-loop)])
  (define p
    (async
      (format #t "  [Async] 开始执行~%")
      (let* ([a (begin
                  (format #t "  [Async] 准备 await第1个Promise~%")
                  (let ([val (await (promise-resolved loop 10))])
                    (format #t "  [Async] 第1个Promise返回: ~a~%"  val)
                    val))]
             [b (begin
                  (format #t "  [Async] 准备await第2个Promise~%")
                  (let ([val (await (promise-resolved loop 20))])
                    (format #t "  [Async] 第2个Promise返回: ~a~%" val)
                    val))]
             [c (begin
                  (format #t "  [Async] 准备await第3个Promise~%")
                  (let ([val (await (promise-resolved loop 12))])
                    (format #t "  [Async] 第3个Promise返回: ~a~%" val)
                    val))])
        (format #t "  [Async] 计算和: ~a + ~a + ~a~%" a b c)
        (+ a b c))))

  (format #t "~%开始运行调度器...~%")

  (guard (ex
          [else
           (format #t "错误: ~a~%" ex)
           (when (condition? ex)
             (format #t "  Message: ~a~%"
                     (if (message-condition? ex)
                         (condition-message ex)
                         "No message")))])
    (let ([result (run-async p)])
      (format #t "~%最终结果: ~a~%" result))))

(format #t "~%=== 测试完成 ===~%")
