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
  (import (chezscheme))

  ;; ========================================
  ;; Timer API
  ;; ========================================

  ;; int uv_timer_init(uv_loop_t* loop, uv_timer_t* handle)
  (define %ffi-uv-timer-init
    (foreign-procedure "uv_timer_init" (void* void*) int))

  ;; int uv_timer_start(uv_timer_t* handle, uv_timer_cb cb, uint64_t timeout, uint64_t repeat)
  (define %ffi-uv-timer-start
    (foreign-procedure "uv_timer_start" (void* void* unsigned-64 unsigned-64) int))

  ;; int uv_timer_stop(uv_timer_t* handle)
  (define %ffi-uv-timer-stop
    (foreign-procedure "uv_timer_stop" (void*) int))

  ;; int uv_timer_again(uv_timer_t* handle)
  (define %ffi-uv-timer-again
    (foreign-procedure "uv_timer_again" (void*) int))

  ;; void uv_timer_set_repeat(uv_timer_t* handle, uint64_t repeat)
  (define %ffi-uv-timer-set-repeat
    (foreign-procedure "uv_timer_set_repeat" (void* unsigned-64) void))

  ;; uint64_t uv_timer_get_repeat(const uv_timer_t* handle)
  (define %ffi-uv-timer-get-repeat
    (foreign-procedure "uv_timer_get_repeat" (void*) unsigned-64))

  ;; uint64_t uv_timer_get_due_in(const uv_timer_t* handle)
  (define %ffi-uv-timer-get-due-in
    (foreign-procedure "uv_timer_get_due_in" (void*) unsigned-64))

) ; end library
