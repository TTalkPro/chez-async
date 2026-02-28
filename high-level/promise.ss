;;; high-level/promise.ss - Promise/Future 异步抽象
;;;
;;; 提供 Promise 风格的异步编程接口，类似于 JavaScript Promise。
;;;
;;; Promise 状态机：
;;;   pending ──resolve──→ fulfilled（不可逆）
;;;   pending ──reject───→ rejected （不可逆）
;;; 状态一旦转为 fulfilled/rejected 就不可再变更。
;;;
;;; 架构分层：
;;; - 核心实现（记录类型、promise-then、fulfill/reject）在 internal/promise-core.ss
;;;   以打破 internal/scheduler.ss 的层级违规
;;; - 本模块提供用户 API（make-promise、组合器、状态查询）
;;; - 本模块在加载时注入基于 uv-timer 的微任务调度器到 promise-core
;;;
;;; 微任务调度器注入原理：
;;; promise-core 的 schedule-microtask 是一个 parameter，默认为空操作。
;;; 本模块加载时通过 install-microtask-scheduler! 注入一个基于 run-after
;;; （0ms timer）的调度器，使 promise-then 回调在下一次事件循环迭代中异步执行。
;;;
;;; run-after 辅助函数：
;;; 封装 timer init→start→close 三步模式为单次调用，
;;; 供本模块微任务调度器和 async-combinators 的 sleep/timeout/delay 使用。
;;;
;;; 基本用法：
;;;   (define p (make-promise
;;;               (lambda (resolve reject)
;;;                 (uv-timer-start! timer 1000 0
;;;                   (lambda (t) (resolve "done!"))))))
;;;   (promise-then p (lambda (value) (display value)))
;;;   (promise-catch p (lambda (error) (display error)))

