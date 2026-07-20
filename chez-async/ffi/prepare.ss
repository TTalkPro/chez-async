;;; ffi/prepare.ss - Prepare 句柄 FFI 绑定
;;;
;;; Prepare 句柄在每次事件循环迭代的 I/O 轮询前运行回调。
;;; 常用于在轮询前准备数据或状态。

(library (chez-async ffi prepare)
  (export
    ;; 句柄操作
    %ffi-uv-prepare-init
    %ffi-uv-prepare-start
    %ffi-uv-prepare-stop
    )
  (import (chezscheme)
          (chez-async ffi lib)
          (chez-async internal macros))

  ;; 确保 libuv 库已加载
  (define _libuv-loaded (ensure-libuv-loaded))

  ;; ========================================
  ;; Prepare 句柄操作
  ;; ========================================

  ;; int uv_prepare_init(uv_loop_t* loop, uv_prepare_t* prepare)
  ;; 初始化 prepare 句柄
  (define-ffi %ffi-uv-prepare-init "uv_prepare_init" (void* void*) int)

  ;; int uv_prepare_start(uv_prepare_t* prepare, uv_prepare_cb cb)
  ;; 启动 prepare 句柄，在每次 I/O 轮询前调用回调
  ;; 回调签名: void (*uv_prepare_cb)(uv_prepare_t* handle)
  (define-ffi %ffi-uv-prepare-start "uv_prepare_start" (void* void*) int)

  ;; int uv_prepare_stop(uv_prepare_t* prepare)
  ;; 停止 prepare 句柄
  (define-ffi %ffi-uv-prepare-stop "uv_prepare_stop" (void*) int)

) ; end library
