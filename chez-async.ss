;;; chez-async.ss - 主库文件
;;;
;;; 统一导出所有 chez-async API

(library (chez-async)
  (export
    ;; 事件循环
    uv-loop-init
    uv-loop-close
    uv-default-loop
    uv-run
    uv-stop
    uv-loop-alive?
    uv-version
    uv-version-string

    ;; 句柄通用操作
    uv-handle-close!
    uv-handle-ref!
    uv-handle-unref!
    uv-handle-has-ref?
    uv-handle-active?
    uv-handle-closing?

    ;; Timer
    uv-timer-init
    uv-timer-start!
    uv-timer-stop!
    uv-timer-again!
    uv-timer-set-repeat!
    uv-timer-get-repeat
    uv-timer-get-due-in

    ;; Async work (high-level)
    async-work
    async-work/error
    loop-threadpool
    loop-set-threadpool!

    ;; Async handle (low-level)
    uv-async-init
    uv-async-send!

    ;; Thread pool (low-level)
    make-threadpool
    threadpool-start!
    threadpool-shutdown!
    threadpool-submit!
    make-task

    ;; 错误处理
    &uv-error
    uv-error?
    uv-error-code
    uv-error-name
    uv-error-operation
    )
  (import (chezscheme)
          (chez-async high-level event-loop)
          (chez-async high-level async-work)
          (chez-async low-level handle-base)
          (chez-async low-level timer)
          (chez-async low-level async)
          (chez-async low-level threadpool)
          (chez-async ffi errors))

) ; end library
