;;; ffi/handles.ss - 句柄基础操作 FFI 绑定
;;;
;;; 本模块提供所有句柄类型通用操作的 FFI 绑定：
;;; - 关闭句柄
;;; - 引用计数管理
;;; - 状态查询
;;; - 各类型句柄大小查询
;;;
;;; 句柄（handle）是 libuv 中长生命周期对象的抽象，
;;; 包括 TCP、Timer、Async 等。所有句柄都有共同的基本操作。

(library (chez-async ffi handles)
  (export
    ;; 句柄通用操作
    %ffi-uv-close          ; 关闭句柄
    %ffi-uv-ref            ; 增加引用
    %ffi-uv-unref          ; 减少引用
    %ffi-uv-has-ref        ; 检查是否有引用
    %ffi-uv-is-active      ; 检查是否活动
    %ffi-uv-is-closing     ; 检查是否正在关闭
    %ffi-uv-handle-get-loop ; 获取句柄关联的事件循环

    ;; 句柄大小查询（用于内存分配）
    %ffi-uv-handle-size    ; 通用大小查询
    %ffi-uv-timer-size     ; Timer 句柄大小
    %ffi-uv-tcp-size       ; TCP 句柄大小
    %ffi-uv-udp-size       ; UDP 句柄大小
    %ffi-uv-pipe-size      ; Pipe 句柄大小
    %ffi-uv-tty-size       ; TTY 句柄大小
    %ffi-uv-poll-size      ; Poll 句柄大小
    %ffi-uv-signal-size    ; Signal 句柄大小
    %ffi-uv-process-size   ; Process 句柄大小
    %ffi-uv-async-size     ; Async 句柄大小
    %ffi-uv-prepare-size   ; Prepare 句柄大小
    %ffi-uv-check-size     ; Check 句柄大小
    %ffi-uv-idle-size      ; Idle 句柄大小
    %ffi-uv-fs-event-size  ; FS Event 句柄大小
    %ffi-uv-fs-poll-size   ; FS Poll 句柄大小
    )
  (import (chezscheme)
          (chez-async ffi lib)
          (chez-async ffi types)
          (chez-async internal macros))

  ;; 确保 libuv 库在此模块范围内已加载
  (define _libuv-loaded (ensure-libuv-loaded))

  ;; ========================================
  ;; 句柄通用操作
  ;; ========================================

  ;; void uv_close(uv_handle_t* handle, uv_close_cb close_cb)
  ;; 关闭句柄
  ;; close_cb 在句柄真正关闭后被调用
  ;; 注意：关闭是异步的，必须等待回调后才能释放内存
  (define-ffi %ffi-uv-close "uv_close" (void* void*) void)

  ;; void uv_ref(uv_handle_t* handle)
  ;; 增加句柄的引用计数
  ;; 有引用的句柄会阻止事件循环退出
  (define-ffi %ffi-uv-ref "uv_ref" (void*) void)

  ;; void uv_unref(uv_handle_t* handle)
  ;; 减少句柄的引用计数
  ;; 无引用的句柄不会阻止事件循环退出
  (define-ffi %ffi-uv-unref "uv_unref" (void*) void)

  ;; int uv_has_ref(const uv_handle_t* handle)
  ;; 检查句柄是否有引用
  ;; 返回值：非零表示有引用
  (define-ffi %ffi-uv-has-ref "uv_has_ref" (void*) int)

  ;; int uv_is_active(const uv_handle_t* handle)
  ;; 检查句柄是否活动（正在执行操作）
  ;; 返回值：非零表示活动
  (define-ffi %ffi-uv-is-active "uv_is_active" (void*) int)

  ;; int uv_is_closing(const uv_handle_t* handle)
  ;; 检查句柄是否正在关闭或已关闭
  ;; 返回值：非零表示正在/已关闭
  (define-ffi %ffi-uv-is-closing "uv_is_closing" (void*) int)

  ;; uv_loop_t* uv_handle_get_loop(const uv_handle_t* handle)
  ;; 获取句柄关联的事件循环
  ;; 返回值：事件循环指针
  (define-ffi %ffi-uv-handle-get-loop "uv_handle_get_loop" (void*) void*)

  ;; ========================================
  ;; 句柄大小查询
  ;; ========================================

  ;; size_t uv_handle_size(uv_handle_type type)
  ;; 获取指定类型句柄的大小（字节）
  ;; type 参数使用 uv_handle_type 枚举值
  (define-ffi %ffi-uv-handle-size "uv_handle_size" (int) size_t)

  ;; ========================================
  ;; 各类型句柄大小的便捷函数
  ;; ========================================
  ;;
  ;; 使用 define-handle-size-fn 宏消除重复代码
  ;; 每个函数返回对应句柄类型的大小（字节）

  ;; Timer 句柄大小
  (define-handle-size-fn %ffi-uv-timer-size timer
    %ffi-uv-handle-size uv-handle-type->int)

  ;; TCP 句柄大小
  (define-handle-size-fn %ffi-uv-tcp-size tcp
    %ffi-uv-handle-size uv-handle-type->int)

  ;; UDP 句柄大小
  (define-handle-size-fn %ffi-uv-udp-size udp
    %ffi-uv-handle-size uv-handle-type->int)

  ;; Pipe 句柄大小
  (define-handle-size-fn %ffi-uv-pipe-size named-pipe
    %ffi-uv-handle-size uv-handle-type->int)

  ;; TTY 句柄大小
  (define-handle-size-fn %ffi-uv-tty-size tty
    %ffi-uv-handle-size uv-handle-type->int)

  ;; Poll 句柄大小
  (define-handle-size-fn %ffi-uv-poll-size poll
    %ffi-uv-handle-size uv-handle-type->int)

  ;; Signal 句柄大小
  (define-handle-size-fn %ffi-uv-signal-size signal
    %ffi-uv-handle-size uv-handle-type->int)

  ;; Process 句柄大小
  (define-handle-size-fn %ffi-uv-process-size process
    %ffi-uv-handle-size uv-handle-type->int)

  ;; Async 句柄大小
  (define-handle-size-fn %ffi-uv-async-size async
    %ffi-uv-handle-size uv-handle-type->int)

  ;; Prepare 句柄大小
  (define-handle-size-fn %ffi-uv-prepare-size prepare
    %ffi-uv-handle-size uv-handle-type->int)

  ;; Check 句柄大小
  (define-handle-size-fn %ffi-uv-check-size check
    %ffi-uv-handle-size uv-handle-type->int)

  ;; Idle 句柄大小
  (define-handle-size-fn %ffi-uv-idle-size idle
    %ffi-uv-handle-size uv-handle-type->int)

  ;; FS Event 句柄大小
  (define-handle-size-fn %ffi-uv-fs-event-size fs-event
    %ffi-uv-handle-size uv-handle-type->int)

  ;; FS Poll 句柄大小
  (define-handle-size-fn %ffi-uv-fs-poll-size fs-poll
    %ffi-uv-handle-size uv-handle-type->int)

) ; end library
