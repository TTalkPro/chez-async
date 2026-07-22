;;; high-level/io-async.ss - 基于 C++ 运行时 cq 的协程调度器（对齐 skiff async）
;;;
;;; 让 io-fs/io-net/io-proc 那套**阻塞写法**的 API 在 async 块里自动变成协程挂起
;;; （不阻塞 OS 线程）。机制 = skiff 的 cq-as-scheduler-substrate：
;;;
;;;   - 重绑 io-runtime 的 await-hook：协程 await 一个 task 时，挂 task→协程 到
;;;     pending 表并逃逸回调度器（不阻塞线程）；current-cq 重绑为调度器的 cq，
;;;     故所有 io-* 提交都路由到它。
;;;   - 调度器单线程 fiber 循环：有可运行协程就跑；否则 completion-queue-wait
;;;     阻塞在调度器 cq 上，收割完成的 task → resume 对应协程（传回 task-result）。
;;;   - 续延纪律照搬 internal/scheduler（已被 27 测试验证）：每轮 call/cc 重捕
;;;     scheduler-k，协程经当前 scheduler-k 逃逸；完成则正常返回回调度循环。
;;;     call/cc 逃逸严格在 Scheme 栈上（cq-wait 是普通 foreign call，返回后才
;;;     invoke 续延，不跨 C 栈）。
;;;
;;; 前置：调用方已 io-runtime-start!（运行时是全局单例，不随 async-run 起停）。

(library (chez-async high-level io-async)
  (export
    io-run-async          ; (thunk) → 跑一个根协程直到完成，返回其值（异常传播）
    io-spawn-async        ; (thunk) → 在当前调度器内新起一个并发协程
    in-io-async?)         ; 当前是否在 io-async 调度上下文中
  (import (chezscheme)
          (chez-async internal io-runtime))

  ;; ========================================
  ;; 协程记录 + 简单 FIFO
  ;; ========================================

  (define-record-type coro
    (fields (immutable id) (mutable k) (mutable state) (mutable result) (mutable error)))
  ;; state: 'new | 'running | 'suspended | 'done | 'failed

  (define next-id!
    (let ([n 0]) (lambda () (set! n (+ n 1)) n)))

  ;; 双列表 FIFO（均摊 O(1)）
  (define-record-type fifo (fields (mutable out) (mutable in)))
  (define (make-empty-fifo) (make-fifo '() '()))
  (define (fifo-empty? q) (and (null? (fifo-out q)) (null? (fifo-in q))))
  (define (fifo-push! q x) (fifo-in-set! q (cons x (fifo-in q))))
  (define (fifo-pop! q)
    (when (null? (fifo-out q))
      (fifo-out-set! q (reverse (fifo-in q)))
      (fifo-in-set! q '()))
    (let ([x (car (fifo-out q))]) (fifo-out-set! q (cdr (fifo-out q))) x))

  ;; ========================================
  ;; 调度器状态（每 io-run-async 一份）
  ;; ========================================

  (define-record-type sched
    (fields (immutable cq) (immutable pending) (immutable runnable)
            (mutable scheduler-k)))
  ;; pending: eq-hashtable  task-handle(uptr) → coro
  ;; runnable: fifo of coro

  (define current-sched (make-thread-parameter #f))
  (define current-coro (make-thread-parameter #f))

  (define (in-io-async?) (and (current-sched) #t))

  ;; ========================================
  ;; await-hook：协程 await 一个 task → 挂起、逃逸调度器
  ;; ========================================
  ;;
  ;; 由 io-runtime 的 task-await 调用（(await-hook t)）。捕获当前协程续延，
  ;; 挂 task→协程 到 pending，跳回 scheduler-k。resume 时以 task-result 返回。

  (define (suspend-for-task! t)
    (let ([s (current-sched)]
          [c (current-coro)])
      (call/cc
        (lambda (k)
          (coro-k-set! c k)
          (coro-state-set! c 'suspended)
          (hashtable-set! (sched-pending s) t c)
          ((sched-scheduler-k s) (void))))))   ; 逃逸回调度循环

  ;; ========================================
  ;; 运行一个协程（首次或 resume）
  ;; ========================================

  (define (run-coro! s c)
    (parameterize ([current-coro c] [current-sched s])
      (let ([k (coro-k c)] [first? (eq? (coro-state c) 'new)])
        (coro-k-set! c #f)
        (coro-state-set! c 'running)
        (if first? (k #f) (k (coro-result c))))))

  ;; 包装用户 thunk：完成置 done/result，异常置 failed/error（不杀调度器）。
  (define (wrap-coro c thunk root?)
    (lambda (_)
      (guard (e [else
                 (coro-state-set! c 'failed)
                 (coro-error-set! c e)
                 (unless root?
                   (fprintf (current-error-port)
                            "[io-async coro ~a] 未捕获异常: ~a~n" (coro-id c) e))])
        (let ([v (thunk)])
          (coro-state-set! c 'done)
          (coro-result-set! c v)))))

  ;; ========================================
  ;; io-spawn-async：当前调度器内新起并发协程
  ;; ========================================

  (define (io-spawn-async thunk)
    (let ([s (current-sched)])
      (unless s (error 'io-spawn-async "not in an io-async context"))
      (let ([c (make-coro (next-id!) #f 'new #f #f)])
        (coro-k-set! c (wrap-coro c thunk #f))
        (fifo-push! (sched-runnable s) c)
        c)))

  ;; ========================================
  ;; io-run-async：跑根协程直到完成
  ;; ========================================

  (define (io-run-async root-thunk)
    (let ([s (make-sched (make-completion-queue) (make-eq-hashtable)
                         (make-empty-fifo) #f)])
      (define root (make-coro (next-id!) #f 'new #f #f))
      (coro-k-set! root (wrap-coro root root-thunk #t))
      (fifo-push! (sched-runnable s) root)
      ;; 在整个调度期间：await-hook 挂起、current-cq 路由到本调度器 cq
      (parameterize ([current-cq (sched-cq s)]
                     [await-hook suspend-for-task!]
                     [current-sched s])
        (let loop ()
          ;; 每轮重捕 scheduler-k：协程经它逃逸回这里
          (call/cc (lambda (k) (sched-scheduler-k-set! s k)))
          (cond
            [(not (fifo-empty? (sched-runnable s)))
             (run-coro! s (fifo-pop! (sched-runnable s)))
             (loop)]
            [(> (hashtable-size (sched-pending s)) 0)
             ;; 无可运行协程：阻塞收割一个完成的 task，resume 其协程
             (let ([t (completion-queue-wait (sched-cq s))])
               (let ([c (hashtable-ref (sched-pending s) t #f)])
                 (hashtable-delete! (sched-pending s) t)
                 (when c
                   (coro-result-set! c (task-result t))
                   (coro-state-set! c 'running)
                   (fifo-push! (sched-runnable s) c))))
             (loop)]
            [else (void)])))
      ;; 调度结束：释放 cq，返回根结果或重抛根异常
      (completion-queue-free (sched-cq s))
      (if (eq? (coro-state root) 'failed)
          (raise (coro-error root))
          (coro-result root))))

) ; end library
