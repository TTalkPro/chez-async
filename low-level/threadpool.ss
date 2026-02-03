;;; low-level/threadpool.ss - Chez Scheme 线程池核心
;;;
;;; 提供基于 Chez Scheme 线程的任务调度系统

(library (chez-async low-level threadpool)
  (export
    ;; 任务记录类型
    make-task
    task?
    task-id
    task-work
    task-callback
    task-error-handler

    ;; 线程池操作
    make-threadpool
    threadpool?
    threadpool-start!
    threadpool-submit!
    threadpool-shutdown!
    threadpool-running?
    )
  (import (chezscheme)
          (chez-async ffi async)
          (chez-async ffi errors)
          (chez-async low-level async)
          (chez-async low-level handle-base))

  ;; ========================================
  ;; 数据结构
  ;; ========================================

  ;; 任务记录类型
  (define-record-type task
    (fields
      (immutable id)
      (immutable work)            ; (lambda () ...) - 工作函数
      (immutable callback)        ; (lambda (result) ...) - 成功回调
      (immutable error-handler))) ; (lambda (error) ...) - 错误回调

  ;; 任务结果记录类型
  (define-record-type task-result
    (fields
      (immutable task-id)
      (immutable success?)        ; #t = 成功, #f = 失败
      (immutable value)))         ; 结果值或错误对象

  ;; 任务队列记录类型
  (define-record-type (task-queue make-task-queue-record task-queue?)
    (fields
      (mutable items)             ; List of tasks
      (immutable mutex)           ; Mutex for thread safety
      (immutable not-empty)))     ; Condition variable

  ;; 线程池记录类型
  (define-record-type (threadpool make-threadpool-record threadpool?)
    (fields
      (immutable loop)            ; uv-loop wrapper
      (immutable size)            ; 工作线程数量
      (mutable workers)           ; 线程列表
      (mutable running?)          ; 是否运行中
      (immutable task-queue)      ; 待处理任务队列
      (immutable result-queue)    ; 完成结果队列
      (mutable async-handle)      ; uv_async_t 句柄
      (immutable task-map)        ; task-id → task 映射
      (immutable shutdown-mutex)  ; 关闭同步
      (mutable next-task-id)))    ; 下一个任务 ID

  ;; ========================================
  ;; 队列操作
  ;; ========================================

  (define (make-task-queue)
    "创建新的任务队列"
    (make-task-queue-record
      '()                         ; items
      (make-mutex)                ; mutex
      (make-condition)))          ; not-empty

  (define (queue-push! q item)
    "添加项到队列（线程安全）"
    (with-mutex (task-queue-mutex q)
      (task-queue-items-set! q (append (task-queue-items q) (list item)))
      (condition-signal (task-queue-not-empty q))))

  (define (queue-try-pop! q timeout-ms)
    "尝试从队列获取项（带超时，毫秒）"
    (with-mutex (task-queue-mutex q)
      (let loop ([remaining-ms timeout-ms])
        (cond
          [(not (null? (task-queue-items q)))
           (let ([item (car (task-queue-items q))])
             (task-queue-items-set! q (cdr (task-queue-items q)))
             item)]
          [(<= remaining-ms 0)
           #f]
          [else
           ;; 等待一小段时间
           (let ([start-time (current-time 'time-monotonic)])
             (condition-wait (task-queue-not-empty q)
                           (task-queue-mutex q)
                           (make-time 'time-duration
                                    0
                                    (quotient remaining-ms 1000)))
             (let* ([elapsed (time-difference (current-time 'time-monotonic) start-time)]
                    [elapsed-ms (+ (* (time-second elapsed) 1000)
                                  (quotient (time-nanosecond elapsed) 1000000))])
               (loop (- remaining-ms elapsed-ms))))]))))

  (define (queue-pop-all! q)
    "获取并清空队列中的所有项"
    (with-mutex (task-queue-mutex q)
      (let ([items (task-queue-items q)])
        (task-queue-items-set! q '())
        items)))

  ;; ========================================
  ;; 工作线程
  ;; ========================================

  (define (worker-thread-proc pool)
    "工作线程主循环"
    (let loop ()
      (when (threadpool-running? pool)
        (let ([task (queue-try-pop! (threadpool-task-queue pool) 100)])
          (when task
            ;; 执行任务并捕获结果或异常
            (let ([result
                   (guard (e [else (make-task-result (task-id task) #f e)])
                     (let ([value ((task-work task))])
                       (make-task-result (task-id task) #t value)))])
              ;; 将结果放入结果队列
              (queue-push! (threadpool-result-queue pool) result)
              ;; 通知主线程
              (let ([async-h (threadpool-async-handle pool)])
                (when async-h
                  (guard (e [else
                             (fprintf (current-error-port)
                                     "Error sending async notification: ~a~n" e)])
                    (uv-async-send! async-h)))))))
        (loop))))

  ;; ========================================
  ;; 结果处理（主线程）
  ;; ========================================

  (define (process-results pool)
    "从 async 回调调用，处理所有完成的任务"
    (let ([results (queue-pop-all! (threadpool-result-queue pool))])
      (for-each
        (lambda (result)
          (let ([task (hashtable-ref (threadpool-task-map pool)
                                     (task-result-task-id result) #f)])
            (when task
              ;; 从 map 中删除
              (hashtable-delete! (threadpool-task-map pool) (task-id task))
              ;; 执行用户回调
              (guard (e [else
                         (fprintf (current-error-port)
                                 "Error in task callback: ~a~n" e)])
                (if (task-result-success? result)
                    (when (task-callback task)
                      ((task-callback task) (task-result-value result)))
                    (when (task-error-handler task)
                      ((task-error-handler task) (task-result-value result))))))))
        results)))

  ;; ========================================
  ;; 线程池 API
  ;; ========================================

  (define (make-threadpool loop size)
    "创建线程池（尚未启动）
     loop: uv-loop wrapper
     size: 工作线程数量"
    (make-threadpool-record
      loop                        ; loop
      size                        ; size
      '()                         ; workers
      #f                          ; running?
      (make-task-queue)           ; task-queue
      (make-task-queue)           ; result-queue
      #f                          ; async-handle
      (make-eq-hashtable)         ; task-map
      (make-mutex)                ; shutdown-mutex
      0))                         ; next-task-id

  (define (threadpool-start! pool)
    "启动线程池（创建 async 句柄和工作线程）"
    (unless (threadpool-running? pool)
      ;; 创建 async 句柄
      (let ([async-h (uv-async-init (threadpool-loop pool)
                                   (lambda (wrapper)
                                     (process-results pool)))])
        (threadpool-async-handle-set! pool async-h))
      ;; 设置运行标志
      (threadpool-running?-set! pool #t)
      ;; 创建工作线程
      (let ([workers
             (let loop ([i 0] [acc '()])
               (if (< i (threadpool-size pool))
                   (loop (+ i 1)
                         (cons (fork-thread (lambda () (worker-thread-proc pool)))
                               acc))
                   acc))])
        (threadpool-workers-set! pool workers))))

  (define (threadpool-submit! pool work callback error-handler)
    "提交任务到线程池
     work: (lambda () ...) - 工作函数
     callback: (lambda (result) ...) - 成功回调
     error-handler: (lambda (error) ...) - 错误回调
     返回: task-id"
    (unless (threadpool-running? pool)
      (error 'threadpool-submit! "threadpool not running"))
    ;; 生成任务 ID
    (let ([task-id (threadpool-next-task-id pool)])
      (threadpool-next-task-id-set! pool (+ task-id 1))
      ;; 创建任务
      (let ([task (make-task task-id work callback error-handler)])
        ;; 锁定任务对象
        (lock-object task)
        (when callback (lock-object callback))
        (when error-handler (lock-object error-handler))
        ;; 存入 task-map
        (hashtable-set! (threadpool-task-map pool) task-id task)
        ;; 提交到队列
        (queue-push! (threadpool-task-queue pool) task)
        task-id)))

  (define (threadpool-shutdown! pool)
    "关闭线程池"
    (with-mutex (threadpool-shutdown-mutex pool)
      (when (threadpool-running? pool)
        ;; 设置运行标志为 false
        (threadpool-running?-set! pool #f)
        ;; 等待一小段时间让线程退出
        (sleep (make-time 'time-duration 100000000 0)) ; 100ms
        ;; 关闭 async 句柄
        (let ([async-h (threadpool-async-handle pool)])
          (when async-h
            (uv-handle-close! async-h)
            (threadpool-async-handle-set! pool #f)))
        ;; 清空任务映射
        (let ([task-map (threadpool-task-map pool)])
          (vector-for-each
            (lambda (task)
              (unlock-object task)
              (when (task-callback task) (unlock-object (task-callback task)))
              (when (task-error-handler task) (unlock-object (task-error-handler task))))
            (hashtable-values task-map))
          (hashtable-clear! task-map)))))

) ; end library
