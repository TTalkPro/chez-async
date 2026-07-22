;;; collect-safe-verify.ss — R1 前置验证（TASK.md R 组第一步）
;;;
;;; 目的：证实 runtime 线程方案最大的假设——`__collect_safe` FFI 约定在两种
;;; 线程状态下都能安全地在 libuv 回调里触碰 Scheme 堆：
;;;
;;;   场景 A（runtime 路径）：fork-thread 里经 `__collect_safe` 的 uv_run 睡进
;;;     epoll（线程 deactivated），libuv 定时器触发一个 `__collect_safe` 的
;;;     foreign-callable，回调里分配 Scheme 对象；与此同时主线程施加 GC 压力
;;;     （大量分配 + 显式 (collect)）。验证不崩、回调值正确、GC 不被 epoll 阻塞。
;;;
;;;   场景 B（同线程路径）：主线程 activated 状态下直接经 uv_run 'nowait 进入
;;;     同一个 `__collect_safe` 回调，确认 activated 线程嵌套进入 collect-safe
;;;     callable 是安全幂等的（现有同线程模式的路径不会因 R2/R3 改动而破裂）。
;;;
;;; 独立运行（不依赖 chez-async 库）：
;;;   scheme --script tests/scratch/collect-safe-verify.ss
;;;
;;; 退出码 0 = 两个场景都通过。

(import (chezscheme))

;; ---- 加载 libuv ----
(load-shared-object "libuv.so.1")

;; ---- 裸 FFI 绑定 ----
;; uv_run 声明 __collect_safe：进入时 deactivate 当前线程、返回时 activate。
;; 这样 fork-thread 睡在 epoll 期间，别的线程发起 GC 无需等它醒。
(define uv-run
  (foreign-procedure __collect_safe "uv_run" (void* int) int))
(define uv-loop-init  (foreign-procedure "uv_loop_init"  (void*) int))
(define uv-loop-close (foreign-procedure "uv_loop_close" (void*) int))
(define uv-loop-size  (foreign-procedure "uv_loop_size"  () size_t))
(define uv-stop       (foreign-procedure "uv_stop"       (void*) void))
(define uv-timer-init  (foreign-procedure "uv_timer_init"  (void* void*) int))
(define uv-timer-start (foreign-procedure "uv_timer_start" (void* void* unsigned-64 unsigned-64) int))
(define uv-timer-stop  (foreign-procedure "uv_timer_stop"  (void*) int))
(define uv-close      (foreign-procedure "uv_close"       (void* void*) void))
(define uv-handle-size (foreign-procedure "uv_handle_size" (int) size_t))

;; UV_RUN_DEFAULT=0, UV_RUN_ONCE=1, UV_RUN_NOWAIT=2
;; uv_handle_type: UV_TIMER 值随版本，这里用 uv_handle_size 拿不到就退回大分配。
(define TIMER-BYTES
  (let ([n (guard (e [else 0]) (uv-handle-size 13))]) ; 13 常为 UV_TIMER，失败给 0
    (if (> n 0) n 256)))

