#!/usr/bin/env scheme-script
;;; examples/signal-handler.ss - 信号处理示例
;;;
;;; 这个示例展示了如何使用 chez-async 处理 POSIX 信号。
;;; 程序会监听 SIGINT (Ctrl+C) 和 SIGTERM，实现优雅关闭。
;;;
;;; 用法：
;;;   scheme --libdirs .:.. --program examples/signal-handler.ss
;;;
;;; 测试：
;;;   1. 运行程序
;;;   2. 按 Ctrl+C 或从另一个终端发送 kill -TERM <pid>
;;;   3. 观察程序优雅关闭

(import (chezscheme)
        (chez-async high-level event-loop)
        (chez-async low-level signal)
        (chez-async low-level timer)
        (chez-async low-level handle-base))

;; ========================================
;; 配置
;; ========================================

(define *shutdown-requested* #f)
(define *signal-handlers* '())
(define *work-timer* #f)
(define *heartbeat-count* 0)

;; ========================================
;; 信号处理
;; ========================================

(define (handle-shutdown-signal signal signum)
  "处理关闭信号"
  (printf "~n[Signal] Received ~a (~a)~n" (signum->name signum) signum)

  (if *shutdown-requested*
      (begin
        (printf "[Signal] Shutdown already in progress, forcing exit...~n")
        (exit 1))
      (begin
        (set! *shutdown-requested* #t)
        (printf "[Signal] Starting graceful shutdown...~n")

        ;; 停止工作定时器
        (when *work-timer*
          (printf "[Cleanup] Stopping work timer...~n")
          (uv-timer-stop! *work-timer*)
          (uv-handle-close! *work-timer*))

        ;; 停止所有信号处理器
        (for-each
          (lambda (sig)
            (printf "[Cleanup] Stopping signal handler for ~a...~n"
                    (handle-type sig))
            (uv-signal-stop! sig)
            (uv-handle-close! sig))
          *signal-handlers*)

        (printf "[Signal] Cleanup complete, exiting...~n"))))

(define (setup-signal-handlers loop)
  "设置信号处理器"
  ;; 处理 SIGINT (Ctrl+C)
  (let ([sigint-handler (uv-signal-init loop)])
    (uv-signal-start! sigint-handler SIGINT handle-shutdown-signal)
    (set! *signal-handlers* (cons sigint-handler *signal-handlers*))
    (printf "[Signal] Registered handler for SIGINT (Ctrl+C)~n"))

  ;; 处理 SIGTERM
  (let ([sigterm-handler (uv-signal-init loop)])
    (uv-signal-start! sigterm-handler SIGTERM handle-shutdown-signal)
    (set! *signal-handlers* (cons sigterm-handler *signal-handlers*))
    (printf "[Signal] Registered handler for SIGTERM~n"))

  ;; 处理 SIGHUP (可选：热重载)
  (let ([sighup-handler (uv-signal-init loop)])
    (uv-signal-start! sighup-handler SIGHUP
      (lambda (sig signum)
        (printf "~n[Signal] Received SIGHUP - Reload configuration (simulated)~n")
        (printf "[Config] Configuration reloaded successfully~n")))
    (set! *signal-handlers* (cons sighup-handler *signal-handlers*))
    (printf "[Signal] Registered handler for SIGHUP (reload)~n")))

;; ========================================
;; 模拟工作
;; ========================================

(define (start-work-simulation loop)
  "启动模拟工作（定期心跳）"
  (let ([timer (uv-timer-init loop)])
    (set! *work-timer* timer)
    (uv-timer-start! timer 0 2000  ; 每 2 秒一次
      (lambda (t)
        (set! *heartbeat-count* (+ *heartbeat-count* 1))
        (printf "[Heartbeat #~a] Application is running...~n"
                *heartbeat-count*)))
    (printf "[Work] Started heartbeat timer (every 2 seconds)~n")))

;; ========================================
;; 主程序
;; ========================================

(define (main)
  (printf "=== chez-async: Signal Handler Demo ===~n")
  (printf "libuv version: ~a~n~n" (uv-version-string))

  (let ([loop (uv-loop-init)]
        [pid ((foreign-procedure "getpid" () int))])

    (printf "Process ID: ~a~n~n" pid)

    ;; 设置信号处理器
    (setup-signal-handlers loop)

    ;; 启动模拟工作
    (start-work-simulation loop)

    (printf "~nApplication started. Press Ctrl+C to shutdown gracefully.~n")
    (printf "Or run: kill -TERM ~a~n" pid)
    (printf "Or run: kill -HUP ~a (to simulate reload)~n~n" pid)

    ;; 运行事件循环
    (uv-run loop 'default)

    ;; 清理
    (uv-loop-close loop))

  (printf "~nApplication terminated normally.~n")
  (printf "Total heartbeats: ~a~n" *heartbeat-count*))

;; 运行
(main)
