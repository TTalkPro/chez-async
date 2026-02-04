;;; high-level/async-await.ss - async/await 语法糖（基于 call/cc）
;;;
;;; 提供类似 JavaScript/Python 的 async/await 语法，
;;; 使用 call/cc 实现真正的协程暂停和恢复。
;;;
;;; 基本用法：
;;;   (define (fetch-data url)
;;;     (async
;;;       (let* ([response (await (http-get url))]
;;;              [body (await (read-body response))])
;;;         body)))
;;;
;;; 特性：
;;; - 同步风格的异步代码
;;; - 自然的错误处理（使用 guard）
;;; - 支持嵌套 await
;;; - 与 Promise API 完全兼容

(library (chez-async high-level async-await)
  (export
    ;; 核心宏
    async
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
       (let ([loop (uv-default-loop)])
         ;; 创建 Promise 包装协程
         (make-promise loop
           (lambda (resolve reject)
             ;; 生成协程
             (spawn-coroutine! loop
               (lambda ()
                 ;; 捕获异常
                 (guard (ex
                         [else
                          ;; 拒绝 Promise
                          (reject ex)])
                   ;; 执行 body
                   (let ([result (begin body ...)])
                     ;; 解决 Promise
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
      ;; 运行调度器
      (run-scheduler loop)
      ;; 等待 Promise 完成
      (promise-wait promise)))

  (define (run-async-loop . args)
    "运行事件循环，支持协程调度

     args: 传递给 uv-run 的参数（可选）

     这是 uv-run 的协程友好版本。"
    (let ([loop (uv-default-loop)]
          [mode (if (null? args) 'default (car args))])
      (run-scheduler loop)))

  ;; ========================================
  ;; 工具函数
  ;; ========================================

  (define (async-value value)
    "创建一个立即解决的异步值

     value: 要包装的值

     返回: Promise

     等价于 (async value)"
    (async value))

  (define (async-error error)
    "创建一个立即拒绝的异步值

     error: 错误值

     返回: Promise

     等价于 (async (raise error))"
    (async (raise error)))

) ; end library
