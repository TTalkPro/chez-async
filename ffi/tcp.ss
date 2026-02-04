;;; ffi/tcp.ss - TCP 套接字 FFI 绑定
;;;
;;; 本模块提供 libuv TCP 句柄（uv_tcp_t）的 FFI 绑定。
;;;
;;; TCP 是最常用的网络协议，提供可靠的、有序的、双向字节流。
;;; TCP 句柄继承自流（stream），因此也支持 stream 模块中的操作。
;;;
;;; 典型用例：
;;; - 客户端：init → connect → read/write → close
;;; - 服务器：init → bind → listen → accept → read/write → close
;;;
;;; 注意：地址信息使用 sockaddr 结构，需要配合 types 模块使用

(library (chez-async ffi tcp)
  (export
    ;; 初始化
    %ffi-uv-tcp-init              ; 初始化 TCP 句柄
    %ffi-uv-tcp-init-ex           ; 初始化（指定地址族）
    %ffi-uv-tcp-open              ; 从已有 fd 创建

    ;; 服务器操作
    %ffi-uv-tcp-bind              ; 绑定地址
    %ffi-uv-tcp-listen            ; 监听连接

    ;; 客户端操作
    %ffi-uv-tcp-connect           ; 连接服务器

    ;; 套接字选项
    %ffi-uv-tcp-nodelay           ; TCP_NODELAY（禁用 Nagle）
    %ffi-uv-tcp-keepalive         ; TCP keepalive
    %ffi-uv-tcp-simultaneous-accepts ; 同时接受（Windows）

    ;; 地址查询
    %ffi-uv-tcp-getsockname       ; 获取本地地址
    %ffi-uv-tcp-getpeername       ; 获取远程地址

    ;; 其他操作
    %ffi-uv-tcp-close-reset       ; 发送 RST 关闭连接
    )
  (import (chezscheme)
          (chez-async ffi lib)
          (chez-async internal macros))

  ;; 确保 libuv 库在此模块范围内已加载
  (define _libuv-loaded (ensure-libuv-loaded))

  ;; ========================================
  ;; TCP 初始化
  ;; ========================================

  ;; int uv_tcp_init(uv_loop_t* loop, uv_tcp_t* handle)
  ;; 初始化 TCP 句柄
  (define-ffi %ffi-uv-tcp-init "uv_tcp_init" (void* void*) int)

  ;; int uv_tcp_init_ex(uv_loop_t* loop, uv_tcp_t* handle, unsigned-int flags)
  ;; 使用指定标志初始化 TCP 句柄（可指定 AF_INET/AF_INET6）
  (define-ffi %ffi-uv-tcp-init-ex "uv_tcp_init_ex" (void* void* unsigned-int) int)

  ;; int uv_tcp_open(uv_tcp_t* handle, uv_os_sock_t sock)
  ;; 打开已存在的文件描述符作为 TCP 句柄
  (define-ffi %ffi-uv-tcp-open "uv_tcp_open" (void* int) int)

  ;; ========================================
  ;; TCP 服务器
  ;; ========================================

  ;; int uv_tcp_bind(uv_tcp_t* handle, const struct sockaddr* addr, unsigned-int flags)
  ;; 绑定 TCP 套接字到地址
  ;; flags:
  ;;   UV_TCP_IPV6ONLY (1) - 只允许 IPv6 连接
  (define-ffi %ffi-uv-tcp-bind "uv_tcp_bind" (void* void* unsigned-int) int)

  ;; uv_listen is in stream.ss (通用接口)
  ;; 这里提供一个别名
  (define %ffi-uv-tcp-listen
    (foreign-procedure "uv_listen" (void* int void*) int))

  ;; ========================================
  ;; TCP 客户端
  ;; ========================================

  ;; int uv_tcp_connect(uv_connect_t* req, uv_tcp_t* handle,
  ;;                    const struct sockaddr* addr, uv_connect_cb cb)
  ;; 连接到远程地址
  (define-ffi %ffi-uv-tcp-connect "uv_tcp_connect" (void* void* void* void*) int)

  ;; ========================================
  ;; TCP 选项
  ;; ========================================

  ;; int uv_tcp_nodelay(uv_tcp_t* handle, int enable)
  ;; 启用/禁用 TCP_NODELAY（禁用 Nagle 算法）
  (define-ffi %ffi-uv-tcp-nodelay "uv_tcp_nodelay" (void* int) int)

  ;; int uv_tcp_keepalive(uv_tcp_t* handle, int enable, unsigned-int delay)
  ;; 启用/禁用 TCP keepalive
  ;; delay: 发送第一个 keepalive 探测前的空闲时间（秒）
  (define-ffi %ffi-uv-tcp-keepalive "uv_tcp_keepalive" (void* int unsigned-int) int)

  ;; int uv_tcp_simultaneous_accepts(uv_tcp_t* handle, int enable)
  ;; 启用/禁用同时接受多个连接（Windows 特有）
  (define-ffi %ffi-uv-tcp-simultaneous-accepts "uv_tcp_simultaneous_accepts" (void* int) int)

  ;; ========================================
  ;; 地址信息
  ;; ========================================

  ;; int uv_tcp_getsockname(const uv_tcp_t* handle, struct sockaddr* name, int* namelen)
  ;; 获取本地地址
  (define-ffi %ffi-uv-tcp-getsockname "uv_tcp_getsockname" (void* void* void*) int)

  ;; int uv_tcp_getpeername(const uv_tcp_t* handle, struct sockaddr* name, int* namelen)
  ;; 获取远程地址
  (define-ffi %ffi-uv-tcp-getpeername "uv_tcp_getpeername" (void* void* void*) int)

  ;; ========================================
  ;; 其他
  ;; ========================================

  ;; int uv_tcp_close_reset(uv_tcp_t* handle, uv_close_cb close_cb)
  ;; 发送 RST 重置连接（而不是正常的 FIN）
  (define-ffi %ffi-uv-tcp-close-reset "uv_tcp_close_reset" (void* void*) int)

) ; end library
