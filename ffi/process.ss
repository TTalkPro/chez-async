;;; ffi/process.ss - 进程管理 FFI 绑定
;;;
;;; 本模块提供 libuv 进程句柄（uv_process_t）的 FFI 绑定。
;;;
;;; 进程管理功能包括：
;;; - 启动子进程（spawn）
;;; - 发送信号给进程
;;; - 获取进程 PID
;;; - 进程退出回调
;;;
;;; 典型用例：
;;; - 执行外部命令并获取输出
;;; - 启动后台服务进程
;;; - 进程间通信（通过 pipe）

(library (chez-async ffi process)
  (export
    ;; 进程操作
    %ffi-uv-spawn                 ; 启动子进程
    %ffi-uv-process-kill          ; 发送信号给进程
    %ffi-uv-process-get-pid       ; 获取进程 PID

    ;; 全局进程函数
    %ffi-uv-kill                  ; 发送信号给任意 PID

    ;; 进程选项相关
    %ffi-uv-process-options-size  ; 进程选项结构大小

    ;; stdio 容器相关
    %ffi-uv-stdio-container-size  ; stdio 容器大小

    ;; 进程选项标志
    UV_PROCESS_SETUID             ; 设置子进程 UID
    UV_PROCESS_SETGID             ; 设置子进程 GID
    UV_PROCESS_WINDOWS_VERBATIM_ARGUMENTS ; Windows: 不解析参数
    UV_PROCESS_DETACHED           ; 分离进程（不随父进程退出）
    UV_PROCESS_WINDOWS_HIDE       ; Windows: 隐藏窗口
    UV_PROCESS_WINDOWS_HIDE_CONSOLE ; Windows: 隐藏控制台
    UV_PROCESS_WINDOWS_HIDE_GUI   ; Windows: 隐藏 GUI

    ;; stdio 标志
    UV_IGNORE                     ; 忽略此 stdio
    UV_CREATE_PIPE                ; 创建管道
    UV_INHERIT_FD                 ; 继承文件描述符
    UV_INHERIT_STREAM             ; 继承流
    UV_READABLE_PIPE              ; 可读管道
    UV_WRITABLE_PIPE              ; 可写管道
    UV_NONBLOCK_PIPE              ; 非阻塞管道
    UV_OVERLAPPED_PIPE            ; Windows: 重叠 I/O 管道
    )
  (import (chezscheme)
          (chez-async ffi lib)
          (chez-async internal macros))

  ;; 确保 libuv 库在此模块范围内已加载
  (define _libuv-loaded (ensure-libuv-loaded))

  ;; ========================================
  ;; 进程选项标志
  ;; ========================================

  ;; uv_process_flags
  (define UV_PROCESS_SETUID 1)
  (define UV_PROCESS_SETGID 2)
  (define UV_PROCESS_WINDOWS_VERBATIM_ARGUMENTS 4)
  (define UV_PROCESS_DETACHED 8)
  (define UV_PROCESS_WINDOWS_HIDE 16)
  (define UV_PROCESS_WINDOWS_HIDE_CONSOLE 32)
  (define UV_PROCESS_WINDOWS_HIDE_GUI 64)

  ;; ========================================
  ;; stdio 标志
  ;; ========================================

  ;; uv_stdio_flags
  (define UV_IGNORE #x00)
  (define UV_CREATE_PIPE #x01)
  (define UV_INHERIT_FD #x02)
  (define UV_INHERIT_STREAM #x04)
  (define UV_READABLE_PIPE #x10)
  (define UV_WRITABLE_PIPE #x20)
  (define UV_NONBLOCK_PIPE #x40)
  (define UV_OVERLAPPED_PIPE #x40)  ; Windows only, same value as NONBLOCK

  ;; ========================================
  ;; 进程操作
  ;; ========================================

  ;; int uv_spawn(uv_loop_t* loop, uv_process_t* handle,
  ;;              const uv_process_options_t* options)
  ;; 启动子进程
  ;; 返回 0 表示成功，负值表示错误
  (define-ffi %ffi-uv-spawn "uv_spawn" (void* void* void*) int)

  ;; int uv_process_kill(uv_process_t* handle, int signum)
  ;; 发送信号给进程
  ;; signum: 信号编号（如 SIGTERM, SIGKILL）
  (define-ffi %ffi-uv-process-kill "uv_process_kill" (void* int) int)

  ;; int uv_process_get_pid(const uv_process_t* handle)
  ;; 获取进程 PID
  ;; 返回: 进程 ID
  (define-ffi %ffi-uv-process-get-pid "uv_process_get_pid" (void*) int)

  ;; int uv_kill(int pid, int signum)
  ;; 发送信号给任意 PID
  ;; pid: 目标进程 ID
  ;; signum: 信号编号
  (define-ffi %ffi-uv-kill "uv_kill" (int int) int)

  ;; ========================================
  ;; 进程选项结构大小
  ;; ========================================
  ;;
  ;; uv_process_options_t 结构较复杂，包含：
  ;; - exit_cb: 退出回调
  ;; - file: 可执行文件路径
  ;; - args: 参数数组
  ;; - env: 环境变量数组
  ;; - cwd: 工作目录
  ;; - flags: 进程标志
  ;; - stdio_count: stdio 数量
  ;; - stdio: stdio 容器数组
  ;; - uid/gid: 用户/组 ID
  ;;
  ;; 由于 Chez Scheme 没有直接方法获取结构大小，
  ;; 我们使用硬编码值（基于 64 位系统）
  ;; 实际大小可能因平台而异

  (define (%ffi-uv-process-options-size)
    "获取 uv_process_options_t 结构大小（估算值）"
    ;; 64 位系统上的近似大小
    ;; exit_cb(8) + file(8) + args(8) + env(8) + cwd(8) +
    ;; flags(4) + padding(4) + stdio_count(4) + padding(4) +
    ;; stdio(8) + uid(4) + gid(4) = 72 bytes
    ;; 加上一些填充，使用 96 字节作为安全值
    96)

  (define (%ffi-uv-stdio-container-size)
    "获取 uv_stdio_container_t 结构大小（估算值）"
    ;; flags(4) + padding(4) + union(8) = 16 bytes
    16)

) ; end library
