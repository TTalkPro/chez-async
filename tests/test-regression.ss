#!/usr/bin/env scheme-script
;;; tests/test-regression.ss - 2026-07-20 修复轮的回归测试
;;;
;;; 覆盖本轮修复中现有测试触及不到的错误路径 / 边界行为：
;;; - B4: then 回调 FIFO 顺序
;;; - B5: async-timeout 操作先完成时取消 timer（loop 不被空 timer 拖住）
;;; - C1: c-string UTF-8 往返（中文内容 + 中文文件名）
;;; - C3: 空数据写入不再触发 (foreign-alloc 0)
;;; - A1/A2: 读/收回调先拷贝后释放（正常读路径仍正确）
;;; - B3: 用户回调抛异常时句柄仍被关闭（loop 能正常退出）

(import (chezscheme)
        (chez-async tests framework)
        (chez-async high-level event-loop)
        (chez-async high-level promise)
        (chez-async high-level async-combinators)
        (chez-async low-level udp)
        (chez-async low-level fs)
        (chez-async low-level process)
        (chez-async low-level handle-base)
        (chez-async ffi fs))

;; 独立的临时目录，避免与其他测试冲突
(define test-dir "/tmp/chez-async-regression-test")
(define (cleanup-test-dir)
  (when (file-exists? test-dir)
    (system (format "rm -rf ~a" test-dir))))
(cleanup-test-dir)

