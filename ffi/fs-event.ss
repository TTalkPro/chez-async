;;; ffi/fs-event.ss - FS Event 句柄 FFI 绑定
;;;
;;; FS Event 句柄用于监视文件或目录的变化。
;;; 当文件被修改、重命名、删除时会触发回调。
;;;
;;; 注意：
;;; - 具体支持的事件类型和行为因操作系统而异
;;; - Linux 使用 inotify，macOS 使用 FSEvents，Windows 使用 ReadDirectoryChangesW
;;; - 某些系统可能不支持递归监视

(library (chez-async ffi fs-event)
  (export
    ;; 句柄操作
    %ffi-uv-fs-event-init
    %ffi-uv-fs-event-start
    %ffi-uv-fs-event-stop
    %ffi-uv-fs-event-getpath

    ;; 事件类型常量
    UV_RENAME               ; 文件重命名
    UV_CHANGE               ; 文件内容变化

    ;; 标志常量
    UV_FS_EVENT_WATCH_ENTRY ; 监视目录本身
    UV_FS_EVENT_STAT        ; 使用 stat 而非 inotify
    UV_FS_EVENT_RECURSIVE   ; 递归监视（某些平台支持）
    )
  (import (chezscheme)
          (chez-async ffi lib)
          (chez-async internal macros))

  ;; 确保 libuv 库已加载
  (define _libuv-loaded (ensure-libuv-loaded))

  ;; ========================================
  ;; 事件类型常量
  ;; ========================================

  ;; uv_fs_event
  (define UV_RENAME 1)      ; 文件被重命名
  (define UV_CHANGE 2)      ; 文件内容变化

  ;; ========================================
  ;; 标志常量
  ;; ========================================

  ;; uv_fs_event_flags
  (define UV_FS_EVENT_WATCH_ENTRY 1)  ; 监视目录条目本身
  (define UV_FS_EVENT_STAT        2)  ; 使用 stat 检测变化
  (define UV_FS_EVENT_RECURSIVE   4)  ; 递归监视子目录

  ;; ========================================
  ;; FS Event 句柄操作
  ;; ========================================

  ;; int uv_fs_event_init(uv_loop_t* loop, uv_fs_event_t* handle)
  ;; 初始化 fs_event 句柄
  (define-ffi %ffi-uv-fs-event-init "uv_fs_event_init" (void* void*) int)

  ;; int uv_fs_event_start(uv_fs_event_t* handle, uv_fs_event_cb cb,
  ;;                       const char* path, unsigned int flags)
  ;; 开始监视指定路径
  ;; 回调签名: void (*uv_fs_event_cb)(uv_fs_event_t* handle,
  ;;                                   const char* filename,
  ;;                                   int events, int status)
  (define-ffi %ffi-uv-fs-event-start "uv_fs_event_start"
    (void* void* string unsigned-int) int)

  ;; int uv_fs_event_stop(uv_fs_event_t* handle)
  ;; 停止监视
  (define-ffi %ffi-uv-fs-event-stop "uv_fs_event_stop" (void*) int)

  ;; int uv_fs_event_getpath(uv_fs_event_t* handle, char* buffer, size_t* size)
  ;; 获取被监视的路径
  ;; buffer: 输出缓冲区
  ;; size: 输入/输出缓冲区大小
  ;; 返回 0 成功，UV_ENOBUFS 如果缓冲区太小
  (define-ffi %ffi-uv-fs-event-getpath "uv_fs_event_getpath"
    (void* void* void*) int)

) ; end library
