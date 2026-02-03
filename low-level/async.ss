;;; low-level/async.ss - Async handle 封装
;;;
;;; 提供 uv_async_t 的 Scheme 包装器

(library (chez-async low-level async)
  (export
    ;; Async handle 创建
    uv-async-init

    ;; Async handle 操作
    uv-async-send!
    )
  (import (chezscheme)
          (chez-async ffi types)
          (chez-async ffi errors)
          (chez-async ffi handles)
          (chez-async ffi async)
          (chez-async ffi callbacks)
          (chez-async low-level handle-base)
          (chez-async high-level event-loop))

  ;; ========================================
  ;; 全局 Async 回调
  ;; ========================================

  (define *async-callback* #f)

  (define (get-async-callback)
    "获取全局 async 回调（延迟创建）"
    (unless *async-callback*
      (set! *async-callback*
        (make-async-callback
          (lambda (wrapper)
            (let ([user-callback (uv-handle-wrapper-scheme-data wrapper)])
              (when user-callback
                (guard (e [else
                           (fprintf (current-error-port)
                                   "Error in async callback: ~a~n" e)])
                  (user-callback wrapper))))))))
    (foreign-callable-entry-point *async-callback*))

  ;; ========================================
  ;; Async handle 创建
  ;; ========================================

  (define (uv-async-init loop callback)
    "创建新的 async 句柄
     loop: uv-loop wrapper
     callback: (lambda (async-wrapper) ...) - 回调函数"
    (let* ([size (%ffi-uv-async-size)]
           [ptr (allocate-handle size)]
           [loop-ptr (uv-loop-ptr loop)])
      (check-uv-result/cleanup
        (%ffi-uv-async-init loop-ptr ptr (get-async-callback))
        'uv-async-init
        (lambda () (foreign-free ptr)))
      (let ([wrapper (make-uv-handle-wrapper ptr 'async loop)])
        ;; 保存用户回调
        (uv-handle-wrapper-scheme-data-set! wrapper callback)
        (lock-object callback)
        wrapper)))

  ;; ========================================
  ;; Async handle 操作
  ;; ========================================

  (define (uv-async-send! async-handle)
    "发送异步通知（唤醒事件循环）
     async-handle: async wrapper"
    (check-uv-result
      (%ffi-uv-async-send (uv-handle-wrapper-ptr async-handle))
      'uv-async-send))

) ; end library
