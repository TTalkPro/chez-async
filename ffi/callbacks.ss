;;; ffi/callbacks.ss - 回调管理基础设施
;;;
;;; 提供 C 回调的创建、注册和管理机制

(library (chez-async ffi callbacks)
  (export
    ;; 回调注册
    register-c-callback!
    unregister-c-callback!

    ;; 指针-对象注册
    ptr->wrapper
    register-ptr-wrapper!
    unregister-ptr-wrapper!

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

    ;; 错误处理
    handle-callback-error
    )
  (import (chezscheme)
          (chez-async ffi errors))

  ;; ========================================
  ;; 回调注册表
  ;; ========================================

  ;; 全局回调注册表（防止 foreign-callable 被 GC）
  (define *callback-registry* (make-eq-hashtable))

  (define (register-c-callback! key callback)
    "注册 C 回调，防止被 GC"
    (hashtable-set! *callback-registry* key callback)
    callback)

  (define (unregister-c-callback! key)
    "注销 C 回调"
    (hashtable-delete! *callback-registry* key))

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
  ;; 辅助函数
  ;; ========================================

  ;; 全局注册表：C 指针 → Scheme 对象
  (define *ptr-to-object-registry* (make-hashtable equal-hash equal?))

  (define (ptr->wrapper ptr)
    "从 C 指针获取 Scheme 包装器对象"
    (hashtable-ref *ptr-to-object-registry* ptr #f))

  (define (register-ptr-wrapper! ptr wrapper)
    "注册 C 指针和 Scheme 包装器的映射"
    (hashtable-set! *ptr-to-object-registry* ptr wrapper))

  (define (unregister-ptr-wrapper! ptr)
    "注销 C 指针和 Scheme 包装器的映射"
    (hashtable-delete! *ptr-to-object-registry* ptr))

  ;; ========================================
  ;; 回调工厂函数
  ;; ========================================

  ;; 通用回调包装器
  (define (make-generic-callback scheme-proc signature)
    "创建通用回调包装器
     signature: 回调的参数签名
       - (void*): 单个句柄指针参数（timer, close）
       - (void* int): 句柄/请求指针 + 状态码（write, connect）
       - (void* ssize_t void*): 流指针 + 读取字节数 + 缓冲区（read）
     "
    (let ([wrapper
           (case signature
             ;; 单个句柄指针参数 (timer, close, idle, prepare, check, etc.)
             [((void*))
              (foreign-callable
                (lambda (handle-ptr)
                  (guard (e [else (handle-callback-error e)])
                    (let ([wrapper (ptr->wrapper handle-ptr)])
                      (when wrapper (scheme-proc wrapper)))))
                (void*) void)]

             ;; 请求指针 + 状态码 (write, connect, shutdown, fs, etc.)
             [((void* int))
              (foreign-callable
                (lambda (req-ptr status)
                  (guard (e [else (handle-callback-error e)])
                    (let ([wrapper (ptr->wrapper req-ptr)])
                      (when wrapper (scheme-proc wrapper status)))))
                (void* int) void)]

             ;; 流读取回调 (stream, tty, pipe, tcp, etc.)
             [((void* ssize_t void*))
              (foreign-callable
                (lambda (stream-ptr nread buf-ptr)
                  (guard (e [else (handle-callback-error e)])
                    (let ([wrapper (ptr->wrapper stream-ptr)])
                      (when wrapper (scheme-proc wrapper nread buf-ptr)))))
                (void* ssize_t void*) void)]

             ;; 连接回调 (listen callback)
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
  (define (make-write-callback scheme-proc)
    "创建写入回调"
    (make-generic-callback scheme-proc '(void* int)))

  ;; connect 回调: void (*uv_connect_cb)(uv_connect_t* req, int status)
  (define (make-connect-callback scheme-proc)
    "创建连接回调"
    (make-generic-callback scheme-proc '(void* int)))

  ;; shutdown 回调: void (*uv_shutdown_cb)(uv_shutdown_t* req, int status)
  (define (make-shutdown-callback scheme-proc)
    "创建关闭流回调"
    (make-generic-callback scheme-proc '(void* int)))

  ;; connection 回调: void (*uv_connection_cb)(uv_stream_t* server, int status)
  (define (make-connection-callback scheme-proc)
    "创建连接监听回调"
    (make-generic-callback scheme-proc '(void* int connection)))

  ;; async 回调: void (*uv_async_cb)(uv_async_t* handle)
  (define (make-async-callback scheme-proc)
    "创建异步唤醒回调"
    (make-generic-callback scheme-proc '(void*)))

) ; end library
