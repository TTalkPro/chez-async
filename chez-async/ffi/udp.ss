;;; ffi/udp.ss - UDP 套接字 FFI 绑定
;;;
;;; 本模块提供 libuv UDP 句柄（uv_udp_t）的 FFI 绑定。
;;;
;;; UDP 是无连接的数据报协议，适用于需要低延迟或广播/多播的场景。
;;; UDP 句柄不继承自流（stream），有自己独立的发送/接收接口。
;;;
;;; 典型用例：
;;; - 接收: init -> bind -> recv_start -> recv_stop -> close
;;; - 发送: init -> send -> close
;;; - 连接模式: init -> connect -> send/recv -> close

(library (chez-async ffi udp)
  (export
    ;; 初始化
    %ffi-uv-udp-init              ; 初始化 UDP 句柄
    %ffi-uv-udp-init-ex           ; 初始化（指定地址族）
    %ffi-uv-udp-open              ; 从已有 fd 创建

    ;; 绑定/连接
    %ffi-uv-udp-bind              ; 绑定地址
    %ffi-uv-udp-connect           ; 连接到远程地址

    ;; 发送
    %ffi-uv-udp-send              ; 异步发送数据报
    %ffi-uv-udp-try-send          ; 同步尝试发送

    ;; 接收
    %ffi-uv-udp-recv-start        ; 开始接收数据
    %ffi-uv-udp-recv-stop         ; 停止接收数据

    ;; 地址查询
    %ffi-uv-udp-getsockname       ; 获取本地地址
    %ffi-uv-udp-getpeername       ; 获取远程地址（连接模式）

    ;; 选项设置
    %ffi-uv-udp-set-broadcast     ; 设置广播选项
    %ffi-uv-udp-set-ttl           ; 设置 TTL
    %ffi-uv-udp-set-membership    ; 加入/离开多播组
    %ffi-uv-udp-set-multicast-loop      ; 设置多播回环
    %ffi-uv-udp-set-multicast-ttl       ; 设置多播 TTL
    %ffi-uv-udp-set-multicast-interface ; 设置多播接口
    %ffi-uv-udp-set-source-membership   ; 源特定多播

    ;; 发送队列
    %ffi-uv-udp-get-send-queue-size   ; 获取发送队列大小
    %ffi-uv-udp-get-send-queue-count  ; 获取发送队列数量
    )
  (import (chezscheme)
          (chez-async ffi lib)
          (chez-async internal macros))

  ;; 确保 libuv 库在此模块范围内已加载
  (define _libuv-loaded (ensure-libuv-loaded))

  ;; ========================================
  ;; UDP 初始化
  ;; ========================================

  ;; int uv_udp_init(uv_loop_t* loop, uv_udp_t* handle)
  ;; 初始化 UDP 句柄
  (define-ffi %ffi-uv-udp-init "uv_udp_init" (void* void*) int)

  ;; int uv_udp_init_ex(uv_loop_t* loop, uv_udp_t* handle, unsigned-int flags)
  ;; 使用指定标志初始化 UDP 句柄（可指定 AF_INET/AF_INET6）
  (define-ffi %ffi-uv-udp-init-ex "uv_udp_init_ex" (void* void* unsigned-int) int)

  ;; int uv_udp_open(uv_udp_t* handle, uv_os_sock_t sock)
  ;; 打开已存在的文件描述符作为 UDP 句柄
  (define-ffi %ffi-uv-udp-open "uv_udp_open" (void* int) int)

  ;; ========================================
  ;; UDP 绑定/连接
  ;; ========================================

  ;; int uv_udp_bind(uv_udp_t* handle, const struct sockaddr* addr, unsigned-int flags)
  ;; 绑定 UDP 套接字到地址
  ;; flags:
  ;;   UV_UDP_IPV6ONLY (1) - 只允许 IPv6
  ;;   UV_UDP_REUSEADDR (4) - 允许地址重用
  (define-ffi %ffi-uv-udp-bind "uv_udp_bind" (void* void* unsigned-int) int)

  ;; int uv_udp_connect(uv_udp_t* handle, const struct sockaddr* addr)
  ;; 将 UDP 句柄连接到远程地址
  ;; 连接后可以使用 uv_udp_send 不指定地址发送数据
  ;; 传入 NULL 地址可断开连接
  (define-ffi %ffi-uv-udp-connect "uv_udp_connect" (void* void*) int)

  ;; ========================================
  ;; UDP 发送
  ;; ========================================

  ;; int uv_udp_send(uv_udp_send_t* req, uv_udp_t* handle,
  ;;                 const uv_buf_t bufs[], unsigned int nbufs,
  ;;                 const struct sockaddr* addr, uv_udp_send_cb send_cb)
  ;; 异步发送 UDP 数据报
  (define-ffi %ffi-uv-udp-send "uv_udp_send" (void* void* void* unsigned-int void* void*) int)

  ;; int uv_udp_try_send(uv_udp_t* handle, const uv_buf_t bufs[],
  ;;                     unsigned int nbufs, const struct sockaddr* addr)
  ;; 同步尝试发送 UDP 数据报（非阻塞）
  ;; 返回发送的字节数，或 UV_EAGAIN 表示需要等待
  (define-ffi %ffi-uv-udp-try-send "uv_udp_try_send" (void* void* unsigned-int void*) int)

  ;; ========================================
  ;; UDP 接收
  ;; ========================================

  ;; int uv_udp_recv_start(uv_udp_t* handle, uv_alloc_cb alloc_cb, uv_udp_recv_cb recv_cb)
  ;; 开始接收 UDP 数据
  ;; recv_cb 的签名:
  ;;   void (*uv_udp_recv_cb)(uv_udp_t* handle, ssize_t nread, const uv_buf_t* buf,
  ;;                          const struct sockaddr* addr, unsigned flags)
  (define-ffi %ffi-uv-udp-recv-start "uv_udp_recv_start" (void* void* void*) int)

  ;; int uv_udp_recv_stop(uv_udp_t* handle)
  ;; 停止接收 UDP 数据
  (define-ffi %ffi-uv-udp-recv-stop "uv_udp_recv_stop" (void*) int)

  ;; ========================================
  ;; 地址信息
  ;; ========================================

  ;; int uv_udp_getsockname(const uv_udp_t* handle, struct sockaddr* name, int* namelen)
  ;; 获取本地地址
  (define-ffi %ffi-uv-udp-getsockname "uv_udp_getsockname" (void* void* void*) int)

  ;; int uv_udp_getpeername(const uv_udp_t* handle, struct sockaddr* name, int* namelen)
  ;; 获取远程地址（仅在连接模式有效）
  (define-ffi %ffi-uv-udp-getpeername "uv_udp_getpeername" (void* void* void*) int)

  ;; ========================================
  ;; UDP 选项
  ;; ========================================

  ;; int uv_udp_set_broadcast(uv_udp_t* handle, int on)
  ;; 启用/禁用 SO_BROADCAST
  (define-ffi %ffi-uv-udp-set-broadcast "uv_udp_set_broadcast" (void* int) int)

  ;; int uv_udp_set_ttl(uv_udp_t* handle, int ttl)
  ;; 设置 IP_TTL（1-255）
  (define-ffi %ffi-uv-udp-set-ttl "uv_udp_set_ttl" (void* int) int)

  ;; int uv_udp_set_membership(uv_udp_t* handle, const char* multicast_addr,
  ;;                           const char* interface_addr, uv_membership membership)
  ;; 加入或离开多播组
  ;; membership: UV_JOIN_GROUP (0) 或 UV_LEAVE_GROUP (1)
  (define-ffi %ffi-uv-udp-set-membership "uv_udp_set_membership" (void* string string int) int)

  ;; int uv_udp_set_multicast_loop(uv_udp_t* handle, int on)
  ;; 启用/禁用 IP_MULTICAST_LOOP
  (define-ffi %ffi-uv-udp-set-multicast-loop "uv_udp_set_multicast_loop" (void* int) int)

  ;; int uv_udp_set_multicast_ttl(uv_udp_t* handle, int ttl)
  ;; 设置 IP_MULTICAST_TTL（1-255）
  (define-ffi %ffi-uv-udp-set-multicast-ttl "uv_udp_set_multicast_ttl" (void* int) int)

  ;; int uv_udp_set_multicast_interface(uv_udp_t* handle, const char* interface_addr)
  ;; 设置多播发送接口
  (define-ffi %ffi-uv-udp-set-multicast-interface "uv_udp_set_multicast_interface" (void* string) int)

  ;; int uv_udp_set_source_membership(uv_udp_t* handle,
  ;;                                   const char* multicast_addr,
  ;;                                   const char* interface_addr,
  ;;                                   const char* source_addr,
  ;;                                   uv_membership membership)
  ;; 源特定多播（SSM）
  (define-ffi %ffi-uv-udp-set-source-membership "uv_udp_set_source_membership"
    (void* string string string int) int)

  ;; ========================================
  ;; 发送队列
  ;; ========================================

  ;; size_t uv_udp_get_send_queue_size(const uv_udp_t* handle)
  ;; 获取发送队列中待发送的字节数
  (define-ffi %ffi-uv-udp-get-send-queue-size "uv_udp_get_send_queue_size" (void*) size_t)

  ;; size_t uv_udp_get_send_queue_count(const uv_udp_t* handle)
  ;; 获取发送队列中待发送的请求数
  (define-ffi %ffi-uv-udp-get-send-queue-count "uv_udp_get_send_queue_count" (void*) size_t)

) ; end library
