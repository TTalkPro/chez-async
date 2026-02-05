;;; high-level/event-loop.ss - 事件循环封装
;;;
;;; 提供友好的事件循环接口
;;;
;;; 设计说明：
;;; 每个 event-loop 维护自己的注册表，避免使用全局变量：
;;; - ptr-registry: C 指针 -> Scheme 包装器对象的映射
;;;
;;; 这种设计的优点：
;;; 1. 无全局状态，多个 loop 互不影响
;;; 2. 易于测试，可以创建独立的测试 loop
;;; 3. 符合 libuv 的 per-loop 架构
;;;
;;; 注意：uv-loop 记录类型和循环注册操作已提取到 internal/loop-registry.ss，
;;; 以打破 low-level 模块对此模块的循环依赖。

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

    ;; 内部 API（从 loop-registry 重新导出）
    make-uv-loop
    uv-loop?
    uv-loop-ptr

    ;; Per-loop 注册表操作（从 loop-registry 重新导出）
    loop-register-wrapper!
    loop-unregister-wrapper!
    loop-get-wrapper

    ;; Loop 查找（从 loop-registry 重新导出）
    get-loop-by-ptr

    ;; Threadpool 管理（从 loop-registry 重新导出）
    uv-loop-threadpool
    uv-loop-threadpool-set!

    ;; 临时缓冲区管理（从 loop-registry 重新导出）
    loop-store-temp-buffer!
    loop-get-temp-buffer
    )
  (import (chezscheme)
          (chez-async ffi types)
          (chez-async ffi errors)
          (chez-async ffi core)
          (chez-async internal macros)
          (chez-async internal utils)
          (chez-async internal loop-registry))

  ;; ========================================
  ;; 事件循环创建和销毁
  ;; ========================================

  (define (uv-loop-init)
    "创建新的事件循环
     返回: 新创建的事件循环对象"
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
    "关闭事件循环并释放资源
     注意：如果有线程池，需要先调用 threadpool-shutdown! 手动关闭
     loop: 要关闭的事件循环"
    (let ([ptr (uv-loop-ptr loop)])
      ;; 从全局注册表注销
      (unregister-loop! loop)
      (with-uv-check uv-loop-close
        (%ffi-uv-loop-close ptr))
      (unlock-object ptr)
      (safe-free ptr)))

  (define (uv-default-loop)
    "获取默认事件循环（全局单例）
     返回: 默认事件循环对象"
    (let ([ptr (%ffi-uv-default-loop)])
      (when (= ptr 0)
        (error 'uv-default-loop "failed to get default loop"))
      ;; 首先尝试从 registry 中查找已存在的 loop 对象
      (or (get-loop-by-ptr ptr)
          ;; 如果不存在，创建新的并注册
          (let ([loop (make-uv-loop ptr)])
            (register-loop! loop)
            loop))))

  ;; ========================================
  ;; 事件循环运行
  ;; ========================================

  (define (uv-run loop mode)
    "运行事件循环
     loop: 事件循环对象
     mode: 运行模式
       - 'default: 运行直到没有活跃句柄
       - 'once: 运行一次，可能阻塞等待 I/O
       - 'nowait: 运行一次，不阻塞
     返回: 如果还有活跃句柄返回非零值"
    (let ([mode-int (uv-run-mode->int mode)])
      (%ffi-uv-run (uv-loop-ptr loop) mode-int)))

  (define (uv-stop loop)
    "停止事件循环
     loop: 要停止的事件循环"
    (%ffi-uv-stop (uv-loop-ptr loop)))

  ;; ========================================
  ;; 事件循环状态
  ;; ========================================

  (define (uv-loop-alive? loop)
    "检查事件循环是否有活跃句柄或请求
     loop: 事件循环对象
     返回: #t 如果有活跃句柄/请求，否则 #f"
    (not (= 0 (%ffi-uv-loop-alive (uv-loop-ptr loop)))))

  ;; ========================================
  ;; 版本信息
  ;; ========================================

  (define (uv-version)
    "获取 libuv 版本号
     返回: 版本号（整数）"
    (%ffi-uv-version))

  (define (uv-version-string)
    "获取 libuv 版本字符串
     返回: 版本字符串"
    (%ffi-uv-version-string))

) ; end library
