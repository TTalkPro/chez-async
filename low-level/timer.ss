;;; low-level/timer.ss - Timer 高层封装
;;;
;;; 本模块提供 libuv 定时器的友好 API：
;;; - 单次定时器和重复定时器
;;; - 定时器控制（启动、停止、重启）
;;; - 定时器参数查询和修改
;;;
;;; 使用示例：
;;;   (let ([timer (uv-timer-init loop)])
;;;     (uv-timer-start! timer 1000 0     ; 1秒后触发，不重复
;;;       (lambda (t)
;;;         (display "Timer fired!\n")
;;;         (uv-handle-close! t)))
;;;     (uv-run loop 'default))

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
          (chez-async internal callback-registry)
          (chez-async internal handle-utils)
          (chez-async internal utils))

  ;; ========================================
  ;; 全局 Timer 回调
  ;; ========================================
  ;;
  ;; 使用统一回调注册表管理定时器回调
  ;; 回调在首次使用时延迟创建

  (define-registered-callback get-timer-callback CALLBACK-TIMER
    (lambda ()
      (make-timer-callback
        (lambda (wrapper)
          (let ([user-callback (handle-data wrapper)])
            (when user-callback
              (user-callback wrapper)))))))

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
    (with-handle-check timer uv-timer-start!
      ;; 保存回调
      (handle-data-set! timer callback)
      (lock-object callback)
      ;; 启动定时器
      (with-uv-check uv-timer-start
        (%ffi-uv-timer-start (handle-ptr timer)
                             (get-timer-callback)
                             timeout
                             repeat))))

  (define (uv-timer-stop! timer)
    "停止定时器"
    (with-handle-check timer uv-timer-stop!
      (with-uv-check uv-timer-stop
        (%ffi-uv-timer-stop (handle-ptr timer)))
      ;; 解锁之前的回调
      (let ([old-callback (handle-data timer)])
        (when old-callback
          (unlock-object old-callback)
          (handle-data-set! timer #f)))))

  (define (uv-timer-again! timer)
    "重启定时器（使用之前的 timeout 和 repeat 值）
     必须先调用过 uv-timer-start! 或 uv-timer-set-repeat!"
    (with-handle-check timer uv-timer-again!
      (with-uv-check uv-timer-again
        (%ffi-uv-timer-again (handle-ptr timer)))))

  (define (uv-timer-set-repeat! timer repeat)
    "设置定时器的重复间隔（毫秒）"
    (with-handle-check timer uv-timer-set-repeat!
      (%ffi-uv-timer-set-repeat (handle-ptr timer) repeat)))

  (define (uv-timer-get-repeat timer)
    "获取定时器的重复间隔（毫秒）"
    (with-handle-check timer uv-timer-get-repeat
      (%ffi-uv-timer-get-repeat (handle-ptr timer))))

  (define (uv-timer-get-due-in timer)
    "获取定时器下次触发的时间（毫秒）"
    (with-handle-check timer uv-timer-get-due-in
      (%ffi-uv-timer-get-due-in (handle-ptr timer))))

) ; end library
