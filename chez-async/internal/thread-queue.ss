;;; internal/thread-queue.ss - 通用线程安全 FIFO 队列
;;;
;;; 从 low-level/threadpool.ss 提炼出来的双列表 FIFO + mutex + condition，
;;; 供 threadpool（结果/任务队列）与 runtime（提交队列、completion-queue）共用。
;;;
;;; 数据结构：双列表 FIFO
;;;   - out：出队端（正序），in：入队端（逆序）
;;;   - push 到 in、pop 从 out；out 空时把 in 反转搬到 out
;;;   - push/pop 均摊 O(1)
;;;
;;; 线程安全：
;;;   - 所有操作在同一 mutex 下；not-empty condition 供阻塞式 pop 使用
;;;   - push! 后 condition-signal 唤醒一个等待者
;;;
;;; 唤醒约定（供 runtime 使用）：
;;;   - blocking-pop! 用谓词 continue? 支持外部关停：continue? 返回 #f 时
;;;     函数解除阻塞返回 #f（不取任何元素）
;;;   - condition 通过 tq-condition 暴露，允许外部（如 shutdown）broadcast

(library (chez-async internal thread-queue)
  (export
    make-thread-queue
    thread-queue?
    tq-mutex
    tq-condition
    tq-push!
    tq-empty?          ; 需调用方持有 mutex
    tq-pop-all!        ; 取出并清空（自加锁）
    tq-blocking-pop!   ; 阻塞取一个，或 continue? 返回 #f 时解除
    tq-try-pop!)       ; 非阻塞取一个，空则返回哨兵
  (import (chezscheme))

  (define-record-type (thread-queue make-thread-queue-record thread-queue?)
    (fields
      (mutable out)              ; 出队端（正序）
      (mutable in)               ; 入队端（逆序）
      (immutable mutex)
      (immutable condition)))    ; not-empty

  (define (make-thread-queue)
    (make-thread-queue-record '() '() (make-mutex) (make-condition)))

  (define (tq-mutex q) (thread-queue-mutex q))
  (define (tq-condition q) (thread-queue-condition q))

  (define (tq-empty? q)
    "队列是否为空（调用方需持有 mutex）"
    (and (null? (thread-queue-out q))
         (null? (thread-queue-in q))))

  (define (tq-push! q item)
    "入队（线程安全）— 均摊 O(1)，并 signal 一个等待者"
    (with-mutex (thread-queue-mutex q)
      (thread-queue-in-set! q (cons item (thread-queue-in q)))
      (condition-signal (thread-queue-condition q))))

  (define (tq-pop-internal! q)
    "内部 pop（调用方需持有 mutex 且队列非空）— 均摊 O(1)"
    (when (null? (thread-queue-out q))
      (thread-queue-out-set! q (reverse (thread-queue-in q)))
      (thread-queue-in-set! q '()))
    (let ([item (car (thread-queue-out q))])
      (thread-queue-out-set! q (cdr (thread-queue-out q)))
      item))

  (define (tq-blocking-pop! q continue?)
    "阻塞取一个元素，直到有元素或 continue? 返回 #f。
     continue?: (lambda () bool) — 返回 #f 时解除阻塞、函数返回 #f。
     被 condition-broadcast 唤醒后会重新检查 continue? 与队列。"
    (with-mutex (thread-queue-mutex q)
      (let loop ()
        (cond
          [(not (continue?)) #f]
          [(not (tq-empty? q)) (tq-pop-internal! q)]
          [else
           (condition-wait (thread-queue-condition q) (thread-queue-mutex q))
           (loop)]))))

  (define tq-empty-sentinel (list 'thread-queue-empty))

  (define (tq-try-pop! q)
    "非阻塞取一个元素；空则返回 tq-empty-sentinel（用 eq? 判定）。
     哨兵作为第二返回值一并给出，方便调用方 (call-with-values) 判空。"
    (with-mutex (thread-queue-mutex q)
      (if (tq-empty? q)
          (values tq-empty-sentinel #t)
          (values (tq-pop-internal! q) #f))))

  (define (tq-pop-all! q)
    "取出并清空所有元素，返回正序列表（自加锁）"
    (with-mutex (thread-queue-mutex q)
      (let ([out (thread-queue-out q)]
            [in (thread-queue-in q)])
        (thread-queue-out-set! q '())
        (thread-queue-in-set! q '())
        (append out (reverse in)))))

) ; end library
