#!/usr/bin/env scheme-script
;;; tests/test-async-combinators.ss - async 组合器测试

(library-directories
  '(("." . ".")
    ("../internal" . "../internal")
    ("../high-level" . "../high-level")
    ("../low-level" . "../low-level")
    ("../ffi" . "../ffi")))

(import (chezscheme)
        (chez-async high-level async-await)
        (chez-async high-level async-combinators)
        (chez-async high-level promise)
        (chez-async high-level event-loop))

(format #t "~%╔════════════════════════════════════════╗~%")
(format #t "║  Async Combinators Tests              ║~%")
(format #t "╚════════════════════════════════════════╝~%~%")

;; ========================================
;; 辅助函数
;; ========================================

(define (test-passed name)
  (format #t "✓ ~a~%" name))

(define (test-failed name error)
  (format #t "✗ ~a: ~a~%" name error))

;; ========================================
;; 测试 1: async-sleep
;; ========================================

(format #t "Test 1: async-sleep~%")
(format #t "─────────────────────~%")

(let ([start-time (time-second (current-time 'time-monotonic))])
  (run-async
    (async
      (format #t "  Starting sleep...~%")
      (await (async-sleep 100))
      (let* ([end-time (time-second (current-time 'time-monotonic))]
             [elapsed-sec (- end-time start-time)]
             [elapsed-ms (* elapsed-sec 1000)])
        (format #t "  Slept for ~a ms~%" (truncate elapsed-ms))
        (if (>= elapsed-ms 90)  ; 至少 90ms
            (test-passed "async-sleep")
            (test-failed "async-sleep" "sleep time too short"))))))

(format #t "~%")

;; ========================================
;; 测试 2: async-all - 所有成功
;; ========================================

(format #t "Test 2: async-all (all succeed)~%")
(format #t "──────────────────────────────~%")

(run-async
  (async
    (let* ([promises (list
                       (async (await (async-sleep 50)) 1)
                       (async (await (async-sleep 30)) 2)
                       (async (await (async-sleep 70)) 3))]
           [results (await (async-all promises))])
      (format #t "  Results: ~a~%" results)
      (if (equal? results '(1 2 3))
          (test-passed "async-all (all succeed)")
          (test-failed "async-all" (format "expected (1 2 3), got ~a" results))))))

(format #t "~%")

;; ========================================
;; 测试 3: async-all - 一个失败
;; ========================================

(format #t "Test 3: async-all (one fails)~%")
(format #t "───────────────────────────────~%")

(run-async
  (async
    (guard (ex
            [else
             (format #t "  Caught error: ~a~%" ex)
             (if (string=? ex "error-2")
                 (test-passed "async-all (one fails)")
                 (test-failed "async-all" (format "unexpected error: ~a" ex)))])
      (let* ([promises (list
                         (async (await (async-sleep 50)) 1)
                         (async (await (async-sleep 30)) (raise "error-2"))
                         (async (await (async-sleep 70)) 3))]
             [results (await (async-all promises))])
        (test-failed "async-all" "should have thrown error")))))

(format #t "~%")

;; ========================================
;; 测试 4: async-race - 最快的完成
;; ========================================

(format #t "Test 4: async-race~%")
(format #t "────────────────────~%")

(run-async
  (async
    (let* ([promises (list
                       (async (await (async-sleep 100)) 'slow)
                       (async (await (async-sleep 30)) 'fast)
                       (async (await (async-sleep 200)) 'very-slow))]
           [winner (await (async-race promises))])
      (format #t "  Winner: ~a~%" winner)
      (if (eq? winner 'fast)
          (test-passed "async-race")
          (test-failed "async-race" (format "expected 'fast, got ~a" winner))))))

(format #t "~%")

;; ========================================
;; 测试 5: async-any - 第一个成功
;; ========================================

(format #t "Test 5: async-any (first success)~%")
(format #t "───────────────────────────────~%")

(run-async
  (async
    (let* ([promises (list
                       (async (await (async-sleep 100)) (raise "error-1"))
                       (async (await (async-sleep 50)) 'success)
                       (async (await (async-sleep 30)) (raise "error-2")))]
           [result (await (async-any promises))])
      (format #t "  Result: ~a~%" result)
      (if (eq? result 'success)
          (test-passed "async-any (first success)")
          (test-failed "async-any" (format "expected 'success, got ~a" result))))))

(format #t "~%")

;; ========================================
;; 测试 6: async-any - 全部失败
;; ========================================

(format #t "Test 6: async-any (all fail)~%")
(format #t "──────────────────────────────~%")

(run-async
  (async
    (guard (ex
            [else
             (format #t "  Caught aggregate error: ~a~%" ex)
             (if (and (pair? ex) (eq? (car ex) 'aggregate-error))
                 (test-passed "async-any (all fail)")
                 (test-failed "async-any" "expected aggregate-error"))])
      (let* ([promises (list
                         (async (await (async-sleep 50)) (raise "error-1"))
                         (async (await (async-sleep 30)) (raise "error-2"))
                         (async (await (async-sleep 70)) (raise "error-3")))]
             [result (await (async-any promises))])
        (test-failed "async-any" "should have thrown aggregate error")))))

(format #t "~%")

;; ========================================
;; 测试 7: async-timeout - 成功完成
;; ========================================

(format #t "Test 7: async-timeout (completes in time)~%")
(format #t "───────────────────────────────────────~%")

(run-async
  (async
    (let ([result (await (async-timeout
                           (async
                             (await (async-sleep 50))
                             'done)
                           200))])  ; 200ms 超时，任务 50ms 完成
      (format #t "  Result: ~a~%" result)
      (if (eq? result 'done)
          (test-passed "async-timeout (completes in time)")
          (test-failed "async-timeout" (format "expected 'done, got ~a" result))))))

(format #t "~%")

;; ========================================
;; 测试 8: async-timeout - 超时
;; ========================================

(format #t "Test 8: async-timeout (times out)~%")
(format #t "────────────────────────────────~%")

(run-async
  (async
    (guard (ex
            [(timeout-error? ex)
             (format #t "  Timeout after ~a ms~%" (timeout-error-timeout-ms ex))
             (test-passed "async-timeout (times out)")]
            [else
             (test-failed "async-timeout" (format "unexpected error: ~a" ex))])
      (let ([result (await (async-timeout
                             (async
                               (await (async-sleep 200))
                               'done)
                             50))])  ; 50ms 超时，任务需要 200ms
        (test-failed "async-timeout" "should have timed out")))))

(format #t "~%")

;; ========================================
;; 测试 9: async-delay
;; ========================================

(format #t "Test 9: async-delay~%")
(format #t "─────────────────────~%")

(let ([start-time (time-second (current-time 'time-monotonic))])
  (run-async
    (async
      (format #t "  Delaying operation...~%")
      (let ([result (await (async-delay 100
                             (lambda ()
                               (async 'delayed-result))))])
        (let* ([end-time (time-second (current-time 'time-monotonic))]
               [elapsed-sec (- end-time start-time)]
               [elapsed-ms (* elapsed-sec 1000)])
          (format #t "  Got result after ~a ms: ~a~%"
                  (truncate elapsed-ms)
                  result)
          (if (and (eq? result 'delayed-result)
                   (>= elapsed-ms 90))
              (test-passed "async-delay")
              (test-failed "async-delay" "timing or result mismatch")))))))

(format #t "~%")

;; ========================================
;; 测试 10: 组合使用
;; ========================================

(format #t "Test 10: Complex combination~%")
(format #t "──────────────────────────────~%")

(run-async
  (async
    (format #t "  Running complex async workflow...~%")

    ;; 场景：并发请求多个服务器，任一成功即可，但有超时
    (guard (ex
            [(timeout-error? ex)
             (test-failed "Complex combination" "timeout")]
            [else
             (test-failed "Complex combination" (format "error: ~a" ex))])

      (let ([result
             (await
               (async-timeout
                 (async-any
                   (list
                     ;; 模拟慢服务器
                     (async (await (async-sleep 150)) 'server-1)
                     ;; 模拟失败的服务器
                     (async (await (async-sleep 30)) (raise "server-2-error"))
                     ;; 模拟快速成功的服务器
                     (async (await (async-sleep 50)) 'server-3)))
                 300))])  ; 300ms 总超时

        (format #t "  Got response from: ~a~%" result)
        (if (eq? result 'server-3)
            (test-passed "Complex combination")
            (test-failed "Complex combination"
                        (format "expected 'server-3, got ~a" result)))))))

(format #t "~%")

;; ========================================
;; 测试总结
;; ========================================

(format #t "╔════════════════════════════════════════╗~%")
(format #t "║  All Tests Completed                  ║~%")
(format #t "╚════════════════════════════════════════╝~%~%")

(format #t "Key Features Demonstrated:~%")
(format #t "  • async-sleep: 延迟执行~%")
(format #t "  • async-all: 等待所有完成~%")
(format #t "  • async-race: 返回最快的~%")
(format #t "  • async-any: 返回第一个成功的~%")
(format #t "  • async-timeout: 超时控制~%")
(format #t "  • async-delay: 延迟操作~%")
(format #t "  • Complex: 组合使用~%~%")
