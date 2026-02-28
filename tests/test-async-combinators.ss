#!/usr/bin/env scheme-script
;;; tests/test-async-combinators.ss - Async 组合器测试

(import (chezscheme)
        (chez-async tests framework)
        (chez-async)
        (chez-async high-level promise))

(test-group "Async Combinators Tests"

  (test "async-sleep-resolves"
    (let ([resolved? #f])
      (promise-then
        (async-sleep 50)
        (lambda (v)
          (set! resolved? #t)
          (uv-stop (uv-default-loop))))
      (uv-run (uv-default-loop) 'default)
      (assert-true resolved? "async-sleep should resolve")))

  (test "async-timeout-completes"
    (let ([result #f])
      (promise-then
        (async-timeout (promise-resolved 42) 1000)
        (lambda (v)
          (set! result v)
          (uv-stop (uv-default-loop))))
      (uv-run (uv-default-loop) 'default)
      (assert-equal 42 result "async-timeout should return value on time")))

  (test "async-all-multi"
    (let ([result #f])
      (promise-then
        (async-all (list (promise-resolved 1) (promise-resolved 2) (promise-resolved 3)))
        (lambda (vals)
          (set! result vals)
          (uv-stop (uv-default-loop))))
      (uv-run (uv-default-loop) 'default)
      (assert-equal '(1 2 3) result "async-all should combine results")))

  (test "async-all-empty-list"
    (let ([result #f])
      (promise-then
        (async-all '())
        (lambda (vals)
          (set! result vals)
          (uv-stop (uv-default-loop))))
      (uv-run (uv-default-loop) 'default)
      (assert-equal '() result "async-all with empty list should return empty list")))

  (test "async-race-first-wins"
    (let ([result #f])
      (promise-then
        (async-race (list (async-sleep 100) (promise-resolved 42)))
        (lambda (v)
          (set! result v)
          (uv-stop (uv-default-loop))))
      (uv-run (uv-default-loop) 'default)
      (assert-equal 42 result "async-race should return first resolved value")))

  (test "async-race-empty-list"
    (let ([p (async-race '())])
      (assert-true (promise-pending? p) "async-race with empty list should be pending")))

  (test "async-any-first-wins"
    (let ([result #f])
      (promise-then
        (async-any (list (async-sleep 100) (promise-resolved 42)))
        (lambda (v)
          (set! result v)
          (uv-stop (uv-default-loop))))
      (uv-run (uv-default-loop) 'default)
      (assert-equal 42 result "async-any should return first successful value")))

  (test "promise-all-settled-all-rejected"
    (let ([result #f])
      (promise-then
        (promise-all-settled
          (list (promise-rejected "error1")
                (promise-rejected "error2")))
        (lambda (vals)
          (set! result vals)
          (uv-stop (uv-default-loop))))
      (uv-run (uv-default-loop) 'default)
      (assert-true (list? result) "promise-all-settled should return list")
      (assert-equal 2 (length result) "should have 2 results")))

  (test "promise-all-settled-mixed"
    (let ([result #f])
      (promise-then
        (promise-all-settled
          (list (promise-resolved 1)
                (promise-rejected "error")
                (promise-resolved 3)))
        (lambda (vals)
          (set! result vals)
          (uv-stop (uv-default-loop))))
      (uv-run (uv-default-loop) 'default)
      (assert-equal 3 (length result) "should have 3 results")))

  (test "async-delay-lazy"
    (let ([call-count 0])
      (let ([delayed (async-delay 50 (lambda () (set! call-count (+ call-count 1)) 42))])
        (promise-then delayed (lambda (v) (uv-stop (uv-default-loop))))
        (uv-run (uv-default-loop) 'default)
        (assert-equal 1 call-count "async-delay should call thunk once")
        (set! call-count 0)
        (promise-then delayed (lambda (v)
          (assert-equal 42 v)
          (uv-stop (uv-default-loop))))
        (uv-run (uv-default-loop) 'default)
        (assert-equal 0 call-count "async-delay should not call thunk again"))))

)
