#!/usr/bin/env scheme-script
;;; tests/test-scheduler-integration.ss - F1 调度器与事件循环集成
;;;
;;; 验证 async/await 协程可由普通 (uv-run loop 'default) 驱动，
;;; 无需单独调用 run-async-loop —— 消除「async + uv-run 静默失效」的陷阱。
;;; 同时验证纯 libuv 程序（不用协程）行为不受影响。

(import (chezscheme)
        (chez-async tests framework)
        (chez-async))

(test-group "Scheduler ↔ Event-loop Integration (F1)"

  ;; ---- 核心：async + 普通 uv-run 'default 可直接混用 ----
  (test "async-runs-under-plain-uv-run-default"
    (let ([loop (uv-default-loop)]
          [done #f])
      (async
        (await (async-sleep 20))
        (set! done #t))
      (uv-run loop 'default)   ; 不用 run-async-loop
      (assert-true done "coroutine should complete under plain uv-run 'default")))

  ;; ---- 多次 await 链式推进 ----
  (test "chained-awaits-complete-under-uv-run-default"
    (let ([loop (uv-default-loop)]
          [steps '()])
      (async
        (await (async-sleep 10))
        (set! steps (cons 'a steps))
        (await (async-sleep 10))
        (set! steps (cons 'b steps))
        (await (async-sleep 10))
        (set! steps (cons 'c steps)))
      (uv-run loop 'default)
      (assert-equal '(a b c) (reverse steps) "all three await stages should run in order")))

  ;; ---- await 一个 resolved promise 也能拿到值 ----
  (test "await-resolved-promise-value"
    (let ([loop (uv-default-loop)]
          [result #f])
      (async
        (let ([v (await (promise-resolved 99))])
          (set! result v)))
      (uv-run loop 'default)
      (assert-equal 99 result "await should yield the resolved value")))

  ;; ---- uv-run 'default 同时驱动协程与普通微任务 ----
  (test "uv-run-default-drives-both-coroutine-and-microtask"
    (let ([loop (uv-default-loop)]
          [coro-done #f]
          [then-done #f])
      (async (await (async-sleep 15)) (set! coro-done #t))
      (promise-then (promise-resolved 'x) (lambda (v) (set! then-done #t)))
      (uv-run loop 'default)
      (assert-true coro-done "coroutine should complete")
      (assert-true then-done "microtask .then should also fire")))

  ;; ---- 协程完成后，uv-run 'default 继续驱动其余句柄 ----
  (test "other-handles-still-driven-after-coroutine-done"
    (let ([loop (uv-default-loop)]
          [coro-done #f]
          [timer-fired #f])
      (async (set! coro-done #t))               ; 立即完成的协程
      (run-after loop 30 (lambda () (set! timer-fired #t)))  ; 独立 timer
      (uv-run loop 'default)
      (assert-true coro-done "coroutine should complete")
      (assert-true timer-fired "independent timer should still fire under same uv-run")))

  ;; ---- 回归：纯 libuv 程序（从不用协程）行为不变 ----
  (test "pure-libuv-loop-unaffected"
    (let ([loop (uv-loop-init)]    ; 全新 loop，从无调度器
          [fired #f])
      (run-after loop 10 (lambda () (set! fired #t)))
      (uv-run loop 'default)       ; 走原生 uv_run 路径
      (assert-true fired "plain timer should fire on a scheduler-free loop")
      (uv-loop-close loop)))

  )

(run-tests)
