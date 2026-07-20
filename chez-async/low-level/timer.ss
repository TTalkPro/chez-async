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
;;;
;;; 定时器类型：
;;; - 单次定时器：repeat = 0，触发一次后需手动重启或关闭
;;; - 重复定时器：repeat > 0，按间隔持续触发直到停止

(library (chez-async low-level timer)
  (export
    ;; Timer 创建
    uv-timer-init           ; 初始化定时器句柄

    ;; Timer 操作
    uv-timer-start!         ; 启动定时器
    uv-timer-stop!          ; 停止定时器
    uv-timer-again!         ; 重启定时器
    uv-timer-set-repeat!    ; 设置重复间隔
    uv-timer-get-repeat     ; 获取重复间隔
    uv-timer-get-due-in     ; 获取下次触发时间
    )
  (import (chezscheme)
          (chez-async ffi types)
          (chez-async ffi errors)
          (chez-async ffi handles)
          (chez-async ffi timer)
          (chez-async ffi callbacks)
          (chez-async low-level handle-base)
          (chez-async internal loop-registry)
          (chez-async internal macros)
          (chez-async internal callback-registry)
          (chez-async internal handle-utils))

  ;; ========================================
  ;; 全局 Timer 回调
  ;; ========================================
  ;;
  ;; 使用统一回调注册表管理定时器回调。
  ;; 回调在首次使用时延迟创建，避免库加载顺序问题。
  ;;
  ;; 回调签名：void (*uv_timer_cb)(uv_timer_t* handle)
  ;; 当定时器触发时，libuv 调用此回调，传入定时器句柄指针。
  ;; 回调从 handle-data 获取用户回调并调用。

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

  (define-handle-init uv-timer-init timer
    %ffi-uv-timer-size %ffi-uv-timer-init
    uv-loop-ptr allocate-handle make-handle)

  ;; ========================================
  ;; Timer 操作
  ;; ========================================

  (define (uv-timer-start! timer timeout repeat callback)
    "启动定时器

     参数：
       timer    - 定时器句柄
       timeout  - 首次触发延迟（毫秒），0 表示立即触发
       repeat   - 重复间隔（毫秒），0 表示单次触发
       callback - 回调函数 (lambda (timer) ...)

     说明：
       如果定时器已启动，会先停止再重新启动。
       回调在事件循环线程中执行，避免长时间阻塞。"
    (with-handle-check timer uv-timer-start!
      ;; 释放旧回调
      (let ([old-callback (handle-data timer)])
        (when old-callback
          (unlock-object old-callback)))
      ;; 保存回调
      (handle-data-set! timer callback)
      (lock-object callback)
      ;; 启动定时器
      (with-uv-check uv-timer-start
        (%ffi-uv-timer-start (handle-ptr timer)
                             (get-timer-callback)
                             timeout
                             repeat))))

  (define-handle-stop! uv-timer-stop! %ffi-uv-timer-stop
    handle-ptr handle-data handle-data-set! handle-closed?)

  (define (uv-timer-again! timer)
    "重启定时器

     参数：
       timer - 定时器句柄

     说明：
       使用之前设置的 timeout 和 repeat 值重新启动定时器。
       如果 repeat 为 0，此函数无效。
       必须先调用过 uv-timer-start! 或 uv-timer-set-repeat!。"
    (with-handle-check timer uv-timer-again!
      (with-uv-check uv-timer-again
        (%ffi-uv-timer-again (handle-ptr timer)))))

  (define (uv-timer-set-repeat! timer repeat)
    "设置定时器的重复间隔

     参数：
       timer  - 定时器句柄
       repeat - 重复间隔（毫秒），0 表示单次触发

     说明：
       此设置会影响下次 uv-timer-again! 调用的行为。
       如果定时器正在运行，当前周期不受影响，下一周期生效。"
    (with-handle-check timer uv-timer-set-repeat!
      (%ffi-uv-timer-set-repeat (handle-ptr timer) repeat)))

  (define (uv-timer-get-repeat timer)
    "获取定时器的重复间隔

     参数：
       timer - 定时器句柄

     返回：
       重复间隔（毫秒），0 表示单次触发"
    (with-handle-check timer uv-timer-get-repeat
      (%ffi-uv-timer-get-repeat (handle-ptr timer))))

  (define (uv-timer-get-due-in timer)
    "获取定时器下次触发的剩余时间

     参数：
       timer - 定时器句柄

     返回：
       距离下次触发的时间（毫秒）
       如果定时器未启动，返回 0"
    (with-handle-check timer uv-timer-get-due-in
      (%ffi-uv-timer-get-due-in (handle-ptr timer))))

) ; end library