(library (chez-async high-level promise)
  (export
    ;; Promise 类型
    make-promise
    promise?
    promise-resolved
    promise-rejected

    ;; 链式操作（从 promise-core 重新导出）
    promise-then
    promise-catch
    promise-finally

    ;; 组合器
    promise-all
    promise-race
    promise-any
    promise-all-settled

    ;; 状态查询
    promise-state
    promise-pending?
    promise-fulfilled?
    promise-rejected?

    ;; 辅助
    promise-wait

    ;; Timer 辅助
    run-after
    )
  (import (chezscheme)
          (chez-async high-level event-loop)
          (chez-async low-level timer)
          (chez-async low-level idle)
          (chez-async low-level handle-base)
          (chez-async internal promise-core))

  ;; ========================================
  ;; 类型谓词别名
  ;; ========================================

  (define promise? promise-record?)

  ;; ========================================
  ;; Promise 创建
  ;; ========================================

  (define make-promise
    (case-lambda
      [(executor)
       ;; 使用默认事件循环
       (make-promise (uv-default-loop) executor)]
      [(loop executor)
       "创建新的 Promise
        loop: 事件循环
        executor: (lambda (resolve reject) ...) 执行器函数"
       (let* ([promise (make-promise-record loop)]
              [resolve (lambda (value)
                         (if (promise-record? value)
                             ;; 如果 resolve 的值是另一个 promise，等待它
                             (promise-then value
                               (lambda (v) (fulfill-promise! promise v))
                               (lambda (r) (reject-promise! promise r)))
                             (fulfill-promise! promise value)))]
              [reject (lambda (reason)
                        (reject-promise! promise reason))])
         ;; 立即执行 executor
         (guard (e [else (reject e)])
           (executor resolve reject))
         promise)]))

  (define promise-resolved
    (case-lambda
      [(value)
       (promise-resolved (uv-default-loop) value)]
      [(loop value)
       "创建一个已成功完成的 Promise
        loop: 事件循环（可选，默认为 uv-default-loop）
        value: 成功值"
       (let ([promise (make-promise-record loop)])
         (promise-record-state-set! promise 'fulfilled)
         (promise-record-value-set! promise value)
         promise)]))

  (define promise-rejected
    (case-lambda
      [(reason)
       (promise-rejected (uv-default-loop) reason)]
      [(loop reason)
       "创建一个已失败的 Promise
        loop: 事件循环（可选，默认为 uv-default-loop）
        reason: 失败原因"
       (let ([promise (make-promise-record loop)])
         (promise-record-state-set! promise 'rejected)
         (promise-record-reason-set! promise reason)
         promise)]))

  ;; ========================================
  ;; 状态查询
  ;; ========================================

  (define (promise-state promise)
    "获取 Promise 状态"
    (promise-record-state promise))

  (define (promise-pending? promise)
    "检查 Promise 是否处于等待状态"
    (eq? (promise-record-state promise) 'pending))

  (define (promise-fulfilled? promise)
    "检查 Promise 是否已成功完成"
    (eq? (promise-record-state promise) 'fulfilled))

  (define (promise-rejected? promise)
    "检查 Promise 是否已失败"
    (eq? (promise-record-state promise) 'rejected))

  ;; ========================================
  ;; 额外链式操作
  ;; ========================================

  (define (promise-finally promise on-finally)
    "添加完成回调（无论成功或失败）
     on-finally 不接收参数，其返回值被忽略"
    (promise-then promise
      (lambda (value)
        (on-finally)
        value)
      (lambda (reason)
        (on-finally)
        (promise-rejected (promise-record-loop promise) reason))))

  ;; ========================================
  ;; 组合器
  ;; ========================================

  (define (promise-all promises)
    "等待所有 Promise 完成
     如果任何一个失败，立即返回失败的 Promise
     成功时返回所有值的列表（保持顺序）"
    (if (null? promises)
        (promise-resolved '())
        (let* ([loop (promise-record-loop (car promises))]
               [count (length promises)]
               [results (make-vector count #f)]
               [completed (box 0)]
               [finished (box #f)])
          (make-promise loop
            (lambda (resolve reject)
              (let loop-promises ([ps promises] [i 0])
                (unless (null? ps)
                  (promise-then (car ps)
                    (lambda (value)
                      (unless (unbox finished)
                        (vector-set! results i value)
                        (set-box! completed (+ (unbox completed) 1))
                        (when (= (unbox completed) count)
                          (set-box! finished #t)
                          (resolve (vector->list results)))))
                    (lambda (reason)
                      (unless (unbox finished)
                        (set-box! finished #t)
                        (reject reason))))
                  (loop-promises (cdr ps) (+ i 1)))))))))

  (define (promise-race promises)
    "返回第一个完成的 Promise 的结果（无论成功或失败）"
    (if (null? promises)
        (make-promise (uv-default-loop) (lambda (resolve reject) #f))  ; 永远 pending
        (let* ([loop (promise-record-loop (car promises))]
               [finished (box #f)])
          (make-promise loop
            (lambda (resolve reject)
              (for-each
                (lambda (p)
                  (promise-then p
                    (lambda (value)
                      (unless (unbox finished)
                        (set-box! finished #t)
                        (resolve value)))
                    (lambda (reason)
                      (unless (unbox finished)
                        (set-box! finished #t)
                        (reject reason)))))
                promises))))))

  (define (promise-any promises)
    "返回第一个成功的 Promise 的结果
     如果所有都失败，返回包含所有错误的失败 Promise"
    (if (null? promises)
        (promise-rejected "No promises provided")
        (let* ([loop (promise-record-loop (car promises))]
               [count (length promises)]
               [errors (make-vector count #f)]
               [rejected-count (box 0)]
               [finished (box #f)])
          (make-promise loop
            (lambda (resolve reject)
              (let loop-promises ([ps promises] [i 0])
                (unless (null? ps)
                  (promise-then (car ps)
                    (lambda (value)
                      (unless (unbox finished)
                        (set-box! finished #t)
                        (resolve value)))
                    (lambda (reason)
                      (unless (unbox finished)
                        (vector-set! errors i reason)
                        (set-box! rejected-count (+ (unbox rejected-count) 1))
                        (when (= (unbox rejected-count) count)
                          (set-box! finished #t)
                          (reject (vector->list errors))))))
                  (loop-promises (cdr ps) (+ i 1)))))))))

  (define (promise-all-settled promises)
    "等待所有 Promise 完成（无论成功或失败）
     返回所有结果的列表，每个结果是 (status . value/reason)
     status 为 'fulfilled 或 'rejected"
    (if (null? promises)
        (promise-resolved '())
        (let* ([loop (promise-record-loop (car promises))]
               [count (length promises)]
               [results (make-vector count #f)]
               [completed (box 0)])
          (make-promise loop
            (lambda (resolve reject)
              (let loop-promises ([ps promises] [i 0])
                (unless (null? ps)
                  (promise-then (car ps)
                    (lambda (value)
                      (vector-set! results i (cons 'fulfilled value))
                      (set-box! completed (+ (unbox completed) 1))
                      (when (= (unbox completed) count)
                        (resolve (vector->list results))))
                    (lambda (reason)
                      (vector-set! results i (cons 'rejected reason))
                      (set-box! completed (+ (unbox completed) 1))
                      (when (= (unbox completed) count)
                        (resolve (vector->list results)))))
                  (loop-promises (cdr ps) (+ i 1)))))))))

  ;; ========================================
  ;; 辅助函数
  ;; ========================================

  (define (promise-wait promise)
    "同步等待 Promise 完成并返回结果
     如果 Promise 失败，抛出异常
     警告：这会阻塞当前线程，仅用于测试"
    (let ([loop (promise-record-loop promise)])
      ;; 运行事件循环直到 promise 完成
      (let wait-loop ()
        (when (promise-pending? promise)
          (uv-run loop 'once)
          (wait-loop)))
      ;; 返回结果或抛出错误
      (if (promise-fulfilled? promise)
          (promise-record-value promise)
          (error 'promise-wait "Promise rejected"
                 (promise-record-reason promise)))))

  ;; ========================================
  ;; Timer 辅助函数
  ;; ========================================

  (define (run-after loop ms thunk)
    "延迟 ms 毫秒后在事件循环中执行 thunk（一次性 timer）
     loop: 事件循环
     ms: 延迟毫秒数（0 表示下一次事件循环迭代）
     thunk: 无参数的回调函数
     用途：封装 timer init→start→close 三步模式，
     适用于微任务调度、sleep、timeout 等场景"
    (let ([timer (uv-timer-init loop)])
      (uv-timer-start! timer ms 0
        (lambda (t)
          (uv-handle-close! t)
          (thunk)))))

  ;; ========================================
  ;; 微任务调度器（基于 uv_idle_t）
  ;; ========================================
  ;;
  ;; 使用 per-loop 的 uv_idle_t + 微任务队列替代 0ms timer。
  ;; 优势：每次 promise 回调不再需要创建/销毁 timer handle，
  ;; 而是共享一个 idle handle，在有微任务时 start，队列空时 stop。
  ;;
  ;; 使用 idle 而非 check 的原因：idle handle 活跃时强制 I/O poll
  ;; timeout=0，确保事件循环不会阻塞等待 I/O。check handle 在 I/O
  ;; 轮询后执行，如果没有其他 I/O 事件，poll 会无限阻塞。

  ;; Per-loop 微任务状态：loop → (idle-handle . microtask-queue)
  ;; microtask-queue 是一个 pair: (front . rear) 用于 O(1) enqueue
  (define microtask-state-table (make-eq-hashtable))

  (define (get-or-create-microtask-state! loop)
    "获取或创建 loop 的微任务状态"
    (or (hashtable-ref microtask-state-table loop #f)
        (let* ([idle (uv-idle-init loop)]
               [queue (cons '() '())]  ; (front . rear)
               [state (cons idle queue)])
          ;; unref idle handle 使其不会阻止事件循环退出（当非活跃时）
          (uv-handle-unref! idle)
          (hashtable-set! microtask-state-table loop state)
          state)))

  (define (microtask-enqueue! queue thunk)
    "将微任务加入队列尾部"
    (let ([new-cell (list thunk)])
      (if (null? (car queue))
          (begin
            (set-car! queue new-cell)
            (set-cdr! queue new-cell))
          (begin
            (set-cdr! (cdr queue) new-cell)
            (set-cdr! queue new-cell)))))

  (define (microtask-dequeue! queue)
    "从队列头部取出微任务"
    (let ([front (car queue)])
      (if (null? front)
          #f
          (let ([thunk (car front)])
            (set-car! queue (cdr front))
            (when (null? (cdr front))
              (set-cdr! queue '()))
            thunk))))

  (define (microtask-queue-empty? queue)
    "检查微任务队列是否为空"
    (null? (car queue)))

  (define (schedule-microtask-impl loop thunk)
    "微任务调度器实现：enqueue 并确保 idle handle 已启动"
    (let* ([state (get-or-create-microtask-state! loop)]
           [idle (car state)]
           [queue (cdr state)])
      ;; 加入队列
      (microtask-enqueue! queue thunk)
      ;; 确保 idle handle 正在运行
      (unless (uv-handle-active? idle)
        ;; ref 使 idle handle 保持事件循环活跃
        (uv-handle-ref! idle)
        (uv-idle-start! idle
          (lambda (idl)
            ;; drain 整个队列
            (let drain ()
              (let ([task (microtask-dequeue! queue)])
                (when task
                  (task)
                  (drain))))
            ;; 队列已空，停止并关闭 idle handle，释放资源
            (when (microtask-queue-empty? queue)
              (uv-idle-stop! idl)
              (uv-handle-close! idl)
              (hashtable-delete! microtask-state-table loop)))))))

  ;; 注入微任务调度器
  (install-microtask-scheduler! schedule-microtask-impl)

) ; end library
