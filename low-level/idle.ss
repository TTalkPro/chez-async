;;; low-level/idle.ss - Idle 句柄低层封装
;;;
;;; Idle 句柄在事件循环空闲时运行回调。
;;;
;;; 警告：当 Idle 句柄活跃时，事件循环会在每次迭代都调用回调，
;;; 这会阻止事件循环进入睡眠状态，增加 CPU 使用率。
;;;
;;; 事件循环阶段顺序：
;;; 1. Timers（定时器到期）
;;; 2. Pending callbacks（上一轮延迟的 I/O 回调）
;;; 3. Idle handlers <- 这里执行
;;; 4. Prepare handlers
;;; 5. Poll for I/O
;;; 6. Check handlers
;;; 7. Close callbacks
;;;
;;; 典型用例：
;;; - 执行低优先级的后台任务
;;; - 在事件之间进行垃圾回收
;;; - 实现协作式多任务
;;; - 在空闲时更新 UI

(library (chez-async low-level idle)
  (export
    uv-idle-init             ; 初始化 Idle 句柄
    uv-idle-start!           ; 启动 Idle 句柄
    uv-idle-stop!            ; 停止 Idle 句柄
    )
  (import (chezscheme)
          (chez-async ffi errors)
          (chez-async ffi handles)
          (chez-async ffi idle)
          (chez-async ffi callbacks)
          (chez-async low-level handle-base)
          (chez-async internal loop-registry)
          (chez-async internal macros)
          (chez-async internal callback-registry))

  ;; ========================================
  ;; Idle 回调处理
  ;; ========================================
  ;;
  ;; 使用统一回调注册表管理 Idle 回调。
  ;; 回调签名：void (*uv_idle_cb)(uv_idle_t* handle)
  ;; 注意：使用 make-timer-callback 因为签名相同。

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

  (define-handle-init uv-idle-init idle
    %ffi-uv-idle-size %ffi-uv-idle-init
    uv-loop-ptr allocate-handle make-handle)

  (define (uv-idle-start! idle callback)
    "启动 Idle 句柄

     参数：
       idle     - Idle 句柄包装器
       callback - 回调函数 (lambda (idle) ...)

     警告：
       Idle 回调会在每次事件循环迭代时调用，
       可能导致高 CPU 使用率。确保在适当时候停止。

     说明：
       回调应该执行简短的操作，避免阻塞。
       可以在回调中调用 uv-idle-stop! 来停止自己。"
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

  (define-handle-stop! uv-idle-stop! %ffi-uv-idle-stop
    handle-ptr handle-data handle-data-set! handle-closed?)

) ; end library
