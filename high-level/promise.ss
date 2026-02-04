;;; high-level/promise.ss - Promise/Future 异步抽象
;;;
;;; 提供 Promise 风格的异步编程接口，类似于 JavaScript Promise。
;;;
;;; 基本用法：
;;;   ;; 创建 Promise
;;;   (define p (make-promise
;;;               (lambda (resolve reject)
;;;                 (uv-timer-start! timer 1000 0
;;;                   (lambda (t) (resolve "done!"))))))
;;;
;;;   ;; 链式调用
;;;   (promise-then p
;;;     (lambda (value) (display value)))
;;;
;;;   ;; 错误处理
;;;   (promise-catch p
;;;     (lambda (error) (display error)))
;;;
;;; 状态：
;;; - pending: 初始状态，等待结果
;;; - fulfilled: 成功完成，有值
;;; - rejected: 失败，有错误

(library (chez-async high-level promise)
  (export
    ;; Promise 类型
    make-promise
    promise?
    promise-resolved
    promise-rejected

    ;; 链式操作
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
    )
  (import (chezscheme)
          (chez-async high-level event-loop)
          (chez-async low-level timer)
          (chez-async low-level handle-base))

  ;; ========================================
  ;; Promise 记录类型
  ;; ========================================

  (define-record-type promise-record
    (fields
      (mutable state)           ; 'pending | 'fulfilled | 'rejected
      (mutable value)           ; 成功时的值
      (mutable reason)          ; 失败时的原因
      (mutable on-fulfilled)    ; 成功回调列表
      (mutable on-rejected)     ; 失败回调列表
      (mutable loop))           ; 关联的事件循环
    (protocol
      (lambda (new)
        (lambda (loop)
          (new 'pending #f #f '() '() loop)))))

  ;; 类型谓词别名
  (define promise? promise-record?)

  ;; ========================================
  ;; 内部辅助函数
  ;; ========================================

  (define (schedule-microtask loop thunk)
    "在下一个事件循环迭代中执行 thunk"
    ;; 使用 0ms 定时器模拟微任务
    (let ([timer (uv-timer-init loop)])
      (uv-timer-start! timer 0 0
        (lambda (t)
          (uv-handle-close! t)
          (thunk)))))

  (define (fulfill-promise! promise value)
    "将 promise 标记为成功完成"
    (when (eq? (promise-record-state promise) 'pending)
      (promise-record-state-set! promise 'fulfilled)
      (promise-record-value-set! promise value)
      ;; 调度所有成功回调
      (let ([loop (promise-record-loop promise)])
        (for-each
          (lambda (callback)
            (schedule-microtask loop
              (lambda () (callback value))))
          (promise-record-on-fulfilled promise)))
      ;; 清空回调列表
      (promise-record-on-fulfilled-set! promise '())
      (promise-record-on-rejected-set! promise '())))

  (define (reject-promise! promise reason)
    "将 promise 标记为失败"
    (when (eq? (promise-record-state promise) 'pending)
      (promise-record-state-set! promise 'rejected)
      (promise-record-reason-set! promise reason)
      ;; 调度所有失败回调
      (let ([loop (promise-record-loop promise)])
        (for-each
          (lambda (callback)
            (schedule-microtask loop
              (lambda () (callback reason))))
          (promise-record-on-rejected promise)))
      ;; 清空回调列表
      (promise-record-on-fulfilled-set! promise '())
      (promise-record-on-rejected-set! promise '())))

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
                         (if (promise? value)
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
  ;; 链式操作
  ;; ========================================

  (define promise-then
    (case-lambda
      [(promise on-fulfilled)
       (promise-then promise on-fulfilled #f)]
      [(promise on-fulfilled on-rejected)
       "添加成功和/或失败回调，返回新的 Promise
        promise: 源 Promise
        on-fulfilled: 成功回调 (lambda (value) ...)
        on-rejected: 失败回调 (lambda (reason) ...)"
       (let* ([loop (promise-record-loop promise)]
              [new-promise (make-promise-record loop)])
         (letrec
           ([handle-fulfilled
              (lambda (value)
                (if on-fulfilled
                    (guard (e [else (reject-promise! new-promise e)])
                      (let ([result (on-fulfilled value)])
                        (if (promise? result)
                            (promise-then result
                              (lambda (v) (fulfill-promise! new-promise v))
                              (lambda (r) (reject-promise! new-promise r)))
                            (fulfill-promise! new-promise result))))
                    (fulfill-promise! new-promise value)))]
            [handle-rejected
              (lambda (reason)
                (if on-rejected
                    (guard (e [else (reject-promise! new-promise e)])
                      (let ([result (on-rejected reason)])
                        (if (promise? result)
                            (promise-then result
                              (lambda (v) (fulfill-promise! new-promise v))
                              (lambda (r) (reject-promise! new-promise r)))
                            (fulfill-promise! new-promise result))))
                    (reject-promise! new-promise reason)))])
           (case (promise-record-state promise)
             [(fulfilled)
              (schedule-microtask loop
                (lambda () (handle-fulfilled (promise-record-value promise))))]
             [(rejected)
              (schedule-microtask loop
                (lambda () (handle-rejected (promise-record-reason promise))))]
             [(pending)
              (promise-record-on-fulfilled-set! promise
                (cons handle-fulfilled (promise-record-on-fulfilled promise)))
              (promise-record-on-rejected-set! promise
                (cons handle-rejected (promise-record-on-rejected promise)))]))
         new-promise)]))

  (define (promise-catch promise on-rejected)
    "添加失败回调
     等同于 (promise-then promise #f on-rejected)"
    (promise-then promise #f on-rejected))

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

) ; end library
