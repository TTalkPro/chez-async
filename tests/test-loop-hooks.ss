#!/usr/bin/env scheme-script
;;; tests/test-loop-hooks.ss - 事件循环钩子测试
;;;
;;; 测试 Prepare、Check 和 Idle 句柄

(import (chezscheme)
        (chez-async tests framework)
        (chez-async high-level event-loop)
        (chez-async low-level prepare)
        (chez-async low-level check)
        (chez-async low-level idle)
        (chez-async low-level timer)
        (chez-async low-level handle-base))

(test-group "Prepare Tests"

  (test "prepare-init"
    ;; 测试 prepare 句柄初始化
    (let* ([loop (uv-loop-init)]
           [prepare (uv-prepare-init loop)])
      (assert-true (handle? prepare) "should create prepare handle")
      (assert-equal 'prepare (handle-type prepare) "should have correct type")
      ;; 清理
      (uv-handle-close! prepare)
      (uv-run loop 'default)
      (uv-loop-close loop)))

  (test "prepare-start-stop"
    ;; 测试 prepare 启动和停止
    (let* ([loop (uv-loop-init)]
           [prepare (uv-prepare-init loop)]
           [call-count 0]
           [timer #f])
      ;; 启动 prepare
      (uv-prepare-start! prepare
        (lambda (p)
          (set! call-count (+ call-count 1))))
      ;; 创建定时器触发一次事件循环迭代
      (set! timer (uv-timer-init loop))
      (uv-timer-start! timer 10 0
        (lambda (t)
          ;; 停止 prepare
          (uv-prepare-stop! prepare)))
      ;; 运行事件循环
      (uv-run loop 'default)
      ;; 验证 prepare 被调用了
      (assert-true (> call-count 0) "prepare callback should be called")
      ;; 清理
      (uv-handle-close! prepare)
      (uv-handle-close! timer)
      (uv-run loop 'default)
      (uv-loop-close loop)))

) ; end Prepare Tests

(test-group "Check Tests"

  (test "check-init"
    ;; 测试 check 句柄初始化
    (let* ([loop (uv-loop-init)]
           [check (uv-check-init loop)])
      (assert-true (handle? check) "should create check handle")
      (assert-equal 'check (handle-type check) "should have correct type")
      ;; 清理
      (uv-handle-close! check)
      (uv-run loop 'default)
      (uv-loop-close loop)))

  (test "check-start-stop"
    ;; 测试 check 启动和停止
    (let* ([loop (uv-loop-init)]
           [check (uv-check-init loop)]
           [call-count 0]
           [timer #f])
      ;; 启动 check
      (uv-check-start! check
        (lambda (c)
          (set! call-count (+ call-count 1))))
      ;; 创建定时器触发一次事件循环迭代
      (set! timer (uv-timer-init loop))
      (uv-timer-start! timer 10 0
        (lambda (t)
          ;; 停止 check
          (uv-check-stop! check)))
      ;; 运行事件循环
      (uv-run loop 'default)
      ;; 验证 check 被调用了
      (assert-true (> call-count 0) "check callback should be called")
      ;; 清理
      (uv-handle-close! check)
      (uv-handle-close! timer)
      (uv-run loop 'default)
      (uv-loop-close loop)))

) ; end Check Tests

(test-group "Idle Tests"

  (test "idle-init"
    ;; 测试 idle 句柄初始化
    (let* ([loop (uv-loop-init)]
           [idle (uv-idle-init loop)])
      (assert-true (handle? idle) "should create idle handle")
      (assert-equal 'idle (handle-type idle) "should have correct type")
      ;; 清理
      (uv-handle-close! idle)
      (uv-run loop 'default)
      (uv-loop-close loop)))

  (test "idle-callback-count"
    ;; 测试 idle 回调被多次调用
    (let* ([loop (uv-loop-init)]
           [idle (uv-idle-init loop)]
           [call-count 0]
           [max-calls 5])
      ;; 启动 idle
      (uv-idle-start! idle
        (lambda (i)
          (set! call-count (+ call-count 1))
          ;; 调用足够次数后停止
          (when (>= call-count max-calls)
            (uv-idle-stop! i))))
      ;; 运行事件循环
      (uv-run loop 'default)
      ;; 验证 idle 被调用了指定次数
      (assert-equal max-calls call-count "idle should be called max-calls times")
      ;; 清理
      (uv-handle-close! idle)
      (uv-run loop 'default)
      (uv-loop-close loop)))

) ; end Idle Tests

(test-group "Hook Order Tests"

  (test "prepare-check-order"
    ;; 测试 prepare 在 check 之前调用
    (let* ([loop (uv-loop-init)]
           [prepare (uv-prepare-init loop)]
           [check (uv-check-init loop)]
           [order '()]
           [timer #f])
      ;; 启动 prepare（记录顺序）
      (uv-prepare-start! prepare
        (lambda (p)
          (set! order (cons 'prepare order))))
      ;; 启动 check（记录顺序）
      (uv-check-start! check
        (lambda (c)
          (set! order (cons 'check order))))
      ;; 创建定时器停止钩子
      (set! timer (uv-timer-init loop))
      (uv-timer-start! timer 10 0
        (lambda (t)
          (uv-prepare-stop! prepare)
          (uv-check-stop! check)))
      ;; 运行事件循环
      (uv-run loop 'default)
      ;; 验证顺序（check 后记录，所以在列表前面）
      (assert-true (memq 'prepare order) "prepare should be called")
      (assert-true (memq 'check order) "check should be called")
      ;; 清理
      (uv-handle-close! prepare)
      (uv-handle-close! check)
      (uv-handle-close! timer)
      (uv-run loop 'default)
      (uv-loop-close loop)))

) ; end Hook Order Tests

(run-tests)
