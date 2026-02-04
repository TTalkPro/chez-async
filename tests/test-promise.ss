#!/usr/bin/env scheme-script
;;; tests/test-promise.ss - Promise 测试

(import (chezscheme)
        (chez-async tests framework)
        (chez-async high-level event-loop)
        (chez-async high-level promise)
        (chez-async low-level timer)
        (chez-async low-level handle-base))

(test-group "Promise Basic Tests"

  (test "promise-resolved"
    ;; 测试立即成功的 Promise
    (let* ([loop (uv-loop-init)]
           [p (promise-resolved loop 42)]
           [result #f])
      (promise-then p
        (lambda (value)
          (set! result value)))
      (uv-run loop 'default)
      (assert-equal 42 result "should resolve with value")
      (uv-loop-close loop)))

  (test "promise-rejected"
    ;; 测试立即失败的 Promise
    (let* ([loop (uv-loop-init)]
           [p (promise-rejected loop "error")]
           [result #f])
      (promise-catch p
        (lambda (reason)
          (set! result reason)))
      (uv-run loop 'default)
      (assert-equal "error" result "should reject with reason")
      (uv-loop-close loop)))

  (test "promise-state"
    ;; 测试 Promise 状态
    (let* ([loop (uv-loop-init)]
           [p1 (promise-resolved loop 1)]
           [p2 (promise-rejected loop "err")])
      (assert-true (promise-fulfilled? p1) "resolved should be fulfilled")
      (assert-true (promise-rejected? p2) "rejected should be rejected")
      (assert-equal 'fulfilled (promise-state p1) "state should be fulfilled")
      (assert-equal 'rejected (promise-state p2) "state should be rejected")
      (uv-loop-close loop)))

) ; end Promise Basic Tests

(test-group "Promise Chain Tests"

  (test "promise-then-chain"
    ;; 测试 then 链式调用
    (let* ([loop (uv-loop-init)]
           [result #f])
      (promise-then
        (promise-then
          (promise-resolved loop 1)
          (lambda (v) (+ v 1)))
        (lambda (v)
          (set! result (* v 2))))
      (uv-run loop 'default)
      (assert-equal 4 result "chain should work: (1+1)*2=4")
      (uv-loop-close loop)))

  (test "promise-catch-recovery"
    ;; 测试 catch 恢复
    (let* ([loop (uv-loop-init)]
           [result #f])
      (promise-then
        (promise-catch
          (promise-rejected loop "error")
          (lambda (r) "recovered"))
        (lambda (v)
          (set! result v)))
      (uv-run loop 'default)
      (assert-equal "recovered" result "catch should recover")
      (uv-loop-close loop)))

  (test "promise-finally"
    ;; 测试 finally
    (let* ([loop (uv-loop-init)]
           [finally-called #f]
           [result #f])
      (promise-then
        (promise-finally
          (promise-resolved loop 42)
          (lambda () (set! finally-called #t)))
        (lambda (v) (set! result v)))
      (uv-run loop 'default)
      (assert-true finally-called "finally should be called")
      (assert-equal 42 result "value should pass through")
      (uv-loop-close loop)))

) ; end Promise Chain Tests

(test-group "Promise Async Tests"

  (test "promise-with-timer"
    ;; 测试与 timer 集成
    (let* ([loop (uv-loop-init)]
           [result #f]
           [p (make-promise loop
                (lambda (resolve reject)
                  (let ([timer (uv-timer-init loop)])
                    (uv-timer-start! timer 10 0
                      (lambda (t)
                        (uv-handle-close! t)
                        (resolve "delayed"))))))])
      (promise-then p
        (lambda (v) (set! result v)))
      (uv-run loop 'default)
      (assert-equal "delayed" result "should resolve after timer")
      (uv-loop-close loop)))

  (test "promise-executor-error"
    ;; 测试 executor 中的错误
    (let* ([loop (uv-loop-init)]
           [result #f]
           [p (make-promise loop
                (lambda (resolve reject)
                  (error 'test "intentional error")))])
      (promise-catch p
        (lambda (r) (set! result 'caught)))
      (uv-run loop 'default)
      (assert-equal 'caught result "executor error should be caught")
      (uv-loop-close loop)))

) ; end Promise Async Tests

(test-group "Promise Combinator Tests"

  (test "promise-all-success"
    ;; 测试 promise-all 全部成功
    (let* ([loop (uv-loop-init)]
           [result #f]
           [p1 (promise-resolved loop 1)]
           [p2 (promise-resolved loop 2)]
           [p3 (promise-resolved loop 3)])
      (promise-then (promise-all (list p1 p2 p3))
        (lambda (values)
          (set! result values)))
      (uv-run loop 'default)
      (assert-equal '(1 2 3) result "should collect all values")
      (uv-loop-close loop)))

  (test "promise-all-failure"
    ;; 测试 promise-all 有失败
    (let* ([loop (uv-loop-init)]
           [result #f]
           [p1 (promise-resolved loop 1)]
           [p2 (promise-rejected loop "fail")]
           [p3 (promise-resolved loop 3)])
      (promise-catch (promise-all (list p1 p2 p3))
        (lambda (reason)
          (set! result reason)))
      (uv-run loop 'default)
      (assert-equal "fail" result "should reject on first failure")
      (uv-loop-close loop)))

  (test "promise-race"
    ;; 测试 promise-race
    (let* ([loop (uv-loop-init)]
           [result #f]
           [p1 (promise-resolved loop "first")]
           [p2 (make-promise loop
                 (lambda (resolve reject)
                   (let ([timer (uv-timer-init loop)])
                     (uv-timer-start! timer 100 0
                       (lambda (t)
                         (uv-handle-close! t)
                         (resolve "second"))))))])
      (promise-then (promise-race (list p1 p2))
        (lambda (v) (set! result v)))
      (uv-run loop 'default)
      (assert-equal "first" result "should return first resolved")
      (uv-loop-close loop)))

  (test "promise-all-settled"
    ;; 测试 promise-all-settled
    (let* ([loop (uv-loop-init)]
           [result #f]
           [p1 (promise-resolved loop 1)]
           [p2 (promise-rejected loop "error")]
           [p3 (promise-resolved loop 3)])
      (promise-then (promise-all-settled (list p1 p2 p3))
        (lambda (results)
          (set! result results)))
      (uv-run loop 'default)
      (assert-equal 3 (length result) "should have 3 results")
      (assert-equal '(fulfilled . 1) (car result) "first should be fulfilled")
      (assert-equal '(rejected . "error") (cadr result) "second should be rejected")
      (assert-equal '(fulfilled . 3) (caddr result) "third should be fulfilled")
      (uv-loop-close loop)))

) ; end Promise Combinator Tests

(test-group "Promise Wait Tests"

  (test "promise-wait-fulfilled"
    ;; 测试 promise-wait
    (let* ([loop (uv-loop-init)]
           [p (promise-resolved loop 42)])
      (let ([result (promise-wait p)])
        (assert-equal 42 result "wait should return value"))
      (uv-loop-close loop)))

) ; end Promise Wait Tests

(run-tests)
