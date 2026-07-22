#!/usr/bin/env scheme-script
;;; examples/runtime-demo.ss - 后台 runtime 线程演示
;;;
;;; 展示 skiff 式的 TASK-based 用法：事件循环跑在后台 runtime 线程，主线程
;;; 提交任务、继续做自己的事，需要结果时再阻塞等待。
;;;
;;; 运行：scheme --libdirs .:.. --program examples/runtime-demo.ss

(import (chezscheme)
        (chez-async))

(printf "=== chez-async: 后台 Runtime 线程 Demo ===~n")
(printf "libuv version: ~a~n~n" (uv-version-string))

;; 建在 runtime 自己 loop 上的可 await 定时器
(define (sleep-on rt ms)
  (let ([loop (runtime-loop rt)])
    (make-promise loop
      (lambda (resolve reject)
        (run-after loop ms (lambda () (resolve ms)))))))

;; ========================================
;; 启动 runtime（fork 一个后台事件循环线程）
;; ========================================
(define rt (make-runtime))
(runtime-start! rt)
(printf "runtime 已在后台线程启动，主线程空闲。~n~n")

;; ========================================
;; 示例 1：提交一个同步写法的异步任务，主线程并行干活
;; ========================================
(printf "=== 示例 1：主线程与后台 I/O 并行 ===~n")
(define t0 (real-time))
(define task1
  (runtime-submit! rt
    (lambda ()
      ;; 同步写法的两段异步 sleep（在后台线程的事件循环上真实异步）
      (let ([a (await (sleep-on rt 100))]
            [b (await (sleep-on rt 100))])
        (printf "  [runtime] 两段 sleep 完成，用时约 ~ams~n" (- (real-time) t0))
        (+ a b)))))

;; 主线程此刻完全自由——算个斐波那契证明没被事件循环占用
(define (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))
(printf "  [main] runtime 跑 I/O 时，主线程算 fib(30) = ~a（耗时 ~ams）~n"
        (fib 30) (- (real-time) t0))

;; 需要结果了，阻塞等待
(printf "  [main] await 任务结果：~a~n~n" (runtime-await task1))

;; ========================================
;; 示例 2：并发提交多个任务
;; ========================================
(printf "=== 示例 2：并发提交，收集全部结果 ===~n")
(define tasks
  (map (lambda (i)
         (runtime-submit! rt
           (lambda ()
             (await (sleep-on rt (* i 20)))   ; 错开完成时间
             (* i i))))
       '(1 2 3 4 5)))
(printf "  5 个任务已提交（各睡 20-100ms）；主线程等待全部完成…~n")
(printf "  结果（i²）：~a~n~n" (map runtime-await tasks))

;; ========================================
;; 示例 3：任务内异常传回主线程
;; ========================================
(printf "=== 示例 3：任务异常跨线程传播 ===~n")
(define bad-task
  (runtime-submit! rt
    (lambda ()
      (await (sleep-on rt 10))
      (error 'demo-task "故意失败" 42))))
(guard (e [(error? e)
           (printf "  [main] 捕获到后台任务的异常：~a~n~n"
                   (if (message-condition? e) (condition-message e) e))])
  (runtime-await bad-task))

;; ========================================
;; 停机（drain：等在途任务跑完）
;; ========================================
(printf "=== 停机 ===~n")
(runtime-stop! rt)
(printf "runtime 已停止，事件循环线程已 join。~n")
(printf "~n=== Demo 结束 ===~n")
