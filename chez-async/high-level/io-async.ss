;;; high-level/io-async.ss - delimited-continuation async/await 调度器（移植 skiff/async.ss）
;;;
;;; 把阻塞式 task 运行时变成 Node 式「同步写法、异步执行」。一个调度器 = 一个
;;; Chez 线程跑多个协作 fiber；`await` 挂起 fiber（捕获其 delimited continuation）
;;; 交还控制给调度循环，调度循环从单个 CompletionQueue 收割完成、resume 对应 fiber。
;;;
;;; 妙处：现有 io-fs/io-net/io-proc 的阻塞操作在这里**免费**变非阻塞——它们调
;;; task-await，被调度器重绑（await-hook）为挂起而非阻塞，且用 (current-cq) 提交
;;; （调度器指向自己的队列）。同一套 fs/net/proc API 在普通线程（阻塞）与 run-async
;;; 内（挂起）都能用。
;;;
;;; 无竞态：调度器单线程，仅在静止（当前 fiber 已 park、登记好 waiter）时排队。
;;; 提前到达的完成先在队列/completed 表里等着，绝不丢失。
;;;
;;; 前置：调用方已 io-runtime-start!（运行时是全局单例，不随 run-async 起停）。
;;; 移植自 skiff src @ 93e0fd6 的 skiff/async.ss。

