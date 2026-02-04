;;; ffi/callbacks.ss - 回调管理基础设施
;;;
;;; 本模块提供 C 回调的创建、注册和管理机制：
;;;
;;; 1. GC 保护注册表 (*gc-protected-callbacks*)
;;;    - 防止 foreign-callable 被垃圾回收
;;;    - 通过 register-c-callback!/unregister-c-callback! 访问
;;;
;;; 2. 指针-包装器映射 (*ptr-to-wrapper-registry*)
;;;    - 将 C 指针映射到 Scheme 包装器对象
;;;    - 通过 ptr->wrapper/register-ptr-wrapper!/unregister-ptr-wrapper! 访问
;;;
;;; 3. 回调工厂函数 (make-*-callback)
;;;    - 创建各种类型的 foreign-callable
;;;    - 自动注册到 GC 保护注册表
;;;    - 自动查找指针对应的包装器
;;;
;;; 注意：此模块与 internal/callback-registry.ss 配合使用：
;;; - internal/callback-registry.ss 管理延迟初始化的全局回调
;;; - 此模块提供回调工厂和运行时管理

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

    ;; UDP 回调
    make-udp-send-callback
    make-udp-recv-callback

    ;; Signal 回调
    make-signal-callback

    ;; Poll 回调
    make-poll-callback

    ;; 错误处理
    handle-callback-error
    )
  (import (chezscheme)
          (chez-async ffi errors))

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
  ;; 指针-包装器映射注册表
  ;; ========================================
  ;;
  ;; 此注册表维护 C 指针到 Scheme 包装器对象的映射。
  ;; 当 libuv 回调被触发时，我们只能得到 C 指针，
  ;; 需要通过此注册表找到对应的 Scheme 包装器对象。
  ;;
  ;; 典型用法：
  ;; 1. 创建句柄/请求时：(register-ptr-wrapper! ptr wrapper)
  ;; 2. 回调中查找包装器：(ptr->wrapper ptr)
  ;; 3. 关闭时清理：(unregister-ptr-wrapper! ptr)

  (define *ptr-to-wrapper-registry* (make-hashtable equal-hash equal?))

  (define (ptr->wrapper ptr)
    "从 C 指针获取对应的 Scheme 包装器对象
     ptr: libuv 句柄或请求的 C 指针
     返回: 对应的包装器对象，如果未找到则返回 #f"
    (hashtable-ref *ptr-to-wrapper-registry* ptr #f))

  (define (register-ptr-wrapper! ptr wrapper)
    "注册 C 指针和 Scheme 包装器的映射
     ptr: libuv 句柄或请求的 C 指针
     wrapper: 对应的 Scheme 包装器对象（handle 或 request）"
    (hashtable-set! *ptr-to-wrapper-registry* ptr wrapper))

  (define (unregister-ptr-wrapper! ptr)
    "从注册表中移除指针映射（通常在句柄关闭时调用）
     ptr: 要移除的 C 指针"
    (hashtable-delete! *ptr-to-wrapper-registry* ptr))

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

  ;; UDP send 回调: void (*uv_udp_send_cb)(uv_udp_send_t* req, int status)
  (define (make-udp-send-callback scheme-proc)
    "创建 UDP 发送回调"
    (make-generic-callback scheme-proc '(void* int)))

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

) ; end library
