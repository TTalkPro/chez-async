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
          (chez-async ffi types))

  ;; ========================================
  ;; 加载 libuv 共享库
  ;; ========================================

  (define libuv-lib
    (load-shared-object "libuv.so.1"))

  ;; ========================================
  ;; 事件循环 API
  ;; ========================================

  ;; int uv_loop_init(uv_loop_t* loop)
  (define %ffi-uv-loop-init
    (foreign-procedure "uv_loop_init" (void*) int))

  ;; int uv_loop_close(uv_loop_t* loop)
  (define %ffi-uv-loop-close
    (foreign-procedure "uv_loop_close" (void*) int))

  ;; int uv_run(uv_loop_t* loop, uv_run_mode mode)
  (define %ffi-uv-run
    (foreign-procedure "uv_run" (void* int) int))

  ;; void uv_stop(uv_loop_t* loop)
  (define %ffi-uv-stop
    (foreign-procedure "uv_stop" (void*) void))

  ;; int uv_loop_alive(const uv_loop_t* loop)
  (define %ffi-uv-loop-alive
    (foreign-procedure "uv_loop_alive" (void*) int))

  ;; uv_loop_t* uv_default_loop(void)
  (define %ffi-uv-default-loop
    (foreign-procedure "uv_default_loop" () void*))

  ;; ========================================
  ;; 版本信息
  ;; ========================================

  ;; unsigned int uv_version(void)
  (define %ffi-uv-version
    (foreign-procedure "uv_version" () unsigned))

  ;; const char* uv_version_string(void)
  (define %ffi-uv-version-string
    (foreign-procedure "uv_version_string" () string))

  ;; ========================================
  ;; 辅助函数
  ;; ========================================

  ;; size_t uv_loop_size(void)
  (define %ffi-uv-loop-size
    (foreign-procedure "uv_loop_size" () size_t))

) ; end library
