;;; ffi/handles.ss - 句柄基础操作
;;;
;;; 提供所有句柄类型的通用操作

(library (chez-async ffi handles)
  (export
    ;; 句柄通用操作
    %ffi-uv-close
    %ffi-uv-ref
    %ffi-uv-unref
    %ffi-uv-has-ref
    %ffi-uv-is-active
    %ffi-uv-is-closing

    ;; 句柄大小查询（用于分配内存）
    %ffi-uv-handle-size
    %ffi-uv-timer-size
    %ffi-uv-tcp-size
    %ffi-uv-udp-size
    %ffi-uv-pipe-size
    %ffi-uv-tty-size
    %ffi-uv-poll-size
    %ffi-uv-signal-size
    %ffi-uv-process-size
    %ffi-uv-async-size
    %ffi-uv-prepare-size
    %ffi-uv-check-size
    %ffi-uv-idle-size
    )
  (import (chezscheme)
          (chez-async ffi types)
          (chez-async internal macros))

  ;; ========================================
  ;; 句柄通用操作
  ;; ========================================

  (define-ffi %ffi-uv-close "uv_close" (void* void*) void)
  (define-ffi %ffi-uv-ref "uv_ref" (void*) void)
  (define-ffi %ffi-uv-unref "uv_unref" (void*) void)
  (define-ffi %ffi-uv-has-ref "uv_has_ref" (void*) int)
  (define-ffi %ffi-uv-is-active "uv_is_active" (void*) int)
  (define-ffi %ffi-uv-is-closing "uv_is_closing" (void*) int)

  ;; ========================================
  ;; 句柄大小查询
  ;; ========================================

  (define-ffi %ffi-uv-handle-size "uv_handle_size" (int) size_t)

  ;; 便捷函数：获取特定句柄类型的大小
  (define (%ffi-uv-timer-size)
    (%ffi-uv-handle-size (uv-handle-type->int 'timer)))

  (define (%ffi-uv-tcp-size)
    (%ffi-uv-handle-size (uv-handle-type->int 'tcp)))

  (define (%ffi-uv-udp-size)
    (%ffi-uv-handle-size (uv-handle-type->int 'udp)))

  (define (%ffi-uv-pipe-size)
    (%ffi-uv-handle-size (uv-handle-type->int 'named-pipe)))

  (define (%ffi-uv-tty-size)
    (%ffi-uv-handle-size (uv-handle-type->int 'tty)))

  (define (%ffi-uv-poll-size)
    (%ffi-uv-handle-size (uv-handle-type->int 'poll)))

  (define (%ffi-uv-signal-size)
    (%ffi-uv-handle-size (uv-handle-type->int 'signal)))

  (define (%ffi-uv-process-size)
    (%ffi-uv-handle-size (uv-handle-type->int 'process)))

  (define (%ffi-uv-async-size)
    (%ffi-uv-handle-size (uv-handle-type->int 'async)))

  (define (%ffi-uv-prepare-size)
    (%ffi-uv-handle-size (uv-handle-type->int 'prepare)))

  (define (%ffi-uv-check-size)
    (%ffi-uv-handle-size (uv-handle-type->int 'check)))

  (define (%ffi-uv-idle-size)
    (%ffi-uv-handle-size (uv-handle-type->int 'idle)))

) ; end library
