;;; low-level/request-base.ss - 请求包装器基础
;;;
;;; 提供请求的 Scheme 包装器和资源管理

(library (chez-async low-level request-base)
  (export
    ;; 请求包装器类型
    make-uv-request-wrapper
    uv-request-wrapper?
    uv-request-wrapper-ptr
    uv-request-wrapper-type
    uv-request-wrapper-scheme-callback
    uv-request-wrapper-scheme-callback-set!
    uv-request-wrapper-scheme-data
    uv-request-wrapper-scheme-data-set!

    ;; 请求操作
    uv-request-cancel!

    ;; 内部辅助
    allocate-request
    store-wrapper-in-request!
    get-wrapper-from-request
    cleanup-request-wrapper!
    )
  (import (chezscheme)
          (chez-async ffi types)
          (chez-async ffi errors)
          (chez-async ffi requests)
          (chez-async ffi callbacks)
          (only (chez-async internal foreign) allocate-zeroed))

  ;; ========================================
  ;; 请求包装器记录类型
  ;; ========================================

  (define-record-type uv-request-wrapper
    (fields
      (immutable ptr)              ; uv_req_t* C 指针
      (immutable type)             ; 'write | 'connect | 'fs | ...
      (mutable scheme-callback)    ; Scheme 回调（被 lock-object）
      (mutable scheme-data))       ; 额外数据（被 lock-object）
    (protocol
      (lambda (new)
        (lambda (ptr type callback data)
          (let ([wrapper (new ptr type callback data)])
            ;; 将 wrapper 存储到 request->data 字段
            (store-wrapper-in-request! ptr wrapper)
            ;; 锁定对象防止 GC
            (when callback (lock-object callback))
            (when data (lock-object data))
            (lock-object wrapper)
            wrapper)))))

  ;; ========================================
  ;; 内存管理辅助函数
  ;; ========================================

  (define (allocate-request size)
    "分配请求内存（清零初始化）"
    (allocate-zeroed size))

  (define (store-wrapper-in-request! request-ptr wrapper)
    "将包装器对象存储到请求全局注册表"
    (register-request-wrapper! request-ptr wrapper))

  (define (get-wrapper-from-request request-ptr)
    "从请求全局注册表获取包装器对象"
    (request-ptr->wrapper request-ptr))

  (define (cleanup-request-wrapper! wrapper)
    "清理请求包装器（在回调执行后调用）"
    ;; 解锁 scheme-callback
    (let ([callback (uv-request-wrapper-scheme-callback wrapper)])
      (when callback (unlock-object callback)))
    ;; 解锁 scheme-data
    (let ([data (uv-request-wrapper-scheme-data wrapper)])
      (when data (unlock-object data)))
    ;; 从请求全局注册表中删除
    (let ([ptr (uv-request-wrapper-ptr wrapper)])
      (unregister-request-wrapper! ptr))
    ;; 解锁 wrapper 本身
    (unlock-object wrapper)
    ;; 释放请求内存
    (foreign-free (uv-request-wrapper-ptr wrapper)))

  ;; ========================================
  ;; 请求操作
  ;; ========================================

  (define (uv-request-cancel! wrapper)
    "尝试取消请求（只有 fs 和 getaddrinfo 请求支持）"
    (check-uv-result
      (%ffi-uv-cancel (uv-request-wrapper-ptr wrapper))
      'uv-request-cancel))

) ; end library
