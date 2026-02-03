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
          (chez-async high-level event-loop)
          (chez-async internal macros)
          (chez-async internal utils))

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
            (let ([user-callback (handle-data wrapper)])
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
      (with-uv-check/cleanup uv-async-init
        (%ffi-uv-async-init loop-ptr ptr (get-async-callback))
        (lambda () (foreign-free ptr)))
      (let ([wrapper (make-handle ptr 'async loop)])
        ;; 保存用户回调
        (handle-data-set! wrapper callback)
        (lock-object callback)
        wrapper)))

  ;; ========================================
  ;; Async handle 操作
  ;; ========================================

  (define (uv-async-send! async-handle)
    "发送异步通知（唤醒事件循环）
     async-handle: async wrapper"
    (with-uv-check uv-async-send
      (%ffi-uv-async-send (handle-ptr async-handle))))

) ; end library
