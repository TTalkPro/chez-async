;;; high-level/stream.ss - 高层 Stream 抽象
;;;
;;; 提供 Promise 风格的 Stream 操作接口，封装 low-level/stream 的回调式 API。
;;;
;;; Promise 包装的读写流程：
;;; - stream-read: 启动 uv-read-start!，收到一次数据后立即 uv-read-stop!，
;;;   返回 bytevector（成功）、#f（EOF）或 reject（错误）
;;; - stream-write: 调用 uv-write!，完成回调中 resolve/reject
;;; - stream-shutdown: 关闭写入端，等待挂起的写入完成
;;; - stream-end: 关闭整个流句柄
;;;
;;; stream-reader 缓冲机制：
;;; stream-reader 支持连续读取，内部维护一个缓冲列表（buffer 字段）。
;;; 调用 stream-reader-read 时，优先从缓冲中取数据；缓冲为空时才启动
;;; uv-read-start! 从 libuv 读取新数据。每次只读一条消息后即停止。
;;;
;;; 用法示例：
;;;   (promise-then (stream-read tcp-handle)
;;;     (lambda (data) (display data)))
;;;   (stream-pipe source-stream dest-stream)

(library (chez-async high-level stream)
  (export
    ;; Promise 包装的 Stream 操作
    stream-read
    stream-write
    stream-shutdown
    stream-end

    ;; 管道连接
    stream-pipe

    ;; 辅助函数
    stream-readable?
    stream-writable?

    ;; 读取器
    make-stream-reader
    stream-reader-read
    stream-reader-close
    )
  (import (chezscheme)
          (chez-async high-level event-loop)
          (chez-async high-level promise)
          (chez-async low-level stream)
          (chez-async low-level handle-base)
          (chez-async ffi types))

  ;; ========================================
  ;; Promise 包装的 Stream 操作
  ;; ========================================

  (define (stream-read stream)
    "读取数据（Promise 版本）
     stream: 流句柄（TCP、Pipe、TTY 等）
     返回: Promise，成功时返回读取的数据（bytevector），
           EOF 时返回 #f，失败时 reject"
    (let ([loop (handle-loop stream)])
      (make-promise loop
        (lambda (resolve reject)
          ;; 使用一次性读取
          ;; 回调签名: (lambda (stream data-or-error) ...)
          ;; data-or-error: bytevector（成功）、#f（EOF）或 error（错误）
          (uv-read-start! stream
            (lambda (handle data-or-error)
              ;; 停止读取
              (uv-read-stop! handle)
              (cond
                [(bytevector? data-or-error)
                 ;; 成功读取数据
                 (resolve data-or-error)]
                [(not data-or-error)
                 ;; EOF
                 (resolve #f)]
                [else
                 ;; 错误
                 (reject data-or-error)])))))))

  (define stream-write
    (case-lambda
      [(stream data)
       (stream-write stream data #f)]
      [(stream data callback)
       "写入数据（Promise 版本）
        stream: 流句柄
        data: 要写入的数据（bytevector 或 string）
        callback: 可选的完成回调
        返回: Promise，成功时 resolve，失败时 reject"
       (let ([loop (handle-loop stream)]
             [bv (if (string? data)
                     (string->utf8 data)
                     data)])
         (make-promise loop
           (lambda (resolve reject)
             ;; 回调签名: (lambda (err) ...)
             ;; err: #f（成功）或 error code（失败）
             (uv-write! stream bv
               (lambda (err)
                 (when callback (callback err))
                 (if err
                     (reject err)
                     (resolve #t)))))))]))

  (define (stream-shutdown stream)
    "关闭流的写入端（Promise 版本）
     stream: 流句柄
     返回: Promise"
    (let ([loop (handle-loop stream)])
      (make-promise loop
        (lambda (resolve reject)
          ;; 回调签名: (lambda (err) ...)
          (uv-shutdown! stream
            (lambda (err)
              (if err
                  (reject err)
                  (resolve #t))))))))

  (define (stream-end stream)
    "关闭流（Promise 版本）
     stream: 流句柄
     返回: Promise"
    (let ([loop (handle-loop stream)])
      (make-promise loop
        (lambda (resolve reject)
          (uv-handle-close! stream
            (lambda (handle)
              (resolve #t)))))))

  ;; ========================================
  ;; Stream 管道
  ;; ========================================

  (define stream-pipe
    (case-lambda
      [(source dest)
       (stream-pipe source dest #f)]
      [(source dest options)
       "将源流的数据管道到目标流
        source: 源流句柄
        dest: 目标流句柄
        options: 选项（保留供将来使用）

        返回: Promise，当源流结束时 resolve"
       (let ([loop (handle-loop source)])
         (make-promise loop
           (lambda (resolve reject)
             ;; 开始读取源流
             ;; 回调签名: (lambda (stream data-or-error) ...)
             (uv-read-start! source
               (lambda (handle data-or-error)
                 (cond
                   [(bytevector? data-or-error)
                    ;; 成功读取数据，写入目标流
                    (uv-write! dest data-or-error
                      (lambda (err)
                        (when err
                          (uv-read-stop! handle)
                          (reject err))))]
                   [(not data-or-error)
                    ;; EOF
                    (uv-read-stop! handle)
                    (resolve #t)]
                   [else
                    ;; 错误
                    (uv-read-stop! handle)
                    (reject data-or-error)]))))))]))

  ;; ========================================
  ;; 辅助函数
  ;; ========================================

  (define (stream-readable? stream)
    "检查流是否可读"
    (uv-stream-readable? stream))

  (define (stream-writable? stream)
    "检查流是否可写"
    (uv-stream-writable? stream))

  ;; ========================================
  ;; Stream 读取器（连续读取支持）
  ;; ========================================

  (define-record-type stream-reader
    (fields
      stream
      (mutable buffer)       ; 缓冲的数据
      (mutable on-data)      ; 数据回调
      (mutable on-end)       ; 结束回调
      (mutable on-error)     ; 错误回调
      (mutable reading?))    ; 是否正在读取
    (protocol
      (lambda (new)
        (lambda (stream)
          (new stream '() #f #f #f #f)))))

  ;; make-stream-reader 由 define-record-type 自动创建

  (define (stream-reader-read reader)
    "从读取器读取数据（Promise 版本）
     reader: stream-reader 对象
     返回: Promise，成功时返回 bytevector，EOF 时返回 #f"
    (let* ([stream (stream-reader-stream reader)]
           [loop (handle-loop stream)])
      (make-promise loop
        (lambda (resolve reject)
          ;; 检查是否有缓冲数据
          (if (not (null? (stream-reader-buffer reader)))
              (let ([data (car (stream-reader-buffer reader))])
                (stream-reader-buffer-set! reader
                  (cdr (stream-reader-buffer reader)))
                (resolve data))
              ;; 开始读取
              ;; 回调签名: (lambda (stream data-or-error) ...)
              (begin
                (stream-reader-reading?-set! reader #t)
                (uv-read-start! stream
                  (lambda (handle data-or-error)
                    (uv-read-stop! handle)
                    (stream-reader-reading?-set! reader #f)
                    (cond
                      [(bytevector? data-or-error)
                       (resolve data-or-error)]
                      [(not data-or-error)
                       (resolve #f)]
                      [else
                       (reject data-or-error)])))))))))

  (define (stream-reader-close reader)
    "关闭读取器
     reader: stream-reader 对象"
    (let ([stream (stream-reader-stream reader)])
      (when (stream-reader-reading? reader)
        (uv-read-stop! stream))
      (stream-end stream)))

) ; end library
