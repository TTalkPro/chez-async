;;; internal/promise-core.ss - Promise 核心实现
;;;
;;; 本模块提供 Promise 的核心数据类型和操作，不依赖任何 low-level 或 high-level 模块。
;;;
;;; 1. Promise 记录类型 —— 状态（pending/fulfilled/rejected）、值、回调列表
;;; 2. 微任务调度器 —— 可注入的参数化调度策略
;;; 3. 核心操作 —— fulfill/reject/then/catch
;;;
;;; 设计目的：
;;; 打破 internal/scheduler.ss → high-level/promise.ss 的层级违规。
;;; scheduler 只需要 promise-then 等核心操作，不需要组合器。
;;;
;;; 微任务调度：
;;; schedule-microtask 函数通过 microtask-scheduler 参数化，
;;; 由 high-level 层在初始化时注入具体实现（基于 uv-timer）。
;;; 这样 internal 层不需要依赖 low-level 层。

(library (chez-async internal promise-core)
  (export
    ;; Promise 记录类型
    make-promise-record
    promise-record?
    promise-record-state
    promise-record-state-set!
    promise-record-value
    promise-record-value-set!
    promise-record-reason
    promise-record-reason-set!
    promise-record-on-fulfilled
    promise-record-on-fulfilled-set!
    promise-record-on-rejected
    promise-record-on-rejected-set!
    promise-record-loop
    promise-record-loop-set!
    promise-record-rejection-handled?
    promise-record-rejection-handled?-set!

    ;; 微任务调度器（可注入）
    microtask-scheduler
    schedule-microtask
    install-microtask-scheduler!

    ;; unhandled rejection 报告钩子（可配置）
    unhandled-rejection-handler

    ;; 核心操作
    fulfill-promise!
    reject-promise!
    promise-then
    promise-catch
    )
  (import (chezscheme))

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
      (mutable loop)            ; 关联的事件循环
      (mutable rejection-handled?)) ; 是否已有人负责此 promise 的 rejection
    (protocol
      (lambda (new)
        (lambda (loop)
          (new 'pending #f #f '() '() loop #f)))))

  ;; ========================================
  ;; 微任务调度器（可注入）
  ;; ========================================
  ;;
  ;; 默认实现直接同步调用 thunk（fallback）。
  ;; high-level/promise.ss 会在加载时注入基于 uv-timer 的实现。
  ;;
  ;; 命名：使用 Chez Scheme 惯例的 make-parameter 名称（无 earmuffs）。

  (define microtask-scheduler
    (make-parameter
      (lambda (loop thunk)
        (thunk))))

  ;; schedule-microtask: 在下一个事件循环迭代中执行 thunk
  ;;
  ;; 参数：
  ;;   loop  - 事件循环
  ;;   thunk - 要执行的无参函数
  ;;
  ;; 说明：
  ;;   具体行为取决于通过 install-microtask-scheduler! 注入的调度器实现。
  ;;   默认同步执行（测试用），生产环境由 high-level 注入异步版本。
  (define (schedule-microtask loop thunk)
    ((microtask-scheduler) loop thunk))

  ;; install-microtask-scheduler!: 注入微任务调度器实现
  ;;
  ;; 参数：
  ;;   scheduler - (lambda (loop thunk) ...) 接受事件循环和 thunk
  (define (install-microtask-scheduler! scheduler)
    (microtask-scheduler scheduler))

  ;; ========================================
  ;; unhandled rejection 报告
  ;; ========================================
  ;;
  ;; 语义：promise 被 reject 时，若从未有人注册过 rejection 处理
  ;; （promise-then/promise-catch/await/promise-wait 都算「负责」），
  ;; 则调度一个微任务延迟一拍再检查——给同一轮同步代码挂 catch 的机会；
  ;; 检查时仍无人负责，调用 unhandled-rejection-handler 报告。
  ;; promise-then 总是会把 rejection 传播给派生 promise，因此父 promise
  ;; 一旦被 then 过即视为 handled，「未处理」责任转移到链尾的派生 promise。
  ;;
  ;; 用户可 parameterize/set 此参数自定义处理（如收集、测试断言、直接抛出）。

  (define unhandled-rejection-handler
    (make-parameter
      (lambda (promise reason)
        (format (current-error-port)
                "[Promise] Unhandled rejection: ~a~%"
                (if (condition? reason)
                    (call-with-string-output-port
                      (lambda (p) (display-condition reason p)))
                    reason)))))

  ;; ========================================
  ;; 核心操作
  ;; ========================================

  (define (fulfill-promise! promise value)
    "将 promise 标记为成功完成"
    (when (eq? (promise-record-state promise) 'pending)
      (promise-record-state-set! promise 'fulfilled)
      (promise-record-value-set! promise value)
      ;; 调度所有成功回调（列表是头插构建的，reverse 恢复注册顺序）
      (let ([loop (promise-record-loop promise)])
        (for-each
          (lambda (callback)
            (schedule-microtask loop
              (lambda () (callback value))))
          (reverse (promise-record-on-fulfilled promise))))
      ;; 清空回调列表
      (promise-record-on-fulfilled-set! promise '())
      (promise-record-on-rejected-set! promise '())))

  (define (reject-promise! promise reason)
    "将 promise 标记为失败"
    (when (eq? (promise-record-state promise) 'pending)
      (promise-record-state-set! promise 'rejected)
      (promise-record-reason-set! promise reason)
      ;; 调度所有失败回调（列表是头插构建的，reverse 恢复注册顺序）
      (let ([loop (promise-record-loop promise)])
        (for-each
          (lambda (callback)
            (schedule-microtask loop
              (lambda () (callback reason))))
          (reverse (promise-record-on-rejected promise)))
        ;; unhandled rejection 检测：reject 时尚无人负责 → 延迟一拍复查
        ;; （同一轮同步代码仍来得及挂 catch / 被 promise-wait 消费）
        (unless (promise-record-rejection-handled? promise)
          (schedule-microtask loop
            (lambda ()
              (unless (promise-record-rejection-handled? promise)
                ((unhandled-rejection-handler) promise reason))))))
      ;; 清空回调列表
      (promise-record-on-fulfilled-set! promise '())
      (promise-record-on-rejected-set! promise '())))

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
         ;; 公共模式：调用 handler，链接返回的 promise 或直接 resolve/reject
         (define (resolve-handler handler pass-through value)
           (if handler
               (guard (e [else (reject-promise! new-promise e)])
                 (let ([result (handler value)])
                   (if (promise-record? result)
                       (promise-then result
                         (lambda (v) (fulfill-promise! new-promise v))
                         (lambda (r) (reject-promise! new-promise r)))
                       (fulfill-promise! new-promise result))))
               (pass-through new-promise value)))
         ;; then 总会把 rejection 传播给派生 promise（on-rejected 缺省时 pass-through），
         ;; 因此本 promise 视为已被负责；「未处理」责任转移到派生 promise
         (promise-record-rejection-handled?-set! promise #t)
         (let ([handle-fulfilled
                 (lambda (value)
                   (resolve-handler on-fulfilled fulfill-promise! value))]
               [handle-rejected
                 (lambda (reason)
                   (resolve-handler on-rejected reject-promise! reason))])
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

) ; end library
