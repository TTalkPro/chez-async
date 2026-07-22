;;; high-level/runtime.ss - 后台 runtime 线程（skiff skiff_runtime_start 同构）
;;;
;;; 把事件循环从调用线程搬到一个专属的 fork-thread「runtime 线程」，任意线程
;;; 通过线程安全的提交队列投递工作、经 mutex+condition 阻塞式取回结果。主线程
;;; 因此从 uv-run 中解放出来，可以并行做别的事，I/O 在后台推进。
;;;
;;; 与 skiff 的对应：
;;;   runtime-start!   ≈ skiff_runtime_start（fork loop 线程）
;;;   runtime-submit!  ≈ skiff_submit_task（入队 + 唤醒 loop 线程）
;;;   runtime-await    ≈ skiff_await / Task::Wait（阻塞等结果）
;;;   result-cell      ≈ Task 的 mutex+cv+done_ 完成同步
;;;
;;; 关键机制（详见 docs/runtime-thread-design.md）：
;;;   - uv_run 声明 __collect_safe（ffi/core.ss）：runtime 线程睡 epoll 时
;;;     deactivate，别的线程可独立 GC；完成回调也全部 __collect_safe。
;;;   - 提交 async 句柄 uv_unref：不把 loop 顶成「有活跃句柄」，保留 F2 死锁
;;;     检测（uv_run 返回 0 ⇒ 无法推进）语义。
;;;   - 双通道唤醒：runtime 线程在 uv_run 里 → uv_async_send 唤醒；静止阻塞在
;;;     提交队列 condition 上 → tq-push! 的 signal 唤醒。
;;;   - 提交回调只 spawn 协程、不直接执行闭包（F1 硬约束：call/cc 逃逸不能跨
;;;     C 帧）；闭包作为协程在 Scheme 栈上由 drive-loop 执行，因此可以 await。
;;;
;;; 线程归属：runtime 模式下 promise/handle/协程等一切 chez-async 对象只能在
;;; runtime 线程触碰；跨线程只允许 runtime-submit! / runtime-await。

