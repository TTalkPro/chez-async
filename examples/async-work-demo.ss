#!/usr/bin/env scheme-script
;;; examples/async-work-demo.ss - Async work 示例

(import (chezscheme)
        (chez-async))

(printf "=== chez-async: Async Work Demo ===~n~n")

;; ========================================
;; 示例 1: 简单的 CPU 密集型任务
;; ========================================

(printf "=== Example 1: CPU-intensive task (Fibonacci) ===~n")

;; CPU 密集型任务：计算斐波那契数
(define (fib n)
  (if (<= n 1)
      n
      (+ (fib (- n 1)) (fib (- n 2)))))

(define loop1 (uv-loop-init))

(printf "Computing fib(35) in background thread...~n")
(async-work loop1
  (lambda ()
    (printf "[Worker] Computing fib(35)...~n")
    (fib 35))
  (lambda (result)
    (printf "[Main] Result: ~a~n" result)
    (uv-stop loop1)))

(printf "Event loop running (non-blocking)...~n")
(uv-run loop1 'default)
(uv-loop-close loop1)

(printf "~n")

;; ========================================
;; 示例 2: 并行任务
;; ========================================

(printf "=== Example 2: Parallel tasks ===~n")

(define loop2 (uv-loop-init))
(define completed 0)

;; 提交 5 个并行任务
(printf "Submitting 5 parallel fibonacci tasks...~n")
(let task-loop ([i 30])
  (when (<= i 34)
    (async-work loop2
      (lambda ()
        (let ([n i])
          (printf "[Worker] Computing fib(~a)...~n" n)
          (cons n (fib n))))
      (lambda (result)
        (printf "[Main] fib(~a) = ~a~n" (car result) (cdr result))
        (set! completed (+ completed 1))
        (when (= completed 5)
          (printf "[Main] All 5 tasks completed!~n")
          (uv-stop loop2))))
    (task-loop (+ i 1))))

(uv-run loop2 'default)
(uv-loop-close loop2)

(printf "~n")

;; ========================================
;; 示例 3: 错误处理
;; ========================================

(printf "=== Example 3: Error handling ===~n")

(define loop3 (uv-loop-init))
(define tasks-done 0)

(define (check-done)
  (set! tasks-done (+ tasks-done 1))
  (when (= tasks-done 2)
    (uv-stop loop3)))

;; 成功的任务
(async-work/error loop3
  (lambda ()
    (printf "[Worker] Success task running...~n")
    (+ 1 2 3))
  (lambda (result)
    (printf "[Main] Success: result = ~a~n" result)
    (check-done))
  (lambda (error)
    (printf "[Main] Error (shouldn't happen): ~a~n" error)
    (check-done)))

;; 失败的任务
(async-work/error loop3
  (lambda ()
    (printf "[Worker] Error task running...~n")
    (error 'worker-task "intentional error"))
  (lambda (result)
    (printf "[Main] Success (shouldn't happen): ~a~n" result)
    (check-done))
  (lambda (error)
    (printf "[Main] Caught error: ~a~n"
            (if (condition? error)
                (condition-message error)
                error))
    (check-done)))

(uv-run loop3 'default)
(uv-loop-close loop3)

(printf "~n")

;; ========================================
;; 示例 4: 模拟耗时 I/O
;; ========================================

(printf "=== Example 4: Simulated slow I/O ===~n")

(define loop4 (uv-loop-init))

(printf "Simulating slow I/O operation...~n")
(async-work loop4
  (lambda ()
    (printf "[Worker] Starting slow operation...~n")
    (sleep (make-time 'time-duration 0 2)) ; sleep 2 seconds
    (printf "[Worker] Operation complete!~n")
    "I/O result")
  (lambda (result)
    (printf "[Main] Received: ~a~n" result)
    (uv-stop loop4)))

(printf "Main thread continues (event loop will handle result)~n")
(uv-run loop4 'default)
(uv-loop-close loop4)

(printf "~n")

(printf "=== All examples completed! ===~n")
