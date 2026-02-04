;;; high-level/cancellation.ss - 取消令牌支持
;;;
;;; 提供异步操作的取消机制

(library (chez-async high-level cancellation)
  (export
    ;; CancellationTokenSource
    make-cancellation-token-source
    cts-token
    cts-cancel!
    cts-cancelled?

    ;; CancellationToken
    token-cancelled?
    token-register!

    ;; 条件类型
    &operation-cancelled
    make-operation-cancelled-error
    operation-cancelled?

    ;; 组合器
    async-with-cancellation
    linked-token-source)

  (import (chezscheme)
          (chez-async high-level promise)
          (chez-async high-level event-loop))

  ;; ========================================
  ;; 条件类型定义
  ;; ========================================

  (define-condition-type &operation-cancelled &error
    make-operation-cancelled-error operation-cancelled?)

  ;; ========================================
  ;; 数据结构（使用闭包而不是 record）
  ;; ========================================

  (define (make-cancellation-token-source)
    "创建新的 CancellationTokenSource"
    (let ([cancelled? #f]
          [callbacks '()]
          [token #f])

      ;; 创建关联的 token
      (set! token
        (lambda (msg . args)
          (case msg
            [(cancelled?)
             cancelled?]
            [(register!)
             (let ([callback (car args)])
               (if cancelled?
                   ;; 已取消，立即调用
                   (callback)
                   ;; 未取消，注册回调
                   (set! callbacks (cons callback callbacks))))]
            [else
             (error 'token "Unknown message" msg)])))

      ;; 返回 CTS 对象
      (lambda (msg . args)
        (case msg
          [(token) token]
          [(cancelled?) cancelled?]
          [(cancel!)
           (unless cancelled?
             ;; 设置取消标志
             (set! cancelled? #t)
             ;; 调用所有回调
             (for-each
               (lambda (callback)
                 (guard (ex
                         [else
                          (format #t "[Cancellation] Error in callback: ~a~%" ex)])
                   (callback)))
               callbacks)
             ;; 清空回调列表
             (set! callbacks '()))]
          [else
           (error 'cts "Unknown message" msg)]))))

  ;; ========================================
  ;; 辅助函数
  ;; ========================================

  (define (cts-token cts)
    "获取 CancellationTokenSource 关联的令牌"
    (cts 'token))

  (define (cts-cancelled? cts)
    "检查 CancellationTokenSource 是否已取消"
    (cts 'cancelled?))

  (define (cts-cancel! cts)
    "取消 CancellationTokenSource"
    (cts 'cancel!))

  (define (token-cancelled? token)
    "检查令牌是否已被取消"
    (token 'cancelled?))

  (define (token-register! token callback)
    "注册取消时的回调函数"
    (token 'register! callback))

  ;; ========================================
  ;; async-with-cancellation
  ;; ========================================

  (define (async-with-cancellation token promise)
    "将异步操作与取消令牌关联"
    (let ([loop (uv-default-loop)])
      ;; 先检查是否已取消
      (if (token-cancelled? token)
          ;; 已取消，立即 reject
          (promise-rejected loop
            (condition
              (make-operation-cancelled-error)
              (make-message-condition "Operation was cancelled before start")))
          ;; 未取消，创建可取消的 Promise
          (make-promise loop
            (lambda (resolve reject)
              (let ([completed? #f])

                ;; 注册取消回调
                (token-register! token
                  (lambda ()
                    (unless completed?
                      (set! completed? #t)
                      (reject
                        (condition
                          (make-operation-cancelled-error)
                          (make-message-condition "Operation was cancelled"))))))

                ;; 注册 Promise 回调
                (promise-then promise
                  ;; 成功回调
                  (lambda (value)
                    (unless completed?
                      (set! completed? #t)
                      (resolve value)))
                  ;; 失败回调
                  (lambda (error)
                    (unless completed?
                      (set! completed? #t)
                      (reject error))))))))))

  ;; ========================================
  ;; linked-token-source
  ;; ========================================

  (define (linked-token-source . tokens)
    "创建链接的令牌源，任一父令牌取消时自动取消"
    (let ([new-cts (make-cancellation-token-source)])
      ;; 为每个父令牌注册回调
      (for-each
        (lambda (parent-token)
          (token-register! parent-token
            (lambda ()
              ;; 父令牌取消时，取消新令牌
              (cts-cancel! new-cts))))
        tokens)
      new-cts))

) ; end library
