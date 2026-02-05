;;; low-level/fs-poll.ss - FS Poll 句柄低层封装
;;;
;;; 文件系统轮询，通过周期性调用 stat() 检测文件变化。
;;;
;;; 与 FS Event 的区别：
;;; - FS Event: 使用操作系统的文件通知机制（inotify, FSEvents 等）
;;; - FS Poll: 周期性轮询，不依赖操作系统机制
;;;
;;; FS Poll 的优点：
;;; - 在网络文件系统上更可靠
;;; - 跨平台行为一致
;;;
;;; FS Poll 的缺点：
;;; - CPU 和 I/O 开销较大
;;; - 延迟取决于轮询间隔

(library (chez-async low-level fs-poll)
  (export
    uv-fs-poll-init
    uv-fs-poll-start!
    uv-fs-poll-stop!
    uv-fs-poll-getpath
    )
  (import (chezscheme)
          (chez-async ffi errors)
          (chez-async ffi handles)
          (chez-async ffi fs-poll)
          (chez-async ffi callbacks)
          (chez-async low-level handle-base)
          (chez-async internal loop-registry)
          (chez-async internal macros)
          (chez-async internal callback-registry)
          (chez-async internal utils))

  ;; ========================================
  ;; FS Poll 回调处理
  ;; ========================================

  (define-registered-callback get-fs-poll-callback CALLBACK-FS-POLL
    (lambda ()
      (make-fs-poll-callback
        (lambda (wrapper status prev-stat curr-stat)
          (let ([user-callback (handle-data wrapper)])
            (when (and user-callback (procedure? user-callback))
              ;; 传递原始指针，用户可以用 low-level/fs.ss 中的函数解析
              (user-callback wrapper status prev-stat curr-stat)))))))

  ;; ========================================
  ;; FS Poll 句柄操作
  ;; ========================================

  (define-handle-init uv-fs-poll-init fs-poll
    %ffi-uv-fs-poll-size %ffi-uv-fs-poll-init
    uv-loop-ptr allocate-handle make-handle)

  (define (uv-fs-poll-start! fs-poll path callback interval)
    "开始轮询文件状态
     fs-poll: fs-poll 句柄包装器
     path: 要监视的文件路径
     callback: 回调函数 (lambda (fs-poll status prev-stat curr-stat) ...)
       status: 0 成功，负值表示错误（如文件不存在）
       prev-stat: 上一次的 stat 信息指针（可用 fs 模块函数解析）
       curr-stat: 当前的 stat 信息指针
     interval: 轮询间隔（毫秒）"
    (when (handle-closed? fs-poll)
      (error 'uv-fs-poll-start! "fs-poll handle is closed"))
    ;; 保存用户回调
    (let ([old-data (handle-data fs-poll)])
      (when old-data (unlock-object old-data)))
    (handle-data-set! fs-poll callback)
    (when callback (lock-object callback))
    ;; 启动轮询
    (with-uv-check uv-fs-poll-start
      (%ffi-uv-fs-poll-start (handle-ptr fs-poll)
                              (get-fs-poll-callback)
                              path
                              interval)))

  (define-handle-stop! uv-fs-poll-stop! %ffi-uv-fs-poll-stop
    handle-ptr handle-data handle-data-set! handle-closed?)

  (define (uv-fs-poll-getpath fs-poll)
    "获取被轮询的路径
     fs-poll: fs-poll 句柄包装器
     返回: 路径字符串"
    (when (handle-closed? fs-poll)
      (error 'uv-fs-poll-getpath "fs-poll handle is closed"))
    (let* ([buffer-size 1024]
           [buffer (foreign-alloc buffer-size)]
           [size-ptr (foreign-alloc (foreign-sizeof 'size_t))])
      (foreign-set! 'size_t size-ptr 0 buffer-size)
      (let ([result (%ffi-uv-fs-poll-getpath (handle-ptr fs-poll)
                                              buffer
                                              size-ptr)])
        (let ([path (if (= result 0)
                        (get-string-from-c-ptr buffer)
                        #f)])
          (foreign-free buffer)
          (foreign-free size-ptr)
          (when (< result 0)
            (raise-uv-error 'uv-fs-poll-getpath result))
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
