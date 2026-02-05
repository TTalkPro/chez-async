;;; internal/scheduler.ss - 协程调度器
;;;
;;; 提供协程调度功能，管理协程的生命周期和执行顺序。
;;;
;;; 调度器负责：
;;; 1. 管理可运行协程队列 (runnable queue)
;;; 2. 管理等待 Promise 的协程表 (pending table)
;;; 3. 执行协程的暂停和恢复
;;; 4. 与 libuv 事件循环集成

(library (chez-async internal scheduler)
  (export
    ;; 调度器类型
    make-scheduler-state
    scheduler-state?
    scheduler-state-loop
    get-scheduler

    ;; 协程操作
    spawn-coroutine!
    suspend-for-promise!
    resume-coroutine!
    run-scheduler
    run-coroutine!

    ;; 调度器状态访问
    scheduler-runnable-queue
    scheduler-pending-table
    scheduler-current-coroutine

    ;; 队列操作（用于调试）
    queue-empty?
    queue-not-empty?
    queue-size
    queue-dequeue!)

  (import (chezscheme)
          (chez-async internal coroutine)
          (chez-async internal promise-core)
          (chez-async internal loop-registry)
          (chez-async ffi types)
          (chez-async ffi core))

  ;; ========================================
  ;; 简单队列实现（FIFO）
  ;; ========================================

  (define-record-type queue-record
    (fields
      (mutable items))      ; (list item)
    (protocol
      (lambda (new)
        (lambda ()
          (new '())))))

  (define (make-queue)
    "创建新的空队列"
    (make-queue-record))

  (define (queue-enqueue! q item)
    "将元素加入队列尾部"
    (queue-record-items-set! q (append (queue-record-items q) (list item))))

  (define (queue-dequeue! q)
    "从队列头部取出元素"
    (let ([items (queue-record-items q)])
      (if (null? items)
          (error 'queue-dequeue! "Queue is empty")
          (let ([item (car items)])
            (queue-record-items-set! q (cdr items))
            item))))

  (define (queue-empty? q)
    "检查队列是否为空"
    (null? (queue-record-items q)))

  (define (queue-not-empty? q)
    "检查队列是否非空"
    (not (queue-empty? q)))

  (define (queue-size q)
    "获取队列大小"
    (length (queue-record-items q)))

  ;; ========================================
  ;; 调度器状态
  ;; ========================================

  (define-record-type scheduler-state
    (fields
      (mutable runnable)      ; (queue coroutine) - 可运行协程队列
      (mutable pending)       ; (hashtable promise -> coroutine) - 等待中的协程
      (mutable current)       ; coroutine - 当前运行的协程
      (mutable scheduler-k)   ; continuation - 调度器 continuation（用于逃逸）
      (immutable loop))       ; uv-loop - 关联的事件循环
    (protocol
      (lambda (new)
        (lambda (loop)
          "创建新的调度器状态"
          (new (make-queue)
               (make-eq-hashtable)
               #f
               #f
               loop)))))

  ;; ========================================
  ;; 全局调度器表（每个 uv-loop 一个调度器）
  ;; ========================================

  ;; 使用弱引用表存储 loop -> scheduler 映射
  (define scheduler-table (make-weak-eq-hashtable))

  (define (get-scheduler loop)
    "获取或创建事件循环的调度器"
    (or (hashtable-ref scheduler-table loop #f)
        (let ([sched (make-scheduler-state loop)])
          (hashtable-set! scheduler-table loop sched)
          sched)))

  ;; ========================================
  ;; 调度器状态访问
  ;; ========================================

  (define (scheduler-runnable-queue sched)
    "获取可运行协程队列"
    (scheduler-state-runnable sched))

  (define (scheduler-pending-table sched)
    "获取等待中的协程表"
    (scheduler-state-pending sched))

  (define (scheduler-current-coroutine sched)
    "获取当前运行的协程"
    (scheduler-state-current sched))

  ;; ========================================
  ;; 核心操作：spawn-coroutine!
  ;; ========================================

  (define (spawn-coroutine! loop thunk)
    "创建新协程并加入可运行队列

     loop: 事件循环
     thunk: 协程执行的函数 (lambda () ...)

     返回: coroutine"
    (let* ([sched (get-scheduler loop)]
           [coro (make-coroutine loop)])

      ;; 包装 thunk，设置当前协程并处理错误
      (let ([wrapped-thunk
             (lambda ()
               (parameterize ([current-coroutine coro])
                 (guard (ex
                         [else
                          ;; 捕获未处理的异常
                          (coroutine-state-set! coro 'failed)
                          (coroutine-result-set! coro ex)
                          (format #t "[Coroutine ~a] Failed with error: ~a~%"
                                  (coroutine-id coro) ex)
                          (when (condition? ex)
                            (format #t "  Message: ~a~%"
                                    (if (message-condition? ex)
                                        (condition-message ex)
                                        "No message"))
                            (when (irritants-condition? ex)
                              (format #t "  Irritants: ~a~%"
                                      (condition-irritants ex))))])
                   (let ([result (thunk)])
                     (coroutine-state-set! coro 'completed)
                     (coroutine-result-set! coro result)
                     result))))])

        ;; 保存 thunk 作为初始 continuation
        (coroutine-continuation-set! coro wrapped-thunk)

        ;; 加入可运行队列
        (queue-enqueue! (scheduler-state-runnable sched) coro)

        coro)))

  ;; ========================================
  ;; 核心操作：suspend-for-promise!
  ;; ========================================

  (define (suspend-for-promise! promise)
    "暂停当前协程，等待 Promise 完成

     promise: 要等待的 Promise

     返回: Promise 的结果值（当协程恢复时）

     这个函数使用 call/cc 捕获当前 continuation，
     然后跳回调度器。"
    (let ([coro (current-coroutine)])
      (unless coro
        (error 'suspend-for-promise! "No current coroutine"))

      (let* ([loop (coroutine-loop coro)]
             [sched (get-scheduler loop)])

        ;; 使用 call/cc 捕获 continuation
        (call/cc
          (lambda (k)
            ;; 1. 保存 continuation
            (coroutine-continuation-set! coro k)
            (coroutine-state-set! coro 'suspended)

            ;; 2. 注册到 pending 表
            (hashtable-set! (scheduler-state-pending sched) promise coro)

            ;; 3. 注册 Promise 回调
            (promise-then promise
              ;; 成功回调
              (lambda (value)
                (resume-coroutine! sched coro value #f))
              ;; 错误回调 - 包装错误以便在恢复后抛出
              (lambda (error)
                ;; 创建一个包装器，标记这是一个错误
                (let ([error-wrapper (cons 'promise-error error)])
                  (resume-coroutine! sched coro error-wrapper #t))))

            ;; 4. 跳回调度器（借鉴 chez-socket 的做法）
            ;; 注意：不清除 current-coroutine，parameterize 会自动管理
            (let ([scheduler-k (scheduler-state-scheduler-k sched)])
              (if scheduler-k
                  ;; 如果有保存的调度器 continuation，跳回调度器
                  (scheduler-k (void))
                  ;; 否则抛出错误
                  (error 'suspend-for-promise!
                         "No scheduler continuation available"))))))))

  ;; ========================================
  ;; 核心操作：resume-coroutine!
  ;; ========================================

  (define (resume-coroutine! sched coro value-or-error is-error?)
    "恢复暂停的协程

     sched: 调度器
     coro: 要恢复的协程
     value-or-error: Promise 的结果或错误
     is-error?: 是否为错误"

    ;; 1. 从 pending 表中移除
    (let ([pending (scheduler-state-pending sched)])
      (let-values ([(keys vals) (hashtable-entries pending)])
        (vector-for-each
          (lambda (i)
            (when (eq? (vector-ref vals i) coro)
              (hashtable-delete! pending (vector-ref keys i))))
          (list->vector (iota (vector-length keys))))))

    ;; 2. 设置结果（错误通过 value-or-error 的结构标记，见 run-coroutine!）
    (coroutine-state-set! coro 'running)
    (coroutine-result-set! coro value-or-error)

    ;; 3. 加入可运行队列
    (queue-enqueue! (scheduler-state-runnable sched) coro))

  ;; ========================================
  ;; 核心操作：run-coroutine!
  ;; ========================================

  (define (run-coroutine! sched coro)
    "执行单个协程（恢复或首次运行）

     sched: 调度器
     coro: 要执行的协程"

    ;; 设置当前协程
    (scheduler-state-current-set! sched coro)

    (parameterize ([current-coroutine coro])
      (let ([k (coroutine-continuation coro)]
            [is-first-run? (coroutine-created? coro)]
            [is-failed? (coroutine-failed? coro)])
        (unless k
          (error 'run-coroutine! "No continuation for coroutine" (coroutine-id coro)))

        ;; 设置为运行状态（除非已失败）
        (unless is-failed?
          (coroutine-state-set! coro 'running))

        ;; 清理 continuation（避免重复执行）
        (coroutine-continuation-set! coro #f)

        ;; 执行 continuation
        (if (procedure? k)
            (if is-first-run?
                ;; 首次运行（thunk）
                (k)
                ;; 恢复
                (let ([result (coroutine-result coro)])
                  (if (and (pair? result) (eq? (car result) 'promise-error))
                      ;; 这是一个 Promise 错误，抛出它
                      (raise (cdr result))
                      ;; 正常结果，传递它
                      (k result))))
            (error 'run-coroutine! "Invalid continuation" k)))))

  ;; ========================================
  ;; 核心操作：run-scheduler
  ;; ========================================

  (define (run-scheduler loop)
    "运行调度器直到所有协程完成

     loop: 事件循环

     调度循环：
     1. 如果有可运行的协程，执行它
     2. 如果有等待中的协程，运行一次事件循环
     3. 否则退出"
    (let ([sched (get-scheduler loop)])
      (let scheduler-loop ()
        ;; 在每次循环开始时设置 scheduler continuation
        ;; 这样 suspend-for-promise! 可以跳回这里
        (call/cc
          (lambda (k)
            (scheduler-state-scheduler-k-set! sched k)))

        (cond
          ;; 情况 1: 有可运行的协程
          [(queue-not-empty? (scheduler-state-runnable sched))
           (let ([coro (queue-dequeue! (scheduler-state-runnable sched))])
             (guard (ex
                     [else
                      (format #t "[Scheduler] Error running coroutine ~a: ~a~%"
                              (coroutine-id coro) ex)
                      (coroutine-state-set! coro 'failed)
                      (coroutine-result-set! coro ex)])
               (run-coroutine! sched coro))
             (scheduler-loop))]

          ;; 情况 2: 有等待中的协程，运行事件循环
          [(> (hashtable-size (scheduler-state-pending sched)) 0)
           ;; 运行一次 libuv 事件循环
           (%ffi-uv-run (uv-loop-ptr loop) (uv-run-mode->int 'once))
           (scheduler-loop)]

          ;; 情况 3: 所有协程完成
          [else
           (values)]))))

) ; end library
