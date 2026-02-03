;;; ffi/async.ss - Async handle FFI bindings
;;;
;;; Provides FFI bindings for uv_async_t

(library (chez-async ffi async)
  (export
    %ffi-uv-async-init
    %ffi-uv-async-send
    )
  (import (chezscheme)
          (chez-async internal macros))

  ;; ========================================
  ;; Async API
  ;; ========================================

  (define-ffi %ffi-uv-async-init "uv_async_init" (void* void* void*) int)
  (define-ffi %ffi-uv-async-send "uv_async_send" (void*) int)

) ; end library
