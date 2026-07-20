;;; ffi/timer.ss - 定时器 FFI 绑定
;;;
;;; 本模块提供 libuv 定时器句柄（uv_timer_t）的 FFI 绑定。
;;;
;;; 定时器用于在指定延迟后或按固定间隔执行回调。
;;; 典型用例：
;;; - 超时处理
;;; - 定期任务（心跳、轮询）
;;; - 延迟执行
;;;
;;; 时间单位：毫秒（unsigned 64 位整数）

(library (chez-async ffi timer)
  (export
    %ffi-uv-timer-init        ; 初始化定时器
    %ffi-uv-timer-start       ; 启动定时器
    %ffi-uv-timer-stop        ; 停止定时器
    %ffi-uv-timer-again       ; 重新启动定时器
    %ffi-uv-timer-set-repeat  ; 设置重复间隔
    %ffi-uv-timer-get-repeat  ; 获取重复间隔
    %ffi-uv-timer-get-due-in  ; 获取距下次触发的时间
    )
  (import (chezscheme)
          (chez-async ffi lib)
          (chez-async internal macros))

  ;; 确保 libuv 库在此模块范围内已加载
  (define _libuv-loaded (ensure-libuv-loaded))

  ;; ========================================
  ;; 定时器 API
  ;; ========================================

  ;; int uv_timer_init(uv_loop_t* loop, uv_timer_t* handle)
  ;; 初始化定时器句柄
  ;; 返回值：0 表示成功
  (define-ffi %ffi-uv-timer-init "uv_timer_init" (void* void*) int)

  ;; int uv_timer_start(uv_timer_t* handle, uv_timer_cb cb,
  ;;                    uint64_t timeout, uint64_t repeat)
  ;; 启动定时器
  ;; 参数：
  ;;   handle  - 定时器句柄
  ;;   cb      - 回调函数
  ;;   timeout - 首次触发前的延迟（毫秒）
  ;;   repeat  - 重复间隔（毫秒），0 表示单次触发
  ;; 返回值：0 表示成功
  (define-ffi %ffi-uv-timer-start "uv_timer_start" (void* void* unsigned-64 unsigned-64) int)

  ;; int uv_timer_stop(uv_timer_t* handle)
  ;; 停止定时器
  ;; 停止后回调不会再被调用
  (define-ffi %ffi-uv-timer-stop "uv_timer_stop" (void*) int)

  ;; int uv_timer_again(uv_timer_t* handle)
  ;; 重新启动定时器
  ;; 如果定时器从未启动，返回 UV_EINVAL
  ;; 使用上次设置的 repeat 值作为 timeout
  (define-ffi %ffi-uv-timer-again "uv_timer_again" (void*) int)

  ;; void uv_timer_set_repeat(uv_timer_t* handle, uint64_t repeat)
  ;; 设置重复间隔（毫秒）
  ;; 立即生效，但不会影响当前正在等待的超时
  (define-ffi %ffi-uv-timer-set-repeat "uv_timer_set_repeat" (void* unsigned-64) void)

  ;; uint64_t uv_timer_get_repeat(const uv_timer_t* handle)
  ;; 获取当前的重复间隔（毫秒）
  (define-ffi %ffi-uv-timer-get-repeat "uv_timer_get_repeat" (void*) unsigned-64)

  ;; uint64_t uv_timer_get_due_in(const uv_timer_t* handle)
  ;; 获取距下次触发还有多少毫秒
  ;; 如果定时器未激活，返回 0
  (define-ffi %ffi-uv-timer-get-due-in "uv_timer_get_due_in" (void*) unsigned-64)

) ; end library
