;;; high-level/task.ss - Task / CompletionQueue 层（skiff Task/CompletionQueue 同构）
;;;
;;; 在 high-level/runtime 之上的一层 API 皮，把「提交 + 完成同步」固化成显式的
;;; task 记录，并提供 completion-queue 批量收割——与 skiff 的 C++ Task /
;;; CompletionQueue 字段级对应，未来若换成 skiff 的 C++ runtime `.so`，
;;; 上层代码可平移。
;;;
;;; 对应关系（skiff src/runtime/task.hpp）：
;;;   task 记录（id/op/cell/runtime/cq）      ≈ struct Task
;;;   task-await / task-poll                  ≈ Task::Wait / done_ 查询
;;;   完成钩子 settle + cq-post!              ≈ Task::Complete → cq->Post
;;;   completion-queue                        ≈ class CompletionQueue
;;;   cq-wait-one / cq-try-pop                ≈ WaitOne / TryPop
;;;
;;; 与 skiff 的简化：不需要引用计数保 cq 生命周期、不需要 skiff_task_free /
;;; pinned buffer——Scheme GC 管理生命周期，结果值在堆上无需手工释放。

(library (chez-async high-level task)
  (export
    task-submit!
    task?
    task-id
    task-op
    task-runtime
    task-await
    task-poll
    task-cancel!            ; 请求取消（F3 语义：reject 包装，不中止底层 libuv）
    task-cancelled?
    task-current-token      ; 参数：在 task thunk 内获取本 task 的 cancel-token
    make-completion-queue
    completion-queue?
    cq-wait-one
    cq-try-pop)
  (import (chezscheme)
          (chez-async high-level runtime)
          (chez-async high-level cancellation)
          (chez-async internal thread-queue))

  ;; ========================================
  ;; task id 生成器（闭包封装的全局计数器）
  ;; ========================================

  (define next-task-id!
    (let ([counter 0]
          [m (make-mutex)])
      (lambda ()
        (with-mutex m
          (let ([id counter]) (set! counter (+ counter 1)) id)))))

  ;; ========================================
  ;; task 记录
  ;; ========================================

  (define-record-type (task %make-task task?)
    (fields
      (immutable id)
      (immutable op)          ; 操作描述符号（'compute / 'fs-read / ...）
      (immutable cell)        ; result-cell（完成同步）
      (immutable runtime)     ; 所属 runtime
      (immutable cq)          ; 可选 completion-queue（或 #f）
      (immutable cancel-src)))  ; 每 task 一个 cancel-source（F3）

  ;; 参数：task thunk 执行期间绑定为本 task 的 cancel-token，
  ;; 供 thunk 内 (await (async-cancellable (task-current-token) p)) 使用。
  (define task-current-token (make-parameter #f))

  ;; ========================================
  ;; completion-queue
  ;; ========================================

  (define-record-type (completion-queue %make-cq completion-queue?)
    (fields (immutable q)))   ; 内部 thread-queue（元素为已完成的 task）

  (define (make-completion-queue) (%make-cq (make-thread-queue)))

  (define (cq-post! cq task)
    "runtime 线程：把一个已完成的 task 投递到 cq（唤醒一个 cq-wait-one）"
    (tq-push! (completion-queue-q cq) task))

  (define (cq-wait-one cq)
    "任意线程：阻塞直到有 task 完成并投递，返回该 task。"
    (tq-blocking-pop! (completion-queue-q cq) (lambda () #t)))

  (define cq-empty-sentinel (list 'cq-empty))

  (define (cq-try-pop cq)
    "任意线程：非阻塞取一个已完成 task，无则返回 #f。"
    (let-values ([(item empty?) (tq-try-pop! (completion-queue-q cq))])
      (if empty? #f item)))

  ;; ========================================
  ;; task-submit!
  ;; ========================================

  (define (task-submit! rt thunk . opts)
    "提交一个 task 到 runtime，返回 task。thunk 在 runtime 线程作为协程执行，
     内部可 await。关键字参数：
       'op  符号  —— 操作描述（默认 'task），仅作标签
       'cq  队列  —— 完成后额外 post 到该 completion-queue"
    (let ([op (opt-ref opts 'op 'task)]
          [cq (opt-ref opts 'cq #f)])
      (let* ([cell (make-result-cell)]
             [src (make-cancel-source)]
             [token (cancel-source-token src)]
             [tk (%make-task (next-task-id!) op cell rt cq src)])
        ;; 用参数把 token 绑到 thunk 执行上下文（thunk 保持零参）
        (runtime-submit-cell! rt cell
          (lambda () (parameterize ([task-current-token token]) (thunk)))
          (and cq (lambda () (cq-post! cq tk))))
        tk)))

  (define (opt-ref opts key default)
    (let loop ([o opts])
      (cond [(null? o) default]
            [(null? (cdr o)) default]
            [(eq? (car o) key) (cadr o)]
            [else (loop (cddr o))])))

  (define (task-await tk)
    "阻塞至 task 完成，成功返回值、失败 re-raise 原异常。"
    (result-cell-await (task-cell tk)))

  (define (task-poll tk)
    "非阻塞三态：'pending / (done . value) / (failed . exn)"
    (result-cell-poll (task-cell tk)))

  (define (task-cancel! tk)
    "请求取消 task。F3 语义：只 reject 该 task 内用 async-cancellable 包装的
     await（token 变为 cancelled），不中止已在飞的底层 libuv 操作。thunk 未
     用 token 包装其 await 时，取消不产生效果。"
    (cancel-source-cancel! (task-cancel-src tk)))

  (define (task-cancelled? tk)
    (cancel-token-cancelled? (cancel-source-token (task-cancel-src tk))))

) ; end library