(library (chez-async high-level io-async)
  (export
    run-async async await await-all
    in-async? future?)
  (import (chezscheme)
          (chez-async internal io-runtime))

  ;; --- Filinski shift/reset（线程局部 metacontinuation）---

  (define meta-prompt (make-thread-parameter #f))

  (define (reset* thunk)
    (let ([saved (meta-prompt)])
      (call/cc
        (lambda (k)
          (meta-prompt (lambda (v) (meta-prompt saved) (k v)))
          (let ([result (thunk)]) ((meta-prompt) result))))))

  (define (shift* f)
    (call/cc
      (lambda (k)
        (let ([ck (lambda (v) (reset* (lambda () (k v))))])
          ((meta-prompt) (f ck))))))

  (define suspended (list 'suspended))          ; 唯一 token
  (define (run-step thunk)                       ; → (ok . v) | (err . c) | suspended
    (reset* (lambda () (guard (e [#t (cons 'err e)]) (cons 'ok (thunk))))))

  ;; --- futures ---
  ;; future 同时是 fiber 身份：resolve/fail 它即交付其代表计算的结果。

  (define-record-type future
    (fields (mutable state) (mutable waiters))   ; state: 'pending | (ok . v) | (err . c)
    (protocol (lambda (new) (lambda () (new 'pending '())))))

  ;; --- 调度器 ---

  (define-record-type scheduler
    (fields cq (mutable ready) waiters completed)
    ;; ready: 逆序 list of (future . step-producer)
    ;; waiters: task-handle → wake（await 在其完成前 park）
    ;; completed: task-handle → result（完成早于 await 注册时暂存，否则那个 await
    ;;   会永远挂起——绝不丢）
    (protocol
      (lambda (new)
        (lambda (cq) (new cq '() (make-eqv-hashtable) (make-eqv-hashtable))))))

  (define current-scheduler (make-thread-parameter #f))
  (define current-fiber (make-thread-parameter #f))

  (define (in-async?) (and (current-scheduler) #t))

  (define (enqueue-ready! sch item)
    (scheduler-ready-set! sch (cons item (scheduler-ready sch))))

  ;; 挂起当前 fiber。register! 收到一个 wake 过程：以某值调用它即把 fiber 重排为
  ;; 用该值 resume。
  (define (park! register!)
    (let ([sch (current-scheduler)] [fib (current-fiber)])
      (unless sch (error 'await "not inside run-async"))
      (shift*
        (lambda (resume-k)
          (register! (lambda (value)
                       (enqueue-ready! sch (cons fib (lambda () (resume-k value))))))
          suspended))))

  ;; await-hook：挂起在一个裸 task 句柄上；运行时把完成 post 到队列后，调度器以
  ;; task-result 唤醒。若完成已到（暂存在 completed 表），直接消费不 park。
  (define (scheduler-await t)
    (let ([sch (current-scheduler)])
      (unless sch (error 'await "not inside run-async"))
      (let ([done (hashtable-ref (scheduler-completed sch) t #f)])
        (if done
            (begin (hashtable-delete! (scheduler-completed sch) t) done)
            (park! (lambda (wake)
                     (hashtable-set! (scheduler-waiters sch) t wake)))))))

  ;; --- fiber 执行 ---

  (define (settle! f outcome)
    (future-state-set! f outcome)
    (let ([ws (future-waiters f)])
      (future-waiters-set! f '())
      (for-each (lambda (wake) (wake #f)) ws)))   ; 值忽略；awaiter 重查

  (define (handle-step fib step)
    (cond
      [(eq? step suspended) (void)]               ; 已 park
      [else (settle! fib step)]))                 ; (ok . v) / (err . c)

  (define (run-fiber! fib produce-step)
    (handle-step fib (parameterize ([current-fiber fib]) (produce-step))))

  (define (deliver-one! sch h)
    (let ([wake (hashtable-ref (scheduler-waiters sch) h #f)])
      (if wake
          (begin
            (hashtable-delete! (scheduler-waiters sch) h)
            (wake (task-result h)))               ; 排入 resume
          ;; 尚无 waiter：暂存给稍后的 scheduler-await。绝不丢（丢则那个 await 永挂）。
          (hashtable-set! (scheduler-completed sch) h (task-result h)))))

  (define (scheduler-loop sch)
    (let loop ()
      ;; 跑完当前所有 ready fiber（批内 FIFO）。
      (let ([batch (reverse (scheduler-ready sch))])
        (scheduler-ready-set! sch '())
        (for-each (lambda (item) (run-fiber! (car item) (cdr item))) batch))
      (cond
        [(pair? (scheduler-ready sch)) (loop)]     ; 上面又产生了新工作
        [(fx> (hashtable-size (scheduler-waiters sch)) 0)
         ;; 阻塞收一个完成，再排干已 post 的其余。
         (deliver-one! sch (completion-queue-wait (scheduler-cq sch)))
         (let poll ()
           (let ([h (completion-queue-try-pop (scheduler-cq sch))])
             (when h (deliver-one! sch h) (poll))))
         (loop)]
        [else (void)])))                           ; 静止：完成

  ;; --- 公共 API ---

  ;; 起一个并发 fiber，返回其结果的 future。
  (define (async thunk)
    (let ([sch (current-scheduler)])
      (unless sch (error 'async "not inside run-async"))
      (let ([f (make-future)])
        (enqueue-ready! sch (cons f (lambda () (run-step thunk))))
        f)))

  (define (await-future f)
    (let ([st (future-state f)])
      (cond
        [(eq? st 'pending)
         (park! (lambda (wake)
                  (future-waiters-set! f (cons wake (future-waiters f)))))
         (await-future f)]                         ; resume 后重查
        [(eq? (car st) 'ok) (cdr st)]
        [else (raise (cdr st))])))

  ;; 挂起至 x resolve；x 是 future 或裸 task 句柄。
  (define (await x)
    (cond
      [(future? x) (await-future x)]
      [(and (integer? x) (exact? x)) (scheduler-await x)]
      [else (error 'await "not awaitable" x)]))

  ;; await 一组 future，返回其值（它们并发运行）。
  (define (await-all fs) (map await fs))

  ;; 在当前线程新调度器里跑 root-thunk；它与其 spawn 的所有 fiber 都 settle 后
  ;; 返回其值（或重抛错误）。
  (define (run-async root-thunk)
    (when (current-scheduler) (error 'run-async "run-async cannot be nested"))
    (let ([cq (make-completion-queue)])
      (dynamic-wind
        (lambda () (void))
        (lambda ()
          (let ([sch (make-scheduler cq)])
            (parameterize ([current-scheduler sch]
                           [current-cq cq]
                           [await-hook scheduler-await])
              (let ([root (async root-thunk)])
                (scheduler-loop sch)
                (let ([st (future-state root)])
                  (cond
                    [(eq? st 'pending)
                     (error 'run-async "deadlock: root fiber never settled")]
                    [(eq? (car st) 'ok) (cdr st)]
                    [else (raise (cdr st))]))))))
        (lambda () (completion-queue-free cq)))))

) ; end library
