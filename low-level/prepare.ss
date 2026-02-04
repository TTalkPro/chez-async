;;; low-level/prepare.ss - Prepare 句柄低层封装
;;;
;;; Prepare 句柄在每次事件循环迭代的 I/O 轮询前运行回调。
;;;
;;; 事件循环阶段顺序：
;;; 1. Timers（定时器到期）
;;; 2. Pending callbacks（上一轮延迟的 I/O 回调）
;;; 3. Idle handlers（空闲处理器）
;;; 4. Prepare handlers ← 这里
;;; 5. Poll for I/O
;;; 6. Check handlers
;;; 7. Close callbacks

(library (chez-async low-level prepare)
  (export
    uv-prepare-init
    uv-prepare-start!
    uv-prepare-stop!
    )
  (import (chezscheme)
          (chez-async ffi errors)
          (chez-async ffi handles)
          (chez-async ffi prepare)
          (chez-async ffi callbacks)
          (chez-async low-level handle-base)
          (chez-async high-level event-loop)
          (chez-async internal macros)
          (chez-async internal callback-registry)
          (chez-async internal utils))

  ;; ========================================
  ;; Prepare 回调处理
  ;; ========================================

  (define-registered-callback get-prepare-callback CALLBACK-PREPARE
    (lambda ()
      (make-timer-callback  ; 使用相同签名: void (*cb)(uv_handle_t*)
        (lambda (wrapper)
          (let ([user-callback (handle-data wrapper)])
            (when (and user-callback (procedure? user-callback))
              (user-callback wrapper)))))))

  ;; ========================================
  ;; Prepare 句柄操作
  ;; ========================================

  (define (uv-prepare-init loop)
    "初始化 prepare 句柄
     loop: 事件循环
     返回: prepare 句柄包装器"
    (let* ([size (%ffi-uv-prepare-size)]
           [ptr (allocate-handle size)]
           [loop-ptr (uv-loop-ptr loop)])
      (let ([result (%ffi-uv-prepare-init loop-ptr ptr)])
        (when (< result 0)
          (foreign-free ptr)
          (raise-uv-error 'uv-prepare-init result))
        (make-handle ptr 'prepare loop))))

  (define (uv-prepare-start! prepare callback)
    "启动 prepare 句柄
     prepare: prepare 句柄包装器
     callback: 回调函数 (lambda (prepare) ...)"
    (when (handle-closed? prepare)
      (error 'uv-prepare-start! "prepare handle is closed"))
    ;; 保存用户回调
    (let ([old-data (handle-data prepare)])
      (when old-data (unlock-object old-data)))
    (handle-data-set! prepare callback)
    (when callback (lock-object callback))
    ;; 启动
    (with-uv-check uv-prepare-start
      (%ffi-uv-prepare-start (handle-ptr prepare)
                             (get-prepare-callback))))

  (define (uv-prepare-stop! prepare)
    "停止 prepare 句柄
     prepare: prepare 句柄包装器"
    (when (handle-closed? prepare)
      (error 'uv-prepare-stop! "prepare handle is closed"))
    (with-uv-check uv-prepare-stop
      (%ffi-uv-prepare-stop (handle-ptr prepare))))

) ; end library
