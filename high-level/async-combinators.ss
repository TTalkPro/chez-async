;;; high-level/async-combinators.ss - async/await 组合器
;;;
;;; 提供常用的异步组合器函数，类似 Promise.all, Promise.race 等。
;;;
;;; 设计说明：
;;; - async-all/race/any 是 promise-all/race/any 的别名，提供 async 风格的命名
;;; - async-catch/async-finally 同理，是 promise-catch/promise-finally 的别名
;;; - async-sleep/timeout/delay 使用 run-after 封装一次性 timer 模式
;;; - &timeout-error 条件类型用于超时错误的结构化处理
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
    ;; 并发组合器（promise-all/race/any 的别名）
    async-all
    async-race
    async-any

    ;; 时间相关（基于 run-after 的 timer 操作）
    async-sleep
    async-timeout
    async-delay

    ;; 工具函数（promise-catch/finally 的别名）
    async-catch
    async-finally)

  (import (chezscheme)
          (chez-async high-level promise)
          (chez-async high-level event-loop))

  ;; ========================================
  ;; 条件类型定义
  ;; ========================================

  ;; 超时错误类型，用于 async-timeout 中标识超时
  (define-condition-type &timeout-error &error
    make-timeout-error timeout-error?
    (timeout-ms timeout-error-timeout-ms))

  ;; ========================================
  ;; 并发组合器（重导出 promise 版本）
  ;; ========================================
  ;;
  ;; async-all/race/any 与 promise-all/race/any 语义完全相同，
  ;; 提供 async 风格的命名以保持 API 一致性。

  (define async-all promise-all)
  (define async-race promise-race)
  (define async-any promise-any)

  ;; ========================================
  ;; 工具函数（重导出 promise 版本）
  ;; ========================================

  (define async-catch promise-catch)
  (define async-finally promise-finally)

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
          (run-after loop ms (lambda () (resolve (void))))))))

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
     - 如果超时，reject 并附带 &timeout-error 条件
     实现: 使用 async-race 让原始 promise 和超时 promise 竞争"
    (let ([loop (uv-default-loop)])
      (async-race
        (list
          promise
          (make-promise loop
            (lambda (resolve reject)
              (run-after loop timeout-ms
                (lambda ()
                  (reject
                    (condition
                      (make-timeout-error timeout-ms)
                      (make-message-condition
                        (format "Operation timed out after ~a ms" timeout-ms))))))))))))

  ;; ========================================
  ;; async-delay - 延迟执行异步操作
  ;; ========================================

  (define (async-delay ms thunk)
    "延迟指定时间后执行异步操作
     ms: 延迟时间（毫秒）
     thunk: 要执行的函数（可返回值或 Promise）
     返回: Promise<any>
     行为: 延迟 ms 毫秒后执行 thunk，
     如果 thunk 返回 Promise 则自动链接"
    (let ([loop (uv-default-loop)])
      (make-promise loop
        (lambda (resolve reject)
          (run-after loop ms
            (lambda ()
              (guard (ex [else (reject ex)])
                (let ([result (thunk)])
                  (if (promise? result)
                      (promise-then result resolve reject)
                      (resolve result))))))))))

) ; end library
