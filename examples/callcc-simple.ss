;;; examples/callcc-simple.ss - 基于 call/cc 的 async/await 简化概念验证

(import (chezscheme))

(format #t "~%========================================~%")
(format #t "基于 call/cc 的 async/await 概念验证~%")
(format #t "========================================~%")

;; ========================================
;; 1. 基本 call/cc 示例
;; ========================================

(format #t "~n【示例 1】call/cc 基础~%")

(define (example-1)
  (call/cc (lambda (k)
             (format #t "  Continuation 已捕获~%")
             (k 10)  ;; 立即调用，返回 10
             (format #t "  这行不会执行~%"))))
(format #t "  结果: ~a~%" (example-1))

;; ========================================
;; 2. 保存和恢复 continuation
;; ========================================

(format #t "~n【示例 2】保存和恢复 continuation~%")

(define saved-cont #f)

(define (save-point)
  (call/cc (lambda (k)
             (set! saved-cont k)
             "saved")))

(format #t "  第一次: ~a~%" (save-point))
(format #t "  第二次: ~a~%" (if saved-cont (saved-cont 100) "none"))

;; ========================================
;; 3. 实现 await（简化版）
;; ========================================

(format #t "~n【示例 3】模拟 await~%")

(define-syntax my-await
  (syntax-rules ()
    [(my-await value)
     (call/cc (lambda (k)
                (format #t "    [暂停] 等待值...~%")
                (format #t "    [恢复] 收到: ~a~%" value)
                (k value)))]))

(define (test-await)
  (format #t "  开始~%")
  (let ([x (my-await 42)])
    (format #t "  继续执行，x = ~a~%" x)))

(test-await)

;; ========================================
;; 4. 任务状态管理
;; ========================================

(format #t "~n【示例 4】任务状态管理~%")

;; 任务记录
(define-record-type ctask
  (fields
    (mutable id)
    (mutable state)      ; 'pending | 'running | 'completed
    (mutable result))
  (protocol
    (lambda (new)
      (lambda (id)
        (new id 'pending #f)))))

;; 创建任务
(define task-counter 0)

(define (make-ctask thunk)
  (let* ([tid task-counter]
         [task (make-ctask tid)])
    (set! task-counter (+ task-counter 1))
    (format #t "  创建任务 #~a~%" tid)
    (ctask-state-set! task 'running)
    (let ([result (thunk)])
      (ctask-result-set! task result)
      (ctask-state-set! task 'completed)
      (format #t "  任务 #~a 完成，结果 = ~a~%" tid result))
    task))

;; 测试
(define (simple-task)
  (+ 1 2 3))

(make-ctask simple-task)

;; ========================================
;; 5. Promise + call/cc
;; ========================================

(format #t "~n【示例 5】基于 call/cc 的 Promise~%")

;; 简单的 Promise
(define-record-type cpromise
  (fields
    (mutable state)
    (mutable value)
    (mutable on-fulfilled))
  (protocol
    (lambda (new)
      (lambda ()
        (new 'pending #f '())))))

(define (cpromise-resolve p v)
  (ctask-state-set! p 'fulfilled)
  (ctask-value-set! p v)
  (for-each (lambda (cb) (cb v))
            (ctask-on-fulfilled p)))

(define (cpromise-then p cb)
  (if (eq? (cpromise-state p) 'fulfilled)
      (cb (cpromise-value p))
      (cpromise-on-fulfilled-set! p
        (cons cb (cpromise-on-fulfilled p)))))

;; await Promise
(define-syntax await-promise
  (syntax-rules ()
    [(await-promise promise)
     (call/cc (lambda (k)
                (cpromise-then promise
                  (lambda (v)
                    (k v)))))]))

;; 测试
(define p1 (make-cpromise))
(cpromise-then p1
  (lambda (v)
    (format #t "  Promise 回调: ~a~%" v)))

(cpromise-resolve p1 123)

;; ========================================
;; 总结
;; ========================================

(format #t "~n========================================~%")
(format #t "总结~%")
(format #t "========================================~%")
(format #t "~ncall/cc 可以实现：~%")
(format #t "  ✓ 捕获和恢复执行状态~%")
(format #t "  ✓ 实现协程（yield/resume）~%")
(format #t "  ✓ 实现 async/await（异步编程）~%")
(format #t "  ✓ 任务状态管理~%")
(format #t "~n核心概念：~%")
(format #t "  1. (call/cc f) 捕获当前 continuation~%")
(format #t "  2. 调用保存的 continuation (k value) 恢复执行~%")
(format #t "  3. 可以实现暂停/恢复、协程、异步等~%")
(format #t "~n在 chez-async 中的应用：~%")
(format #t "  • await 暂停当前任务，保存 continuation~%")
(format #t "  • libuv 回调恢复 continuation~%")
(format #t "  • 事件循环调度任务队列~%")
(format #t "========================================~%")
