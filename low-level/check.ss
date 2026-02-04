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
;;; 6. Check handlers ← 这里
;;; 7. Close callbacks

(library (chez-async low-level check)
  (export
    uv-check-init
    uv-check-start!
    uv-check-stop!
    )
  (import (chezscheme)
          (chez-async ffi errors)
          (chez-async ffi handles)
          (chez-async ffi check)
          (chez-async ffi callbacks)
          (chez-async low-level handle-base)
          (chez-async high-level event-loop)
          (chez-async internal macros)
          (chez-async internal callback-registry)
          (chez-async internal utils))

  ;; ========================================
  ;; Check 回调处理
  ;; ========================================

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

  (define (uv-check-init loop)
    "初始化 check 句柄
     loop: 事件循环
     返回: check 句柄包装器"
    (let* ([size (%ffi-uv-check-size)]
           [ptr (allocate-handle size)]
           [loop-ptr (uv-loop-ptr loop)])
      (let ([result (%ffi-uv-check-init loop-ptr ptr)])
        (when (< result 0)
          (foreign-free ptr)
          (raise-uv-error 'uv-check-init result))
        (make-handle ptr 'check loop))))

  (define (uv-check-start! check callback)
    "启动 check 句柄
     check: check 句柄包装器
     callback: 回调函数 (lambda (check) ...)"
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

  (define (uv-check-stop! check)
    "停止 check 句柄
     check: check 句柄包装器"
    (when (handle-closed? check)
      (error 'uv-check-stop! "check handle is closed"))
    (with-uv-check uv-check-stop
      (%ffi-uv-check-stop (handle-ptr check))))

) ; end library
