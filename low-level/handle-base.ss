;;; low-level/handle-base.ss - 句柄包装器基础
;;;
;;; 提供句柄的 Scheme 包装器和资源管理
;;;
;;; 设计说明：
;;; 本模块依赖 internal/loop-registry 进行循环注册操作，
;;; 避免直接依赖 high-level/event-loop，打破循环依赖。

(library (chez-async low-level handle-base)
  (export
    ;; 句柄包装器类型（完整名称）
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

    ;; 简化别名（推荐使用）
    make-handle
    handle?
    handle-ptr
    handle-type
    handle-loop
    handle-data
    handle-data-set!
    handle-closed?
    handle-closed?-set!
    handle-close-callback
    handle-close-callback-set!

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
          (chez-async ffi callbacks)
          (chez-async internal loop-registry)
          (chez-async internal foreign)
          (chez-async internal callback-registry)
          (chez-async internal macros))

  ;; ========================================
  ;; 句柄包装器记录类型
  ;; ========================================
  ;;
  ;; uv-handle-wrapper 记录类型封装 libuv 句柄，提供：
  ;; - ptr: C 句柄指针
  ;; - type: 句柄类型符号（'timer, 'tcp, 'udp 等）
  ;; - loop: 关联的事件循环
  ;; - scheme-data: 用户数据（被 lock-object 保护）
  ;; - closed?: 关闭状态标志
  ;; - close-callback: 关闭时的用户回调

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
            ;; 将 wrapper 注册到 loop 的 per-loop 注册表
            (loop-register-wrapper! loop ptr wrapper)
            ;; 防止 wrapper 被 GC
            (lock-object wrapper)
            wrapper)))))

  ;; ========================================
  ;; 内存管理辅助函数
  ;; ========================================

  (define (allocate-handle size)
    "分配句柄内存
     size: 句柄大小（字节）
     返回: 分配的内存指针"
    (allocate-zeroed size))

  (define (store-wrapper-in-handle! loop handle-ptr wrapper)
    "将包装器对象存储到 loop 的 per-loop 注册表
     loop: 事件循环包装器
     handle-ptr: 句柄 C 指针
     wrapper: 句柄包装器对象"
    (loop-register-wrapper! loop handle-ptr wrapper))

  (define (get-wrapper-from-handle handle-ptr)
    "从注册表获取包装器对象
     handle-ptr: 句柄 C 指针
     返回: 句柄包装器对象，如果未找到则返回 #f
     注意：此函数使用 per-loop 注册表，通过 uv_handle_get_loop 获取 loop"
    (ptr->wrapper handle-ptr))

  ;; ========================================
  ;; 简化别名（推荐使用）
  ;; ========================================
  ;;
  ;; 提供更短的函数名，推荐在应用代码中使用
  ;; 注意：别名必须在回调定义之前，因为回调工厂函数引用这些名称

  (define make-handle make-uv-handle-wrapper)
  (define handle? uv-handle-wrapper?)
  (define handle-ptr uv-handle-wrapper-ptr)
  (define handle-type uv-handle-wrapper-type)
  (define handle-loop uv-handle-wrapper-loop)
  (define handle-data uv-handle-wrapper-scheme-data)
  (define handle-data-set! uv-handle-wrapper-scheme-data-set!)
  (define handle-closed? uv-handle-wrapper-closed?)
  (define handle-closed?-set! uv-handle-wrapper-closed?-set!)
  (define handle-close-callback uv-handle-wrapper-close-callback)
  (define handle-close-callback-set! uv-handle-wrapper-close-callback-set!)

  ;; ========================================
  ;; 资源清理
  ;; ========================================

  (define (cleanup-handle-wrapper! wrapper)
    "清理句柄包装器资源
     wrapper: 要清理的句柄包装器"
    ;; 解锁 scheme-data
    (let ([data (handle-data wrapper)])
      (when data (unlock-object data)))
    ;; 从 loop 的 per-loop 注册表中删除
    (let ([loop (handle-loop wrapper)]
          [ptr (handle-ptr wrapper)])
      (loop-unregister-wrapper! loop ptr))
    ;; 解锁 wrapper 本身
    (unlock-object wrapper)
    ;; 释放句柄内存
    (safe-free (handle-ptr wrapper)))

  ;; ========================================
  ;; 关闭回调处理
  ;; ========================================
  ;;
  ;; libuv 的关闭机制是两阶段的：
  ;; 1. 调用 uv_close(handle, close_cb) 发起关闭
  ;; 2. close_cb 在下一个事件循环迭代中被调用
  ;;
  ;; 在 close_cb 被调用之前，句柄内存不能释放，
  ;; 否则 libuv 会访问已释放的内存。因此：
  ;; - uv-handle-close! 仅设置 closed? 标志，不释放内存
  ;; - 内存释放（cleanup-handle-wrapper!）在 close_cb 内完成
  ;; - 用户的 close-callback 也在 close_cb 内调用
  ;;
  ;; 使用统一回调注册表管理关闭回调
  ;; 回调在首次使用时延迟创建

  (define-registered-callback get-close-callback CALLBACK-CLOSE
    (lambda ()
      (make-close-callback
        (lambda (wrapper)
          ;; 执行用户关闭回调
          (let ([user-cb (handle-close-callback wrapper)])
            (when user-cb
              (guard (e [else (handle-callback-error e)])
                (user-cb wrapper))))
          ;; 清理资源
          (cleanup-handle-wrapper! wrapper)))))

  ;; ========================================
  ;; 句柄操作
  ;; ========================================

  (define (uv-handle-close! wrapper . user-callback)
    "关闭句柄，确保资源正确释放
     wrapper: 句柄包装器
     user-callback: 可选的关闭完成回调 (lambda (handle) ...)"
    (unless (handle-closed? wrapper)
      (handle-closed?-set! wrapper #t)
      (when (not (null? user-callback))
        (handle-close-callback-set! wrapper (car user-callback)))
      (%ffi-uv-close (handle-ptr wrapper)
                     (get-close-callback))))

  (define (uv-handle-ref! wrapper)
    "增加句柄引用计数（防止事件循环退出）
     wrapper: 句柄包装器"
    (%ffi-uv-ref (handle-ptr wrapper)))

  (define (uv-handle-unref! wrapper)
    "减少句柄引用计数（允许事件循环退出）
     wrapper: 句柄包装器"
    (%ffi-uv-unref (handle-ptr wrapper)))

  (define (uv-handle-has-ref? wrapper)
    "检查句柄是否有引用
     wrapper: 句柄包装器
     返回: #t 如果有引用，否则 #f"
    (not (= 0 (%ffi-uv-has-ref (handle-ptr wrapper)))))

  (define (uv-handle-active? wrapper)
    "检查句柄是否活跃
     wrapper: 句柄包装器
     返回: #t 如果活跃，否则 #f"
    (not (= 0 (%ffi-uv-is-active (handle-ptr wrapper)))))

  (define (uv-handle-closing? wrapper)
    "检查句柄是否正在关闭
     wrapper: 句柄包装器
     返回: #t 如果正在关闭，否则 #f"
    (not (= 0 (%ffi-uv-is-closing (handle-ptr wrapper)))))

) ; end library