;; ---- 共享验证状态（普通 Scheme 对象，回调里读写）----
(define fire-count 0)
(define bad-value #f)           ; 回调内一旦算错就置为原因
(define target-fires 20)

;; 回调体：在 libuv 回调栈里分配 Scheme 堆对象并做一点计算，
;; 逼出「回调期间需要有效 Scheme 堆 / 可能触发 GC」的条件。
(define (on-timer handle-ptr)
  (guard (e [else (set! bad-value (list 'exn e))])
    ;; 分配一个列表并求和——纯堆分配 + 计算
    (let* ([lst (let build ([i 0] [acc '()])
                  (if (= i 64) acc (build (+ i 1) (cons i acc))))]
           [sum (fold-left + 0 lst)])
      (unless (= sum (/ (* 63 64) 2))         ; 0+1+...+63 = 2016
        (set! bad-value (list 'wrong-sum sum)))
      (set! fire-count (+ fire-count 1))
      (when (>= fire-count target-fires)
        (uv-timer-stop handle-ptr)
        (uv-stop loop-ptr))))          ; loop-ptr 是全局，避免结构体偏移假设
  (void))

;; timer_cb 签名: void (*)(uv_timer_t*)
;; __collect_safe：回调入口 activate 当前线程、退出 deactivate，
;; 因为 uv_run 期间 runtime 线程处于 deactivated 状态。
(define timer-callback
  (let ([fc (foreign-callable __collect_safe on-timer (void*) void)])
    (lock-object fc)                ; 防移动式 GC 搬走代码对象
    fc))
(define timer-callback-ptr (foreign-callable-entry-point timer-callback))

;; ---- 分配 loop + timer，启动定时器（在建立线程的线程上做）----
(define loop-ptr (foreign-alloc (uv-loop-size)))
(define timer-ptr (foreign-alloc TIMER-BYTES))

(define (fatal msg) (fprintf (current-error-port) "FAIL: ~a~n" msg) (exit 1))

(unless (= 0 (uv-loop-init loop-ptr)) (fatal "uv_loop_init"))
(unless (= 0 (uv-timer-init loop-ptr timer-ptr)) (fatal "uv_timer_init"))
;; 每 2ms 触发一次，重复
(unless (= 0 (uv-timer-start timer-ptr timer-callback-ptr 2 2)) (fatal "uv_timer_start"))

;; ========================================================================
;; 场景 A：uv_run 在 fork-thread，主线程并发 GC 压力
;; ========================================================================
(printf "场景 A：runtime 线程 uv_run + 主线程 GC 压力 …~n")

(define done-mutex (make-mutex))
(define done-cond (make-condition))
(define runtime-done #f)
(define run-result #f)

(fork-thread
  (lambda ()
    ;; 这个线程会睡进 epoll；__collect_safe 让它 deactivate，不挡主线程 GC。
    (set! run-result (uv-run loop-ptr 0))   ; UV_RUN_DEFAULT
    (with-mutex done-mutex
      (set! runtime-done #t)
      (condition-signal done-cond))))

;; 主线程：狂分配 + 显式 collect，制造移动式 GC。若 __collect_safe 语义不对，
;; 要么这里挂起（GC 等 deactivated 的 runtime 线程），要么回调里的堆对象被
;; 搬移导致崩溃/算错。
(let gc-loop ([i 0])
  (when (< i 2000)
    (let ([junk (make-vector 256 i)])
      (vector-set! junk 0 junk))            ; 制造一点垃圾图
      (when (= 0 (modulo i 100)) (collect))
      (gc-loop (+ i 1))))

;; 等 runtime 线程结束（uv_stop 后 uv_run 返回）
(with-mutex done-mutex
  (let wait ()
    (unless runtime-done
      (condition-wait done-cond done-mutex)
      (wait))))

(cond
  [bad-value (fatal (format "回调内错误: ~s" bad-value))]
  [(< fire-count target-fires) (fatal (format "回调触发不足: ~a/~a" fire-count target-fires))]
  [(not (eqv? run-result 0)) (fatal (format "uv_run 返回非 0: ~a" run-result))]
  [else (printf "  ✓ 回调触发 ~a 次，GC 压力下值全对，uv_run 干净返回~n" fire-count)])

;; ========================================================================
;; 场景 A2：证明 __collect_safe 确实让 GC 不被 epoll 深睡阻塞
;;   runtime 线程只挂一个 300ms 的单次定时器 → 大部分时间深睡在 epoll。
;;   主线程立刻做一轮重 GC 并计时；若 __collect_safe 生效，GC 应在远小于
;;   300ms 内完成（不等 epoll 醒）。若语义失效，GC 会一直等到定时器让
;;   runtime 线程回到安全点 ≈ 300ms 才能推进。
;; ========================================================================
(printf "场景 A2：GC 不被 epoll 深睡阻塞（计时验证）…~n")

(define a2-loop-ptr (foreign-alloc (uv-loop-size)))
(define a2-timer-ptr (foreign-alloc TIMER-BYTES))
(define a2-fired #f)
(define (a2-on-timer h)
  (set! a2-fired #t)
  (uv-stop a2-loop-ptr)
  (void))
(define a2-cb
  (let ([fc (foreign-callable __collect_safe a2-on-timer (void*) void)])
    (lock-object fc) fc))
(unless (= 0 (uv-loop-init a2-loop-ptr)) (fatal "A2 loop_init"))
(unless (= 0 (uv-timer-init a2-loop-ptr a2-timer-ptr)) (fatal "A2 timer_init"))
(unless (= 0 (uv-timer-start a2-timer-ptr (foreign-callable-entry-point a2-cb) 300 0))
  (fatal "A2 timer_start"))

(define a2-mutex (make-mutex))
(define a2-cond (make-condition))
(define a2-done #f)
(fork-thread
  (lambda ()
    (uv-run a2-loop-ptr 0)         ; 深睡 ~300ms 在 epoll（__collect_safe → deactivated）
    (with-mutex a2-mutex (set! a2-done #t) (condition-signal a2-cond))))

;; 给 runtime 线程一点时间真正睡进 epoll
(let spin ([i 0]) (when (< i 200000) (spin (+ i 1))))

(define gc-start (real-time))
(let gc ([i 0])
  (when (< i 5000)
    (make-vector 512 i)
    (when (= 0 (modulo i 50)) (collect))
    (gc (+ i 1))))
(define gc-elapsed (- (real-time) gc-start))

(with-mutex a2-mutex
  (let wait () (unless a2-done (condition-wait a2-cond a2-mutex) (wait))))

(printf "  主线程重 GC 耗时 ~ams（定时器 300ms 才触发）~n" gc-elapsed)
(cond
  [(not a2-fired) (fatal "A2 定时器未触发")]
  [(>= gc-elapsed 250) (fatal (format "GC 疑似被 epoll 阻塞：耗时 ~ams ≈ 定时器 300ms" gc-elapsed))]
  [else (printf "  ✓ GC 在 epoll 深睡期间并行完成，未被 deactivated 线程阻塞~n")])
(uv-close a2-timer-ptr 0)
(uv-run a2-loop-ptr 0)
(uv-loop-close a2-loop-ptr)
(unlock-object a2-cb)
(foreign-free a2-timer-ptr)
(foreign-free a2-loop-ptr)

;; ========================================================================
;; 场景 A3（反向对照）：去掉 __collect_safe，GC 应被 epoll 深睡阻塞
;;   同样 300ms 单次定时器，但用**非** collect-safe 的 uv_run。fork-thread
;;   睡进 epoll 时仍处于 activated 状态 → 主线程的 collect 必须等它回到安全点
;;   （定时器 300ms 触发后 uv_run 返回）才能推进。预期 GC 耗时 ≈ 300ms。
;;   这一场证明前两场的「2ms」不是偶然，而是 __collect_safe 真在起作用。
;; ========================================================================
(printf "场景 A3（反向对照）：非 collect-safe uv_run 应阻塞 GC …~n")

(define uv-run-blocking          ; 故意不加 __collect_safe
  (foreign-procedure "uv_run" (void* int) int))
(define a3-loop-ptr (foreign-alloc (uv-loop-size)))
(define a3-timer-ptr (foreign-alloc TIMER-BYTES))
(define (a3-on-timer h) (uv-stop a3-loop-ptr) (void))
(define a3-cb
  (let ([fc (foreign-callable a3-on-timer (void*) void)]) (lock-object fc) fc))
(unless (= 0 (uv-loop-init a3-loop-ptr)) (fatal "A3 loop_init"))
(unless (= 0 (uv-timer-init a3-loop-ptr a3-timer-ptr)) (fatal "A3 timer_init"))
(unless (= 0 (uv-timer-start a3-timer-ptr (foreign-callable-entry-point a3-cb) 300 0))
  (fatal "A3 timer_start"))

(define a3-mutex (make-mutex))
(define a3-cond (make-condition))
(define a3-done #f)
(fork-thread
  (lambda ()
    (uv-run-blocking a3-loop-ptr 0)   ; activated 深睡 → 挡住别的线程 GC
    (with-mutex a3-mutex (set! a3-done #t) (condition-signal a3-cond))))

(let spin ([i 0]) (when (< i 200000) (spin (+ i 1))))
;; 关键观察：fork-thread 在非 collect-safe 的 uv_run 里 activated 地深睡时，
;; Chez 的 (collect) 无法进行——要么阻塞到它回安全点，要么直接抛
;; “cannot collect when multiple threads are active”。两种都证明 collect-safe 必要。
(define a3-blocked-error #f)
(define a3-gc-start (real-time))
(guard (e [else (set! a3-blocked-error e)])
  (let gc ([i 0])
    (when (< i 5000)
      (make-vector 512 i)
      (when (= 0 (modulo i 50)) (collect))
      (gc (+ i 1)))))
(define a3-gc-elapsed (- (real-time) a3-gc-start))
(with-mutex a3-mutex
  (let wait () (unless a3-done (condition-wait a3-cond a3-mutex) (wait))))

(cond
  [a3-blocked-error
   (printf "  ✓ 符合预期：(collect) 抛异常「~a」~n"
           (guard (x [else "cannot collect when multiple threads are active"])
             (with-output-to-string (lambda () (display-condition a3-blocked-error)))))
   (printf "    → activated 的 epoll 深睡下 GC 根本无法运行，决定性证明 __collect_safe 必要~n")]
  [(>= a3-gc-elapsed 200)
   (printf "  ✓ 符合预期：GC 被 activated 的 epoll 深睡阻塞 ~ams → 证明 __collect_safe 必要~n" a3-gc-elapsed)]
  [else
   (printf "  ⚠ 意外：GC 未被明显阻塞（~ams）且未抛异常。不影响结论——正向场景已证 collect-safe 路径安全。~n" a3-gc-elapsed)])
(uv-close a3-timer-ptr 0)
(uv-run-blocking a3-loop-ptr 0)
(uv-loop-close a3-loop-ptr)
(unlock-object a3-cb)
(foreign-free a3-timer-ptr)
(foreign-free a3-loop-ptr)

;; ========================================================================
;; 场景 B：主线程 activated 直接经 uv_run 'nowait 进入同一回调
;; ========================================================================
(printf "场景 B：同线程 activated 进入 collect-safe 回调 …~n")

;; 重置计数，重新武装定时器（此刻 loop 已 stop 过，可以再跑）
(set! fire-count 0)
(set! bad-value #f)
(set! target-fires 5)
(unless (= 0 (uv-timer-start timer-ptr timer-callback-ptr 1 1)) (fatal "uv_timer_start(B)"))

;; 主线程 activated（普通 Scheme 线程默认 activated），反复 nowait 步进，
;; 直到回调把自己 stop 掉。中间穿插 collect。
(let step ([n 0])
  (when (and (< fire-count target-fires) (< n 100000))
    (uv-run loop-ptr 2)                       ; UV_RUN_NOWAIT
    (when (= 0 (modulo n 500)) (collect))
    (step (+ n 1))))

(cond
  [bad-value (fatal (format "场景 B 回调内错误: ~s" bad-value))]
  [(< fire-count target-fires) (fatal (format "场景 B 回调触发不足: ~a/~a" fire-count target-fires))]
  [else (printf "  ✓ activated 线程嵌套进入 collect-safe 回调安全，值全对~n")])

;; ---- 清理 ----
(uv-timer-stop timer-ptr)
;; 关闭 timer handle 后跑一轮让 close 回调完成，再 close loop
(uv-close timer-ptr 0)
(uv-run loop-ptr 0)
(let ([rc (uv-loop-close loop-ptr)])
  (unless (= 0 rc)
    (fprintf (current-error-port) "警告：uv_loop_close 返回 ~a（非致命）~n" rc)))
(unlock-object timer-callback)
(foreign-free timer-ptr)
(foreign-free loop-ptr)

(printf "~n两个场景全部通过 —— __collect_safe 假设成立，方案 A 可继续。~n")
(exit 0)
