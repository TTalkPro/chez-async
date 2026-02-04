;;; low-level/stream.ss - Stream 低层封装
;;;
;;; 提供 Stream 操作的高层封装（用于 TCP、Pipe、TTY 等）

(library (chez-async low-level stream)
  (export
    ;; Stream 读取
    uv-read-start!
    uv-read-stop!

    ;; Stream 写入
    uv-write!
    uv-try-write

    ;; Stream 关闭
    uv-shutdown!

    ;; Stream 服务器
    uv-listen!
    uv-accept!

    ;; Stream 状态
    uv-stream-readable?
    uv-stream-writable?
    uv-stream-write-queue-size

    ;; 回调获取函数
    get-alloc-callback
    get-read-callback
    get-write-callback
    get-shutdown-callback
    get-connection-callback
    )
  (import (chezscheme)
          (chez-async ffi types)
          (chez-async ffi errors)
          (chez-async ffi stream)
          (chez-async ffi requests)
          (chez-async ffi callbacks)
          (chez-async low-level handle-base)
          (chez-async low-level request-base)
          (chez-async low-level buffer)
          (chez-async internal macros)
          (chez-async internal callback-registry)
          (chez-async internal utils))

  ;; ========================================
  ;; 全局回调（使用统一注册表管理）
  ;; ========================================
  ;;
  ;; 所有流回调都注册到统一注册表，在首次使用时延迟创建

  ;; Alloc 回调：分配读取缓冲区
  (define-registered-callback get-alloc-callback CALLBACK-ALLOC
    (lambda ()
      (make-alloc-callback
        (lambda (wrapper suggested-size buf-ptr)
          ;; 分配 C 内存缓冲区
          (let* ([size (min suggested-size 65536)]  ; 最大 64KB
                 [data-ptr (foreign-alloc size)]
                 [buf-fptr (make-ftype-pointer uv-buf-t buf-ptr)])
            (ftype-set! uv-buf-t (base) buf-fptr data-ptr)
            (ftype-set! uv-buf-t (len) buf-fptr size)
            ;; 存储指针以便后续释放
            (let ([read-data (handle-data wrapper)])
              (when (pair? read-data)
                (set-car! (cdr read-data) data-ptr))))))))

  ;; Read 回调：处理读取完成
  (define-registered-callback get-read-callback CALLBACK-READ
    (lambda ()
      (make-read-callback
        (lambda (wrapper nread buf-ptr)
          (let ([read-data (handle-data wrapper)])
            (when (and read-data (pair? read-data))
              (let ([user-callback (car read-data)]
                    [alloc-ptr (cadr read-data)])
                ;; 释放 alloc 分配的内存
                (when alloc-ptr
                  (foreign-free alloc-ptr)
                  (set-car! (cdr read-data) #f))
                ;; 调用用户回调
                (when user-callback
                  (if (< nread 0)
                      ;; 错误或 EOF
                      (if (= nread -4095)  ; UV_EOF
                          (user-callback wrapper #f)  ; EOF
                          (user-callback wrapper (make-uv-error nread (%ffi-uv-err-name nread) 'read)))
                      ;; 读取成功
                      (let* ([buf-fptr (make-ftype-pointer uv-buf-t buf-ptr)]
                             [base (ftype-ref uv-buf-t (base) buf-fptr)]
                             [bv (make-bytevector nread)])
                        ;; 复制数据到 bytevector
                        (do ([i 0 (+ i 1)])
                            ((= i nread))
                          (bytevector-u8-set! bv i (foreign-ref 'unsigned-8 base i)))
                        (user-callback wrapper bv)))))))))))

  ;; Write 回调：处理写入完成
  (define-registered-callback get-write-callback CALLBACK-WRITE
    (lambda ()
      (make-write-callback
        (lambda (req-wrapper status)
          (let ([user-callback (uv-request-wrapper-scheme-callback req-wrapper)]
                [write-data (uv-request-wrapper-scheme-data req-wrapper)])
            ;; 释放缓冲区内存
            (when (and write-data (pair? write-data))
              (let ([buf-ptr (car write-data)]
                    [data-ptr (cdr write-data)])
                (when data-ptr (foreign-free data-ptr))
                (when buf-ptr (foreign-free buf-ptr))))
            ;; 调用用户回调
            (when user-callback
              (if (< status 0)
                  (user-callback (make-uv-error status (%ffi-uv-err-name status) 'write))
                  (user-callback #f)))
            ;; 清理请求
            (cleanup-request-wrapper! req-wrapper))))))

  ;; Shutdown 回调：处理流关闭完成
  (define-registered-callback get-shutdown-callback CALLBACK-SHUTDOWN
    (lambda ()
      (make-shutdown-callback
        (lambda (req-wrapper status)
          (let ([user-callback (uv-request-wrapper-scheme-callback req-wrapper)])
            ;; 调用用户回调
            (when user-callback
              (if (< status 0)
                  (user-callback (make-uv-error status (%ffi-uv-err-name status) 'shutdown))
                  (user-callback #f)))
            ;; 清理请求
            (cleanup-request-wrapper! req-wrapper))))))

  ;; Connection 回调：处理新连接
  (define-registered-callback get-connection-callback CALLBACK-CONNECTION
    (lambda ()
      (make-connection-callback
        (lambda (server-wrapper status)
          (let ([user-callback (handle-data server-wrapper)])
            (when user-callback
              (if (< status 0)
                  (user-callback server-wrapper (make-uv-error status (%ffi-uv-err-name status) 'connection))
                  (user-callback server-wrapper #f))))))))

  ;; ========================================
  ;; Stream 读取
  ;; ========================================

  (define (uv-read-start! stream callback)
    "开始从 stream 读取数据
     stream: stream 句柄
     callback: 回调函数 (lambda (stream data-or-error) ...)
               data-or-error 为 bytevector（成功）、#f（EOF）或 error（错误）"
    (when (handle-closed? stream)
      (error 'uv-read-start! "stream is closed"))
    ;; 保存回调和 alloc 缓冲区指针
    (let ([read-data (list callback #f)])  ; (user-callback alloc-ptr)
      (handle-data-set! stream read-data)
      (lock-object read-data))
    ;; 开始读取
    (with-uv-check uv-read-start
      (%ffi-uv-read-start (handle-ptr stream)
                          (get-alloc-callback)
                          (get-read-callback))))

  (define (uv-read-stop! stream)
    "停止从 stream 读取数据"
    (when (handle-closed? stream)
      (error 'uv-read-stop! "stream is closed"))
    (with-uv-check uv-read-stop
      (%ffi-uv-read-stop (handle-ptr stream)))
    ;; 清理回调数据
    (let ([read-data (handle-data stream)])
      (when read-data
        (unlock-object read-data)
        (handle-data-set! stream #f))))

  ;; ========================================
  ;; Stream 写入
  ;; ========================================

  (define (uv-write! stream data callback)
    "写入数据到 stream
     stream: stream 句柄
     data: bytevector 或 string
     callback: 回调函数 (lambda (error-or-#f) ...)"
    (when (handle-closed? stream)
      (error 'uv-write! "stream is closed"))
    ;; 将数据转换为 bytevector
    (let* ([bv (if (string? data)
                   (string->utf8 data)
                   data)]
           [len (bytevector-length bv)]
           ;; 分配缓冲区结构和数据
           [buf-ptr (foreign-alloc (ftype-sizeof uv-buf-t))]
           [data-ptr (foreign-alloc len)]
           ;; 分配请求
           [req-size (%ffi-uv-write-req-size)]
           [req-ptr (allocate-request req-size)])
      ;; 复制数据到 C 内存
      (do ([i 0 (+ i 1)])
          ((= i len))
        (foreign-set! 'unsigned-8 data-ptr i (bytevector-u8-ref bv i)))
      ;; 设置 uv_buf_t
      (let ([buf-fptr (make-ftype-pointer uv-buf-t buf-ptr)])
        (ftype-set! uv-buf-t (base) buf-fptr data-ptr)
        (ftype-set! uv-buf-t (len) buf-fptr len))
      ;; 创建请求包装器
      (let ([req-wrapper (make-uv-request-wrapper
                           req-ptr 'write callback
                           (cons buf-ptr data-ptr))])
        ;; 执行写入
        (let ([result (%ffi-uv-write req-ptr
                                      (handle-ptr stream)
                                      buf-ptr
                                      1  ; nbufs
                                      (get-write-callback))])
          (when (< result 0)
            ;; 写入失败，清理资源
            (cleanup-request-wrapper! req-wrapper)
            (foreign-free buf-ptr)
            (foreign-free data-ptr)
            (raise-uv-error 'uv-write result))))))

  (define (uv-try-write stream data)
    "尝试同步写入数据到 stream（非阻塞）
     返回：写入的字节数，或负数表示错误
     注意：UV_EAGAIN 表示需要等待"
    (when (handle-closed? stream)
      (error 'uv-try-write "stream is closed"))
    (let* ([bv (if (string? data)
                   (string->utf8 data)
                   data)]
           [len (bytevector-length bv)]
           [buf-ptr (foreign-alloc (ftype-sizeof uv-buf-t))]
           [data-ptr (foreign-alloc len)])
      ;; 复制数据
      (do ([i 0 (+ i 1)])
          ((= i len))
        (foreign-set! 'unsigned-8 data-ptr i (bytevector-u8-ref bv i)))
      ;; 设置 uv_buf_t
      (let ([buf-fptr (make-ftype-pointer uv-buf-t buf-ptr)])
        (ftype-set! uv-buf-t (base) buf-fptr data-ptr)
        (ftype-set! uv-buf-t (len) buf-fptr len))
      ;; 尝试写入
      (let ([result (%ffi-uv-try-write (handle-ptr stream) buf-ptr 1)])
        (foreign-free data-ptr)
        (foreign-free buf-ptr)
        result)))

  ;; ========================================
  ;; Stream 关闭
  ;; ========================================

  (define (uv-shutdown! stream callback)
    "关闭 stream 的写端（half-close）
     callback: 回调函数 (lambda (error-or-#f) ...)"
    (when (handle-closed? stream)
      (error 'uv-shutdown! "stream is closed"))
    ;; 分配请求
    (let* ([req-size (%ffi-uv-shutdown-req-size)]
           [req-ptr (allocate-request req-size)]
           [req-wrapper (make-uv-request-wrapper req-ptr 'shutdown callback #f)])
      ;; 执行 shutdown
      (let ([result (%ffi-uv-shutdown req-ptr
                                       (handle-ptr stream)
                                       (get-shutdown-callback))])
        (when (< result 0)
          (cleanup-request-wrapper! req-wrapper)
          (raise-uv-error 'uv-shutdown result)))))

  ;; ========================================
  ;; Stream 服务器
  ;; ========================================

  (define (uv-listen! stream backlog callback)
    "监听传入连接
     stream: stream 句柄（需要先绑定）
     backlog: 等待队列长度
     callback: 回调函数 (lambda (server error-or-#f) ...)"
    (when (handle-closed? stream)
      (error 'uv-listen! "stream is closed"))
    ;; 保存连接回调
    (handle-data-set! stream callback)
    (lock-object callback)
    ;; 开始监听
    (with-uv-check uv-listen
      (%ffi-uv-listen (handle-ptr stream)
                      backlog
                      (get-connection-callback))))

  (define (uv-accept! server client)
    "接受传入的连接
     server: 服务器 stream 句柄
     client: 新的 stream 句柄（用于接受连接）"
    (when (handle-closed? server)
      (error 'uv-accept! "server stream is closed"))
    (when (handle-closed? client)
      (error 'uv-accept! "client stream is closed"))
    (with-uv-check uv-accept
      (%ffi-uv-accept (handle-ptr server)
                      (handle-ptr client))))

  ;; ========================================
  ;; Stream 状态查询
  ;; ========================================

  (define (uv-stream-readable? stream)
    "检查 stream 是否可读"
    (and (not (handle-closed? stream))
         (not (= 0 (%ffi-uv-is-readable (handle-ptr stream))))))

  (define (uv-stream-writable? stream)
    "检查 stream 是否可写"
    (and (not (handle-closed? stream))
         (not (= 0 (%ffi-uv-is-writable (handle-ptr stream))))))

  (define (uv-stream-write-queue-size stream)
    "获取写队列中待写入的字节数"
    (when (handle-closed? stream)
      (error 'uv-stream-write-queue-size "stream is closed"))
    (%ffi-uv-stream-get-write-queue-size (handle-ptr stream)))

) ; end library
