;;; examples/callcc-poc.ss - 基于 call/cc 的 async/await 概念验证
;;;
;;; 这个文件展示了如何使用 call/cc 实现基本的协程功能
;;; 可以作为 chez-async call/cc 版本的参考

(import (chezscheme))

;; ========================================
;; 1. 基本概念：理解 call/cc
;; ========================================

(format #t "~%=== 1. 基本 call/cc 示例 ===~%")

;; 示例 1: 简单的 continuation 捕获
(define x 0)
(set! x
  (+ 1 (call/cc (lambda (k)
                 (format #t "Continuation 被捕获~%")
                 (k 5)  ;; 立即调用 continuation
                 10))))  ;; 这行不会执行
(format #t "x = ~a (应该是 6)~%" x)

;; 示例 2: 保存和恢复 continuation
(define saved-cont #f)

(define (save-continuation)
  (call/cc (lambda (k)
             (set! saved-cont k)
             "saved")))

(format #t "~n第一次调用: ~a~%" (save-continuation))

;; 恢复 continuation
(if saved-cont
    (begin
      (format #t "恢复 continuation，传入 100~%")
      (saved-cont 100))  ;; 从保存的 point 继续
    (void))

;; ========================================
;; 2. 实现 yield/resume（协程基础）
;; ========================================

(format #t "~%=== 2. 简化的 yield 示例 ===~%")

;; 简化版：只演示一次 yield
(define yield-point #f)

(define (yield-example)
  (format #t "  1. 执行到 yield 点~%")
  (call/cc (lambda (k)
             (set! yield-point k)
             (format #t "  2. 保存 continuation~%")))
  (format #t "  4. 从 yield 恢复~%"))

(yield-example)
(format #t "  3. 主线程继续~%")
(when yield-point
  (format #t "  恢复 yield 点...~%")
  (yield-point 'continue))

;; ========================================
;; 3. 简单的 async/await 模拟
;; ========================================

(format #t "~%=== 3. 模拟 async/await ===~%")

;; 任务队列
(define task-queue '())
(define current-task #f)

;; 暂停当前任务
(define-syntax await
  (syntax-rules ()
    [(await promise)
     (call/cc (lambda (k)
                ;; 保存当前任务的 continuation
                (format #t "  [await] 暂停任务，等待 Promise...~%")
                ;; 模拟异步操作
                (let ([result promise])  ;; 实际中这里会等待
                  (format #t "  [await] 收到结果: ~a~%" result)
                  ;; 立即恢复（实际中会加入队列）
                  (k result))))]))

;; 创建异步任务
(define-syntax async
  (syntax-rules ()
    [(_ body)
     (lambda ()
       (format #t "[async] 开始执行任务~%")
       body
       (format #t "[async] 任务完成~%"))]))

;; 使用示例
(define (fetch-data)
  (async
    (begin
      (format #t "  [fetch] 开始获取数据...~%")
      (let ([data (await "模拟数据")])
        (format #t "  [fetch] 处理数据: ~a~%" data)
        data))))

(format #t "~n执行异步任务:~%")
(fetch-data)

;; ========================================
;; 4. 带状态的任务管理
;; ========================================

(format #t "~%=== 4. 带状态的任务管理 ===~%")

;; 任务状态
(define-record-type task
  (fields
    (mutable id)
    (mutable continuation)
    (mutable state)
    (mutable result))
  (protocol
    (lambda (new)
      (lambda (id)
        (new id 'pending #f #f)))))

;; 任务调度器
(define task-counter 0)
(define tasks '())

(define (create-task thunk)
  (let ([task (make-task task-counter)])
    (set! task-counter (+ task-counter 1))
    (set! tasks (cons task tasks))
    (format #t "[scheduler] 创建任务 #~a~%" (task-id task))
    ;; 启动任务
    (call/cc (lambda (return)
               (task-continuation-set! task
                 (call/cc (lambda (k)
                            (task-state-set! task 'running)
                            (let ([result (thunk)])
                              (task-result-set! task result)
                              (task-state-set! task 'completed)
                              (format #t "[scheduler] 任务 #~a 完成，结果: ~a~%"
                                      (task-id task) result)
                              (return result))))))
    task)))

;; 暂停任务
(define (task-await task)
  (call/cc (lambda (k)
             (task-continuation-set! task k)
             (task-state-set! task 'waiting)
             (format #t "[scheduler] 任务 #~a 暂停~%" (task-id task))
             ;; 模拟被调度器恢复
             (task-continuation task 'value)))))

;; 示例：带暂停的任务
(define (example-task)
  (format #t "  [task] 步骤 1: 初始化~%")
  (format #t "  [task] 步骤 2: 等待数据~%")
  ;; 这里会暂停
  (format #t "  [task] 步骤 3: 继续执行~%")
  "task-result")

(format #t "~n执行带状态的任务:~%")
(define t1 (create-task example-task))

;; ========================================
;; 5. Promise + call/cc 混合
;; ========================================

(format #t "~%=== 5. Promise + call/cc 混合 ===~%")

;; 简单的 Promise 实现（基于 call/cc）
(define-record-type promise-cc
  (fields
    (mutable state)
    (mutable value)
    (mutable callbacks))
  (protocol
    (lambda (new)
      (lambda ()
        (new 'pending #f '())))))

(define (promise-resolve p value)
  (when (eq? (promise-cc-state p) 'pending)
    (promise-cc-state-set! p 'fulfilled)
    (promise-cc-value-set! p value)
    (for-each (lambda (cb) (cb value))
              (promise-cc-callbacks p))
    (promise-cc-callbacks-set! p '())))

(define (promise-then p callback)
  (if (eq? (promise-cc-state p) 'fulfilled)
      (callback (promise-cc-value p))
      (promise-cc-callbacks-set! p
        (cons callback (promise-cc-callbacks p)))))

;; await 基于这种 Promise
(define-syntax await-cc
  (syntax-rules ()
    [(await-cc promise)
     (call/cc (lambda (k)
                (promise-then promise
                  (lambda (value)
                    (format #t "  [await-cc] 收到: ~a~%" value)
                    (k value)))))]))

;; 使用示例
(define p-cc (make-promise-cc))
(promise-then p-cc
  (lambda (v)
    (format #t "Promise 回调: ~a~%" v)))

(promise-resolve p-cc 42)

;; ========================================
;; 总结
;; ========================================

(format #t "~%=== 总结 ===~%")
(format #t "~%call/cc 的关键点：~%")
(format #t "1. (call/cc f) 捕获当前 continuation 并传给 f~%")
(format #t "2. 调用保存的 continuation 可以恢复执行~%")
(format #t "3. 可以实现 yield/resume（协程）~%")
(format #t "4. 可以实现 async/await（异步编程）~%")
(format #t "~n下一步：将这个概念整合到 chez-async 中~%")
