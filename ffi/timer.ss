;;; ffi/timer.ss - Timer FFI 绑定
;;;
;;; 提供 libuv timer 的 FFI 接口

(library (chez-async ffi timer)
  (export
    %ffi-uv-timer-init
    %ffi-uv-timer-start
    %ffi-uv-timer-stop
    %ffi-uv-timer-again
    %ffi-uv-timer-set-repeat
    %ffi-uv-timer-get-repeat
    %ffi-uv-timer-get-due-in
    )
  (import (chezscheme)
          (chez-async internal macros))

  ;; ========================================
  ;; Timer API
  ;; ========================================

  (define-ffi %ffi-uv-timer-init "uv_timer_init" (void* void*) int)
  (define-ffi %ffi-uv-timer-start "uv_timer_start" (void* void* unsigned-64 unsigned-64) int)
  (define-ffi %ffi-uv-timer-stop "uv_timer_stop" (void*) int)
  (define-ffi %ffi-uv-timer-again "uv_timer_again" (void*) int)
  (define-ffi %ffi-uv-timer-set-repeat "uv_timer_set_repeat" (void* unsigned-64) void)
  (define-ffi %ffi-uv-timer-get-repeat "uv_timer_get_repeat" (void*) unsigned-64)
  (define-ffi %ffi-uv-timer-get-due-in "uv_timer_get_due_in" (void*) unsigned-64)

) ; end library
