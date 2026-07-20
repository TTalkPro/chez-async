;;; ffi/check.ss - Check 句柄 FFI 绑定
;;;
;;; Check 句柄在每次事件循环迭代的 I/O 轮询后运行回调。
;;; 常用于在轮询后处理结果或执行清理。

(library (chez-async ffi check)
  (export
    ;; 句柄操作
    %ffi-uv-check-init
    %ffi-uv-check-start
    %ffi-uv-check-stop
    )
  (import (chezscheme)
          (chez-async ffi lib)
          (chez-async internal macros))

  ;; 确保 libuv 库已加载
  (define _libuv-loaded (ensure-libuv-loaded))

  ;; ========================================
  ;; Check 句柄操作
  ;; ========================================

  ;; int uv_check_init(uv_loop_t* loop, uv_check_t* check)
  ;; 初始化 check 句柄
  (define-ffi %ffi-uv-check-init "uv_check_init" (void* void*) int)

  ;; int uv_check_start(uv_check_t* check, uv_check_cb cb)
  ;; 启动 check 句柄，在每次 I/O 轮询后调用回调
  ;; 回调签名: void (*uv_check_cb)(uv_check_t* handle)
  (define-ffi %ffi-uv-check-start "uv_check_start" (void* void*) int)

  ;; int uv_check_stop(uv_check_t* check)
  ;; 停止 check 句柄
  (define-ffi %ffi-uv-check-stop "uv_check_stop" (void*) int)

) ; end library
