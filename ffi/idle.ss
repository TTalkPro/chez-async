;;; ffi/idle.ss - Idle 句柄 FFI 绑定
;;;
;;; Idle 句柄在事件循环空闲时运行回调（每次迭代都运行，如果没有其他事件）。
;;; 注意：Idle 句柄会阻止事件循环进入睡眠状态，因此应谨慎使用。

(library (chez-async ffi idle)
  (export
    ;; 句柄操作
    %ffi-uv-idle-init
    %ffi-uv-idle-start
    %ffi-uv-idle-stop
    )
  (import (chezscheme)
          (chez-async ffi lib)
          (chez-async internal macros))

  ;; 确保 libuv 库已加载
  (define _libuv-loaded (ensure-libuv-loaded))

  ;; ========================================
  ;; Idle 句柄操作
  ;; ========================================

  ;; int uv_idle_init(uv_loop_t* loop, uv_idle_t* idle)
  ;; 初始化 idle 句柄
  (define-ffi %ffi-uv-idle-init "uv_idle_init" (void* void*) int)

  ;; int uv_idle_start(uv_idle_t* idle, uv_idle_cb cb)
  ;; 启动 idle 句柄，在每次事件循环迭代时调用回调
  ;; 回调签名: void (*uv_idle_cb)(uv_idle_t* handle)
  (define-ffi %ffi-uv-idle-start "uv_idle_start" (void* void*) int)

  ;; int uv_idle_stop(uv_idle_t* idle)
  ;; 停止 idle 句柄
  (define-ffi %ffi-uv-idle-stop "uv_idle_stop" (void*) int)

) ; end library
