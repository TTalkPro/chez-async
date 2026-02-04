;;; ffi/poll.ss - Poll (文件描述符轮询) FFI 绑定
;;;
;;; 本模块提供 libuv Poll 句柄（uv_poll_t）的 FFI 绑定。
;;;
;;; Poll 用于监视任意文件描述符的可读/可写状态，适用于：
;;; - 与不使用 libuv 的库集成
;;; - 监视非 libuv 管理的套接字
;;; - 通用文件描述符事件通知
;;;
;;; 注意：
;;; - 不要在同一个 fd 上同时使用 poll 和其他 libuv 句柄
;;; - 在 Windows 上只支持套接字
;;; - 对于常规文件，轮询总是返回可读

(library (chez-async ffi poll)
  (export
    ;; 初始化
    %ffi-uv-poll-init            ; 初始化 Poll 句柄
    %ffi-uv-poll-init-socket     ; 从套接字初始化（Windows）

    ;; 轮询控制
    %ffi-uv-poll-start           ; 开始轮询
    %ffi-uv-poll-stop            ; 停止轮询
    )
  (import (chezscheme)
          (chez-async ffi lib)
          (chez-async internal macros))

  ;; 确保 libuv 库在此模块范围内已加载
  (define _libuv-loaded (ensure-libuv-loaded))

  ;; ========================================
  ;; Poll 初始化
  ;; ========================================

  ;; int uv_poll_init(uv_loop_t* loop, uv_poll_t* handle, int fd)
  ;; 初始化 Poll 句柄
  ;; fd: 要监视的文件描述符
  (define-ffi %ffi-uv-poll-init "uv_poll_init" (void* void* int) int)

  ;; int uv_poll_init_socket(uv_loop_t* loop, uv_poll_t* handle, uv_os_sock_t socket)
  ;; 从套接字初始化 Poll 句柄（主要用于 Windows）
  (define-ffi %ffi-uv-poll-init-socket "uv_poll_init_socket" (void* void* int) int)

  ;; ========================================
  ;; Poll 控制
  ;; ========================================

  ;; int uv_poll_start(uv_poll_t* handle, int events, uv_poll_cb cb)
  ;; 开始轮询指定事件
  ;; events: UV_READABLE, UV_WRITABLE, UV_DISCONNECT 的组合
  ;; cb: void (*uv_poll_cb)(uv_poll_t* handle, int status, int events)
  (define-ffi %ffi-uv-poll-start "uv_poll_start" (void* int void*) int)

  ;; int uv_poll_stop(uv_poll_t* handle)
  ;; 停止轮询
  (define-ffi %ffi-uv-poll-stop "uv_poll_stop" (void*) int)

) ; end library
