#!/usr/bin/env scheme-script
;;; tests/test-poll.ss - Poll 功能测试
;;;
;;; 注意：Poll 测试需要直接使用 POSIX 系统调用（pipe, close, write）
;;; 在不支持直接 libc 链接的平台（如 FreeBSD）上，这些测试会被跳过

(import (chezscheme)
        (chez-async tests framework)
        (chez-async high-level event-loop)
        (chez-async low-level poll)
        (chez-async low-level timer)
        (chez-async low-level handle-base)
        (chez-async internal posix-ffi))

;; Check if we can use direct system calls
(define %can-use-posix-ffi?
  (posix-ffi-available?))

;; 辅助函数：创建管道（用于测试轮询）
(define (make-pipe)
  "创建管道，返回 (read-fd . write-fd)"
  (let ([fds (foreign-alloc (* 2 (foreign-sizeof 'int)))])
    (let ([result (posix-pipe fds)])
      (if (= result 0)
          (let ([read-fd (foreign-ref 'int fds 0)]
                [write-fd (foreign-ref 'int fds (foreign-sizeof 'int))])
            (foreign-free fds)
            (cons read-fd write-fd))
          (begin
            (foreign-free fds)
            (error 'make-pipe "failed to create pipe"))))))

(define (write-to-fd fd str)
  "向文件描述符写入字符串"
  (let* ([bv (string->utf8 str)]
         [len (bytevector-length bv)]
         [buf (foreign-alloc len)])
    (do ([i 0 (+ i 1)])
        ((= i len))
      (foreign-set! 'unsigned-8 buf i (bytevector-u8-ref bv i)))
    (let ([result (posix-write fd buf len)])
      (foreign-free buf)
      result)))

;; Skip entire test group if POSIX FFI is not available
(unless %can-use-posix-ffi?
  (printf "=== Poll Tests ===~n")
  (printf "Note: Poll tests skipped - POSIX FFI not available on this platform~n")
  (printf "This is expected on some platforms (e.g., FreeBSD) that don't automatically link libc~n")
  (printf "Use libuv's pipe or stream functionality instead for cross-platform code~n")
  (exit 0))

(test-group "Poll Tests"

  (test "poll-constants"
    ;; 验证常量定义正确
    (assert-equal 1 UV_READABLE "UV_READABLE should be 1")
    (assert-equal 2 UV_WRITABLE "UV_WRITABLE should be 2")
    (assert-equal 4 UV_DISCONNECT "UV_DISCONNECT should be 4"))

  (test "poll-init"
    (let* ([pipe-fds (make-pipe)]
           [read-fd (car pipe-fds)]
           [write-fd (cdr pipe-fds)]
           [loop (uv-loop-init)]
           [poll (uv-poll-init loop read-fd)])
      ;; 验证 Poll 句柄创建成功
      (assert-true (handle? poll) "should be a handle")
      (assert-equal 'poll (handle-type poll) "should be poll type")
      ;; 清理
      (uv-handle-close! poll)
      (uv-run loop 'default)
      (uv-loop-close loop)
      (posix-close read-fd)
      (posix-close write-fd)))

  (test "poll-readable"
    (let* ([pipe-fds (make-pipe)]
           [read-fd (car pipe-fds)]
           [write-fd (cdr pipe-fds)]
           [loop (uv-loop-init)]
           [poll (uv-poll-init loop read-fd)]
           [timer (uv-timer-init loop)]
           [readable-detected? #f])
      ;; 开始轮询可读事件
      (uv-poll-start! poll UV_READABLE
        (lambda (p err events)
          (when (and (not err) (not (= 0 (bitwise-and events UV_READABLE))))
            (set! readable-detected? #t))
          (uv-poll-stop! p)
          (uv-handle-close! p)))
      ;; 使用定时器延迟写入数据
      (uv-timer-start! timer 10 0
        (lambda (t)
          (write-to-fd write-fd "hello")
          (uv-handle-close! t)))
      ;; 运行事件循环
      (uv-run loop 'default)
      ;; 验证
      (assert-true readable-detected? "should detect readable event")
      ;; 清理
      (uv-loop-close loop)
      (posix-close read-fd)
      (posix-close write-fd)))

  (test "poll-writable"
    (let* ([pipe-fds (make-pipe)]
           [read-fd (car pipe-fds)]
           [write-fd (cdr pipe-fds)]
           [loop (uv-loop-init)]
           [poll (uv-poll-init loop write-fd)]
           [writable-detected? #f])
      ;; 开始轮询可写事件
      (uv-poll-start! poll UV_WRITABLE
        (lambda (p err events)
          (when (and (not err) (not (= 0 (bitwise-and events UV_WRITABLE))))
            (set! writable-detected? #t))
          (uv-poll-stop! p)
          (uv-handle-close! p)))
      ;; 运行事件循环（管道初始时刻应该是可写的）
      (uv-run loop 'once)
      ;; 验证
      (assert-true writable-detected? "should detect writable event")
      ;; 清理
      (uv-loop-close loop)
      (posix-close read-fd)
      (posix-close write-fd)))

  (test "poll-multiple-events"
    (let* ([pipe-fds (make-pipe)]
           [read-fd (car pipe-fds)]
           [write-fd (cdr pipe-fds)]
           [loop (uv-loop-init)]
           [poll (uv-poll-init loop read-fd)]
           [timer (uv-timer-init loop)]
           [events-detected '()])
      ;; 开始轮询读写事件
      (uv-poll-start! poll (bitwise-ior UV_READABLE UV_WRITABLE)
        (lambda (p err events)
          (set! events-detected (cons events events-detected))
          (when (> (length events-detected) 2)
            (uv-poll-stop! p)
            (uv-handle-close! p))))
      ;; 使用定时器写入数据
      (uv-timer-start! timer 10 0
        (lambda (t)
          (write-to-fd write-fd "test")
          (uv-handle-close! t)))
      ;; 运行事件循环
      (uv-run loop 'default)
      ;; 验证至少检测到一些事件
      (assert-true (> (length events-detected) 0) "should detect events")
      ;; 清理
      (uv-loop-close loop)
      (posix-close read-fd)
      (posix-close write-fd)))

  ) ; end test-group

(run-tests)
