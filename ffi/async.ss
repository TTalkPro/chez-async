;;; ffi/async.ss - Async handle FFI bindings
;;;
;;; Provides FFI bindings for uv_async_t

(library (chez-async ffi async)
  (export
    %ffi-uv-async-init
    %ffi-uv-async-send
    )
  (import (chezscheme))

  ;; ========================================
  ;; Async API
  ;; ========================================

  ;; int uv_async_init(uv_loop_t* loop, uv_async_t* async, uv_async_cb cb)
  (define %ffi-uv-async-init
    (foreign-procedure "uv_async_init" (void* void* void*) int))

  ;; int uv_async_send(uv_async_t* async)
  (define %ffi-uv-async-send
    (foreign-procedure "uv_async_send" (void*) int))

) ; end library
