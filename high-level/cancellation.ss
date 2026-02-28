;;; high-level/cancellation.ss - 取消令牌支持
;;;
;;; 提供异步操作的取消机制，基于 .NET CancellationToken 模式。
;;;
;;; 设计说明：
;;; - cancel-source 是取消操作的控制端，持有 cancel-token
;;; - cancel-token 是取消状态的只读视图，传递给异步操作
;;; - 取消时按注册顺序调用所有回调，已取消的 token 上注册回调会立即执行
;;; - link-tokens 可将多个父 token 链接，任一取消即触发子 source 取消
;;;
;;; 数据结构使用 record 类型，字段含义：
;;; - cancel-token: cancelled?（是否已取消）、callbacks（取消时的回调列表）
;;; - cancel-source: token（关联的只读令牌）

(library (chez-async high-level cancellation)
  (export
    ;; cancel-source（新名）
    make-cancel-source
    cancel-source?
    cancel-source-token
    cancel-source-cancel!
    cancel-source-cancelled?

    ;; cancel-token（新名）
    cancel-token?
    cancel-token-cancelled?
    cancel-token-register!

    ;; 条件类型（新名）
    &cancelled
    make-cancelled-error
    cancelled-error?
    &operation-cancelled
    make-operation-cancelled-error
    operation-cancelled?

    ;; 组合器（新名）
    async-cancellable
    link-tokens

    ;; 向后兼容别名
    make-cancellation-token-source
    cts-token
    cts-cancelled?
    cts-cancel!
    token-cancelled?
    token-register!
    async-with-cancellation
    linked-token-source)

  (import (chezscheme)
          (chez-async high-level promise)
          (chez-async high-level event-loop))

  ;; ========================================
  ;; 条件类型定义
  ;; ========================================

  ;; 取消操作的条件类型，用于 reject Promise 或 guard 捕获
  (define-condition-type &cancelled &error
    make-cancelled-error cancelled-error?)

  ;; ========================================
  ;; Record 类型定义
  ;; ========================================

  ;; cancel-token: 取消状态的只读视图
  ;; - cancelled?: 是否已被取消
  ;; - callbacks: 取消时需要调用的回调函数列表
  (define-record-type cancel-token
    (fields
      (mutable cancelled?)
      (mutable callbacks))
    (protocol
      (lambda (new) (lambda () (new #f '())))))

  ;; cancel-source: 取消操作的控制端
  ;; - token: 关联的 cancel-token，传递给异步操作
  (define-record-type cancel-source
    (fields (immutable token))
    (protocol
      (lambda (new)
        (lambda ()
          (new (make-cancel-token))))))

  (define (cancel-source-cancelled? source)
    "检查 cancel-source 是否已取消"
    (cancel-token-cancelled? (cancel-source-token source)))

  (define (cancel-source-cancel! source)
    "取消 cancel-source，触发所有注册的回调"
    (let ([token (cancel-source-token source)])
      (unless (cancel-token-cancelled? token)
        ;; 设置取消标志
        (cancel-token-cancelled?-set! token #t)
        ;; 调用所有回调
        (for-each
          (lambda (callback)
            (guard (ex
                    [else
                     (format (current-error-port) "[Cancellation] Error in callback: ~a~%" ex)])
              (callback)))
          (cancel-token-callbacks token))
        ;; 清空回调列表
        (cancel-token-callbacks-set! token '()))))

  ;; ========================================
  ;; cancel-token 操作
  ;; ========================================

  (define (cancel-token-register! token callback)
    "注册取消时的回调函数（按注册顺序调用）
     如果 token 已取消，立即调用 callback"
    (if (cancel-token-cancelled? token)
        ;; 已取消，立即调用
        (callback)
        ;; 未取消，注册回调（使用 append 实现 FIFO 顺序）
        (cancel-token-callbacks-set! token
          (append (cancel-token-callbacks token) (list callback)))))

  ;; ========================================
  ;; async-cancellable - 将异步操作与取消令牌关联
  ;; ========================================

  (define (async-cancellable token promise)
    "将异步操作与取消令牌关联
     token: cancel-token
     promise: 要关联的 Promise
     返回: 新的 Promise，取消时自动 reject"
    (let ([loop (uv-default-loop)])
      ;; 先检查是否已取消
      (if (cancel-token-cancelled? token)
          ;; 已取消，立即 reject
          (promise-rejected loop
            (condition
              (make-cancelled-error)
              (make-message-condition "Operation was cancelled before start")))
          ;; 未取消，创建可取消的 Promise
          (make-promise loop
            (lambda (resolve reject)
              (let ([completed? #f])

                ;; 注册取消回调
                (cancel-token-register! token
                  (lambda ()
                    (unless completed?
                      (set! completed? #t)
                      (reject
                        (condition
                          (make-cancelled-error)
                          (make-message-condition "Operation was cancelled"))))))

                ;; 注册 Promise 回调
                (promise-then promise
                  (lambda (value)
                    (unless completed?
                      (set! completed? #t)
                      (resolve value)))
                  (lambda (error)
                    (unless completed?
                      (set! completed? #t)
                      (reject error))))))))))

  ;; ========================================
  ;; link-tokens - 链接多个令牌
  ;; ========================================

  (define (link-tokens . tokens)
    "创建链接的令牌源，任一父令牌取消时自动取消
     tokens: 父 cancel-token 列表
     返回: 新的 cancel-source"
    (let ([new-source (make-cancel-source)])
      (for-each
        (lambda (parent-token)
          (cancel-token-register! parent-token
            (lambda ()
              (cancel-source-cancel! new-source))))
        tokens)
      new-source))

  ;; ========================================
  ;; 向后兼容别名
  ;; ========================================

  (define make-cancellation-token-source make-cancel-source)
  (define (cts-token cts) (cancel-source-token cts))
  (define (cts-cancelled? cts) (cancel-source-cancelled? cts))
  (define (cts-cancel! cts) (cancel-source-cancel! cts))
  (define token-cancelled? cancel-token-cancelled?)
  (define token-register! cancel-token-register!)

  ;; 条件类型别名（使用 identifier-syntax 因为 &cancelled 是 syntax binding）
  (define-syntax &operation-cancelled (identifier-syntax &cancelled))
  (define make-operation-cancelled-error make-cancelled-error)
  (define operation-cancelled? cancelled-error?)

  ;; 组合器别名
  (define async-with-cancellation async-cancellable)
  (define linked-token-source link-tokens)

) ; end library
