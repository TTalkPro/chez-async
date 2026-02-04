;;; tests/debug-suspend-test.ss - 调试暂停/恢复

(import (chezscheme)
        (chez-async internal coroutine)
        (chez-async internal scheduler)
        (chez-async high-level event-loop)
        (chez-async high-level promise))

(format #t "~%=== 调试暂停/恢复 ===~%~%")

;; 简单测试：等待已解决的 Promise
(format #t "测试：等待已解决的 Promise~%")
(let* ([loop (uv-default-loop)]
       [result #f]
       [promise (promise-resolved loop 42)])

  (format #t "  Promise 状态: ~a~%" (promise-state promise))

  (let ([coro (spawn-coroutine! loop
                (lambda ()
                  (format #t "    协程：开始执行~%")
                  (format #t "    协程：调用 suspend-for-promise!~%")
                  (let ([value (suspend-for-promise! promise)])
                    (format #t "    协程：恢复后收到值 ~a~%" value)
                    (set! result value)
                    value)))])

    (format #t "  运行调度器...~%")

    ;; 手动控制调度循环，添加调试输出
    (let ([sched (get-scheduler loop)])
      (format #t "  [调度器] 开始调度循环~%")

      ;; 手动执行几次迭代
      (do ([i 0 (+ i 1)])
          ((or (> i 10)
               (and (queue-empty? (scheduler-runnable-queue sched))
                    (= (hashtable-size (scheduler-pending-table sched)) 0))))
        (format #t "  [调度器] 迭代 ~a~%" i)
        (format #t "    可运行队列大小: ~a~%"
                (queue-size (scheduler-runnable-queue sched)))
        (format #t "    等待表大小: ~a~%"
                (hashtable-size (scheduler-pending-table sched)))

        (cond
          [(queue-not-empty? (scheduler-runnable-queue sched))
           (format #t "    执行可运行协程~%")
           (let ([c (queue-dequeue! (scheduler-runnable-queue sched))])
             (format #t "    协程 ~a 状态: ~a~%" (coroutine-id c) (coroutine-state c))
             (run-coroutine! sched c))]
          [(> (hashtable-size (scheduler-pending-table sched)) 0)
           (format #t "    运行事件循环~%")
           (uv-run loop 'once)]
          [else
           (format #t "    没有更多工作~%")])))

    (format #t "~%  最终结果:~%")
    (format #t "    result = ~a~%" result)
    (format #t "    协程状态: ~a~%" (coroutine-state coro))
    (when (coroutine-result coro)
      (format #t "    协程结果: ~a~%" (coroutine-result coro)))))

(format #t "~%=== 测试完成 ===~%")
