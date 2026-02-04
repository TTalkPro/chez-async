;;; high-level/event-loop.ss - 事件循环封装
;;;
;;; 提供友好的事件循环接口
;;;
;;; 设计说明：
;;; 每个 event-loop 维护自己的注册表，避免使用全局变量：
;;; - ptr-registry: C 指针 → Scheme 包装器对象的映射
;;;
;;; 这种设计的优点：
;;; 1. 无全局状态，多个 loop 互不影响
;;; 2. 易于测试，可以创建独立的测试 loop
;;; 3. 符合 libuv 的 per-loop 架构

(library (chez-async high-level event-loop)
  (export
    ;; 事件循环创建和销毁
    uv-loop-init
    uv-loop-close
    uv-default-loop

    ;; 事件循环运行
    uv-run
    uv-stop

    ;; 事件循环状态
    uv-loop-alive?

    ;; 版本信息
    uv-version
    uv-version-string

    ;; 内部 API（低层使用）
    uv-loop-ptr

    ;; Per-loop 注册表操作
    loop-register-wrapper!
    loop-unregister-wrapper!
    loop-get-wrapper

    ;; Loop 查找（用于回调）
    get-loop-by-ptr

    ;; Threadpool 管理（per-loop）
    uv-loop-threadpool
    uv-loop-threadpool-set!

    ;; 临时缓冲区管理（per-loop）
    loop-store-temp-buffer!
    loop-get-temp-buffer
    )
  (import (chezscheme)
          (chez-async ffi types)
          (chez-async ffi errors)
          (chez-async ffi core)
          (chez-async internal macros)
          (chez-async internal utils))

  ;; ========================================
  ;; 事件循环包装器
  ;; ========================================
  ;;
  ;; uv-loop 记录类型包含：
  ;; - ptr: libuv uv_loop_t 的 C 指针
  ;; - ptr-registry: C 指针到 Scheme 包装器的哈希表
  ;; - threadpool: 关联的线程池（可选）
  ;; - temp-buffers: 临时缓冲区存储（用于 alloc 回调）
  ;;
  ;; 所有 per-loop 状态都存储在此记录中，避免全局变量

  (define-record-type uv-loop
    (fields
      (immutable ptr)            ; uv_loop_t* C 指针
      (immutable ptr-registry)   ; hashtable: C 指针 → Scheme 包装器
      (mutable threadpool)       ; 关联的线程池（懒初始化）
      (immutable temp-buffers))  ; hashtable: handle-ptr → temp buffer
    (protocol
      (lambda (new)
        (lambda (ptr)
          (lock-object ptr)
          (new ptr
               (make-eqv-hashtable)  ; ptr-registry
               #f                     ; threadpool (initially none)
               (make-eqv-hashtable)  ; temp-buffers
               )))))

  ;; ========================================
  ;; Per-loop 注册表操作
  ;; ========================================
  ;;
  ;; 这些函数替代了之前的全局注册表
  ;; 每个 handle/request 在创建时注册，关闭时注销

  (define (loop-register-wrapper! loop ptr wrapper)
    "注册 C 指针到 Scheme 包装器的映射
     loop: 事件循环
     ptr: C 指针（handle 或 request 的地址）
     wrapper: 对应的 Scheme 包装器对象"
    (hashtable-set! (uv-loop-ptr-registry loop) ptr wrapper))

  (define (loop-unregister-wrapper! loop ptr)
    "注销 C 指针的映射（通常在 handle 关闭时调用）
     loop: 事件循环
     ptr: 要注销的 C 指针"
    (hashtable-delete! (uv-loop-ptr-registry loop) ptr))

  (define (loop-get-wrapper loop ptr)
    "从 C 指针获取 Scheme 包装器
     loop: 事件循环
     ptr: C 指针
     返回: 包装器对象，如果未找到则返回 #f"
    (hashtable-ref (uv-loop-ptr-registry loop) ptr #f))

  ;; ========================================
  ;; 临时缓冲区管理（Per-loop）
  ;; ========================================
  ;;
  ;; 用于 alloc 回调中临时存储分配的缓冲区指针。
  ;; 在 read 回调完成后释放。

  (define (loop-store-temp-buffer! loop handle-ptr buffer-ptr)
    "存储临时缓冲区（用于 alloc 回调）
     loop: 事件循环
     handle-ptr: handle 的 C 指针
     buffer-ptr: 分配的缓冲区指针"
    (hashtable-set! (uv-loop-temp-buffers loop) handle-ptr buffer-ptr))

  (define (loop-get-temp-buffer loop handle-ptr)
    "获取并移除临时缓冲区
     loop: 事件循环
     handle-ptr: handle 的 C 指针
     返回: 缓冲区指针，如果未找到则返回 #f"
    (let ([buffer (hashtable-ref (uv-loop-temp-buffers loop) handle-ptr #f)])
      (when buffer
        (hashtable-delete! (uv-loop-temp-buffers loop) handle-ptr))
      buffer))

  ;; ========================================
  ;; Loop 注册表（全局）
  ;; ========================================
  ;;
  ;; 这是唯一的全局状态，用于从 C 指针查找 loop 包装器。
  ;; 在回调中，我们通过 uv_handle_get_loop 获取 loop 指针，
  ;; 然后通过此注册表找到对应的 Scheme loop 包装器。
  ;;
  ;; 条目数量很少（通常只有 1-2 个 loop），所以影响很小。

  (define *loop-registry* (make-eqv-hashtable))

  (define (register-loop! loop)
    "注册 loop 到全局注册表（在 uv-loop-init 中调用）"
    (hashtable-set! *loop-registry* (uv-loop-ptr loop) loop))

  (define (unregister-loop! loop)
    "从全局注册表注销 loop（在 uv-loop-close 中调用）"
    (hashtable-delete! *loop-registry* (uv-loop-ptr loop)))

  (define (get-loop-by-ptr ptr)
    "通过 C 指针查找 loop 包装器
     ptr: uv_loop_t* C 指针
     返回: loop 包装器，如果未找到则返回 #f"
    (hashtable-ref *loop-registry* ptr #f))

  ;; ========================================
  ;; 事件循环创建和销毁
  ;; ========================================

  (define (uv-loop-init)
    "创建新的事件循环"
    (let* ([size (%ffi-uv-loop-size)]
           [ptr (allocate-zeroed size)])
      ;; 初始化事件循环
      (with-uv-check uv-loop-init
        (%ffi-uv-loop-init ptr))
      (let ([loop (make-uv-loop ptr)])
        ;; 注册到全局 loop 注册表
        (register-loop! loop)
        loop)))

  (define (uv-loop-close loop)
    "关闭事件循环并释放资源"
    (let ([ptr (uv-loop-ptr loop)])
      ;; 从全局注册表注销
      (unregister-loop! loop)
      (with-uv-check uv-loop-close
        (%ffi-uv-loop-close ptr))
      (unlock-object ptr)
      (safe-free ptr)))

  (define (uv-default-loop)
    "获取默认事件循环（全局单例）"
    (let ([ptr (%ffi-uv-default-loop)])
      (when (= ptr 0)
        (error 'uv-default-loop "failed to get default loop"))
      (make-uv-loop ptr)))

  ;; ========================================
  ;; 事件循环运行
  ;; ========================================

  (define (uv-run loop mode)
    "运行事件循环
     mode: 'default | 'once | 'nowait
       - default: 运行直到没有活跃句柄
       - once: 运行一次，可能阻塞等待 I/O
       - nowait: 运行一次，不阻塞"
    (let ([mode-int (uv-run-mode->int mode)])
      (%ffi-uv-run (uv-loop-ptr loop) mode-int)))

  (define (uv-stop loop)
    "停止事件循环"
    (%ffi-uv-stop (uv-loop-ptr loop)))

  ;; ========================================
  ;; 事件循环状态
  ;; ========================================

  (define (uv-loop-alive? loop)
    "检查事件循环是否有活跃句柄或请求"
    (not (= 0 (%ffi-uv-loop-alive (uv-loop-ptr loop)))))

  ;; ========================================
  ;; 版本信息
  ;; ========================================

  (define (uv-version)
    "获取 libuv 版本号（整数）"
    (%ffi-uv-version))

  (define (uv-version-string)
    "获取 libuv 版本字符串"
    (%ffi-uv-version-string))

) ; end library
