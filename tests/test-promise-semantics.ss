#!/usr/bin/env scheme-script
;;; tests/test-promise-semantics.ss - F2 死锁检测 + H3 Promise 语义对齐
;;;
;;; F2: promise-wait / 调度器在无活跃句柄却仍 pending 时报死锁，而非 100% CPU 空转
;;; H3: promise-resolved 跟随 promise 值；promise-finally 等待返回的 promise

(import (chezscheme)
        (chez-async tests framework)
        (chez-async)
        (chez-async high-level promise))

(test-group "Promise Semantics (F2 + H3)"

  ;; ---- F2: promise-wait 永不 settle 的 promise → 报死锁（不空转/不挂起）----
  (test "promise-wait-detects-deadlock"
    (let ([loop (uv-default-loop)])
      (let ([p (make-promise loop (lambda (resolve reject) #f))])  ; 永不 settle
        (assert-error (lambda () (promise-wait p))
                      "promise-wait on never-settling promise should raise deadlock, not spin"))))

  ;; ---- F2: 调度器检测协程 await 永不 settle 的 promise（用独立 loop 隔离）----
  (test "scheduler-detects-coroutine-deadlock"
    (let ([loop (uv-loop-init)])
      (async/loop loop (await (make-promise loop (lambda (r j) #f))))
      (assert-error (lambda () (uv-run loop 'default))
                    "scheduler should raise deadlock for coroutine awaiting unresolvable promise")
      (uv-loop-close loop)))

  ;; ---- F2: promise-wait 正常 promise 仍能拿到值 ----
  (test "promise-wait-still-resolves-normally"
    (let ([loop (uv-default-loop)])
      (let ([p (make-promise loop
                 (lambda (resolve reject)
                   (run-after loop 20 (lambda () (resolve 7)))))])
        (assert-equal 7 (promise-wait p) "promise-wait should return value for a resolvable promise"))))

  ;; ---- H3.1: promise-resolved 跟随 promise 值（不再把 promise 当普通值）----
  (test "promise-resolved-follows-inner-promise"
    (let ([loop (uv-default-loop)]
          [result 'unset])
      (let ([inner (make-promise loop
                     (lambda (resolve reject)
                       (run-after loop 10 (lambda () (resolve 'inner-value)))))])
        (promise-then (promise-resolved loop inner)
          (lambda (v) (set! result v) (uv-stop loop)))
        (uv-run loop 'default)
        ;; 若未解包，result 会是 inner 这个 promise 对象；解包后应是 'inner-value
        (assert-equal 'inner-value result
                      "promise-resolved should adopt the inner promise's value"))))

  ;; ---- H3.1: promise-resolved 普通值仍立即 fulfilled ----
  (test "promise-resolved-plain-value"
    (let ([p (promise-resolved 42)])
      (assert-true (promise-fulfilled? p) "plain value should be immediately fulfilled")))

  ;; ---- H3.2: promise-finally 等待 on-finally 返回的 promise 后再传递原值 ----
  (test "promise-finally-awaits-returned-promise"
    (let ([loop (uv-default-loop)]
          [order '()]
          [result 'unset])
      (promise-then
        (promise-finally (promise-resolved loop 'original)
          (lambda ()
            (make-promise loop
              (lambda (resolve reject)
                (run-after loop 20
                  (lambda () (set! order (cons 'finally-done order)) (resolve 'ignored)))))))
        (lambda (v)
          (set! order (cons 'value-seen order))
          (set! result v)
          (uv-stop loop)))
      (uv-run loop 'default)
      (assert-equal 'original result "finally should pass through the original value")
      (assert-equal '(finally-done value-seen) (reverse order)
                    "finally's promise must settle BEFORE the original value propagates")))

  ;; ---- H3.2: on-finally 的 promise reject 时，以该错误取代原结果 ----
  (test "promise-finally-rejection-overrides"
    (let ([loop (uv-default-loop)]
          [caught 'unset])
      (promise-then
        (promise-finally (promise-resolved loop 'original)
          (lambda ()
            (promise-rejected loop 'finally-error)))
        (lambda (v) (uv-stop loop))
        (lambda (e) (set! caught e) (uv-stop loop)))
      (uv-run loop 'default)
      (assert-equal 'finally-error caught
                    "a rejecting finally promise should override the outcome")))

  )

(run-tests)
