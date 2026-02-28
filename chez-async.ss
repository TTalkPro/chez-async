;;; chez-async.ss - 统一入口模块
;;;
;;; 一行 (import (chez-async)) 即可使用所有 high-level 异步 API。
;;;
;;; 包含：
;;; - 事件循环管理（init, run, close）
;;; - Promise/Future（make-promise, then, catch, all, race, ...）
;;; - async/await 语法糖
;;; - async 组合器（sleep, timeout, delay, ...）
;;; - Stream 操作（read, write, pipe, ...）
;;; - 异步任务（async-work）
;;; - 取消令牌

(library (chez-async)
  (export
    ;; ========================================
    ;; 事件循环
    ;; ========================================
    uv-loop-init
    uv-loop-close
    uv-default-loop
    uv-run
    uv-stop
    uv-loop-alive?
    uv-version
    uv-version-string

    ;; ========================================
    ;; Promise
    ;; ========================================
    make-promise
    promise?
    promise-resolved
    promise-rejected
    promise-then
    promise-catch
    promise-finally
    promise-all
    promise-race
    promise-any
    promise-all-settled
    promise-state
    promise-pending?
    promise-fulfilled?
    promise-rejected?
    promise-wait
    run-after

    ;; ========================================
    ;; async/await
    ;; ========================================
    async
    async/loop
    await
    async*
    run-async
    run-async-loop
    async-value
    async-error

    ;; ========================================
    ;; async 组合器
    ;; ========================================
    async-all
    async-race
    async-any
    async-sleep
    async-timeout
    async-delay
    async-catch
    async-finally

    ;; 超时错误类型
    &timeout-error
    make-timeout-error
    timeout-error?

    ;; ========================================
    ;; Stream
    ;; ========================================
    stream-read
    stream-write
    stream-shutdown
    stream-end
    stream-pipe
    stream-readable?
    stream-writable?
    make-stream-reader
    stream-reader-read
    stream-reader-close

    ;; ========================================
    ;; 异步任务
    ;; ========================================
    loop-threadpool
    loop-set-threadpool!
    async-work
    async-work/error

    ;; ========================================
    ;; 取消令牌
    ;; ========================================
    make-cancel-source
    cancel-source?
    cancel-source-token
    cancel-source-cancel!
    cancel-source-cancelled?
    cancel-token?
    cancel-token-cancelled?
    cancel-token-register!
    make-cancelled-error
    cancelled-error?
    &operation-cancelled
    make-operation-cancelled-error
    operation-cancelled?
    async-cancellable
    link-tokens
    )
  (import
    (chez-async high-level event-loop)
    (chez-async high-level promise)
    (chez-async high-level async-await)
    (chez-async high-level async-combinators)
    (chez-async high-level stream)
    (chez-async high-level async-work)
    (chez-async high-level cancellation))

) ; end library
