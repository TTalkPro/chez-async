;;; low-level/timer.ss - Timer 高层封装
;;;
;;; 提供友好的 Timer API

(library (chez-async low-level timer)
  (export
    ;; Timer 创建
    uv-timer-init

    ;; Timer 操作
    uv-timer-start!
    uv-timer-stop!
    uv-timer-again!
    uv-timer-set-repeat!
    uv-timer-get-repeat
    uv-timer-get-due-in
    )
  (import (chezscheme)
          (chez-async ffi types)
          (chez-async ffi errors)
          (chez-async ffi handles)
          (chez-async ffi timer)
          (chez-async ffi callbacks)
          (chez-async low-level handle-base)
          (chez-async high-level event-loop)
          (chez-async internal macros)
          (chez-async internal utils))

  ;; ========================================
  ;; 全局 Timer 回调
  ;; ========================================

  (define *timer-callback* #f)

  (define (get-timer-callback)
    "获取全局 timer 回调（延迟创建）"
    (unless *timer-callback*
      (set! *timer-callback*
        (make-timer-callback
          (lambda (wrapper)
            (let ([user-callback (handle-data wrapper)])
              (when user-callback
                (user-callback wrapper)))))))
    (foreign-callable-entry-point *timer-callback*))

  ;; ========================================
  ;; Timer 创建
  ;; ========================================

  (define (uv-timer-init loop)
    "创建新的 timer 句柄"
    (let* ([size (%ffi-uv-timer-size)]
           [ptr (allocate-handle size)]
           [loop-ptr (uv-loop-ptr loop)])
      (with-uv-check/cleanup uv-timer-init
        (%ffi-uv-timer-init loop-ptr ptr)
        (lambda () (foreign-free ptr)))
      (make-handle ptr 'timer loop)))

  ;; ========================================
  ;; Timer 操作
  ;; ========================================

  (define (uv-timer-start! timer timeout repeat callback)
    "启动定时器
     timer: timer 句柄
     timeout: 超时时间（毫秒）
     repeat: 重复间隔（毫秒，0 表示单次）
     callback: 回调函数 (lambda (timer) ...)"
    (when (handle-closed? timer)
      (error 'uv-timer-start! "timer is closed"))
    ;; 保存回调
    (handle-data-set! timer callback)
    (lock-object callback)
    ;; 启动定时器
    (with-uv-check uv-timer-start
      (%ffi-uv-timer-start (handle-ptr timer)
                           (get-timer-callback)
                           timeout
                           repeat)))

  (define (uv-timer-stop! timer)
    "停止定时器"
    (when (handle-closed? timer)
      (error 'uv-timer-stop! "timer is closed"))
    (with-uv-check uv-timer-stop
      (%ffi-uv-timer-stop (handle-ptr timer)))
    ;; 解锁之前的回调
    (let ([old-callback (handle-data timer)])
      (when old-callback
        (unlock-object old-callback)
        (handle-data-set! timer #f))))

  (define (uv-timer-again! timer)
    "重启定时器（使用之前的 timeout 和 repeat 值）
     必须先调用过 uv-timer-start! 或 uv-timer-set-repeat!"
    (when (handle-closed? timer)
      (error 'uv-timer-again! "timer is closed"))
    (with-uv-check uv-timer-again
      (%ffi-uv-timer-again (handle-ptr timer))))

  (define (uv-timer-set-repeat! timer repeat)
    "设置定时器的重复间隔（毫秒）"
    (when (handle-closed? timer)
      (error 'uv-timer-set-repeat! "timer is closed"))
    (%ffi-uv-timer-set-repeat (handle-ptr timer) repeat))

  (define (uv-timer-get-repeat timer)
    "获取定时器的重复间隔（毫秒）"
    (when (handle-closed? timer)
      (error 'uv-timer-get-repeat "timer is closed"))
    (%ffi-uv-timer-get-repeat (handle-ptr timer)))

  (define (uv-timer-get-due-in timer)
    "获取定时器下次触发的时间（毫秒）"
    (when (handle-closed? timer)
      (error 'uv-timer-get-due-in "timer is closed"))
    (%ffi-uv-timer-get-due-in (handle-ptr timer)))

) ; end library
