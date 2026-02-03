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
          (chez-async high-level event-loop))

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
            (let ([user-callback (uv-handle-wrapper-scheme-data wrapper)])
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
      (check-uv-result/cleanup
        (%ffi-uv-timer-init loop-ptr ptr)
        'uv-timer-init
        (lambda () (foreign-free ptr)))
      (make-uv-handle-wrapper ptr 'timer loop)))

  ;; ========================================
  ;; Timer 操作
  ;; ========================================

  (define (uv-timer-start! timer timeout repeat callback)
    "启动定时器
     timer: timer 句柄
     timeout: 超时时间（毫秒）
     repeat: 重复间隔（毫秒，0 表示单次）
     callback: 回调函数 (lambda (timer) ...)"
    (when (uv-handle-wrapper-closed? timer)
      (error 'uv-timer-start! "timer is closed"))
    ;; 保存回调
    (uv-handle-wrapper-scheme-data-set! timer callback)
    (lock-object callback)
    ;; 启动定时器
    (check-uv-result
      (%ffi-uv-timer-start (uv-handle-wrapper-ptr timer)
                           (get-timer-callback)
                           timeout
                           repeat)
      'uv-timer-start))

  (define (uv-timer-stop! timer)
    "停止定时器"
    (when (uv-handle-wrapper-closed? timer)
      (error 'uv-timer-stop! "timer is closed"))
    (check-uv-result
      (%ffi-uv-timer-stop (uv-handle-wrapper-ptr timer))
      'uv-timer-stop)
    ;; 解锁之前的回调
    (let ([old-callback (uv-handle-wrapper-scheme-data timer)])
      (when old-callback
        (unlock-object old-callback)
        (uv-handle-wrapper-scheme-data-set! timer #f))))

  (define (uv-timer-again! timer)
    "重启定时器（使用之前的 timeout 和 repeat 值）
     必须先调用过 uv-timer-start! 或 uv-timer-set-repeat!"
    (when (uv-handle-wrapper-closed? timer)
      (error 'uv-timer-again! "timer is closed"))
    (check-uv-result
      (%ffi-uv-timer-again (uv-handle-wrapper-ptr timer))
      'uv-timer-again))

  (define (uv-timer-set-repeat! timer repeat)
    "设置定时器的重复间隔（毫秒）"
    (when (uv-handle-wrapper-closed? timer)
      (error 'uv-timer-set-repeat! "timer is closed"))
    (%ffi-uv-timer-set-repeat (uv-handle-wrapper-ptr timer) repeat))

  (define (uv-timer-get-repeat timer)
    "获取定时器的重复间隔（毫秒）"
    (when (uv-handle-wrapper-closed? timer)
      (error 'uv-timer-get-repeat "timer is closed"))
    (%ffi-uv-timer-get-repeat (uv-handle-wrapper-ptr timer)))

  (define (uv-timer-get-due-in timer)
    "获取定时器下次触发的时间（毫秒）"
    (when (uv-handle-wrapper-closed? timer)
      (error 'uv-timer-get-due-in "timer is closed"))
    (%ffi-uv-timer-get-due-in (uv-handle-wrapper-ptr timer)))

) ; end library
