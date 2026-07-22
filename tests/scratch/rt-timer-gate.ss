;;; rt-timer-gate.ss — S0 原型闸门:证明「移植 skiff 运行时」整条工具链成立。
;;;
;;; 验证:
;;;   ① Chez 加载 C++ .so,任意线程 rt_timer → rt_await 端到端拿到结果
;;;   ② rt_await 声明 __collect_safe:某线程阻塞 await 时,别的线程能照常 GC
;;;      (对齐 R1;区别是阻塞点从 uv_run 移到 C++ 运行时的 cv)
;;;   ③ CompletionQueue 批量收割:N 个 timer 汇入一个 cq,cq_wait 收 N 次不重不漏
;;;
;;; 运行:LD_LIBRARY_PATH=native/build scheme --script tests/scratch/rt-timer-gate.ss

(import (chezscheme))

;; 加载 C++ 运行时 .so（chez-async 宿主模型:Chez 当宿主,load 独立 .so）
(load-shared-object "libchez-async-rt.so")

;; --- C ABI 绑定（对齐 skiff/task.ss 的形状）---
(define rt-start (foreign-procedure "rt_runtime_start" () void))
(define rt-stop  (foreign-procedure "rt_runtime_stop" () void))
(define rt-timer (foreign-procedure "rt_timer" (unsigned-64 uptr) uptr))
;; 阻塞调用:__collect_safe → await 期间线程 deactivate,别的线程 GC 不被卡
(define rt-await (foreign-procedure __collect_safe "rt_await" (uptr) integer-64))
(define rt-task-result (foreign-procedure "rt_task_result" (uptr) integer-64))
(define rt-task-free (foreign-procedure "rt_task_free" (uptr) void))
(define rt-cq-create (foreign-procedure "rt_cq_create" () uptr))
(define rt-cq-free   (foreign-procedure "rt_cq_free" (uptr) void))
(define rt-cq-wait   (foreign-procedure __collect_safe "rt_cq_wait" (uptr) uptr))
(define rt-cq-try-pop (foreign-procedure "rt_cq_try_pop" (uptr) uptr))

(define fail-count 0)
(define (check name ok?)
  (printf "  ~a ~a~n" (if ok? "✓" "✗") name)
  (unless ok? (set! fail-count (+ fail-count 1))))

(printf "S0 原型闸门:移植 skiff 运行时工具链验证…~n")
(rt-start)

;; ========================================================================
;; ① 端到端:提交 timer,阻塞 await 取回结果
;; ========================================================================
(let* ([t0 (real-time)]
       [task (rt-timer 60 0)]          ; 60ms 单次定时器,cq=0(逐 task await)
       [r (rt-await task)]
       [elapsed (- (real-time) t0)])
  (rt-task-free task)
  (check "端到端 timer→await 返回 0" (= r 0))
  (printf "    (定时器 60ms,await 耗时 ~ams)~n" elapsed)
  (check "await 确实等到了定时器(≥50ms)" (>= elapsed 50)))

;; ========================================================================
;; ② __collect_safe:一个线程阻塞在 rt_await(300ms 定时器)时,主线程能 GC
;;    非 collect_safe 会抛「cannot collect when multiple threads are active」
;;    (R1 已证);collect_safe 则主线程 GC 应快速完成、远小于 300ms
;; ========================================================================
(printf "  ② __collect_safe await 期间别的线程可 GC …~n")
(let ([done #f] [dm (make-mutex)] [dc (make-condition)])
  (fork-thread
    (lambda ()
      (let ([task (rt-timer 300 0)])   ; 深睡 300ms
        (rt-await task)                ; __collect_safe:deactivate
        (rt-task-free task))
      (with-mutex dm (set! done #t) (condition-signal dc))))
  ;; 给那个线程时间进入 await
  (let spin ([i 0]) (when (< i 200000) (spin (+ i 1))))
  (let ([gc-start (real-time)])
    (let gc ([i 0])
      (when (< i 5000)
        (make-vector 512 i)
        (when (= 0 (modulo i 50)) (collect))
        (gc (+ i 1))))
    (let ([gc-elapsed (- (real-time) gc-start)])
      (printf "    主线程重 GC 耗时 ~ams(定时器 300ms)~n" gc-elapsed)
      (check "GC 未被阻塞的 await 线程卡住(<250ms)" (< gc-elapsed 250))))
  (with-mutex dm (let w () (unless done (condition-wait dc dm) (w)))))

;; ========================================================================
;; ③ CompletionQueue 批量收割:N 个 timer 汇入一个 cq,收 N 次不重不漏
;; ========================================================================
(printf "  ③ CompletionQueue 批量收割 …~n")
(let ([cq (rt-cq-create)]
      [n 15])
  ;; 提交 N 个错开完成时间的定时器,全路由到 cq
  (let loop ([i 0])
    (when (< i n)
      (rt-timer (+ 10 (* (modulo i 5) 8)) cq)   ; 10..42ms
      (loop (+ i 1))))
  ;; 收割 N 次
  (let reap ([k 0] [results '()])
    (if (= k n)
        (begin
          (check "cq 收割到 N 个 task" (= (length results) n))
          (check "每个 task 结果都是 0(timer)" (for-all (lambda (r) (= r 0)) results))
          ;; 收完应无残留
          (check "收割 N 个后 cq 空" (= 0 (rt-cq-try-pop cq))))
        (let ([task (rt-cq-wait cq)])
          (let ([r (rt-task-result task)])
            (rt-task-free task)
            (reap (+ k 1) (cons r results))))))
  (rt-cq-free cq))

(rt-stop)

(if (= fail-count 0)
    (begin (printf "~n✅ S0 闸门通过 —— 移植 skiff 运行时的工具链成立,可继续 S1。~n") (exit 0))
    (begin (printf "~n❌ ~a 项失败。~n" fail-count) (exit 1)))
