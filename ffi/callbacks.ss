;;; ffi/callbacks.ss - 回调管理基础设施
;;;
;;; 本模块提供 C 回调的创建、注册和管理机制：
;;;
;;; 1. GC 保护注册表 (*gc-protected-callbacks*)
;;;    - 防止 foreign-callable 被垃圾回收
;;;    - 通过 register-c-callback!/unregister-c-callback! 访问
;;;
;;; 2. 指针-包装器查找 (ptr->wrapper)
;;;    - 从 C 指针查找对应的 Scheme 包装器
;;;    - 使用 per-loop 注册表，通过 uv_handle_get_loop 获取 loop
;;;
;;; 3. 回调工厂函数 (make-*-callback)
;;;    - 创建各种类型的 foreign-callable
;;;    - 自动注册到 GC 保护注册表
;;;
;;; 设计说明：
;;; 指针-包装器映射已移至 per-loop 注册表（在 high-level/event-loop.ss），
;;; 避免了全局变量。查找流程：handle-ptr → loop-ptr → loop → wrapper

(library (chez-async ffi callbacks)
  (export
    ;; GC 保护注册
    register-c-callback!
    unregister-c-callback!

    ;; 句柄指针-包装器查找（使用 per-loop 注册表）
    ptr->wrapper

    ;; 请求指针-包装器注册（使用小的全局注册表）
    register-request-wrapper!
    unregister-request-wrapper!
    request-ptr->wrapper

    ;; 回调工厂函数
    make-generic-callback
    make-close-callback
    make-timer-callback
    make-alloc-callback
    make-read-callback
    make-write-callback
    make-connect-callback
    make-shutdown-callback
    make-connection-callback
    make-async-callback

    ;; UDP 回调
    make-udp-send-callback
    make-udp-recv-callback

    ;; Signal 回调
    make-signal-callback

    ;; Poll 回调
    make-poll-callback

    ;; FS Event 回调
    make-fs-event-callback

    ;; FS Poll 回调
    make-fs-poll-callback

    ;; 错误处理
    handle-callback-error
    )
  (import (chezscheme)
          (chez-async ffi errors)
          (chez-async ffi handles)
          (chez-async high-level event-loop))

  ;; ========================================
  ;; GC 保护注册表
  ;; ========================================
  ;;
  ;; 此注册表用于防止 foreign-callable 被垃圾回收。
  ;; 当创建 foreign-callable 后，必须将其存储在此注册表中，
  ;; 否则可能在 C 代码调用前就被 GC 回收。
  ;;
  ;; 注意：这与 internal/callback-registry.ss 中的回调注册表不同：
  ;; - internal/callback-registry.ss: 管理延迟初始化的全局回调工厂
  ;; - 此注册表: 防止已创建的 foreign-callable 被 GC 回收

  (define *gc-protected-callbacks* (make-eq-hashtable))

  (define (register-c-callback! key callback)
    "注册 C 回调到 GC 保护注册表，防止被垃圾回收
     key: 唯一标识键（通常为 (cons proc signature)）
     callback: foreign-callable 对象
     返回: callback 本身"
    (hashtable-set! *gc-protected-callbacks* key callback)
    callback)

  (define (unregister-c-callback! key)
    "从 GC 保护注册表中移除回调
     key: 之前注册时使用的键"
    (hashtable-delete! *gc-protected-callbacks* key))

  ;; ========================================
  ;; 错误处理
  ;; ========================================

  (define (handle-callback-error e)
    "在回调中处理异常"
    (fprintf (current-error-port)
             "Error in libuv callback: ~a~n"
             (if (condition? e)
                 (call-with-string-output-port
                   (lambda (p) (display-condition e p)))
                 e)))

  ;; ========================================
  ;; 指针-包装器查找
  ;; ========================================
  ;;
  ;; 分两种情况处理：
  ;;
  ;; 1. 句柄（Handles）：使用 per-loop 注册表
  ;;    handle-ptr → uv_handle_get_loop → loop-ptr → loop → wrapper
  ;;    优点：无全局变量，多个 loop 互不影响
  ;;
  ;; 2. 请求（Requests）：使用小的全局注册表
  ;;    请求是短生命周期对象，没有 uv_handle_get_loop 等效函数
  ;;    所以保留一个小的全局注册表用于请求

  ;; 请求注册表（全局，但仅用于短生命周期的请求）
  (define *request-registry* (make-eqv-hashtable))

  (define (register-request-wrapper! ptr wrapper)
    "注册请求包装器（全局注册表）"
    (hashtable-set! *request-registry* ptr wrapper))

  (define (unregister-request-wrapper! ptr)
    "注销请求包装器"
    (hashtable-delete! *request-registry* ptr))

  (define (request-ptr->wrapper ptr)
    "从请求 C 指针获取包装器"
    (hashtable-ref *request-registry* ptr #f))

  (define (ptr->wrapper handle-ptr)
    "从句柄 C 指针获取对应的 Scheme 包装器对象
     handle-ptr: libuv 句柄的 C 指针
     返回: 对应的包装器对象，如果未找到则返回 #f

     注意：此函数适用于句柄（handle）。
     对于请求（request），请使用 request-ptr->wrapper。"
    (let* ([loop-ptr (%ffi-uv-handle-get-loop handle-ptr)]
           [loop (get-loop-by-ptr loop-ptr)])
      (and loop (loop-get-wrapper loop handle-ptr))))

  ;; ========================================
  ;; 回调工厂函数
  ;; ========================================

  ;; 通用回调包装器
  (define (make-generic-callback scheme-proc signature)
    "创建通用回调包装器
     signature: 回调的参数签名
       - (void*): 单个句柄指针参数（timer, close）- 使用 ptr->wrapper
       - (void* int request): 请求指针 + 状态码（write, connect）- 使用 request-ptr->wrapper
       - (void* ssize_t void*): 流指针 + 读取字节数 + 缓冲区（read）- 使用 ptr->wrapper
       - (void* int connection): 连接监听回调 - 使用 ptr->wrapper
     "
    (let ([wrapper
           (case signature
             ;; 单个句柄指针参数 (timer, close, idle, prepare, check, etc.)
             ;; 使用 per-loop 注册表
             [((void*))
              (foreign-callable
                (lambda (handle-ptr)
                  (guard (e [else (handle-callback-error e)])
                    (let ([wrapper (ptr->wrapper handle-ptr)])
                      (when wrapper (scheme-proc wrapper)))))
                (void*) void)]

             ;; 请求指针 + 状态码 (write, connect, shutdown, etc.)
             ;; 使用请求全局注册表
             [((void* int request))
              (foreign-callable
                (lambda (req-ptr status)
                  (guard (e [else (handle-callback-error e)])
                    (let ([wrapper (request-ptr->wrapper req-ptr)])
                      (when wrapper (scheme-proc wrapper status)))))
                (void* int) void)]

             ;; 流读取回调 (stream, tty, pipe, tcp, etc.)
             ;; 使用 per-loop 注册表
             [((void* ssize_t void*))
              (foreign-callable
                (lambda (stream-ptr nread buf-ptr)
                  (guard (e [else (handle-callback-error e)])
                    (let ([wrapper (ptr->wrapper stream-ptr)])
                      (when wrapper (scheme-proc wrapper nread buf-ptr)))))
                (void* ssize_t void*) void)]

             ;; 连接监听回调 (listen callback on server handle)
             ;; 使用 per-loop 注册表
             [((void* int connection))
              (foreign-callable
                (lambda (server-ptr status)
                  (guard (e [else (handle-callback-error e)])
                    (let ([wrapper (ptr->wrapper server-ptr)])
                      (when wrapper (scheme-proc wrapper status)))))
                (void* int) void)]

             [else
              (error 'make-generic-callback "unsupported signature" signature)])])
      (register-c-callback! (cons scheme-proc signature) wrapper)
      wrapper))

  ;; close 回调: void (*uv_close_cb)(uv_handle_t* handle)
  (define (make-close-callback scheme-proc)
    "创建关闭回调"
    (make-generic-callback scheme-proc '(void*)))

  ;; timer 回调: void (*uv_timer_cb)(uv_timer_t* handle)
  (define (make-timer-callback scheme-proc)
    "创建定时器回调"
    (make-generic-callback scheme-proc '(void*)))

  ;; alloc 回调: void (*uv_alloc_cb)(uv_handle_t* handle, size_t suggested_size, uv_buf_t* buf)
  (define (make-alloc-callback scheme-proc)
    "创建内存分配回调"
    (let ([wrapper
           (foreign-callable
             (lambda (handle-ptr suggested-size buf-ptr)
               (guard (e [else (handle-callback-error e)])
                 (let ([wrapper (ptr->wrapper handle-ptr)])
                   (when wrapper (scheme-proc wrapper suggested-size buf-ptr)))))
             (void* size_t void*) void)])
      (register-c-callback! (cons scheme-proc 'alloc) wrapper)
      wrapper))

  ;; read 回调: void (*uv_read_cb)(uv_stream_t* stream, ssize_t nread, const uv_buf_t* buf)
  (define (make-read-callback scheme-proc)
    "创建读取回调"
    (make-generic-callback scheme-proc '(void* ssize_t void*)))

  ;; write 回调: void (*uv_write_cb)(uv_write_t* req, int status)
  ;; 使用请求注册表
  (define (make-write-callback scheme-proc)
    "创建写入回调"
    (make-generic-callback scheme-proc '(void* int request)))

  ;; connect 回调: void (*uv_connect_cb)(uv_connect_t* req, int status)
  ;; 使用请求注册表
  (define (make-connect-callback scheme-proc)
    "创建连接回调"
    (make-generic-callback scheme-proc '(void* int request)))

  ;; shutdown 回调: void (*uv_shutdown_cb)(uv_shutdown_t* req, int status)
  ;; 使用请求注册表
  (define (make-shutdown-callback scheme-proc)
    "创建关闭流回调"
    (make-generic-callback scheme-proc '(void* int request)))

  ;; connection 回调: void (*uv_connection_cb)(uv_stream_t* server, int status)
  (define (make-connection-callback scheme-proc)
    "创建连接监听回调"
    (make-generic-callback scheme-proc '(void* int connection)))

  ;; async 回调: void (*uv_async_cb)(uv_async_t* handle)
  (define (make-async-callback scheme-proc)
    "创建异步唤醒回调"
    (make-generic-callback scheme-proc '(void*)))

  ;; UDP send 回调: void (*uv_udp_send_cb)(uv_udp_send_t* req, int status)
  ;; 使用请求注册表
  (define (make-udp-send-callback scheme-proc)
    "创建 UDP 发送回调"
    (make-generic-callback scheme-proc '(void* int request)))

  ;; UDP recv 回调: void (*uv_udp_recv_cb)(uv_udp_t* handle, ssize_t nread,
  ;;                                        const uv_buf_t* buf,
  ;;                                        const struct sockaddr* addr,
  ;;                                        unsigned flags)
  (define (make-udp-recv-callback scheme-proc)
    "创建 UDP 接收回调"
    (let ([wrapper
           (foreign-callable
             (lambda (handle-ptr nread buf-ptr addr-ptr flags)
               (guard (e [else (handle-callback-error e)])
                 (let ([wrapper (ptr->wrapper handle-ptr)])
                   (when wrapper (scheme-proc wrapper nread buf-ptr addr-ptr flags)))))
             (void* ssize_t void* void* unsigned-int) void)])
      (register-c-callback! (cons scheme-proc 'udp-recv) wrapper)
      wrapper))

  ;; Signal 回调: void (*uv_signal_cb)(uv_signal_t* handle, int signum)
  (define (make-signal-callback scheme-proc)
    "创建信号处理回调"
    (let ([wrapper
           (foreign-callable
             (lambda (handle-ptr signum)
               (guard (e [else (handle-callback-error e)])
                 (let ([wrapper (ptr->wrapper handle-ptr)])
                   (when wrapper (scheme-proc wrapper signum)))))
             (void* int) void)])
      (register-c-callback! (cons scheme-proc 'signal) wrapper)
      wrapper))

  ;; Poll 回调: void (*uv_poll_cb)(uv_poll_t* handle, int status, int events)
  (define (make-poll-callback scheme-proc)
    "创建轮询回调"
    (let ([wrapper
           (foreign-callable
             (lambda (handle-ptr status events)
               (guard (e [else (handle-callback-error e)])
                 (let ([wrapper (ptr->wrapper handle-ptr)])
                   (when wrapper (scheme-proc wrapper status events)))))
             (void* int int) void)])
      (register-c-callback! (cons scheme-proc 'poll) wrapper)
      wrapper))

  ;; FS Event 回调: void (*uv_fs_event_cb)(uv_fs_event_t* handle,
  ;;                                        const char* filename,
  ;;                                        int events, int status)
  (define (make-fs-event-callback scheme-proc)
    "创建文件系统事件回调"
    (let ([wrapper
           (foreign-callable
             (lambda (handle-ptr filename-ptr events status)
               (guard (e [else (handle-callback-error e)])
                 (let ([wrapper (ptr->wrapper handle-ptr)]
                       [filename (if (= filename-ptr 0)
                                     #f
                                     (get-string-from-ptr filename-ptr))])
                   (when wrapper (scheme-proc wrapper filename events status)))))
             (void* void* int int) void)])
      (register-c-callback! (cons scheme-proc 'fs-event) wrapper)
      wrapper))

  ;; FS Poll 回调: void (*uv_fs_poll_cb)(uv_fs_poll_t* handle,
  ;;                                      int status,
  ;;                                      const uv_stat_t* prev,
  ;;                                      const uv_stat_t* curr)
  (define (make-fs-poll-callback scheme-proc)
    "创建文件系统轮询回调"
    (let ([wrapper
           (foreign-callable
             (lambda (handle-ptr status prev-stat-ptr curr-stat-ptr)
               (guard (e [else (handle-callback-error e)])
                 (let ([wrapper (ptr->wrapper handle-ptr)])
                   (when wrapper
                     (scheme-proc wrapper status prev-stat-ptr curr-stat-ptr)))))
             (void* int void* void*) void)])
      (register-c-callback! (cons scheme-proc 'fs-poll) wrapper)
      wrapper))

  ;; 辅助函数：从 C 字符串指针获取 Scheme 字符串
  (define (get-string-from-ptr ptr)
    "从 C 字符串指针获取 Scheme 字符串"
    (let loop ([i 0] [chars '()])
      (let ([byte (foreign-ref 'unsigned-8 ptr i)])
        (if (= byte 0)
            (list->string (reverse chars))
            (loop (+ i 1) (cons (integer->char byte) chars))))))

) ; end library
