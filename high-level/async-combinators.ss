;;; high-level/async-combinators.ss - async/await 组合器
;;;
;;; 提供常用的异步组合器函数，类似 Promise.all, Promise.race 等
;;;
;;; 功能：
;;; - async-all: 并发执行多个 Promise，等待全部完成
;;; - async-race: 并发执行多个 Promise，返回第一个完成的
;;; - async-any: 并发执行多个 Promise，返回第一个成功的
;;; - async-timeout: 为异步操作添加超时
;;; - async-sleep: 延迟指定时间
;;; - async-delay: 延迟执行异步操作

(library (chez-async high-level async-combinators)
  (export
    ;; 并发组合器
    async-all
    async-race
    async-any

    ;; 时间相关
    async-sleep
    async-timeout
    async-delay

    ;; 工具函数
    async-catch
    async-finally)

  (import (chezscheme)
          (chez-async high-level promise)
          (chez-async high-level event-loop)
          (chez-async low-level timer)
          (chez-async low-level handle-base))

  ;; ========================================
  ;; 条件类型定义
  ;; ========================================

  ;; 超时错误类型
  (define-condition-type &timeout-error &error
    make-timeout-error timeout-error?
    (timeout-ms timeout-error-timeout-ms))

  ;; ========================================
  ;; async-sleep - 延迟指定时间
  ;; ========================================

  (define (async-sleep ms)
    "延迟指定毫秒数，返回 Promise

     ms: 延迟时间（毫秒）

     返回: Promise<void>

     示例:
       (async
         (await (async-sleep 1000))
         (format #t \"1 second passed~%\"))"
    (let ([loop (uv-default-loop)])
      (make-promise loop
        (lambda (resolve reject)
          (let ([timer (uv-timer-init loop)])
            (uv-timer-start! timer ms 0
              (lambda (t)
                (uv-handle-close! t)
                (resolve (void)))))))))

  ;; ========================================
  ;; async-all - 等待所有 Promise 完成
  ;; ========================================

  (define (async-all promises)
    "并发执行多个 Promise，等待全部完成

     promises: Promise 列表

     返回: Promise<list>，包含所有结果（按顺序）

     行为:
     - 如果所有 Promise 成功，返回结果列表
     - 如果任一 Promise 失败，立即 reject

     示例:
       (async
         (let ([results (await (async-all
                                 (list (http-get \"url1\")
                                       (http-get \"url2\")
                                       (http-get \"url3\"))))])
           (format #t \"All done: ~a~%\" results)))"
    (if (null? promises)
        ;; 空列表立即返回
        (promise-resolved (uv-default-loop) '())
        ;; 处理 Promise 列表
        (let ([loop (uv-default-loop)]
              [count (length promises)]
              [results (make-vector (length promises) #f)]
              [completed 0]
              [failed? #f])
          (make-promise loop
            (lambda (resolve reject)
              (let loop-promises ([ps promises] [index 0])
                (unless (null? ps)
                  (let ([p (car ps)]
                        [i index])
                    ;; 为每个 Promise 注册回调
                    (promise-then p
                      ;; 成功回调
                      (lambda (value)
                        (unless failed?
                          (vector-set! results i value)
                          (set! completed (+ completed 1))
                          ;; 检查是否全部完成
                          (when (= completed count)
                            (resolve (vector->list results)))))
                      ;; 失败回调
                      (lambda (error)
                        (unless failed?
                          (set! failed? #t)
                          (reject error))))
                    ;; 处理下一个
                    (loop-promises (cdr ps) (+ i 1))))))))))

  ;; ========================================
  ;; async-race - 返回第一个完成的
  ;; ========================================

  (define (async-race promises)
    "并发执行多个 Promise，返回第一个完成的（无论成功或失败）

     promises: Promise 列表

     返回: Promise<any>，第一个完成的 Promise 的结果

     行为:
     - 返回第一个 settled（fulfilled 或 rejected）的 Promise
     - 其他 Promise 仍然执行，但结果被忽略

     示例:
       (async
         (let ([winner (await (async-race
                                (list (http-get \"fast-server\")
                                      (http-get \"slow-server\"))))])
           (format #t \"Winner: ~a~%\" winner)))"
    (if (null? promises)
        ;; 空列表永远 pending
        (make-promise (uv-default-loop) (lambda (resolve reject) (void)))
        ;; 处理 Promise 列表
        (let ([loop (uv-default-loop)]
              [settled? #f])
          (make-promise loop
            (lambda (resolve reject)
              (for-each
                (lambda (p)
                  (promise-then p
                    ;; 成功回调
                    (lambda (value)
                      (unless settled?
                        (set! settled? #t)
                        (resolve value)))
                    ;; 失败回调
                    (lambda (error)
                      (unless settled?
                        (set! settled? #t)
                        (reject error)))))
                promises))))))

  ;; ========================================
  ;; async-any - 返回第一个成功的
  ;; ========================================

  (define (async-any promises)
    "并发执行多个 Promise，返回第一个成功的

     promises: Promise 列表

     返回: Promise<any>，第一个成功的 Promise 的结果

     行为:
     - 返回第一个 fulfilled 的 Promise
     - 如果所有 Promise 都失败，reject 并附带所有错误

     示例:
       (async
         (let ([result (await (async-any
                                (list (http-get \"mirror1\")
                                      (http-get \"mirror2\")
                                      (http-get \"mirror3\"))))])
           (format #t \"Got response: ~a~%\" result)))"
    (if (null? promises)
        ;; 空列表立即 reject
        (promise-rejected (uv-default-loop)
                         "async-any: empty promise list")
        ;; 处理 Promise 列表
        (let ([loop (uv-default-loop)]
              [count (length promises)]
              [failed-count 0]
              [errors (make-vector (length promises) #f)]
              [settled? #f])
          (make-promise loop
            (lambda (resolve reject)
              (let loop-promises ([ps promises] [index 0])
                (unless (null? ps)
                  (let ([p (car ps)]
                        [i index])
                    ;; 为每个 Promise 注册回调
                    (promise-then p
                      ;; 成功回调
                      (lambda (value)
                        (unless settled?
                          (set! settled? #t)
                          (resolve value)))
                      ;; 失败回调
                      (lambda (error)
                        (unless settled?
                          (vector-set! errors i error)
                          (set! failed-count (+ failed-count 1))
                          ;; 检查是否全部失败
                          (when (= failed-count count)
                            (set! settled? #t)
                            (reject (cons 'aggregate-error
                                        (vector->list errors)))))))
                    ;; 处理下一个
                    (loop-promises (cdr ps) (+ i 1))))))))))

  ;; ========================================
  ;; async-timeout - 为异步操作添加超时
  ;; ========================================

  (define (async-timeout promise timeout-ms)
    "为 Promise 添加超时限制

     promise: 要执行的 Promise
     timeout-ms: 超时时间（毫秒）

     返回: Promise<any>

     行为:
     - 如果在超时前完成，返回 Promise 的结果
     - 如果超时，reject 并附带超时错误

     示例:
       (async
         (guard (ex
                 [(timeout-error? ex)
                  (format #t \"Operation timed out~%\")])
           (let ([result (await (async-timeout
                                  (http-get \"slow-server\")
                                  5000))])
             (format #t \"Got: ~a~%\" result))))"
    (let ([loop (uv-default-loop)])
      (async-race
        (list
          promise
          (make-promise loop
            (lambda (resolve reject)
              (let ([timer (uv-timer-init loop)])
                (uv-timer-start! timer timeout-ms 0
                  (lambda (t)
                    (uv-handle-close! t)
                    (reject
                      (condition
                        (make-timeout-error timeout-ms)
                        (make-message-condition
                          (format "Operation timed out after ~a ms" timeout-ms)))))))))))))

  ;; ========================================
  ;; async-delay - 延迟执行异步操作
  ;; ========================================

  (define (async-delay ms thunk)
    "延迟指定时间后执行异步操作

     ms: 延迟时间（毫秒）
     thunk: 要执行的函数（应该返回 Promise）

     返回: Promise<any>

     示例:
       (async-delay 1000
         (lambda ()
           (http-get \"url\")))"
    (let ([loop (uv-default-loop)])
      (make-promise loop
        (lambda (resolve reject)
          (let ([timer (uv-timer-init loop)])
            (uv-timer-start! timer ms 0
              (lambda (t)
                (uv-handle-close! t)
                ;; 执行 thunk 并链接 Promise
                (guard (ex [else (reject ex)])
                  (let ([result (thunk)])
                    (if (promise? result)
                        (promise-then result resolve reject)
                        (resolve result)))))))))))

  ;; ========================================
  ;; async-catch - 错误处理
  ;; ========================================

  (define (async-catch promise handler)
    "为 Promise 添加错误处理器

     promise: Promise
     handler: 错误处理函数 (lambda (error) ...)

     返回: Promise<any>

     示例:
       (async-catch
         (http-get \"url\")
         (lambda (error)
           (format #t \"Error: ~a~%\" error)
           'default-value))"
    (promise-catch promise handler))

  ;; ========================================
  ;; async-finally - 清理操作
  ;; ========================================

  (define (async-finally promise finalizer)
    "为 Promise 添加清理操作（无论成功或失败都执行）

     promise: Promise
     finalizer: 清理函数 (lambda () ...)

     返回: Promise<any>

     示例:
       (async-finally
         (file-operation)
         (lambda ()
           (close-file)))"
    (promise-finally promise finalizer))

) ; end library
