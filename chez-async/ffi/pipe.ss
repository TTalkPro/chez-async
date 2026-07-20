;;; ffi/pipe.ss - Pipe (命名管道) FFI 绑定
;;;
;;; 本模块提供 libuv Pipe 句柄（uv_pipe_t）的 FFI 绑定。
;;;
;;; Pipe 用于进程间通信（IPC），支持：
;;; - 本地域套接字（Unix domain socket）
;;; - Windows 命名管道
;;; - 文件描述符传递（IPC 模式）
;;;
;;; Pipe 继承自 Stream，因此也支持 stream 模块中的读写操作。
;;;
;;; 典型用例：
;;; - 服务器: init -> bind -> listen -> accept -> read/write -> close
;;; - 客户端: init -> connect -> read/write -> close
;;; - IPC: init(ipc=true) -> 用于父子进程通信

(library (chez-async ffi pipe)
  (export
    ;; 初始化
    %ffi-uv-pipe-init             ; 初始化 Pipe 句柄
    %ffi-uv-pipe-open             ; 从已有 fd 创建

    ;; 服务器操作
    %ffi-uv-pipe-bind             ; 绑定到路径
    ;; listen 使用 stream 模块的 uv_listen

    ;; 客户端操作
    %ffi-uv-pipe-connect          ; 连接到路径

    ;; 地址查询
    %ffi-uv-pipe-getsockname      ; 获取本地路径
    %ffi-uv-pipe-getpeername      ; 获取远程路径

    ;; 配置
    %ffi-uv-pipe-pending-instances ; 设置待处理实例数（Windows）
    %ffi-uv-pipe-chmod            ; 设置权限（Unix）

    ;; IPC 相关
    %ffi-uv-pipe-pending-count    ; 获取待处理的句柄数
    %ffi-uv-pipe-pending-type     ; 获取待处理句柄的类型
    )
  (import (chezscheme)
          (chez-async ffi lib)
          (chez-async internal macros))

  ;; 确保 libuv 库在此模块范围内已加载
  (define _libuv-loaded (ensure-libuv-loaded))

  ;; ========================================
  ;; Pipe 初始化
  ;; ========================================

  ;; int uv_pipe_init(uv_loop_t* loop, uv_pipe_t* handle, int ipc)
  ;; 初始化 Pipe 句柄
  ;; ipc: 非零表示此管道用于 IPC（可传递文件描述符）
  (define-ffi %ffi-uv-pipe-init "uv_pipe_init" (void* void* int) int)

  ;; int uv_pipe_open(uv_pipe_t* handle, uv_file file)
  ;; 打开已存在的文件描述符作为 Pipe 句柄
  (define-ffi %ffi-uv-pipe-open "uv_pipe_open" (void* int) int)

  ;; ========================================
  ;; Pipe 服务器
  ;; ========================================

  ;; int uv_pipe_bind(uv_pipe_t* handle, const char* name)
  ;; 绑定 Pipe 到指定路径
  ;; Unix: 路径为文件系统路径
  ;; Windows: 路径为 \\.\pipe\<name> 格式
  (define-ffi %ffi-uv-pipe-bind "uv_pipe_bind" (void* string) int)

  ;; uv_listen 在 stream.ss 中（通用接口）

  ;; ========================================
  ;; Pipe 客户端
  ;; ========================================

  ;; void uv_pipe_connect(uv_connect_t* req, uv_pipe_t* handle,
  ;;                      const char* name, uv_connect_cb cb)
  ;; 连接到指定路径的 Pipe
  ;; 注意：此函数返回 void，不像 TCP connect 返回 int
  (define %ffi-uv-pipe-connect
    (foreign-procedure "uv_pipe_connect" (void* void* string void*) void))

  ;; ========================================
  ;; 地址信息
  ;; ========================================

  ;; int uv_pipe_getsockname(const uv_pipe_t* handle, char* buffer, size_t* size)
  ;; 获取 Pipe 绑定的路径
  (define-ffi %ffi-uv-pipe-getsockname "uv_pipe_getsockname" (void* void* void*) int)

  ;; int uv_pipe_getpeername(const uv_pipe_t* handle, char* buffer, size_t* size)
  ;; 获取连接的远程路径
  (define-ffi %ffi-uv-pipe-getpeername "uv_pipe_getpeername" (void* void* void*) int)

  ;; ========================================
  ;; Pipe 配置
  ;; ========================================

  ;; void uv_pipe_pending_instances(uv_pipe_t* handle, int count)
  ;; 设置待处理的实例数（仅 Windows，用于负载均衡）
  (define %ffi-uv-pipe-pending-instances
    (foreign-procedure "uv_pipe_pending_instances" (void* int) void))

  ;; int uv_pipe_chmod(uv_pipe_t* handle, int flags)
  ;; 设置 Pipe 权限（仅 Unix）
  ;; flags: UV_READABLE, UV_WRITABLE, 或两者的组合
  (define-ffi %ffi-uv-pipe-chmod "uv_pipe_chmod" (void* int) int)

  ;; ========================================
  ;; IPC 相关
  ;; ========================================

  ;; int uv_pipe_pending_count(uv_pipe_t* handle)
  ;; 获取待处理的句柄数（用于 IPC）
  (define-ffi %ffi-uv-pipe-pending-count "uv_pipe_pending_count" (void*) int)

  ;; uv_handle_type uv_pipe_pending_type(uv_pipe_t* handle)
  ;; 获取下一个待处理句柄的类型
  (define-ffi %ffi-uv-pipe-pending-type "uv_pipe_pending_type" (void*) int)

) ; end library
