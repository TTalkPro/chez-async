;;; low-level/pipe.ss - Pipe 低层封装
;;;
;;; 提供 Pipe（命名管道）的高层封装
;;;
;;; Pipe 用于进程间通信（IPC），支持：
;;; - Unix domain socket
;;; - Windows named pipe
;;; - 文件描述符传递（IPC 模式）

(library (chez-async low-level pipe)
  (export
    ;; Pipe 创建
    uv-pipe-init
    uv-pipe-open

    ;; Pipe 服务器
    uv-pipe-bind
    uv-pipe-listen
    uv-pipe-accept

    ;; Pipe 客户端
    uv-pipe-connect

    ;; 地址信息
    uv-pipe-getsockname
    uv-pipe-getpeername

    ;; 配置
    uv-pipe-pending-instances!
    uv-pipe-chmod!

    ;; IPC 相关
    uv-pipe-pending-count
    uv-pipe-pending-type

    ;; Stream 操作（从 stream 模块重新导出）
    uv-read-start!
    uv-read-stop!
    uv-write!
    uv-try-write
    uv-shutdown!
    uv-stream-readable?
    uv-stream-writable?
    )
  (import (chezscheme)
          (chez-async ffi types)  ; includes UV_READABLE, UV_WRITABLE
          (chez-async ffi errors)
          (chez-async ffi handles)
          (chez-async ffi pipe)
          (chez-async ffi requests)
          (chez-async ffi callbacks)
          (chez-async low-level handle-base)
          (chez-async low-level request-base)
          (chez-async low-level stream)
          (chez-async high-level event-loop)
          (chez-async internal macros)
          (chez-async internal callback-registry))

  ;; ========================================
  ;; 全局 Connect 回调（复用 TCP 的）
  ;; ========================================

  (define-registered-callback get-connect-callback CALLBACK-CONNECT
    (lambda ()
      (make-connect-callback
        (lambda (req-wrapper status)
          (let ([user-callback (uv-request-wrapper-scheme-callback req-wrapper)]
                [pipe-handle (uv-request-wrapper-scheme-data req-wrapper)])
            ;; 调用用户回调
            (when user-callback
              (if (< status 0)
                  (user-callback pipe-handle (make-uv-error status (%ffi-uv-err-name status) 'pipe-connect))
                  (user-callback pipe-handle #f)))
            ;; 清理请求
            (cleanup-request-wrapper! req-wrapper))))))

  ;; ========================================
  ;; Pipe 创建
  ;; ========================================

  (define uv-pipe-init
    (case-lambda
      [(loop)
       (uv-pipe-init loop #f)]
      [(loop ipc?)
       "创建 Pipe 句柄
        loop: 事件循环
        ipc?: 是否用于 IPC（可传递文件描述符）"
       (let* ([size (%ffi-uv-pipe-size)]
              [ptr (allocate-handle size)]
              [loop-ptr (uv-loop-ptr loop)])
         (with-uv-check/cleanup uv-pipe-init
           (%ffi-uv-pipe-init loop-ptr ptr (if ipc? 1 0))
           (lambda () (foreign-free ptr)))
         (make-handle ptr 'pipe loop))]))

  (define (uv-pipe-open pipe fd)
    "打开已存在的文件描述符作为 Pipe 句柄
     pipe: Pipe 句柄
     fd: 文件描述符"
    (when (handle-closed? pipe)
      (error 'uv-pipe-open "pipe handle is closed"))
    (with-uv-check uv-pipe-open
      (%ffi-uv-pipe-open (handle-ptr pipe) fd)))

  ;; ========================================
  ;; Pipe 服务器
  ;; ========================================

  (define (uv-pipe-bind pipe name)
    "绑定 Pipe 到指定路径
     pipe: Pipe 句柄
     name: 路径（Unix: 文件路径, Windows: \\\\.\\.\\pipe\\name）"
    (when (handle-closed? pipe)
      (error 'uv-pipe-bind "pipe handle is closed"))
    (with-uv-check uv-pipe-bind
      (%ffi-uv-pipe-bind (handle-ptr pipe) name)))

  (define (uv-pipe-listen pipe backlog callback)
    "监听传入连接
     pipe: Pipe 句柄（需要先绑定）
     backlog: 等待队列长度
     callback: 回调函数 (lambda (server error-or-#f) ...)"
    (uv-listen! pipe backlog callback))

  (define (uv-pipe-accept server)
    "接受传入的连接，返回新的 Pipe 句柄
     server: 服务器 Pipe 句柄"
    (when (handle-closed? server)
      (error 'uv-pipe-accept "server pipe handle is closed"))
    ;; 创建新的 Pipe 句柄来接受连接
    (let ([client (uv-pipe-init (handle-loop server))])
      (guard (e [else (uv-handle-close! client) (raise e)])
        (uv-accept! server client))
      client))

  ;; ========================================
  ;; Pipe 客户端
  ;; ========================================

  (define (uv-pipe-connect pipe name callback)
    "连接到指定路径的 Pipe
     pipe: Pipe 句柄
     name: 路径
     callback: 回调函数 (lambda (pipe error-or-#f) ...)"
    (when (handle-closed? pipe)
      (error 'uv-pipe-connect "pipe handle is closed"))
    ;; 分配连接请求
    (let* ([req-size (%ffi-uv-connect-req-size)]
           [req-ptr (allocate-request req-size)]
           [req-wrapper (make-uv-request-wrapper req-ptr 'connect callback pipe)])
      ;; 执行连接（注意：pipe_connect 返回 void，不返回错误码）
      (%ffi-uv-pipe-connect req-ptr
                             (handle-ptr pipe)
                             name
                             (get-connect-callback))))

  ;; ========================================
  ;; 地址信息
  ;; ========================================

  (define (uv-pipe-getsockname pipe)
    "获取 Pipe 绑定的路径
     返回: 路径字符串"
    (when (handle-closed? pipe)
      (error 'uv-pipe-getsockname "pipe handle is closed"))
    ;; 分配缓冲区
    (let* ([buf-size 256]  ; 通常足够
           [buf-ptr (foreign-alloc buf-size)]
           [size-ptr (foreign-alloc (foreign-sizeof 'size_t))])
      (foreign-set! 'size_t size-ptr 0 buf-size)
      (guard (e [else
                 (foreign-free buf-ptr)
                 (foreign-free size-ptr)
                 (raise e)])
        (with-uv-check uv-pipe-getsockname
          (%ffi-uv-pipe-getsockname (handle-ptr pipe) buf-ptr size-ptr))
        (let ([result (c-string->string buf-ptr)])
          (foreign-free buf-ptr)
          (foreign-free size-ptr)
          result))))

  (define (uv-pipe-getpeername pipe)
    "获取连接的远程路径
     返回: 路径字符串"
    (when (handle-closed? pipe)
      (error 'uv-pipe-getpeername "pipe handle is closed"))
    ;; 分配缓冲区
    (let* ([buf-size 256]
           [buf-ptr (foreign-alloc buf-size)]
           [size-ptr (foreign-alloc (foreign-sizeof 'size_t))])
      (foreign-set! 'size_t size-ptr 0 buf-size)
      (guard (e [else
                 (foreign-free buf-ptr)
                 (foreign-free size-ptr)
                 (raise e)])
        (with-uv-check uv-pipe-getpeername
          (%ffi-uv-pipe-getpeername (handle-ptr pipe) buf-ptr size-ptr))
        (let ([result (c-string->string buf-ptr)])
          (foreign-free buf-ptr)
          (foreign-free size-ptr)
          result))))

  ;; 辅助函数：C 字符串转 Scheme 字符串
  (define (c-string->string ptr)
    (let loop ([i 0] [chars '()])
      (let ([byte (foreign-ref 'unsigned-8 ptr i)])
        (if (= byte 0)
            (list->string (reverse chars))
            (loop (+ i 1) (cons (integer->char byte) chars))))))

  ;; ========================================
  ;; Pipe 配置
  ;; ========================================

  (define (uv-pipe-pending-instances! pipe count)
    "设置待处理的实例数（仅 Windows）
     pipe: Pipe 句柄
     count: 实例数"
    (when (handle-closed? pipe)
      (error 'uv-pipe-pending-instances! "pipe handle is closed"))
    (%ffi-uv-pipe-pending-instances (handle-ptr pipe) count))

  (define (uv-pipe-chmod! pipe flags)
    "设置 Pipe 权限（仅 Unix）
     pipe: Pipe 句柄
     flags: UV_READABLE, UV_WRITABLE, 或两者的按位或"
    (when (handle-closed? pipe)
      (error 'uv-pipe-chmod! "pipe handle is closed"))
    (with-uv-check uv-pipe-chmod
      (%ffi-uv-pipe-chmod (handle-ptr pipe) flags)))

  ;; ========================================
  ;; IPC 相关
  ;; ========================================

  (define (uv-pipe-pending-count pipe)
    "获取待处理的句柄数（用于 IPC）
     返回: 待处理句柄数量"
    (when (handle-closed? pipe)
      (error 'uv-pipe-pending-count "pipe handle is closed"))
    (%ffi-uv-pipe-pending-count (handle-ptr pipe)))

  (define (uv-pipe-pending-type pipe)
    "获取下一个待处理句柄的类型
     返回: 句柄类型（如 'tcp, 'pipe, 'unknown）"
    (when (handle-closed? pipe)
      (error 'uv-pipe-pending-type "pipe handle is closed"))
    (let ([type-int (%ffi-uv-pipe-pending-type (handle-ptr pipe))])
      (case type-int
        [(0) 'unknown]
        [(7) 'pipe]
        [(12) 'tcp]
        [else 'unknown])))

) ; end library
