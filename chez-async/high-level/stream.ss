;;; high-level/stream.ss - 高层 Stream 抽象
;;;
;;; 提供 Promise 风格的 Stream 操作接口，封装 low-level/stream 的回调式 API。
;;;
;;; Promise 包装的读写流程：
;;; - stream-read: 一次性读取。启动 uv-read-start!，收到一次数据/EOF/错误后立即
;;;   uv-read-stop!。仅适合「一次读一条」；连续或并发读取请用 stream-reader。
;;; - stream-write: 调用 uv-write!，完成回调中 resolve/reject
;;; - stream-shutdown: 关闭写入端，等待挂起的写入完成
;;; - stream-end: 关闭整个流句柄
;;;
;;; stream-reader（连续/并发安全 + 背压）：
;;; reader 持有一个持续的 uv-read-start!，把到达的数据块放入缓冲队列；
;;; stream-reader-read 从缓冲取数据，缓冲空时把自己登记为「等待者」，
;;; 数据到达后按 FIFO 派发给等待者。因此：
;;; - 多个并发的 stream-reader-read 会按注册顺序依次拿到数据块（不再互相覆盖回调）；
;;; - 生产快于消费时，缓冲超过高水位即暂停底层读取（uv-read-stop!），
;;;   消费把缓冲降到低水位后自动恢复 —— 实现背压，避免内存无界增长。
;;;
;;; stream-pipe（带背压）：
;;; 持续读源、写目标，用「在途写入字节数」计量；超过高水位暂停读源，
;;; 写入排空到高水位以下再恢复；源 EOF 后等所有在途写入完成才 resolve。
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
    "读取数据（Promise 版本，一次性）
     stream: 流句柄（TCP、Pipe、TTY 等）
     返回: Promise，成功时返回读取的数据（bytevector），
           EOF 时返回 #f，失败时 reject
     注意: 这是一次性读取。若需连续读取或可能并发读取，请用 stream-reader，
           否则并发的 stream-read 会互相覆盖底层读回调。"
    (let ([loop (handle-loop stream)])
      (make-promise loop
        (lambda (resolve reject)
          (uv-read-start! stream
            (lambda (handle data-or-error)
              ;; 停止读取
              (uv-read-stop! handle)
              (cond
                [(bytevector? data-or-error)
                 (resolve data-or-error)]
                [(not data-or-error)
                 (resolve #f)]      ; EOF
                [else
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
  ;; Stream 管道（带背压）
  ;; ========================================

  (define stream-pipe
    (case-lambda
      [(source dest)
       (stream-pipe source dest #f)]
      [(source dest options)
       "将源流的数据管道到目标流（带背压）
        source: 源流句柄
        dest: 目标流句柄
        options: 选项（保留供将来使用）
        返回: Promise，源流 EOF 且所有数据写完后 resolve；出错时 reject

        背压：以在途写入字节数计量，超过高水位（256KB）暂停读源，
        写入排空到高水位以下再恢复，避免慢目标导致内存无界增长。"
       (let ([loop (handle-loop source)]
             [high-water (* 256 1024)])
         (make-promise loop
           (lambda (resolve reject)
             (let ([pending 0]        ; 在途写入字节数
                   [ended #f]         ; 源已 EOF
                   [paused #f]        ; 因背压暂停读源
                   [finished #f])
               (define (finish-ok!)
                 (unless finished (set! finished #t) (resolve #t)))
               (define (finish-err! e)
                 (unless finished
                   (set! finished #t)
                   (guard (x [else #f]) (uv-read-stop! source))
                   (reject e)))
               (define (on-source handle data-or-error)
                 (cond
                   [(bytevector? data-or-error)
                    (let ([n (bytevector-length data-or-error)])
                      (set! pending (+ pending n))
                      ;; 背压：目标积压超过高水位则暂停读源
                      (when (and (not paused) (>= pending high-water))
                        (set! paused #t)
                        (uv-read-stop! handle))
                      (uv-write! dest data-or-error
                        (lambda (err)
                          (set! pending (- pending n))
                          (cond
                            [err (finish-err! err)]
                            [(and ended (= pending 0)) (finish-ok!)]
                            [(and paused (< pending high-water) (not ended) (not finished))
                             (set! paused #f)
                             (uv-read-start! source on-source)]
                            [else (void)]))))]
                   [(not data-or-error)
                    ;; 源 EOF：停止读，等在途写入排空
                    (set! ended #t)
                    (uv-read-stop! handle)
                    (when (= pending 0) (finish-ok!))]
                   [else
                    ;; 读错误
                    (uv-read-stop! handle)
                    (finish-err! data-or-error)]))
               (uv-read-start! source on-source)))))]))

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
  ;; Stream 读取器（连续/并发安全 + 背压）
  ;; ========================================
  ;;
  ;; 不变式：data-queue 与 waiters 至多一个非空
  ;;   - 数据到达时：有等待者则派发给等待者，否则入 data-queue
  ;;   - 读取时：data-queue 非空则取，否则登记为等待者
  ;; 队列长度受背压高水位约束，故用 list + append 的 O(n) 入队可接受。

  (define reader-high-water 64)   ; 缓冲块数高水位：超过则暂停读取
  (define reader-low-water 16)    ; 低水位：降到此值以下恢复读取

  (define-record-type stream-reader
    (fields
      stream
      (mutable data-queue)   ; 已收到、待消费的 bytevector 块（FIFO）
      (mutable waiters)      ; 等待数据的 (resolve . reject)（FIFO）
      (mutable started?)     ; uv-read-start! 是否活跃
      (mutable paused?)      ; 是否因背压暂停
      (mutable ended?)       ; 是否已 EOF
      (mutable error)        ; 终止错误，或 #f
      (mutable closed?))     ; reader 是否已关闭
    (protocol
      (lambda (new)
        (lambda (stream)
          (new stream '() '() #f #f #f #f #f)))))

  ;; make-stream-reader 由 define-record-type 自动创建

  (define (reader-push-data! reader bv)
    (stream-reader-data-queue-set! reader
      (append (stream-reader-data-queue reader) (list bv))))

  (define (reader-pop-data! reader)
    (let ([q (stream-reader-data-queue reader)])
      (stream-reader-data-queue-set! reader (cdr q))
      (car q)))

  (define (reader-push-waiter! reader w)
    (stream-reader-waiters-set! reader
      (append (stream-reader-waiters reader) (list w))))

  (define (reader-pop-waiter! reader)
    (let ([q (stream-reader-waiters reader)])
      (stream-reader-waiters-set! reader (cdr q))
      (car q)))

  (define (reader-ensure-started! reader)
    "在需要更多数据时确保底层读取正在运行"
    (unless (or (stream-reader-started? reader)
                (stream-reader-ended? reader)
                (stream-reader-error reader)
                (stream-reader-closed? reader))
      (stream-reader-started?-set! reader #t)
      (stream-reader-paused?-set! reader #f)
      (uv-read-start! (stream-reader-stream reader)
        (lambda (handle data-or-error)
          (reader-on-data reader handle data-or-error)))))

  (define (reader-on-data reader handle data-or-error)
    (cond
      [(bytevector? data-or-error)
       (if (pair? (stream-reader-waiters reader))
           ;; 有等待者：直接派发（此时 data-queue 必为空，维持不变式）
           (let ([w (reader-pop-waiter! reader)])
             ((car w) data-or-error))
           ;; 无等待者：缓冲，并按高水位施加背压
           (begin
             (reader-push-data! reader data-or-error)
             (when (and (stream-reader-started? reader)
                        (not (stream-reader-paused? reader))
                        (>= (length (stream-reader-data-queue reader)) reader-high-water))
               (stream-reader-paused?-set! reader #t)
               (stream-reader-started?-set! reader #f)
               (uv-read-stop! handle))))]
      [(not data-or-error)
       ;; EOF：停止读取，唤醒所有等待者为 #f
       (stream-reader-ended?-set! reader #t)
       (uv-read-stop! handle)
       (stream-reader-started?-set! reader #f)
       (let loop ()
         (when (pair? (stream-reader-waiters reader))
           ((car (reader-pop-waiter! reader)) #f)
           (loop)))]
      [else
       ;; 错误：停止读取，reject 所有等待者
       (stream-reader-error-set! reader data-or-error)
       (uv-read-stop! handle)
       (stream-reader-started?-set! reader #f)
       (let loop ()
         (when (pair? (stream-reader-waiters reader))
           ((cdr (reader-pop-waiter! reader)) data-or-error)
           (loop)))]))

  (define (stream-reader-read reader)
    "从读取器读取一块数据（Promise 版本）
     reader: stream-reader 对象
     返回: Promise，成功时返回 bytevector，EOF 或已关闭时返回 #f，出错时 reject
     并发安全：多个未完成的读取会按调用顺序依次拿到后续数据块。"
    (let* ([stream (stream-reader-stream reader)]
           [loop (handle-loop stream)])
      (make-promise loop
        (lambda (resolve reject)
          (cond
            ;; 已关闭：按 EOF 处理
            [(stream-reader-closed? reader) (resolve #f)]
            ;; 有缓冲数据：立即取一块，取完后视水位恢复读取
            [(pair? (stream-reader-data-queue reader))
             (let ([data (reader-pop-data! reader)])
               (when (and (stream-reader-paused? reader)
                          (<= (length (stream-reader-data-queue reader)) reader-low-water))
                 (reader-ensure-started! reader))
               (resolve data))]
            ;; 终止错误
            [(stream-reader-error reader) (reject (stream-reader-error reader))]
            ;; EOF
            [(stream-reader-ended? reader) (resolve #f)]
            ;; 暂无数据：登记为等待者并确保底层读取运行
            [else
             (reader-push-waiter! reader (cons resolve reject))
             (reader-ensure-started! reader)])))))

  (define (stream-reader-close reader)
    "关闭读取器（停止读取并关闭底层流）
     reader: stream-reader 对象
     返回: stream-end 的 Promise
     未完成的读取会以 #f（EOF 语义）resolve。"
    (if (stream-reader-closed? reader)
        (stream-end (stream-reader-stream reader))
        (let ([stream (stream-reader-stream reader)])
          (stream-reader-closed?-set! reader #t)
          (when (stream-reader-started? reader)
            (uv-read-stop! stream)
            (stream-reader-started?-set! reader #f))
          ;; 唤醒所有等待者为 #f
          (let loop ()
            (when (pair? (stream-reader-waiters reader))
              ((car (reader-pop-waiter! reader)) #f)
              (loop)))
          (stream-end stream))))

) ; end library
