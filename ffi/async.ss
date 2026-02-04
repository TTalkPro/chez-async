;;; ffi/async.ss - 异步句柄 FFI 绑定
;;;
;;; 本模块提供 libuv 异步句柄（uv_async_t）的 FFI 绑定。
;;;
;;; 异步句柄用于跨线程通信，是唯一线程安全的句柄类型。
;;; 典型用例：
;;; - 从工作线程通知主事件循环
;;; - 实现线程池与事件循环的协作
;;; - 异步任务完成通知
;;;
;;; 注意：
;;; - uv_async_send 可以从任何线程调用
;;; - 多次调用 uv_async_send 可能只触发一次回调（合并）
;;; - 回调总是在事件循环线程中执行

(library (chez-async ffi async)
  (export
    %ffi-uv-async-init    ; 初始化异步句柄
    %ffi-uv-async-send    ; 发送异步通知
    )
  (import (chezscheme)
          (chez-async ffi lib)
          (chez-async internal macros))

  ;; 确保 libuv 库在此模块范围内已加载
  (define _libuv-loaded (ensure-libuv-loaded))

  ;; ========================================
  ;; 异步句柄 API
  ;; ========================================

  ;; int uv_async_init(uv_loop_t* loop, uv_async_t* async, uv_async_cb async_cb)
  ;; 初始化异步句柄
  ;; 参数：
  ;;   loop     - 事件循环
  ;;   async    - 异步句柄指针
  ;;   async_cb - 接收通知时的回调函数
  ;; 返回值：0 表示成功，负数表示错误
  ;; 注意：初始化后句柄立即开始活动，会阻止事件循环退出
  (define-ffi %ffi-uv-async-init "uv_async_init" (void* void* void*) int)

  ;; int uv_async_send(uv_async_t* async)
  ;; 向异步句柄发送通知
  ;; 参数：
  ;;   async - 异步句柄指针
  ;; 返回值：0 表示成功，负数表示错误
  ;; 特性：
  ;;   - 此函数是线程安全的，可以从任何线程调用
  ;;   - 如果在回调执行前多次调用，回调可能只执行一次
  ;;   - 唤醒事件循环（如果它正在等待）
  (define-ffi %ffi-uv-async-send "uv_async_send" (void*) int)

) ; end library
