;;; low-level/fs-event.ss - FS Event 句柄低层封装
;;;
;;; 文件系统事件监视，用于监控文件或目录的变化。
;;;
;;; 典型用例：
;;; - 监视配置文件变化并自动重载
;;; - 监视目录中的新文件
;;; - 实现文件同步工具
;;;
;;; 注意：
;;; - 行为因操作系统而异
;;; - 某些系统可能合并多个事件
;;; - 递归监视在某些平台上不支持

(library (chez-async low-level fs-event)
  (export
    uv-fs-event-init
    uv-fs-event-start!
    uv-fs-event-stop!
    uv-fs-event-getpath

    ;; 事件类型常量
    UV_RENAME
    UV_CHANGE

    ;; 标志常量
    UV_FS_EVENT_WATCH_ENTRY
    UV_FS_EVENT_STAT
    UV_FS_EVENT_RECURSIVE
    )
  (import (chezscheme)
          (chez-async ffi errors)
          (chez-async ffi handles)
          (chez-async ffi fs-event)
          (chez-async ffi callbacks)
          (chez-async low-level handle-base)
          (chez-async internal loop-registry)
          (chez-async internal macros)
          (chez-async internal callback-registry)
          (chez-async internal utils))

  ;; ========================================
  ;; FS Event 回调处理
  ;; ========================================

  (define-registered-callback get-fs-event-callback CALLBACK-FS-EVENT
    (lambda ()
      (make-fs-event-callback
        (lambda (wrapper filename events status)
          (let ([user-callback (handle-data wrapper)])
            (when (and user-callback (procedure? user-callback))
              (user-callback wrapper filename events status)))))))

  ;; ========================================
  ;; FS Event 句柄操作
  ;; ========================================

  (define-handle-init uv-fs-event-init fs-event
    %ffi-uv-fs-event-size %ffi-uv-fs-event-init
    uv-loop-ptr allocate-handle make-handle)

  (define uv-fs-event-start!
    (case-lambda
      [(fs-event path callback)
       (uv-fs-event-start! fs-event path callback 0)]
      [(fs-event path callback flags)
       "开始监视文件或目录
        fs-event: fs-event 句柄包装器
        path: 要监视的路径
        callback: 回调函数 (lambda (fs-event filename events status) ...)
          filename: 变化的文件名（可能为 #f）
          events: 事件类型（UV_RENAME, UV_CHANGE）
          status: 0 成功，负值表示错误
        flags: 监视标志（可选，默认 0）
          UV_FS_EVENT_WATCH_ENTRY - 监视目录条目本身
          UV_FS_EVENT_STAT - 使用 stat 检测变化
          UV_FS_EVENT_RECURSIVE - 递归监视（部分平台支持）"
       (when (handle-closed? fs-event)
         (error 'uv-fs-event-start! "fs-event handle is closed"))
       ;; 保存用户回调
       (let ([old-data (handle-data fs-event)])
         (when old-data (unlock-object old-data)))
       (handle-data-set! fs-event callback)
       (when callback (lock-object callback))
       ;; 启动监视
       (with-uv-check uv-fs-event-start
         (%ffi-uv-fs-event-start (handle-ptr fs-event)
                                  (get-fs-event-callback)
                                  path
                                  flags))]))

  (define-handle-stop! uv-fs-event-stop! %ffi-uv-fs-event-stop
    handle-ptr handle-data handle-data-set! handle-closed?)

  (define (uv-fs-event-getpath fs-event)
    "获取被监视的路径
     fs-event: fs-event 句柄包装器
     返回: 路径字符串"
    (when (handle-closed? fs-event)
      (error 'uv-fs-event-getpath "fs-event handle is closed"))
    (let* ([buffer-size 1024]
           [buffer (foreign-alloc buffer-size)]
           [size-ptr (foreign-alloc (foreign-sizeof 'size_t))])
      (foreign-set! 'size_t size-ptr 0 buffer-size)
      (let ([result (%ffi-uv-fs-event-getpath (handle-ptr fs-event)
                                               buffer
                                               size-ptr)])
        (let ([path (if (= result 0)
                        (get-string-from-c-ptr buffer)
                        #f)])
          (foreign-free buffer)
          (foreign-free size-ptr)
          (when (< result 0)
            (raise-uv-error 'uv-fs-event-getpath result))
          path))))

  ;; 辅助函数
  (define (get-string-from-c-ptr ptr)
    "从 C 字符串指针获取 Scheme 字符串"
    (let loop ([i 0] [chars '()])
      (let ([byte (foreign-ref 'unsigned-8 ptr i)])
        (if (= byte 0)
            (list->string (reverse chars))
            (loop (+ i 1) (cons (integer->char byte) chars))))))

) ; end library
