;;; low-level/check.ss - Check 句柄低层封装
;;;
;;; Check 句柄在每次事件循环迭代的 I/O 轮询后运行回调。
;;;
;;; 事件循环阶段顺序：
;;; 1. Timers（定时器到期）
;;; 2. Pending callbacks（上一轮延迟的 I/O 回调）
;;; 3. Idle handlers（空闲处理器）
;;; 4. Prepare handlers
;;; 5. Poll for I/O
;;; 6. Check handlers <- 这里执行
;;; 7. Close callbacks
;;;
;;; 典型用例：
;;; - 在 I/O 轮询后执行清理工作
;;; - 处理需要在 I/O 完成后立即执行的任务
;;; - 性能监控（记录轮询后时间戳）
;;; - 与 Prepare 配合实现精确计时

(library (chez-async low-level check)
  (export
    uv-check-init            ; 初始化 Check 句柄
    uv-check-start!          ; 启动 Check 句柄
    uv-check-stop!           ; 停止 Check 句柄
    )
  (import (chezscheme)
          (chez-async ffi errors)
          (chez-async ffi handles)
          (chez-async ffi check)
          (chez-async ffi callbacks)
          (chez-async low-level handle-base)
          (chez-async internal loop-registry)
          (chez-async internal macros)
          (chez-async internal callback-registry))

  ;; ========================================
  ;; Check 回调处理
  ;; ========================================
  ;;
  ;; 使用统一回调注册表管理 Check 回调。
  ;; 回调签名：void (*uv_check_cb)(uv_check_t* handle)
  ;; 注意：使用 make-timer-callback 因为签名相同。

  (define-registered-callback get-check-callback CALLBACK-CHECK
    (lambda ()
      (make-timer-callback  ; 使用相同签名: void (*cb)(uv_handle_t*)
        (lambda (wrapper)
          (let ([user-callback (handle-data wrapper)])
            (when (and user-callback (procedure? user-callback))
              (user-callback wrapper)))))))

  ;; ========================================
  ;; Check 句柄操作
  ;; ========================================

  (define-handle-init uv-check-init check
    %ffi-uv-check-size %ffi-uv-check-init
    uv-loop-ptr allocate-handle make-handle)

  (define (uv-check-start! check callback)
    "启动 Check 句柄

     参数：
       check    - Check 句柄包装器
       callback - 回调函数 (lambda (check) ...)

     说明：
       回调在每次 I/O 轮询后执行。
       回调应该执行快速操作，避免阻塞。"
    (when (handle-closed? check)
      (error 'uv-check-start! "check handle is closed"))
    ;; 保存用户回调
    (let ([old-data (handle-data check)])
      (when old-data (unlock-object old-data)))
    (handle-data-set! check callback)
    (when callback (lock-object callback))
    ;; 启动
    (with-uv-check uv-check-start
      (%ffi-uv-check-start (handle-ptr check)
                           (get-check-callback))))

  (define-handle-stop! uv-check-stop! %ffi-uv-check-stop
    handle-ptr handle-data handle-data-set! handle-closed?)

) ; end library
