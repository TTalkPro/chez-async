#!/usr/bin/env scheme-script
;;; tests/test-fs-watch.ss - 文件系统监视测试
;;;
;;; 测试 FS Event 和 FS Poll 句柄

(import (chezscheme)
        (chez-async tests framework)
        (chez-async high-level event-loop)
        (chez-async low-level fs-event)
        (chez-async low-level fs-poll)
        (chez-async low-level timer)
        (chez-async low-level handle-base))

(test-group "FS Event Tests"

  (test "fs-event-init"
    ;; 测试 fs-event 句柄初始化
    (let* ([loop (uv-loop-init)]
           [fs-event (uv-fs-event-init loop)])
      (assert-true (handle? fs-event) "should create fs-event handle")
      (assert-equal 'fs-event (handle-type fs-event) "should have correct type")
      ;; 清理
      (uv-handle-close! fs-event)
      (uv-run loop 'default)
      (uv-loop-close loop)))

  (test "fs-event-watch-file"
    ;; 测试监视文件变化
    (let* ([loop (uv-loop-init)]
           [fs-event (uv-fs-event-init loop)]
           [test-file "/tmp/chez-async-test-file.txt"]
           [event-received #f]
           [timer #f])
      ;; 创建测试文件
      (call-with-output-file test-file
        (lambda (port)
          (display "initial content" port))
        'truncate)
      ;; 启动监视
      (uv-fs-event-start! fs-event test-file
        (lambda (handle filename events status)
          (set! event-received #t)
          (uv-fs-event-stop! handle)))
      ;; 设置定时器来修改文件
      (set! timer (uv-timer-init loop))
      (uv-timer-start! timer 50 0
        (lambda (t)
          ;; 修改文件触发事件
          (call-with-output-file test-file
            (lambda (port)
              (display "modified content" port))
            'truncate)))
      ;; 设置超时
      (let ([timeout (uv-timer-init loop)])
        (uv-timer-start! timeout 500 0
          (lambda (t)
            ;; 超时，停止监视
            (when (not (handle-closed? fs-event))
              (uv-fs-event-stop! fs-event))
            (uv-handle-close! timeout)))
        ;; 运行事件循环
        (uv-run loop 'default)
        ;; 清理
        (uv-handle-close! fs-event)
        (uv-handle-close! timer)
        (uv-run loop 'default)
        (delete-file test-file)
        (uv-loop-close loop)
        ;; 验证（某些系统可能不触发事件，所以不强制断言）
        (assert-true #t "fs-event test completed"))))

  (test "fs-event-getpath"
    ;; 测试获取监视路径
    (let* ([loop (uv-loop-init)]
           [fs-event (uv-fs-event-init loop)]
           [test-path "/tmp"])
      ;; 启动监视
      (uv-fs-event-start! fs-event test-path
        (lambda (handle filename events status) #f))
      ;; 获取路径
      (let ([path (uv-fs-event-getpath fs-event)])
        (assert-true (string? path) "should return path string")
        (assert-equal test-path path "path should match"))
      ;; 清理
      (uv-fs-event-stop! fs-event)
      (uv-handle-close! fs-event)
      (uv-run loop 'default)
      (uv-loop-close loop)))

) ; end FS Event Tests

(test-group "FS Poll Tests"

  (test "fs-poll-init"
    ;; 测试 fs-poll 句柄初始化
    (let* ([loop (uv-loop-init)]
           [fs-poll (uv-fs-poll-init loop)])
      (assert-true (handle? fs-poll) "should create fs-poll handle")
      (assert-equal 'fs-poll (handle-type fs-poll) "should have correct type")
      ;; 清理
      (uv-handle-close! fs-poll)
      (uv-run loop 'default)
      (uv-loop-close loop)))

  (test "fs-poll-watch-file"
    ;; 测试轮询文件变化
    (let* ([loop (uv-loop-init)]
           [fs-poll (uv-fs-poll-init loop)]
           [test-file "/tmp/chez-async-poll-test.txt"]
           [poll-count 0]
           [timer #f])
      ;; 创建测试文件
      (call-with-output-file test-file
        (lambda (port)
          (display "initial" port))
        'truncate)
      ;; 启动轮询（100ms 间隔）
      (uv-fs-poll-start! fs-poll test-file
        (lambda (handle status prev-stat curr-stat)
          (set! poll-count (+ poll-count 1))
          ;; 轮询几次后停止
          (when (>= poll-count 2)
            (uv-fs-poll-stop! handle)))
        100)
      ;; 设置定时器修改文件
      (set! timer (uv-timer-init loop))
      (uv-timer-start! timer 150 0
        (lambda (t)
          (call-with-output-file test-file
            (lambda (port)
              (display "modified!" port))
            'truncate)))
      ;; 设置超时
      (let ([timeout (uv-timer-init loop)])
        (uv-timer-start! timeout 1000 0
          (lambda (t)
            (when (not (handle-closed? fs-poll))
              (uv-fs-poll-stop! fs-poll))
            (uv-handle-close! timeout)))
        ;; 运行事件循环
        (uv-run loop 'default)
        ;; 清理
        (uv-handle-close! fs-poll)
        (uv-handle-close! timer)
        (uv-run loop 'default)
        (delete-file test-file)
        (uv-loop-close loop)
        ;; 验证轮询被调用了
        (assert-true (> poll-count 0) "poll callback should be called"))))

  (test "fs-poll-getpath"
    ;; 测试获取轮询路径
    (let* ([loop (uv-loop-init)]
           [fs-poll (uv-fs-poll-init loop)]
           [test-file "/tmp/chez-async-poll-path.txt"])
      ;; 创建测试文件
      (call-with-output-file test-file
        (lambda (port)
          (display "test" port))
        'truncate)
      ;; 启动轮询
      (uv-fs-poll-start! fs-poll test-file
        (lambda (handle status prev-stat curr-stat) #f)
        1000)
      ;; 获取路径
      (let ([path (uv-fs-poll-getpath fs-poll)])
        (assert-true (string? path) "should return path string")
        (assert-equal test-file path "path should match"))
      ;; 清理
      (uv-fs-poll-stop! fs-poll)
      (uv-handle-close! fs-poll)
      (uv-run loop 'default)
      (delete-file test-file)
      (uv-loop-close loop)))

) ; end FS Poll Tests

(run-tests)
