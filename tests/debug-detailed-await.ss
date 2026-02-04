;;; tests/debug-detailed-await.ss - 详细调试 await

(import (chezscheme)
        (chez-async high-level async-await-cc)
        (chez-async high-level promise)
        (chez-async high-level event-loop)
        (chez-async internal coroutine)
        (chez-async internal scheduler))

(format #t "~%=== 详细调试 await ===~%~%")

(define test-loop (uv-default-loop))

(format #t "Loop: ~a~%~%" test-loop)

(define p
  (async
    (format #t "[Async] 开始执行~%")
    (format #t "[Async] 当前协程: ~a~%~%" (current-coroutine))

    (format #t "[Async] === 第1次 await ===~%")
    (format #t "[Async] 创建第1个 Promise~%")
    (let ([p1 (promise-resolved test-loop 10)])
      (format #t "[Async] Promise状态: ~a~%" (promise-state p1))
      (format #t "[Async] 调用 await~%")
      (let ([a (guard (ex
                       [else
                        (format #t "[Async] await抛出错误: ~a~%" ex)
                        (raise ex)])
                 (await p1))])
        (format #t "[Async] await返回: ~a~%~%" a)

        (format #t "[Async] === 第2次 await ===~%")
        (format #t "[Async] 当前协程: ~a~%" (current-coroutine))
        (format #t "[Async] 创建第2个 Promise~%")
        (let ([p2 (guard (ex
                          [else
                           (format #t "[Async] 创建Promise失败: ~a~%" ex)
                           (raise ex)])
                    (promise-resolved test-loop 20))])
          (format #t "[Async] Promise状态: ~a~%" (promise-state p2))
          (format #t "[Async] 调用 await~%")
          (let ([b (guard (ex
                           [else
                            (format #t "[Async] await抛出错误: ~a~%" ex)
                            (raise ex)])
                     (await p2))])
            (format #t "[Async] await返回: ~a~%~%" b)
            (+ a b)))))))

(format #t "开始运行...~%~%")

(guard (ex
        [else
         (format #t "~%外层捕获错误: ~a~%" ex)])
  (let ([result (run-async p)])
    (format #t "~%最终结果: ~a~%" result)))

(format #t "~%=== 测试完成 ===~%")
