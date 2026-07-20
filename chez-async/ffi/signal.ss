;;; ffi/signal.ss - Signal 处理 FFI 绑定
;;;
;;; 本模块提供 libuv 信号句柄（uv_signal_t）的 FFI 绑定。
;;;
;;; 信号句柄用于监听和处理 POSIX 信号（如 SIGINT, SIGTERM 等）。
;;; 在 Windows 上仅支持 SIGINT 和 SIGBREAK。
;;;
;;; 典型用例：
;;; - 优雅关闭: 捕获 SIGTERM/SIGINT 进行清理
;;; - 子进程管理: 捕获 SIGCHLD
;;; - 热重载: 捕获 SIGHUP 重新加载配置
;;;
;;; 注意事项：
;;; - 同一信号可以被多个句柄监听
;;; - 信号回调在事件循环线程中执行
;;; - 某些信号（如 SIGKILL, SIGSTOP）无法被捕获

(library (chez-async ffi signal)
  (export
    ;; 信号操作
    %ffi-uv-signal-init           ; 初始化信号句柄
    %ffi-uv-signal-start          ; 开始监听信号
    %ffi-uv-signal-start-oneshot  ; 一次性监听（触发后自动停止）
    %ffi-uv-signal-stop           ; 停止监听

    ;; 信号常量（POSIX）
    SIGINT      ; 中断（Ctrl+C）
    SIGTERM     ; 终止请求
    SIGHUP      ; 挂起/终端断开
    SIGQUIT     ; 退出（Ctrl+\）
    SIGABRT     ; 中止
    SIGALRM     ; 定时器
    SIGPIPE     ; 管道破裂
    SIGUSR1     ; 用户定义信号 1
    SIGUSR2     ; 用户定义信号 2
    SIGCHLD     ; 子进程状态改变
    SIGWINCH    ; 窗口大小改变
    SIGCONT     ; 继续执行
    SIGTSTP     ; 终端停止（Ctrl+Z）

    ;; Windows 特有
    SIGBREAK    ; Ctrl+Break (Windows)
    )
  (import (chezscheme)
          (chez-async ffi lib)
          (chez-async internal macros))

  ;; 确保 libuv 库在此模块范围内已加载
  (define _libuv-loaded (ensure-libuv-loaded))

  ;; ========================================
  ;; 信号常量
  ;; ========================================
  ;;
  ;; POSIX 信号编号（Linux）
  ;; 注意：不同平台的信号编号可能不同，但 libuv 会处理跨平台差异

  (define SIGHUP    1)   ; 挂起
  (define SIGINT    2)   ; 中断 (Ctrl+C)
  (define SIGQUIT   3)   ; 退出 (Ctrl+\)
  (define SIGABRT   6)   ; 中止
  (define SIGALRM   14)  ; 定时器
  (define SIGTERM   15)  ; 终止
  (define SIGUSR1   10)  ; 用户定义 1
  (define SIGUSR2   12)  ; 用户定义 2
  (define SIGCHLD   17)  ; 子进程状态改变
  (define SIGCONT   18)  ; 继续执行
  (define SIGTSTP   20)  ; 终端停止 (Ctrl+Z)
  (define SIGPIPE   13)  ; 管道破裂
  (define SIGWINCH  28)  ; 窗口大小改变

  ;; Windows 特有信号
  (define SIGBREAK  21)  ; Ctrl+Break (Windows)

  ;; ========================================
  ;; 信号句柄操作
  ;; ========================================

  ;; int uv_signal_init(uv_loop_t* loop, uv_signal_t* handle)
  ;; 初始化信号句柄
  (define-ffi %ffi-uv-signal-init "uv_signal_init" (void* void*) int)

  ;; int uv_signal_start(uv_signal_t* handle, uv_signal_cb signal_cb, int signum)
  ;; 开始监听指定信号
  ;; signal_cb: void (*uv_signal_cb)(uv_signal_t* handle, int signum)
  (define-ffi %ffi-uv-signal-start "uv_signal_start" (void* void* int) int)

  ;; int uv_signal_start_oneshot(uv_signal_t* handle, uv_signal_cb signal_cb, int signum)
  ;; 一次性监听信号（触发一次后自动停止）
  (define-ffi %ffi-uv-signal-start-oneshot "uv_signal_start_oneshot" (void* void* int) int)

  ;; int uv_signal_stop(uv_signal_t* handle)
  ;; 停止监听信号
  (define-ffi %ffi-uv-signal-stop "uv_signal_stop" (void*) int)

) ; end library
