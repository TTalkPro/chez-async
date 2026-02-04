;;; tests/single-loop-timer-test.ss - 使用单一 loop 对象测试

(import (chezscheme)
        (chez-async high-level event-loop)
        (chez-async low-level timer)
        (chez-async low-level handle-base))

(format #t "~%=== 单一 Loop 对象定时器测试 ===~%~%")

;; 只创建一次 loop，并一直重用
(define test-loop (uv-default-loop))

(format #t "使用 loop: ~a~%" test-loop)
(format #t "loop ptr: ~a~%~%" (uv-loop-ptr test-loop))

;; 测试 1: 0ms 定时器
(format #t "测试 1: 0ms 定时器（使用同一个 loop）~%")
(let ([called? #f])

  (format #t "  创建定时器...~%")
  (let ([timer (uv-timer-init test-loop)])
    (format #t "  定时器对象: ~a~%" timer)
    (format #t "  启动定时器（0ms）...~%")
    (uv-timer-start! timer 0 0
      (lambda (t)
        (format #t "  [回调] 定时器被触发！~%")
        (set! called? #t)
        (uv-handle-close! t))))

  (format #t "  运行事件循环（使用同一个 loop）...~%")
  (do ([i 0 (+ i 1)])
      ((or (> i 5) called?))
    (format #t "    迭代 ~a: called?=~a, loop-alive?=~a~%"
            i called? (uv-loop-alive? test-loop))
    (let ([result (uv-run test-loop 'once)])
      (format #t "      uv-run 返回: ~a~%" result)))

  (format #t "  最终: called?=~a~%~%" called?))

;; 测试 2: 使用 'default 模式而不是 'once
(format #t "测试 2: 50ms 定时器（使用 'default 模式）~%")
(let ([called? #f])

  (format #t "  创建定时器...~%")
  (let ([timer (uv-timer-init test-loop)])
    (format #t "  启动定时器（50ms）...~%")
    (uv-timer-start! timer 50 0
      (lambda (t)
        (format #t "  [回调] 定时器被触发！~%")
        (set! called? #t)
        (uv-handle-close! t)
        ;; 停止循环
        (uv-stop test-loop))))

  (format #t "  运行事件循环（'default 模式）...~%")
  (uv-run test-loop 'default)

  (format #t "  最终: called?=~a~%~%" called?))

(format #t "=== 测试完成 ===~%")
