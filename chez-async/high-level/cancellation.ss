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
;;; 内存与复杂度（相对旧实现的修正）：
;;; - cancel-token-register! 返回一个「注销器」thunk，调用即 O(1) 移除该回调；
;;;   回调存于 id→callback 哈希表（旧实现用 append 的列表，注册 O(n²) 且只增不减）。
;;; - async-cancellable 在被包装的 promise settle 后调用注销器，把取消回调从 token 移除，
;;;   因此长命 token 上跑成千上万个操作也不会无界累积（旧实现靠 completed? 标志失效，
;;;   闭包仍永久滞留在列表里）。
;;; - link-tokens 在子 token 取消时从所有父 token 注销，避免父 token 永久持有子 source。
;;;
;;; 取消语义（重要）：取消只会 reject 包装 promise，**不会**真正中止底层 libuv 操作
;;; （底层操作继续运行，其结果被丢弃）。这与 JS AbortController 一致。
;;; 若未来需要真正中止（uv_cancel），需在各底层操作单独接线，属独立工作项。
;;;
;;; 数据结构使用 record 类型，字段含义：
;;; - cancel-token: cancelled?（是否已取消）、callbacks（id→回调 哈希表）、next-id（FIFO 序号）
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
          (chez-async high-level promise))

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
  ;; - callbacks: id→回调 的哈希表（O(1) 增删，取消时按 id 升序 FIFO 调用）
  ;; - next-id: 单调递增的注册序号，用于恢复 FIFO 顺序
  (define-record-type cancel-token
    (fields
      (mutable cancelled?)
      (mutable callbacks)
      (mutable next-id))
    (protocol
      (lambda (new) (lambda () (new #f (make-eqv-hashtable) 0)))))

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
    "取消 cancel-source，按注册顺序触发所有注册的回调"
    (let ([token (cancel-source-token source)])
      (unless (cancel-token-cancelled? token)
        ;; 先置取消标志：此后新注册的回调会立即执行（不进表），
        ;; 回调内的注销器（hashtable-delete!）也安全，因为下面遍历的是快照
        (cancel-token-cancelled?-set! token #t)
        (let ([tbl (cancel-token-callbacks token)])
          ;; 取快照并按 id 升序（= 注册顺序）调用
          (let-values ([(ids cbs) (hashtable-entries tbl)])
            (for-each
              (lambda (pair)
                (guard (ex
                        [else
                         (format (current-error-port) "[Cancellation] Error in callback: ~a~%" ex)])
                  ((cdr pair))))
              (list-sort (lambda (a b) (< (car a) (car b)))
                         (vector->list (vector-map cons ids cbs)))))
          ;; 清空回调表，释放引用
          (hashtable-clear! tbl)))))

  ;; ========================================
  ;; cancel-token 操作
  ;; ========================================

  (define (cancel-token-register! token callback)
    "注册取消时的回调函数（按注册顺序调用）。
     如果 token 已取消，立即调用 callback。
     返回：一个注销器 thunk，调用即 O(1) 移除该回调；重复调用安全。"
    (if (cancel-token-cancelled? token)
        ;; 已取消，立即调用，返回 no-op 注销器
        (begin (callback) (lambda () (void)))
        ;; 未取消，存入 id→callback 表；返回移除该 id 的注销器
        (let ([id (cancel-token-next-id token)]
              [tbl (cancel-token-callbacks token)])
          (cancel-token-next-id-set! token (+ id 1))
          (hashtable-set! tbl id callback)
          (lambda () (hashtable-delete! tbl id)))))

  ;; ========================================
  ;; async-cancellable - 将异步操作与取消令牌关联
  ;; ========================================

  (define (cancelled-condition msg)
    (condition (make-cancelled-error) (make-message-condition msg)))

  (define (async-cancellable token promise)
    "将异步操作与取消令牌关联
     token: cancel-token
     promise: 要关联的 Promise
     返回: 新的 Promise，取消时自动 reject（取消不会中止底层操作，只丢弃其结果）

     派生 promise 与输入 promise 同属一个事件循环（修正旧实现固定用 default loop）。
     操作 settle 后会从 token 注销取消回调，长命 token 不会无界累积。"
    (let ([loop (promise-loop promise)])
      ;; 先检查是否已取消
      (if (cancel-token-cancelled? token)
          ;; 已取消，立即 reject
          (promise-rejected loop
            (cancelled-condition "Operation was cancelled before start"))
          ;; 未取消，创建可取消的 Promise
          (make-promise loop
            (lambda (resolve reject)
              (let ([completed? #f]
                    [unregister #f])
                ;; 统一的一次性收尾：置完成标志、从 token 注销取消回调、再执行动作
                (define (finish! action)
                  (unless completed?
                    (set! completed? #t)
                    (when unregister (unregister))
                    (action)))
                ;; 注册取消回调，保存注销器供 settle 时清理
                (set! unregister
                  (cancel-token-register! token
                    (lambda ()
                      (finish! (lambda () (reject (cancelled-condition "Operation was cancelled")))))))
                ;; 注册 Promise 回调
                (promise-then promise
                  (lambda (value) (finish! (lambda () (resolve value))))
                  (lambda (error) (finish! (lambda () (reject error)))))))))))

  ;; ========================================
  ;; link-tokens - 链接多个令牌
  ;; ========================================

  (define (link-tokens . tokens)
    "创建链接的令牌源，任一父令牌取消时自动取消
     tokens: 父 cancel-token 列表
     返回: 新的 cancel-source

     子令牌取消时（无论来自某个父令牌还是直接取消）会从所有父令牌注销，
     避免父令牌永久持有子 source（旧实现的泄漏点）。"
    (let* ([new-source (make-cancel-source)]
           [child (cancel-source-token new-source)]
           ;; 注册到每个父令牌，收集注销器
           [unregisters
            (map (lambda (parent-token)
                   (cancel-token-register! parent-token
                     (lambda () (cancel-source-cancel! new-source))))
                 tokens)])
      ;; 子令牌取消时，从所有父令牌注销自身回调
      (cancel-token-register! child
        (lambda () (for-each (lambda (u) (u)) unregisters)))
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