(library (chez-async high-level runtime)
  (export
    make-runtime
    runtime?
    runtime-start!
    runtime-stop!
    runtime-running?
    runtime-loop           ; 专属 loop：提交的 I/O 须建在此 loop 上
    runtime-submit!
    runtime-submit-cell!    ; 低层：调用方提供 cell + 完成钩子（Task 层用）
    runtime-await
    runtime-poll
    runtime-on-thread?
    ;; 结果单元（供 Task 层 R11 复用）
    make-result-cell
    result-cell?
    result-cell-settle-ok!
    result-cell-settle-fail!
    result-cell-await
    result-cell-poll
    ;; 错误条件
    &runtime-error runtime-error?
    &runtime-stopped runtime-stopped-error?
    make-runtime-stopped-error)
  (import (chezscheme)
          (chez-async high-level event-loop)
          (chez-async internal scheduler)
          (chez-async internal thread-queue)
          (chez-async low-level async)
          (chez-async low-level handle-base))

  ;; ========================================
  ;; 错误条件
  ;; ========================================

  (define-condition-type &runtime-error &error
    make-runtime-error runtime-error?)

  (define-condition-type &runtime-stopped &runtime-error
    make-runtime-stopped-error* runtime-stopped-error?)

  (define (make-runtime-stopped-error)
    (make-runtime-stopped-error*))

  ;; ========================================
  ;; result-cell：跨线程完成同步（skiff Task 的 mutex+cv+done_）
  ;; ========================================

  (define-record-type (result-cell %make-result-cell result-cell?)
    (fields
      (immutable mutex)
      (immutable cond)
      (mutable done?)          ; #f 直到 settle
      (mutable ok?)            ; settle 后：#t 成功 / #f 失败
      (mutable value)))        ; 结果值或捕获的异常对象

  (define (make-result-cell)
    (%make-result-cell (make-mutex) (make-condition) #f #f #f))

  (define (result-cell-settle-ok! cell value)
    "在 runtime 线程标记成功完成并唤醒等待者"
    (with-mutex (result-cell-mutex cell)
      (unless (result-cell-done? cell)
        (result-cell-value-set! cell value)
        (result-cell-ok?-set! cell #t)
        (result-cell-done?-set! cell #t)
        (condition-broadcast (result-cell-cond cell)))))

  (define (result-cell-settle-fail! cell exn)
    "在 runtime 线程标记失败完成（保存原始异常对象）并唤醒等待者"
    (with-mutex (result-cell-mutex cell)
      (unless (result-cell-done? cell)
        (result-cell-value-set! cell exn)
        (result-cell-ok?-set! cell #f)
        (result-cell-done?-set! cell #t)
        (condition-broadcast (result-cell-cond cell)))))

  (define (result-cell-await cell)
    "任意线程：阻塞至完成，成功返回值、失败 re-raise 原始异常。
     condition-wait 是 GC 安全的阻塞点，无需 __collect_safe。"
    (with-mutex (result-cell-mutex cell)
      (let wait ()
        (unless (result-cell-done? cell)
          (condition-wait (result-cell-cond cell) (result-cell-mutex cell))
          (wait))))
    (if (result-cell-ok? cell)
        (result-cell-value cell)
        (raise (result-cell-value cell))))

  (define (result-cell-poll cell)
    "非阻塞三态：'pending / (done . value) / (failed . exn)"
    (with-mutex (result-cell-mutex cell)
      (cond
        [(not (result-cell-done? cell)) 'pending]
        [(result-cell-ok? cell) (cons 'done (result-cell-value cell))]
        [else (cons 'failed (result-cell-value cell))])))

  ;; ========================================
  ;; runtime 记录
  ;; ========================================

  (define-record-type (runtime %make-runtime runtime?)
    (fields
      (mutable loop)             ; 专属 uv-loop（start! 时创建）
      (immutable submit-queue)   ; thread-queue，元素 = (result-cell . thunk)
      (mutable async-handle)     ; unref'd 唤醒 async 句柄
      (immutable submit-mutex)   ; 守护 stopped?/drain? 与提交排他
      (mutable stopped?)         ; 置 #t 后拒绝新提交
      (mutable drain?)           ; 停机策略：#t 排干在途、#f 失败未启动项
      (immutable done-mutex)     ; join 同步
      (immutable done-cond)
      (mutable state)            ; 'created | 'running | 'stopped
      (mutable thread)))         ; runtime 线程句柄

  (define (make-runtime)
    "创建 runtime（尚未启动）"
    (%make-runtime
      #f                 ; loop
      (make-thread-queue)
      #f                 ; async-handle
      (make-mutex)       ; submit-mutex
      #f                 ; stopped?
      #t                 ; drain? 默认排干
      (make-mutex)       ; done-mutex
      (make-condition)   ; done-cond
      'created
      #f))               ; thread

  (define (runtime-running? rt)
    (eq? (runtime-state rt) 'running))

  ;; 当前线程是否就是该 runtime 的 loop 线程
  (define (runtime-on-thread? rt)
    (eq? (get-thread-id) (runtime-thread-id rt)))
  ;; 记录 runtime 线程的 id 以支持归属断言
  (define runtime-thread-ids (make-eq-hashtable))
  (define (runtime-thread-id rt) (hashtable-ref runtime-thread-ids rt #f))
  (define (set-runtime-thread-id! rt id) (hashtable-set! runtime-thread-ids rt id))

  ;; ========================================
  ;; 提交队列 → 协程
  ;; ========================================

  ;; 提交项：cell（完成同步单元）+ thunk（用户工作）+ on-complete（settle 后
  ;; 在 runtime 线程回调的钩子，或 #f）。on-complete 供 Task 层 post 到 cq。
  (define-record-type submission
    (fields (immutable cell) (immutable thunk) (immutable on-complete)))

  (define (run-on-complete sub)
    (let ([oc (submission-on-complete sub)]) (when oc (oc))))

  (define (spawn-submission! rt sub)
    "把提交项包成协程压入 runtime loop 的 runnable 队列。协程正常结束 →
     settle-ok；抛异常 → settle-fail。settle 后调用 on-complete（若有）。"
    (let ([cell (submission-cell sub)]
          [thunk (submission-thunk sub)])
      (spawn-coroutine! (runtime-loop rt)
        (lambda ()
          (guard (e [else (result-cell-settle-fail! cell e) (run-on-complete sub)])
            (let ([v (thunk)])
              (result-cell-settle-ok! cell v)
              (run-on-complete sub)))))))

  (define (fail-submission! sub exn)
    (result-cell-settle-fail! (submission-cell sub) exn)
    (run-on-complete sub))

  (define (drain-submit-queue! rt)
    "在 runtime 线程：取出全部待处理提交，spawn（或停机非 drain 时失败）。
     两处调用：async 唤醒回调（uv_run 内）、外层循环顶部。均在 runtime 线程，
     彼此无并发。"
    (let ([items (tq-pop-all! (runtime-submit-queue rt))])
      (for-each
        (lambda (item)
          (if (and (runtime-stopped? rt) (not (runtime-drain? rt)))
              (fail-submission! item (make-runtime-stopped-error))
              (spawn-submission! rt item)))
        items)))

  (define (submit-queue-empty? rt)
    (let ([sq (runtime-submit-queue rt)])
      (with-mutex (tq-mutex sq) (tq-empty? sq))))

  ;; ========================================
  ;; runtime 线程主体
  ;; ========================================

  (define (runtime-thread-body rt)
    ;; 外层循环：drain 提交 → drive-loop 到静止 → 停机则收尾，否则阻塞等新提交
    (let outer ()
      (drain-submit-queue! rt)
      (drive-loop (runtime-loop rt) 'default)   ; 协程 + 句柄跑到无活跃工作
      (cond
        [(and (runtime-stopped? rt) (submit-queue-empty? rt))
         (finish-shutdown! rt)]
        [(runtime-stopped? rt)
         ;; 停机但队列在 drive 期间又进了项（drain 语义）：回去处理
         (outer)]
        [else
         ;; 未停机且静止：阻塞等下一个提交或停机信号
         (let ([item (tq-blocking-pop! (runtime-submit-queue rt)
                                       (lambda () (not (runtime-stopped? rt))))])
           (when item (spawn-submission! rt item)))
         (outer)])))

  (define (finish-shutdown! rt)
    "runtime 线程：关闭 async 句柄、flush close 回调、关闭 loop、signal join。"
    (let ([ah (runtime-async-handle rt)])
      (when ah
        (uv-handle-close! ah)
        (runtime-async-handle-set! rt #f)))
    ;; 跑几轮 nowait 处理 close 回调
    (let flush ([n 0])
      (when (and (< n 16) (not (= 0 (uv-run (runtime-loop rt) 'nowait))))
        (flush (+ n 1))))
    (guard (e [else (fprintf (current-error-port)
                             "runtime: uv-loop-close 警告: ~a~n" e)])
      (uv-loop-close (runtime-loop rt)))
    (with-mutex (runtime-done-mutex rt)
      (runtime-state-set! rt 'stopped)
      (condition-broadcast (runtime-done-cond rt))))

  ;; ========================================
  ;; 生命周期 API
  ;; ========================================

  (define (runtime-start! rt)
    "启动 runtime：建专属 loop + unref'd 唤醒 async 句柄 + fork runtime 线程。"
    (unless (threaded?)
      (assertion-violationf 'runtime-start!
        "runtime 需要线程版 Chez（__collect_safe / fork-thread）"))
    (when (eq? (runtime-state rt) 'running)
      (assertion-violationf 'runtime-start! "runtime 已在运行"))
    (let ([loop (uv-loop-init)])
      (runtime-loop-set! rt loop)
      ;; 唤醒回调：drain 提交队列并 spawn（仅入队，安全在回调内做）
      (let ([ah (uv-async-init loop (lambda (wrapper) (drain-submit-queue! rt)))])
        (uv-handle-unref! ah)          ; 关键：不计入活跃句柄，保留 F2 语义
        (runtime-async-handle-set! rt ah))
      (runtime-stopped?-set! rt #f)
      (runtime-state-set! rt 'running)
      ;; fork runtime 线程
      (let ([started (make-condition)]
            [start-mutex (make-mutex)]
            [ready #f])
        (runtime-thread-set! rt
          (fork-thread
            (lambda ()
              (set-runtime-thread-id! rt (get-thread-id))
              (with-mutex start-mutex
                (set! ready #t)
                (condition-signal started))
              (runtime-thread-body rt))))
        ;; 等线程记录好自己的 id，保证 runtime-on-thread? 可用
        (with-mutex start-mutex
          (let wait () (unless ready (condition-wait started start-mutex) (wait)))))
      rt))

  (define (runtime-submit-cell! rt cell thunk on-complete)
    "低层提交：调用方提供 cell 与 on-complete 钩子（settle 后在 runtime 线程
     调用，用于 Task 层 post 到 completion-queue）。返回 cell。"
    (with-mutex (runtime-submit-mutex rt)
      (when (runtime-stopped? rt)
        (raise (make-runtime-stopped-error)))
      ;; 锁内 push，保证与 stop 的 stopped? 置位串行化，杜绝孤儿 cell
      (tq-push! (runtime-submit-queue rt)
                (make-submission cell thunk on-complete)))
    ;; 双通道唤醒之 uv_run 通道（tq-push! 已 signal condition 通道）
    (let ([ah (runtime-async-handle rt)])
      (when ah
        (guard (e [else (void)])   ; 停机竞态下句柄可能已关，忽略
          (uv-async-send! ah))))
    cell)

  (define (runtime-submit! rt thunk)
    "任意线程：提交一个 thunk 到 runtime，返回 result-cell。thunk 在 runtime
     线程作为协程执行，内部可以 await promise。"
    (runtime-submit-cell! rt (make-result-cell) thunk #f))

  (define (runtime-await cell)
    "任意线程：阻塞至提交完成，成功返回值、失败 re-raise 原异常。"
    (result-cell-await cell))

  (define (runtime-poll cell)
    "非阻塞三态查询：'pending / (done . value) / (failed . exn)"
    (result-cell-poll cell))

  (define (runtime-stop! rt . opts)
    "停止 runtime 并 join。关键字 drain?：
       #t（默认）—— 排干队列中未启动的提交（spawn 并等其完成）后再退；
       #f        —— 未启动的提交以 &runtime-stopped 失败；已启动的协程仍跑完。
     两种都等已 spawn 的协程跑完（安全，不中途丢弃在途 libuv 操作）。"
    (let ([drain? (let loop ([o opts])
                    (cond [(null? o) #t]
                          [(eq? (car o) 'drain?) (cadr o)]
                          [else (loop (cdr o))]))])
      (with-mutex (runtime-submit-mutex rt)
        (unless (runtime-stopped? rt)
          (runtime-drain?-set! rt drain?)
          (runtime-stopped?-set! rt #t)))
      ;; 唤醒 runtime 线程（两条通道都戳一下）
      (let ([ah (runtime-async-handle rt)])
        (when ah (guard (e [else (void)]) (uv-async-send! ah))))
      (let ([sq (runtime-submit-queue rt)])
        (with-mutex (tq-mutex sq) (condition-broadcast (tq-condition sq))))
      ;; join：等 runtime 线程收尾
      (with-mutex (runtime-done-mutex rt)
        (let wait ()
          (unless (eq? (runtime-state rt) 'stopped)
            (condition-wait (runtime-done-cond rt) (runtime-done-mutex rt))
            (wait))))
      (void)))

) ; end library
