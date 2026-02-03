;;; high-level/event-loop.ss - 事件循环封装
;;;
;;; 提供友好的事件循环接口

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
    )
  (import (chezscheme)
          (chez-async ffi types)
          (chez-async ffi errors)
          (chez-async ffi core))

  ;; ========================================
  ;; 事件循环包装器
  ;; ========================================

  (define-record-type uv-loop
    (fields (immutable ptr))
    (protocol
      (lambda (new)
        (lambda (ptr)
          (lock-object ptr)
          (new ptr)))))

  ;; ========================================
  ;; 事件循环创建和销毁
  ;; ========================================

  (define (uv-loop-init)
    "创建新的事件循环"
    (let* ([size (%ffi-uv-loop-size)]
           [ptr (foreign-alloc size)])
      ;; 初始化内存为 0
      (let loop ([i 0])
        (when (< i size)
          (foreign-set! 'unsigned-8 ptr i 0)
          (loop (+ i 1))))
      ;; 初始化事件循环
      (check-uv-result (%ffi-uv-loop-init ptr) 'uv-loop-init)
      (make-uv-loop ptr)))

  (define (uv-loop-close loop)
    "关闭事件循环并释放资源"
    (let ([ptr (uv-loop-ptr loop)])
      (check-uv-result (%ffi-uv-loop-close ptr) 'uv-loop-close)
      (unlock-object ptr)
      (foreign-free ptr)))

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
