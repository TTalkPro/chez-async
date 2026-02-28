;;; high-level/async-await.ss - async/await 语法糖（基于 call/cc 协程）
;;;
;;; 提供类似 JavaScript/Python 的 async/await 语法，
;;; 使用 call/cc 实现真正的协程暂停和恢复。
;;;
;;; 实现原理：
;;; - async 宏创建一个 Promise，并在其中 spawn 一个协程（spawn-coroutine!）
;;; - await 宏调用 suspend-for-promise!，通过 call/cc 捕获当前 continuation，
;;;   将协程挂起直到目标 Promise 被 resolve/reject
;;; - 协程由 internal/scheduler.ss 的调度器管理，FIFO 队列调度
;;;
;;; 限制条件：
;;; - await 只能在 async 块内使用（需要 current-coroutine 上下文）
;;; - await 不能跨越 lambda 边界（continuation 作用域限制）
;;; - 不支持在 dynamic-wind 的 before/after thunk 中使用 await
;;;
;;; 基本用法：
;;;   (define (fetch-data url)
;;;     (async
;;;       (let* ([response (await (http-get url))]
;;;              [body (await (read-body response))])
;;;         body)))

(library (chez-async high-level async-await)
  (export
    ;; 核心宏
    async
    async/loop
    await
    async*

    ;; 运行函数
    run-async
    run-async-loop

    ;; 工具函数
    async-value
    async-error)

  (import (chezscheme)
          (chez-async internal coroutine)
          (chez-async internal scheduler)
          (chez-async high-level promise)
          (chez-async high-level event-loop))

  ;; ========================================
  ;; await 宏
  ;; ========================================
  ;;
  ;; await 必须在 async 块内使用，用于等待 Promise 完成。
  ;; 它会暂停当前协程，直到 Promise 被解决或拒绝。

  (define-syntax await
    (syntax-rules ()
      [(await promise-expr)
       (let ([promise promise-expr])
         ;; 检查是否在协程中
         (if (current-coroutine)
             ;; 在协程中，暂停等待
             (suspend-for-promise! promise)
             ;; 不在协程中，报错
             (error 'await "await can only be used inside async block")))]))

  ;; ========================================
  ;; async 宏
  ;; ========================================
  ;;
  ;; async 创建一个异步任务，返回 Promise。
  ;; 任务在协程中执行，可以使用 await。

  (define-syntax async
    (syntax-rules ()
      [(async body ...)
       (async/loop (uv-default-loop) body ...)]))

  (define-syntax async/loop
    (syntax-rules ()
      [(async/loop loop-expr body ...)
       (let ([loop loop-expr])
         (make-promise loop
           (lambda (resolve reject)
             (spawn-coroutine! loop
               (lambda ()
                 (guard (ex
                         [else (reject ex)])
                   (let ([result (begin body ...)])
                     (resolve result))))))))]))

  ;; ========================================
  ;; async* 宏（带参数的异步函数）
  ;; ========================================
  ;;
  ;; async* 创建一个返回 Promise 的函数。
  ;; 函数体在协程中执行，可以使用 await。
  ;;
  ;; 示例：
  ;;   (define fetch-url
  ;;     (async* (url)
  ;;       (let ([response (await (http-get url))])
  ;;         (await (read-body response)))))

  (define-syntax async*
    (syntax-rules ()
      [(async* (params ...) body ...)
       (lambda (params ...)
         (async body ...))]))

  ;; ========================================
  ;; 运行函数
  ;; ========================================

  (define (run-async promise)
    "运行异步 Promise 直到完成

     promise: async 返回的 Promise

     返回: Promise 的结果值

     这是一个同步函数，会阻塞直到 Promise 完成。
     主要用于顶层或测试代码。"
    (let ([loop (uv-default-loop)])
      (run-scheduler loop)
      (promise-wait promise)))

  (define (run-async-loop)
    "运行事件循环，支持协程调度

     这是 uv-run 的协程友好版本，运行直到所有协程完成。"
    (run-scheduler (uv-default-loop)))

  ;; ========================================
  ;; 工具函数
  ;; ========================================

  (define (async-value value)
    "创建一个立即解决的异步值
     value: 要包装的值
     返回: 已 fulfilled 的 Promise
     直接创建 resolved promise，不创建协程，开销更低"
    (promise-resolved value))

  (define (async-error error)
    "创建一个立即拒绝的异步值
     error: 错误值
     返回: 已 rejected 的 Promise
     直接创建 rejected promise，不创建协程，开销更低"
    (promise-rejected error))

) ; end library
