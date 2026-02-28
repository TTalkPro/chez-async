;;; tests/simple-coroutine-test.ss - 简单的协程测试

(import (chezscheme)
        (chez-async internal coroutine)
        (chez-async internal scheduler)
        (chez-async high-level event-loop))

(format #t "~%=== 简单协程测试 ===~%~%")

;; 测试 1: 创建协程
(format #t "测试 1: 创建协程~%")
(let* ([loop (uv-default-loop)]
       [coro (make-coroutine loop)])
  (format #t "  协程 ID: ~a~%" (coroutine-id coro))
  (format #t "  协程状态: ~a~%" (coroutine-state coro))
  (format #t "  ✓ 成功~%~%"))

;; 测试 2: spawn 简单协程
(format #t "测试 2: spawn 简单协程~%")
(let* ([loop (uv-default-loop)]
       [executed? #f]
       [coro (spawn-coroutine! loop
               (lambda ()
                 (format #t "  协程正在执行...~%")
                 (set! executed? #t)
                 42))])
  (format #t "  协程已创建: ~a~%" (coroutine-id coro))
  (format #t "  初始状态: ~a~%" (coroutine-state coro))
  (format #t "  开始运行调度器...~%")
  (run-scheduler loop)
  (format #t "  执行完成!~%")
  (format #t "  executed? = ~a~%" executed?)
  (format #t "  协程状态: ~a~%" (coroutine-state coro))
  (format #t "  协程结果: ~a~%" (coroutine-result coro))
  (format #t "  ~a~%~%" (if executed? "✓ 成功" "✗ 失败")))

(format #t "=== 测试完成 ===~%")
