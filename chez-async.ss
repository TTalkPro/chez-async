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
    unhandled-rejection-handler

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
    timeout-error-timeout-ms

    ;; ========================================
    ;; UV 错误条件类型
    ;; ========================================
    ;; high-level 操作 reject 的正是这类 condition，
    ;; 从统一入口导出判定器供用户按类型捕获
    &uv-error
    make-uv-error
    uv-error?
    uv-error-code
    uv-error-name
    uv-error-operation

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
    &cancelled
    make-cancelled-error
    cancelled-error?
    &operation-cancelled
    make-operation-cancelled-error
    operation-cancelled?
    async-cancellable
    link-tokens

    ;; ========================================
    ;; 后台 runtime 线程 + Task 化
    ;; ========================================
    make-runtime
    runtime?
    runtime-start!
    runtime-stop!
    runtime-running?
    runtime-loop
    runtime-submit!
    runtime-await
    runtime-poll
    runtime-on-thread?
    &runtime-error runtime-error?
    &runtime-stopped runtime-stopped-error?
    make-runtime-stopped-error
    ;; Task / CompletionQueue 层
    task-submit!
    task?
    task-id
    task-op
    task-runtime
    task-await
    task-poll
    task-cancel!
    task-cancelled?
    task-current-token
    make-completion-queue
    completion-queue?
    cq-wait-one
    cq-try-pop
    )
  (import
    (only (chez-async ffi errors)
          &uv-error make-uv-error uv-error?
          uv-error-code uv-error-name uv-error-operation)
    (chez-async high-level event-loop)
    (chez-async high-level promise)
    (chez-async high-level async-await)
    (chez-async high-level async-combinators)
    (chez-async high-level stream)
    (chez-async high-level async-work)
    (chez-async high-level cancellation)
    (only (chez-async high-level runtime)
          make-runtime runtime? runtime-start! runtime-stop!
          runtime-running? runtime-loop runtime-submit! runtime-await
          runtime-poll runtime-on-thread?
          &runtime-error runtime-error?
          &runtime-stopped runtime-stopped-error?
          make-runtime-stopped-error)
    (chez-async high-level task))

) ; end library
