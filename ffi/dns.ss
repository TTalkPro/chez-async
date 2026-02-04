;;; ffi/dns.ss - DNS 解析 FFI 绑定
;;;
;;; 本模块提供 libuv DNS 解析功能的 FFI 绑定。
;;;
;;; 包含两种解析方向：
;;; - getaddrinfo: 主机名/服务名 → 地址（正向解析）
;;; - getnameinfo: 地址 → 主机名/服务名（反向解析）
;;;
;;; 这些操作都是异步的，不会阻塞事件循环。
;;; libuv 使用线程池来执行底层的 DNS 查询。
;;;
;;; 数据结构：
;;; - addrinfo: POSIX 标准结构，包含解析结果
;;; - hints: 用于控制解析行为的提示结构

(library (chez-async ffi dns)
  (export
    ;; DNS 解析函数
    %ffi-uv-getaddrinfo    ; 异步正向解析
    %ffi-uv-freeaddrinfo   ; 释放解析结果
    %ffi-uv-getnameinfo    ; 异步反向解析

    ;; addrinfo 结构字段访问
    addrinfo-ai-flags      ; 获取标志
    addrinfo-ai-family     ; 获取地址族
    addrinfo-ai-socktype   ; 获取套接字类型
    addrinfo-ai-protocol   ; 获取协议
    addrinfo-ai-addrlen    ; 获取地址长度
    addrinfo-ai-addr       ; 获取地址指针
    addrinfo-ai-canonname  ; 获取规范名称
    addrinfo-ai-next       ; 获取下一个结果

    ;; hints 结构管理
    make-addrinfo-hints    ; 创建提示结构
    free-addrinfo-hints    ; 释放提示结构

    ;; getaddrinfo 标志常量
    AI_PASSIVE             ; 用于服务器绑定
    AI_CANONNAME           ; 请求规范名称
    AI_NUMERICHOST         ; 不进行 DNS 查询
    AI_NUMERICSERV         ; 服务必须是数字
    AI_V4MAPPED            ; 返回 IPv4 映射的 IPv6 地址
    AI_ALL                 ; 返回所有地址
    AI_ADDRCONFIG          ; 仅返回本机支持的地址类型

    ;; getnameinfo 常量
    NI_MAXHOST             ; 主机名最大长度
    NI_MAXSERV             ; 服务名最大长度
    NI_NUMERICHOST         ; 返回数字形式的主机
    NI_NUMERICSERV         ; 返回数字形式的服务
    NI_NOFQDN              ; 不返回完全限定域名
    NI_NAMEREQD            ; 必须返回名称
    NI_DGRAM               ; 数据报服务
    )
  (import (chezscheme)
          (chez-async ffi lib)
          (chez-async ffi types)
          (chez-async internal macros))

  ;; 确保 libuv 库在此模块范围内已加载
  (define _libuv-loaded (ensure-libuv-loaded))

  ;; ========================================
  ;; addrinfo 结构（POSIX 标准）
  ;; ========================================

  ;; struct addrinfo 的大小在不同平台可能不同
  ;; 这里定义字段偏移量（基于 Linux x86_64）
  (define addrinfo-size 48)  ; sizeof(struct addrinfo) on Linux x86_64

  ;; 字段偏移量
  (define ai-flags-offset 0)      ; int
  (define ai-family-offset 4)     ; int
  (define ai-socktype-offset 8)   ; int
  (define ai-protocol-offset 12)  ; int
  (define ai-addrlen-offset 16)   ; socklen_t (4 bytes on most systems)
  (define ai-addr-offset 24)      ; struct sockaddr* (8 bytes on x86_64)
  (define ai-canonname-offset 32) ; char* (8 bytes on x86_64)
  (define ai-next-offset 40)      ; struct addrinfo* (8 bytes on x86_64)

  ;; addrinfo 字段访问函数
  (define (addrinfo-ai-flags ptr)
    (foreign-ref 'int ptr ai-flags-offset))

  (define (addrinfo-ai-family ptr)
    (foreign-ref 'int ptr ai-family-offset))

  (define (addrinfo-ai-socktype ptr)
    (foreign-ref 'int ptr ai-socktype-offset))

  (define (addrinfo-ai-protocol ptr)
    (foreign-ref 'int ptr ai-protocol-offset))

  (define (addrinfo-ai-addrlen ptr)
    (foreign-ref 'unsigned-32 ptr ai-addrlen-offset))

  (define (addrinfo-ai-addr ptr)
    (foreign-ref 'void* ptr ai-addr-offset))

  (define (addrinfo-ai-canonname ptr)
    (foreign-ref 'void* ptr ai-canonname-offset))

  (define (addrinfo-ai-next ptr)
    (foreign-ref 'void* ptr ai-next-offset))

  ;; ========================================
  ;; hints 结构创建
  ;; ========================================

  (define (make-addrinfo-hints family socktype protocol flags)
    "创建 addrinfo hints 结构
     family: AF_UNSPEC (0), AF_INET (2), AF_INET6 (10)
     socktype: SOCK_STREAM (1), SOCK_DGRAM (2), 0 for any
     protocol: 通常为 0
     flags: AI_* 标志的组合"
    (let ([ptr (foreign-alloc addrinfo-size)])
      ;; 初始化为 0
      (do ([i 0 (+ i 1)])
          ((= i addrinfo-size))
        (foreign-set! 'unsigned-8 ptr i 0))
      ;; 设置字段
      (foreign-set! 'int ptr ai-flags-offset flags)
      (foreign-set! 'int ptr ai-family-offset family)
      (foreign-set! 'int ptr ai-socktype-offset socktype)
      (foreign-set! 'int ptr ai-protocol-offset protocol)
      ptr))

  (define (free-addrinfo-hints ptr)
    "释放 hints 结构"
    (foreign-free ptr))

  ;; ========================================
  ;; 常量
  ;; ========================================

  ;; getaddrinfo flags
  (define AI_PASSIVE     #x0001)
  (define AI_CANONNAME   #x0002)
  (define AI_NUMERICHOST #x0004)
  (define AI_NUMERICSERV #x0400)
  (define AI_V4MAPPED    #x0008)
  (define AI_ALL         #x0010)
  (define AI_ADDRCONFIG  #x0020)

  ;; getnameinfo flags and limits
  (define NI_MAXHOST 1025)
  (define NI_MAXSERV 32)
  (define NI_NUMERICHOST #x0001)
  (define NI_NUMERICSERV #x0002)
  (define NI_NOFQDN      #x0004)
  (define NI_NAMEREQD    #x0008)
  (define NI_DGRAM       #x0010)

  ;; ========================================
  ;; DNS 解析 FFI
  ;; ========================================

  ;; int uv_getaddrinfo(uv_loop_t* loop, uv_getaddrinfo_t* req,
  ;;                    uv_getaddrinfo_cb getaddrinfo_cb,
  ;;                    const char* node, const char* service,
  ;;                    const struct addrinfo* hints)
  ;; 异步 DNS 解析
  (define-ffi %ffi-uv-getaddrinfo "uv_getaddrinfo"
    (void* void* void* string string void*) int)

  ;; void uv_freeaddrinfo(struct addrinfo* ai)
  ;; 释放 getaddrinfo 返回的结果
  (define-ffi %ffi-uv-freeaddrinfo "uv_freeaddrinfo" (void*) void)

  ;; int uv_getnameinfo(uv_loop_t* loop, uv_getnameinfo_t* req,
  ;;                    uv_getnameinfo_cb getnameinfo_cb,
  ;;                    const struct sockaddr* addr, int flags)
  ;; 反向 DNS 解析（IP 到主机名）
  (define-ffi %ffi-uv-getnameinfo "uv_getnameinfo"
    (void* void* void* void* int) int)

) ; end library
