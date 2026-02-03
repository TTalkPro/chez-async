;;; ffi/core.ss - 核心 API（事件循环和版本）
;;;
;;; 提供 libuv 核心功能的 FFI 绑定

(library (chez-async ffi core)
  (export
    ;; 事件循环
    %ffi-uv-loop-init
    %ffi-uv-loop-close
    %ffi-uv-run
    %ffi-uv-stop
    %ffi-uv-loop-alive
    %ffi-uv-default-loop

    ;; 版本信息
    %ffi-uv-version
    %ffi-uv-version-string

    ;; 事件循环大小（用于分配内存）
    %ffi-uv-loop-size
    )
  (import (chezscheme)
          (chez-async ffi types)
          (chez-async internal macros))

  ;; ========================================
  ;; 加载 libuv 共享库
  ;; ========================================

  (define libuv-lib
    (load-shared-object "libuv.so.1"))

  ;; ========================================
  ;; 事件循环 API
  ;; ========================================

  (define-ffi %ffi-uv-loop-init "uv_loop_init" (void*) int)
  (define-ffi %ffi-uv-loop-close "uv_loop_close" (void*) int)
  (define-ffi %ffi-uv-run "uv_run" (void* int) int)
  (define-ffi %ffi-uv-stop "uv_stop" (void*) void)
  (define-ffi %ffi-uv-loop-alive "uv_loop_alive" (void*) int)
  (define-ffi %ffi-uv-default-loop "uv_default_loop" () void*)

  ;; ========================================
  ;; 版本信息
  ;; ========================================

  (define-ffi %ffi-uv-version "uv_version" () unsigned)
  (define-ffi %ffi-uv-version-string "uv_version_string" () string)

  ;; ========================================
  ;; 辅助函数
  ;; ========================================

  (define-ffi %ffi-uv-loop-size "uv_loop_size" () size_t)

) ; end library
