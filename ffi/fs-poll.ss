;;; ffi/fs-poll.ss - FS Poll 句柄 FFI 绑定
;;;
;;; FS Poll 句柄通过定期调用 stat() 来检测文件变化。
;;; 与 FS Event 不同，FS Poll 不依赖操作系统的文件通知机制，
;;; 而是周期性地轮询文件状态。
;;;
;;; 使用场景：
;;; - 在不支持 inotify/FSEvents 的网络文件系统上
;;; - 需要跨平台一致行为时
;;; - 监视通过 FS Event 无法可靠检测的变化

(library (chez-async ffi fs-poll)
  (export
    ;; 句柄操作
    %ffi-uv-fs-poll-init
    %ffi-uv-fs-poll-start
    %ffi-uv-fs-poll-stop
    %ffi-uv-fs-poll-getpath
    )
  (import (chezscheme)
          (chez-async ffi lib)
          (chez-async internal macros))

  ;; 确保 libuv 库已加载
  (define _libuv-loaded (ensure-libuv-loaded))

  ;; ========================================
  ;; FS Poll 句柄操作
  ;; ========================================

  ;; int uv_fs_poll_init(uv_loop_t* loop, uv_fs_poll_t* handle)
  ;; 初始化 fs_poll 句柄
  (define-ffi %ffi-uv-fs-poll-init "uv_fs_poll_init" (void* void*) int)

  ;; int uv_fs_poll_start(uv_fs_poll_t* handle, uv_fs_poll_cb poll_cb,
  ;;                      const char* path, unsigned int interval)
  ;; 开始轮询文件状态
  ;; interval: 轮询间隔（毫秒）
  ;; 回调签名: void (*uv_fs_poll_cb)(uv_fs_poll_t* handle,
  ;;                                  int status,
  ;;                                  const uv_stat_t* prev,
  ;;                                  const uv_stat_t* curr)
  (define-ffi %ffi-uv-fs-poll-start "uv_fs_poll_start"
    (void* void* string unsigned-int) int)

  ;; int uv_fs_poll_stop(uv_fs_poll_t* handle)
  ;; 停止轮询
  (define-ffi %ffi-uv-fs-poll-stop "uv_fs_poll_stop" (void*) int)

  ;; int uv_fs_poll_getpath(uv_fs_poll_t* handle, char* buffer, size_t* size)
  ;; 获取被轮询的路径
  (define-ffi %ffi-uv-fs-poll-getpath "uv_fs_poll_getpath"
    (void* void* void*) int)

) ; end library
