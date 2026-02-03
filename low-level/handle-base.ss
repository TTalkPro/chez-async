;;; low-level/handle-base.ss - 句柄包装器基础
;;;
;;; 提供句柄的 Scheme 包装器和资源管理

(library (chez-async low-level handle-base)
  (export
    ;; 句柄包装器类型
    make-uv-handle-wrapper
    uv-handle-wrapper?
    uv-handle-wrapper-ptr
    uv-handle-wrapper-type
    uv-handle-wrapper-loop
    uv-handle-wrapper-scheme-data
    uv-handle-wrapper-scheme-data-set!
    uv-handle-wrapper-closed?
    uv-handle-wrapper-closed?-set!
    uv-handle-wrapper-close-callback
    uv-handle-wrapper-close-callback-set!

    ;; 句柄操作
    uv-handle-close!
    uv-handle-ref!
    uv-handle-unref!
    uv-handle-has-ref?
    uv-handle-active?
    uv-handle-closing?

    ;; 内部辅助
    allocate-handle
    store-wrapper-in-handle!
    get-wrapper-from-handle
    )
  (import (chezscheme)
          (chez-async ffi types)
          (chez-async ffi errors)
          (chez-async ffi handles)
          (chez-async ffi callbacks))

  ;; ========================================
  ;; 句柄包装器记录类型
  ;; ========================================

  (define-record-type uv-handle-wrapper
    (fields
      (immutable ptr)              ; uv_handle_t* C 指针
      (immutable type)             ; 'timer | 'tcp | 'udp | ...
      (immutable loop)             ; 关联的 loop 包装器
      (mutable scheme-data)        ; 关联的 Scheme 数据（被 lock-object）
      (mutable closed?)            ; 是否已关闭
      (mutable close-callback))    ; 关闭时的用户回调
    (protocol
      (lambda (new)
        (lambda (ptr type loop)
          (let ([wrapper (new ptr type loop #f #f #f)])
            ;; 将 wrapper 存储到 handle->data 字段（第一个字段）
            (store-wrapper-in-handle! ptr wrapper)
            ;; 防止 wrapper 被 GC
            (lock-object wrapper)
            wrapper)))))

  ;; ========================================
  ;; 内存管理辅助函数
  ;; ========================================

  (define (allocate-handle size)
    "分配句柄内存"
    (let ([ptr (foreign-alloc size)])
      ;; 初始化为 0
      (let loop ([i 0])
        (when (< i size)
          (foreign-set! 'unsigned-8 ptr i 0)
          (loop (+ i 1))))
      ptr))

  (define (store-wrapper-in-handle! handle-ptr wrapper)
    "将包装器对象存储到注册表"
    (register-ptr-wrapper! handle-ptr wrapper))

  (define (get-wrapper-from-handle handle-ptr)
    "从注册表获取包装器对象"
    (ptr->wrapper handle-ptr))

  ;; ========================================
  ;; 关闭回调处理
  ;; ========================================

  (define *close-callback* #f)

  (define (get-close-callback)
    "获取全局关闭回调（延迟创建）"
    (unless *close-callback*
      (set! *close-callback*
        (make-close-callback
          (lambda (wrapper)
            ;; 执行用户关闭回调
            (let ([user-cb (uv-handle-wrapper-close-callback wrapper)])
              (when user-cb
                (guard (e [else (handle-callback-error e)])
                  (user-cb wrapper))))
            ;; 清理资源
            (cleanup-handle-wrapper! wrapper)))))
    (foreign-callable-entry-point *close-callback*))

  (define (cleanup-handle-wrapper! wrapper)
    "清理句柄包装器资源"
    ;; 解锁 scheme-data
    (let ([data (uv-handle-wrapper-scheme-data wrapper)])
      (when data (unlock-object data)))
    ;; 从注册表中删除
    (let ([ptr (uv-handle-wrapper-ptr wrapper)])
      (unregister-ptr-wrapper! ptr))
    ;; 解锁 wrapper 本身
    (unlock-object wrapper)
    ;; 释放句柄内存
    (foreign-free (uv-handle-wrapper-ptr wrapper)))

  ;; ========================================
  ;; 句柄操作
  ;; ========================================

  (define (uv-handle-close! wrapper . user-callback)
    "关闭句柄，确保资源正确释放"
    (unless (uv-handle-wrapper-closed? wrapper)
      (uv-handle-wrapper-closed?-set! wrapper #t)
      (when (not (null? user-callback))
        (uv-handle-wrapper-close-callback-set! wrapper (car user-callback)))
      (%ffi-uv-close (uv-handle-wrapper-ptr wrapper)
                     (get-close-callback))))

  (define (uv-handle-ref! wrapper)
    "增加句柄引用计数（防止事件循环退出）"
    (%ffi-uv-ref (uv-handle-wrapper-ptr wrapper)))

  (define (uv-handle-unref! wrapper)
    "减少句柄引用计数（允许事件循环退出）"
    (%ffi-uv-unref (uv-handle-wrapper-ptr wrapper)))

  (define (uv-handle-has-ref? wrapper)
    "检查句柄是否有引用"
    (not (= 0 (%ffi-uv-has-ref (uv-handle-wrapper-ptr wrapper)))))

  (define (uv-handle-active? wrapper)
    "检查句柄是否活跃"
    (not (= 0 (%ffi-uv-is-active (uv-handle-wrapper-ptr wrapper)))))

  (define (uv-handle-closing? wrapper)
    "检查句柄是否正在关闭"
    (not (= 0 (%ffi-uv-is-closing (uv-handle-wrapper-ptr wrapper)))))

) ; end library
