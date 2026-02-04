;;; low-level/prepare.ss - Prepare 句柄低层封装
;;;
;;; Prepare 句柄在每次事件循环迭代的 I/O 轮询前运行回调。
;;;
;;; 事件循环阶段顺序：
;;; 1. Timers（定时器到期）
;;; 2. Pending callbacks（上一轮延迟的 I/O 回调）
;;; 3. Idle handlers（空闲处理器）
;;; 4. Prepare handlers <- 这里执行
;;; 5. Poll for I/O
;;; 6. Check handlers
;;; 7. Close callbacks
;;;
;;; 典型用例：
;;; - 在 I/O 轮询前执行准备工作
;;; - 更新内部状态或缓存
;;; - 设置 I/O 操作所需的数据
;;; - 性能监控（记录轮询前时间戳）

(library (chez-async low-level prepare)
  (export
    uv-prepare-init          ; 初始化 Prepare 句柄
    uv-prepare-start!        ; 启动 Prepare 句柄
    uv-prepare-stop!         ; 停止 Prepare 句柄
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
  ;;
  ;; 使用统一回调注册表管理 Prepare 回调。
  ;; 回调签名：void (*uv_prepare_cb)(uv_prepare_t* handle)
  ;; 注意：使用 make-timer-callback 因为签名相同。

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
    "初始化 Prepare 句柄

     参数：
       loop - 事件循环对象

     返回：
       新创建的 Prepare 句柄包装器

     说明：
       Prepare 句柄初始化后处于停止状态。
       使用完毕后必须调用 uv-handle-close! 释放资源。"
    (let* ([size (%ffi-uv-prepare-size)]
           [ptr (allocate-handle size)]
           [loop-ptr (uv-loop-ptr loop)])
      (let ([result (%ffi-uv-prepare-init loop-ptr ptr)])
        (when (< result 0)
          (foreign-free ptr)
          (raise-uv-error 'uv-prepare-init result))
        (make-handle ptr 'prepare loop))))

  (define (uv-prepare-start! prepare callback)
    "启动 Prepare 句柄

     参数：
       prepare  - Prepare 句柄包装器
       callback - 回调函数 (lambda (prepare) ...)

     说明：
       回调在每次 I/O 轮询前执行。
       回调应该执行快速操作，避免阻塞。"
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
    "停止 Prepare 句柄

     参数：
       prepare - Prepare 句柄包装器

     说明：
       停止后回调将不再被调用。
       可以通过 uv-prepare-start! 重新启动。"
    (when (handle-closed? prepare)
      (error 'uv-prepare-stop! "prepare handle is closed"))
    (with-uv-check uv-prepare-stop
      (%ffi-uv-prepare-stop (handle-ptr prepare))))

) ; end library
