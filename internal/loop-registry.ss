;;; internal/loop-registry.ss - 循环注册表
;;;
;;; 本模块提供事件循环的全局注册和 per-loop 句柄注册功能。
;;; 这是一个低层模块，被 ffi/callbacks.ss 和 low-level/handle-base.ss 使用，
;;; 而不是直接依赖 high-level/event-loop.ss。
;;;
;;; 设计目的：
;;; 1. 打破循环依赖：low-level 模块不再需要导入 high-level/event-loop
;;; 2. 集中管理循环注册：全局循环查找 + per-loop 句柄注册
;;; 3. 临时缓冲区管理：用于 alloc 回调
;;;
;;; 设计说明：
;;; 此模块定义通用的注册表操作函数，但实际的 loop 对象访问器
;;; 需要由调用者提供。为了简化，我们假设 loop 对象具有以下字段：
;;; - 第一个字段 (index 0): ptr - C 指针
;;; - 第二个字段 (index 1): ptr-registry - 句柄注册表 (hashtable)
;;; - 第四个字段 (index 3): temp-buffers - 临时缓冲区存储 (hashtable)
;;;
;;; 这与 high-level/event-loop.ss 中的 uv-loop 记录类型匹配。
;;;
;;; 全局状态说明：
;;; *loop-registry* 是必要的全局状态，用于 C 回调查找对应的 Scheme 循环对象。
;;; 这是因为 libuv 回调只提供 C 指针，我们需要从指针找到 Scheme 对象。

(library (chez-async internal loop-registry)
  (export
    ;; 全局循环注册表操作
    register-loop!           ; 注册循环到全局注册表
    unregister-loop!         ; 从全局注册表注销循环
    get-loop-by-ptr          ; 通过 C 指针查找循环

    ;; Per-loop 句柄注册操作
    loop-register-wrapper!   ; 注册句柄包装器到循环
    loop-unregister-wrapper! ; 注销句柄包装器
    loop-get-wrapper         ; 获取句柄包装器

    ;; 临时缓冲区管理（用于 alloc 回调）
    loop-store-temp-buffer!  ; 存储临时缓冲区
    loop-get-temp-buffer     ; 获取并移除临时缓冲区
    )
  (import (chezscheme))

  ;; ========================================
  ;; 全局循环注册表
  ;; ========================================
  ;;
  ;; 这是唯一的全局状态，用于从 C 指针查找 loop 包装器。
  ;; 在回调中，我们通过 uv_handle_get_loop 获取 loop 指针，
  ;; 然后通过此注册表找到对应的 Scheme loop 包装器。
  ;;
  ;; 条目数量很少（通常只有 1-2 个 loop），所以影响很小。

  (define *loop-registry* (make-eqv-hashtable))

  ;; ========================================
  ;; 内部辅助函数 - 访问 loop 记录字段
  ;; ========================================
  ;;
  ;; 使用直接的记录字段访问，假设 loop 是 uv-loop 记录类型：
  ;; - field 0: ptr
  ;; - field 1: ptr-registry
  ;; - field 2: threadpool
  ;; - field 3: temp-buffers

  (define (loop-ptr loop)
    "获取循环的 C 指针（第一个字段）"
    (let ([rtd (record-rtd loop)])
      ((record-accessor rtd 0) loop)))

  (define (loop-ptr-registry loop)
    "获取循环的句柄注册表（第二个字段）"
    (let ([rtd (record-rtd loop)])
      ((record-accessor rtd 1) loop)))

  (define (loop-temp-buffers loop)
    "获取循环的临时缓冲区存储（第四个字段）"
    (let ([rtd (record-rtd loop)])
      ((record-accessor rtd 3) loop)))

  ;; ========================================
  ;; 全局循环注册表操作
  ;; ========================================

  (define (register-loop! loop)
    "注册 loop 到全局注册表
     loop: 事件循环对象"
    (hashtable-set! *loop-registry* (loop-ptr loop) loop))

  (define (unregister-loop! loop)
    "从全局注册表注销 loop
     loop: 事件循环对象"
    (hashtable-delete! *loop-registry* (loop-ptr loop)))

  (define (get-loop-by-ptr ptr)
    "通过 C 指针查找 loop 包装器
     ptr: uv_loop_t* C 指针
     返回: loop 包装器，如果未找到则返回 #f"
    (hashtable-ref *loop-registry* ptr #f))

  ;; ========================================
  ;; Per-loop 句柄注册操作
  ;; ========================================
  ;;
  ;; 这些函数操作每个 loop 对象内部的注册表，
  ;; 用于存储和查找句柄包装器。
  ;;
  ;; 设计原则：
  ;; - 句柄注册在 make-handle 时调用
  ;; - 句柄注销在 close 回调时调用
  ;; - 查找在 C 回调中用于获取 Scheme 包装器

  (define (loop-register-wrapper! loop ptr wrapper)
    "注册 C 指针到 Scheme 包装器的映射
     loop: 事件循环
     ptr: C 指针（handle 的地址）
     wrapper: 对应的 Scheme 包装器对象"
    (hashtable-set! (loop-ptr-registry loop) ptr wrapper))

  (define (loop-unregister-wrapper! loop ptr)
    "注销 C 指针的映射（通常在 handle 关闭时调用）
     loop: 事件循环
     ptr: 要注销的 C 指针"
    (hashtable-delete! (loop-ptr-registry loop) ptr))

  (define (loop-get-wrapper loop ptr)
    "从 C 指针获取 Scheme 包装器
     loop: 事件循环
     ptr: C 指针
     返回: 包装器对象，如果未找到则返回 #f"
    (hashtable-ref (loop-ptr-registry loop) ptr #f))

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
    (hashtable-set! (loop-temp-buffers loop) handle-ptr buffer-ptr))

  (define (loop-get-temp-buffer loop handle-ptr)
    "获取并移除临时缓冲区
     loop: 事件循环
     handle-ptr: handle 的 C 指针
     返回: 缓冲区指针，如果未找到则返回 #f"
    (let ([buffer (hashtable-ref (loop-temp-buffers loop) handle-ptr #f)])
      (when buffer
        (hashtable-delete! (loop-temp-buffers loop) handle-ptr))
      buffer))

) ; end library
