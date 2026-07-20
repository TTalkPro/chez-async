;;; low-level/signal.ss - Signal 低层封装
;;;
;;; 提供 Unix 信号处理的高层封装
;;;
;;; 使用场景：
;;; - 优雅关闭服务器: (uv-signal-start! sig SIGTERM (lambda (sig signum) ...))
;;; - 热重载配置: (uv-signal-start! sig SIGHUP reload-config)
;;; - 子进程监控: (uv-signal-start! sig SIGCHLD handle-child-exit)
;;; - 中断处理: (uv-signal-start! sig SIGINT graceful-shutdown)
;;;
;;; 注意事项：
;;; - 信号处理是异步的，回调在事件循环中执行
;;; - 同一信号可以有多个处理器（多个 signal 句柄）
;;; - Windows 上只支持部分信号（SIGINT, SIGBREAK 等）

(library (chez-async low-level signal)
  (export
    ;; Signal 创建和控制
    uv-signal-init           ; 初始化信号句柄
    uv-signal-start!         ; 开始监听信号
    uv-signal-start-oneshot! ; 一次性监听信号
    uv-signal-stop!          ; 停止监听信号

    ;; 信号常量（从 ffi/signal.ss 重新导出）
    SIGINT SIGTERM SIGHUP SIGQUIT SIGABRT SIGALRM
    SIGPIPE SIGUSR1 SIGUSR2 SIGCHLD SIGWINCH
    SIGCONT SIGTSTP SIGBREAK

    ;; 辅助函数
    signum->name             ; 信号编号转名称
    )
  (import (chezscheme)
          (chez-async ffi types)
          (chez-async ffi errors)
          (chez-async ffi handles)
          (chez-async ffi signal)
          (chez-async ffi callbacks)
          (chez-async low-level handle-base)
          (chez-async internal loop-registry)
          (chez-async internal macros)
          (chez-async internal callback-registry)
          (chez-async internal handle-utils))

  ;; ========================================
  ;; 全局 Signal 回调
  ;; ========================================
  ;;
  ;; 使用统一回调注册表管理信号回调。
  ;; 回调签名：void (*uv_signal_cb)(uv_signal_t* handle, int signum)
  ;; 当信号触发时，libuv 调用此回调，传入句柄指针和信号编号。

  (define-registered-callback get-signal-callback CALLBACK-SIGNAL
    (lambda ()
      (make-signal-callback
        (lambda (wrapper signum)
          (let ([user-callback (handle-data wrapper)])
            (when user-callback
              (user-callback wrapper signum)))))))

  ;; ========================================
  ;; Signal 辅助函数
  ;; ========================================

  (define (signum->name signum)
    "将信号编号转换为名称字符串

     参数：
       signum - 信号编号

     返回：
       信号名称字符串（如 \"SIGINT\", \"SIGTERM\"）"
    (case signum
      [(1)  "SIGHUP"]
      [(2)  "SIGINT"]
      [(3)  "SIGQUIT"]
      [(6)  "SIGABRT"]
      [(10) "SIGUSR1"]
      [(12) "SIGUSR2"]
      [(13) "SIGPIPE"]
      [(14) "SIGALRM"]
      [(15) "SIGTERM"]
      [(17) "SIGCHLD"]
      [(18) "SIGCONT"]
      [(20) "SIGTSTP"]
      [(21) "SIGBREAK"]
      [(28) "SIGWINCH"]
      [else (format "SIG~a" signum)]))

  ;; ========================================
  ;; Signal 创建
  ;; ========================================

  (define-handle-init uv-signal-init signal
    %ffi-uv-signal-size %ffi-uv-signal-init
    uv-loop-ptr allocate-handle make-handle)

  ;; ========================================
  ;; Signal 控制
  ;; ========================================

  (define (uv-signal-start! signal signum callback)
    "开始监听指定信号

     参数：
       signal   - 信号句柄
       signum   - 信号编号（如 SIGINT, SIGTERM）
       callback - 回调函数 (lambda (signal signum) ...)

     说明：
       每次收到信号时都会调用回调。
       要停止监听，调用 uv-signal-stop! 或 uv-handle-close!。"
    (with-handle-check signal uv-signal-start!
      ;; 释放旧回调
      (let ([old-callback (handle-data signal)])
        (when old-callback
          (unlock-object old-callback)))
      ;; 保存用户回调
      (handle-data-set! signal callback)
      (lock-object callback)
      ;; 开始监听
      (with-uv-check uv-signal-start
        (%ffi-uv-signal-start (handle-ptr signal)
                              (get-signal-callback)
                              signum))))

  (define (uv-signal-start-oneshot! signal signum callback)
    "一次性监听指定信号

     参数：
       signal   - 信号句柄
       signum   - 信号编号
       callback - 回调函数 (lambda (signal signum) ...)

     说明：
       信号触发一次后自动停止监听。
       适用于只需要处理一次的场景（如优雅关闭）。"
    (with-handle-check signal uv-signal-start-oneshot!
      ;; 释放旧回调
      (let ([old-callback (handle-data signal)])
        (when old-callback
          (unlock-object old-callback)))
      ;; 保存用户回调
      (handle-data-set! signal callback)
      (lock-object callback)
      ;; 开始一次性监听
      (with-uv-check uv-signal-start-oneshot
        (%ffi-uv-signal-start-oneshot (handle-ptr signal)
                                       (get-signal-callback)
                                       signum))))

  (define-handle-stop! uv-signal-stop! %ffi-uv-signal-stop
    handle-ptr handle-data handle-data-set! handle-closed?)

) ; end library
