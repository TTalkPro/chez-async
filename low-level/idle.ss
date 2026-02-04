;;; low-level/idle.ss - Idle 句柄低层封装
;;;
;;; Idle 句柄在事件循环空闲时运行回调。
;;; 注意：当 Idle 句柄活跃时，事件循环会在每次迭代都调用回调，
;;; 这会阻止事件循环进入睡眠状态，增加 CPU 使用率。
;;;
;;; 事件循环阶段顺序：
;;; 1. Timers（定时器到期）
;;; 2. Pending callbacks（上一轮延迟的 I/O 回调）
;;; 3. Idle handlers ← 这里
;;; 4. Prepare handlers
;;; 5. Poll for I/O
;;; 6. Check handlers
;;; 7. Close callbacks
;;;
;;; 典型用例：
;;; - 执行低优先级的后台任务
;;; - 在事件之间进行垃圾回收
;;; - 实现协作式多任务

(library (chez-async low-level idle)
  (export
    uv-idle-init
    uv-idle-start!
    uv-idle-stop!
    )
  (import (chezscheme)
          (chez-async ffi errors)
          (chez-async ffi handles)
          (chez-async ffi idle)
          (chez-async ffi callbacks)
          (chez-async low-level handle-base)
          (chez-async high-level event-loop)
          (chez-async internal macros)
          (chez-async internal callback-registry)
          (chez-async internal utils))

  ;; ========================================
  ;; Idle 回调处理
  ;; ========================================

  (define-registered-callback get-idle-callback CALLBACK-IDLE
    (lambda ()
      (make-timer-callback  ; 使用相同签名: void (*cb)(uv_handle_t*)
        (lambda (wrapper)
          (let ([user-callback (handle-data wrapper)])
            (when (and user-callback (procedure? user-callback))
              (user-callback wrapper)))))))

  ;; ========================================
  ;; Idle 句柄操作
  ;; ========================================

  (define (uv-idle-init loop)
    "初始化 idle 句柄
     loop: 事件循环
     返回: idle 句柄包装器"
    (let* ([size (%ffi-uv-idle-size)]
           [ptr (allocate-handle size)]
           [loop-ptr (uv-loop-ptr loop)])
      (let ([result (%ffi-uv-idle-init loop-ptr ptr)])
        (when (< result 0)
          (foreign-free ptr)
          (raise-uv-error 'uv-idle-init result))
        (make-handle ptr 'idle loop))))

  (define (uv-idle-start! idle callback)
    "启动 idle 句柄
     idle: idle 句柄包装器
     callback: 回调函数 (lambda (idle) ...)

     警告：Idle 回调会在每次事件循环迭代时调用，
     可能导致高 CPU 使用率。确保在适当时候停止。"
    (when (handle-closed? idle)
      (error 'uv-idle-start! "idle handle is closed"))
    ;; 保存用户回调
    (let ([old-data (handle-data idle)])
      (when old-data (unlock-object old-data)))
    (handle-data-set! idle callback)
    (when callback (lock-object callback))
    ;; 启动
    (with-uv-check uv-idle-start
      (%ffi-uv-idle-start (handle-ptr idle)
                          (get-idle-callback))))

  (define (uv-idle-stop! idle)
    "停止 idle 句柄
     idle: idle 句柄包装器"
    (when (handle-closed? idle)
      (error 'uv-idle-stop! "idle handle is closed"))
    (with-uv-check uv-idle-stop
      (%ffi-uv-idle-stop (handle-ptr idle))))

) ; end library