(test-group "Regression Tests (2026-07-20 fixes)"

  ;; ---- B4: then 回调按注册顺序（FIFO）触发 ----
  (test "then-callbacks-fire-in-registration-order"
    (let* ([loop (uv-loop-init)]
           [resolve-fn #f]
           [order '()]
           [p (make-promise loop
                (lambda (resolve reject) (set! resolve-fn resolve)))])
      ;; 在 pending 状态注册三个回调
      (promise-then p (lambda (v) (set! order (cons 1 order))))
      (promise-then p (lambda (v) (set! order (cons 2 order))))
      (promise-then p (lambda (v)
                        (set! order (cons 3 order))
                        (uv-stop loop)))
      (resolve-fn 'ready)
      (uv-run loop 'default)
      ;; order 是头插构建的，reverse 得到实际触发顺序
      (assert-equal '(1 2 3) (reverse order)
                    "then callbacks should fire in FIFO order")
      (uv-loop-close loop)))

  ;; ---- B5: 操作先完成时超时 timer 被取消，loop 立即退出 ----
  ;; 若 timer 未取消，20s 的 ref'd timer 会把 loop 拖住，
  ;; 触发测试套件 15s 超时（TIMEOUT）。修复后 loop 立即自然退出。
  (test "async-timeout-cancels-pending-timer-on-early-completion"
    (let ([result #f])
      ;; 注意：故意不调用 uv-stop——依赖 timer 被取消后 loop 自然退出
      (promise-then
        (async-timeout (promise-resolved 42) 20000)
        (lambda (v) (set! result v)))
      (uv-run (uv-default-loop) 'default)
      (assert-equal 42 result
                    "async-timeout should resolve and cancel timer so loop exits")))

  ;; ---- C1: 中文文件内容 UTF-8 往返 ----
  (test "utf8-file-content-roundtrip"
    (let* ([loop (uv-loop-init)]
           [got-error #f])
      (uv-fs-mkdir loop test-dir (lambda (r err) (when err (set! got-error err))))
      (uv-run loop 'default)
      (let ([test-file (string-append test-dir "/内容.txt")]
            [content "你好，世界！🌏 chez-async"]
            [fd #f])
        ;; 写入
        (uv-fs-open loop test-file
          (bitwise-ior O_WRONLY O_CREAT O_TRUNC) #o644
          (lambda (r err) (if err (set! got-error err) (set! fd r))))
        (uv-run loop 'default)
        (assert-false got-error "open-write should not error")
        (uv-fs-write loop fd content
          (lambda (r err) (when err (set! got-error err))))
        (uv-run loop 'default)
        (uv-fs-close loop fd (lambda (r err) (when err (set! got-error err))))
        (uv-run loop 'default)
        ;; 读回
        (set! fd #f)
        (uv-fs-open loop test-file O_RDONLY 0
          (lambda (r err) (if err (set! got-error err) (set! fd r))))
        (uv-run loop 'default)
        (let ([buffer (make-bytevector 200)]
              [nread #f])
          (uv-fs-read loop fd buffer
            (lambda (r err) (if err (set! got-error err) (set! nread r))))
          (uv-run loop 'default)
          (assert-false got-error "read should not error")
          (let ([read-str (utf8->string
                            (let ([b (make-bytevector nread)])
                              (bytevector-copy! buffer 0 b 0 nread) b))])
            (assert-equal content read-str "UTF-8 content should round-trip intact")))
        (uv-fs-close loop fd (lambda (r err) (when err (set! got-error err))))
        (uv-run loop 'default))
      (uv-loop-close loop)))

  ;; ---- C1: 中文文件名经 scandir 往返（dirent-name UTF-8 解码）----
  (test "utf8-filename-via-scandir-roundtrip"
    (let* ([loop (uv-loop-init)]
           [got-error #f]
           [names '()])
      (uv-fs-scandir loop test-dir
        (lambda (entries err)
          (if err
              (set! got-error err)
              (set! names (map dirent-name entries)))))
      (uv-run loop 'default)
      (assert-false got-error "scandir should not error")
      (assert-true (member "内容.txt" names)
                   "Chinese filename should decode correctly from scandir")
      (uv-loop-close loop)))

  ;; ---- C3: 空数据 UDP 发送不再触发 (foreign-alloc 0) ----
  (test "empty-udp-datagram-send-recv"
    (let* ([loop (uv-loop-init)]
           [server (uv-udp-init loop)]
           [client (uv-udp-init loop)]
           [server-port 0]
           [recv-len #f]
           [send-error 'unset])
      (uv-udp-bind server "127.0.0.1" 0)
      (set! server-port (cdr (uv-udp-getsockname server)))
      (uv-udp-recv-start! server
        (lambda (udp data-or-error sender-addr flags)
          (when (bytevector? data-or-error)
            (set! recv-len (bytevector-length data-or-error))
            (uv-udp-recv-stop! udp)
            (uv-handle-close! udp))))
      ;; 发送空 bytevector（触发 make-uv-buf 的 (max len 1) 路径）
      (uv-udp-send! client (make-bytevector 0) "127.0.0.1" server-port
        (lambda (err)
          (set! send-error err)
          (uv-handle-close! client)))
      (uv-run loop 'default)
      (assert-false send-error "empty datagram send should not error")
      (assert-equal 0 recv-len "should receive a 0-length datagram")
      (uv-loop-close loop)))

  ;; ---- B3: 用户回调抛异常时进程句柄仍被关闭，loop 能退出 ----
  ;; 若 exit 回调抛异常跳过 uv-handle-close!，句柄不关，loop 永久挂起
  ;; → 测试套件超时。修复后 guard 保证关闭，loop 正常退出。
  (test "process-exit-callback-exception-still-closes-handle"
    (let* ([loop (uv-loop-init)]
           [reached-callback #f])
      (uv-spawn loop "/bin/echo" '("hi")
        (lambda (process status signal)
          (set! reached-callback #t)
          ;; 故意抛异常：foreign-callable 外层 guard 会捕获并打印 stderr，
          ;; 我们新增的内层 guard 应先关闭句柄再 re-raise
          (error 'test "intentional exception in exit callback")))
      (uv-run loop 'default)  ; 若句柄未关闭这里会挂起
      (assert-true reached-callback "exit callback should have run")
      (uv-loop-close loop)))

  )

(cleanup-test-dir)
(run-tests)
