;;; low-level/signal.ss - Signal 低层封装
;;;
;;; 提供信号处理的高层封装
;;;
;;; 用例：
;;; - 优雅关闭服务器: (uv-signal-start! sig SIGTERM (lambda (sig signum) ...))
;;; - 热重载配置: (uv-signal-start! sig SIGHUP reload-config)
;;; - 子进程监控: (uv-signal-start! sig SIGCHLD handle-child-exit)

(library (chez-async low-level signal)
  (export
    ;; Signal 创建和控制
    uv-signal-init
    uv-signal-start!
    uv-signal-start-oneshot!
    uv-signal-stop!

    ;; 信号常量（从 ffi/signal.ss 重新导出）
    SIGINT SIGTERM SIGHUP SIGQUIT SIGABRT SIGALRM
    SIGPIPE SIGUSR1 SIGUSR2 SIGCHLD SIGWINCH
    SIGCONT SIGTSTP SIGBREAK

    ;; 辅助函数
    signum->name
    )
  (import (chezscheme)
          (chez-async ffi types)
          (chez-async ffi errors)
          (chez-async ffi handles)
          (chez-async ffi signal)
          (chez-async ffi callbacks)
          (chez-async low-level handle-base)
          (chez-async high-level event-loop)
          (chez-async internal macros)
          (chez-async internal callback-registry)
          (chez-async internal handle-utils))

  ;; ========================================
  ;; 全局 Signal 回调
  ;; ========================================
  ;;
  ;; 使用统一回调注册表管理信号回调

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
    "将信号编号转换为名称字符串"
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

  (define (uv-signal-init loop)
    "创建信号句柄
     loop: 事件循环"
    (let* ([size (%ffi-uv-signal-size)]
           [ptr (allocate-handle size)]
           [loop-ptr (uv-loop-ptr loop)])
      (with-uv-check/cleanup uv-signal-init
        (%ffi-uv-signal-init loop-ptr ptr)
        (lambda () (foreign-free ptr)))
      (make-handle ptr 'signal loop)))

  ;; ========================================
  ;; Signal 控制
  ;; ========================================

  (define (uv-signal-start! signal signum callback)
    "开始监听指定信号
     signal: 信号句柄
     signum: 信号编号（如 SIGINT, SIGTERM）
     callback: 回调函数 (lambda (signal signum) ...)"
    (with-handle-check signal uv-signal-start!
      ;; 保存用户回调
      (handle-data-set! signal callback)
      (lock-object callback)
      ;; 开始监听
      (with-uv-check uv-signal-start
        (%ffi-uv-signal-start (handle-ptr signal)
                              (get-signal-callback)
                              signum))))

  (define (uv-signal-start-oneshot! signal signum callback)
    "一次性监听指定信号（触发一次后自动停止）
     signal: 信号句柄
     signum: 信号编号
     callback: 回调函数 (lambda (signal signum) ...)"
    (with-handle-check signal uv-signal-start-oneshot!
      ;; 保存用户回调
      (handle-data-set! signal callback)
      (lock-object callback)
      ;; 开始一次性监听
      (with-uv-check uv-signal-start-oneshot
        (%ffi-uv-signal-start-oneshot (handle-ptr signal)
                                       (get-signal-callback)
                                       signum))))

  (define (uv-signal-stop! signal)
    "停止监听信号
     signal: 信号句柄"
    (with-handle-check signal uv-signal-stop!
      (with-uv-check uv-signal-stop
        (%ffi-uv-signal-stop (handle-ptr signal)))
      ;; 清理回调
      (let ([callback (handle-data signal)])
        (when callback
          (unlock-object callback)
          (handle-data-set! signal #f)))))

) ; end library
