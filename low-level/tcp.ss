;;; low-level/tcp.ss - TCP 低层封装
;;;
;;; 提供 TCP 套接字的高层封装

(library (chez-async low-level tcp)
  (export
    ;; TCP 创建
    uv-tcp-init
    uv-tcp-init-ex
    uv-tcp-open

    ;; TCP 服务器
    uv-tcp-bind
    uv-tcp-listen
    uv-tcp-accept

    ;; TCP 客户端
    uv-tcp-connect

    ;; TCP 选项
    uv-tcp-nodelay!
    uv-tcp-keepalive!
    uv-tcp-simultaneous-accepts!

    ;; 地址信息
    uv-tcp-getsockname
    uv-tcp-getpeername

    ;; Stream 操作（从 stream 模块重新导出）
    uv-read-start!
    uv-read-stop!
    uv-write!
    uv-try-write
    uv-shutdown!
    uv-stream-readable?
    uv-stream-writable?
    uv-stream-write-queue-size
    )
  (import (chezscheme)
          (chez-async ffi types)
          (chez-async ffi errors)
          (chez-async ffi handles)
          (chez-async ffi tcp)
          (chez-async ffi requests)
          (chez-async ffi callbacks)
          (chez-async low-level handle-base)
          (chez-async low-level request-base)
          (chez-async low-level stream)
          (chez-async low-level sockaddr)
          (chez-async high-level event-loop)
          (chez-async internal macros)
          (chez-async internal callback-registry)
          (chez-async internal utils))

  ;; ========================================
  ;; 全局 Connect 回调
  ;; ========================================
  ;;
  ;; 使用统一回调注册表管理 TCP 连接回调
  ;; 回调在首次使用时延迟创建

  (define-registered-callback get-connect-callback CALLBACK-CONNECT
    (lambda ()
      (make-connect-callback
        (lambda (req-wrapper status)
          (let ([user-callback (uv-request-wrapper-scheme-callback req-wrapper)]
                [tcp-handle (uv-request-wrapper-scheme-data req-wrapper)])
            ;; 调用用户回调
            (when user-callback
              (if (< status 0)
                  (user-callback tcp-handle (make-uv-error status (%ffi-uv-err-name status) 'connect))
                  (user-callback tcp-handle #f)))
            ;; 清理请求
            (cleanup-request-wrapper! req-wrapper))))))

  ;; ========================================
  ;; TCP 创建
  ;; ========================================

  (define (uv-tcp-init loop)
    "创建 TCP 句柄
     loop: 事件循环"
    (let* ([size (%ffi-uv-tcp-size)]
           [ptr (allocate-handle size)]
           [loop-ptr (uv-loop-ptr loop)])
      (with-uv-check/cleanup uv-tcp-init
        (%ffi-uv-tcp-init loop-ptr ptr)
        (lambda () (foreign-free ptr)))
      (make-handle ptr 'tcp loop)))

  (define (uv-tcp-init-ex loop flags)
    "创建 TCP 句柄（指定地址族）
     loop: 事件循环
     flags: 地址族标志（AF_INET 或 AF_INET6）"
    (let* ([size (%ffi-uv-tcp-size)]
           [ptr (allocate-handle size)]
           [loop-ptr (uv-loop-ptr loop)])
      (with-uv-check/cleanup uv-tcp-init-ex
        (%ffi-uv-tcp-init-ex loop-ptr ptr flags)
        (lambda () (foreign-free ptr)))
      (make-handle ptr 'tcp loop)))

  (define (uv-tcp-open tcp fd)
    "打开已存在的文件描述符作为 TCP 句柄
     tcp: TCP 句柄
     fd: 文件描述符"
    (when (handle-closed? tcp)
      (error 'uv-tcp-open "tcp handle is closed"))
    (with-uv-check uv-tcp-open
      (%ffi-uv-tcp-open (handle-ptr tcp) fd)))

  ;; ========================================
  ;; TCP 服务器
  ;; ========================================

  (define uv-tcp-bind
    (case-lambda
      [(tcp addr port)
       (uv-tcp-bind tcp addr port 0)]
      [(tcp addr port flags)
       "绑定 TCP 套接字到地址
        tcp: TCP 句柄
        addr: IP 地址字符串
        port: 端口号
        flags: 绑定标志（可选）"
       (when (handle-closed? tcp)
         (error 'uv-tcp-bind "tcp handle is closed"))
       (let ([sockaddr (parse-address addr port)])
         (guard (e [else (free-sockaddr sockaddr) (raise e)])
           (with-uv-check uv-tcp-bind
             (%ffi-uv-tcp-bind (handle-ptr tcp) sockaddr flags))
           (free-sockaddr sockaddr)))]))

  (define (uv-tcp-listen tcp backlog callback)
    "监听传入连接
     tcp: TCP 句柄（需要先绑定）
     backlog: 等待队列长度
     callback: 回调函数 (lambda (server error-or-#f) ...)"
    (uv-listen! tcp backlog callback))

  (define (uv-tcp-accept server)
    "接受传入的连接，返回新的 TCP 句柄
     server: 服务器 TCP 句柄"
    (when (handle-closed? server)
      (error 'uv-tcp-accept "server tcp handle is closed"))
    ;; 创建新的 TCP 句柄来接受连接
    (let ([client (uv-tcp-init (handle-loop server))])
      (guard (e [else (uv-handle-close! client) (raise e)])
        (uv-accept! server client))
      client))

  ;; ========================================
  ;; TCP 客户端
  ;; ========================================

  (define (uv-tcp-connect tcp addr port callback)
    "连接到远程地址
     tcp: TCP 句柄
     addr: 远程 IP 地址字符串
     port: 远程端口号
     callback: 回调函数 (lambda (tcp error-or-#f) ...)"
    (when (handle-closed? tcp)
      (error 'uv-tcp-connect "tcp handle is closed"))
    ;; 解析地址
    (let ([sockaddr (parse-address addr port)])
      (guard (e [else (free-sockaddr sockaddr) (raise e)])
        ;; 分配连接请求
        (let* ([req-size (%ffi-uv-connect-req-size)]
               [req-ptr (allocate-request req-size)]
               [req-wrapper (make-uv-request-wrapper req-ptr 'connect callback tcp)])
          ;; 执行连接
          (let ([result (%ffi-uv-tcp-connect req-ptr
                                              (handle-ptr tcp)
                                              sockaddr
                                              (get-connect-callback))])
            (free-sockaddr sockaddr)
            (when (< result 0)
              (cleanup-request-wrapper! req-wrapper)
              (raise-uv-error 'uv-tcp-connect result)))))))

  ;; ========================================
  ;; TCP 选项
  ;; ========================================

  (define (uv-tcp-nodelay! tcp enable?)
    "启用/禁用 TCP_NODELAY（禁用 Nagle 算法）
     tcp: TCP 句柄
     enable?: 是否启用"
    (when (handle-closed? tcp)
      (error 'uv-tcp-nodelay! "tcp handle is closed"))
    (with-uv-check uv-tcp-nodelay
      (%ffi-uv-tcp-nodelay (handle-ptr tcp) (if enable? 1 0))))

  (define uv-tcp-keepalive!
    (case-lambda
      [(tcp enable?)
       (uv-tcp-keepalive! tcp enable? 0)]
      [(tcp enable? delay)
       "启用/禁用 TCP keepalive
        tcp: TCP 句柄
        enable?: 是否启用
        delay: 发送第一个 keepalive 探测前的空闲时间（秒）"
       (when (handle-closed? tcp)
         (error 'uv-tcp-keepalive! "tcp handle is closed"))
       (with-uv-check uv-tcp-keepalive
         (%ffi-uv-tcp-keepalive (handle-ptr tcp) (if enable? 1 0) delay))]))

  (define (uv-tcp-simultaneous-accepts! tcp enable?)
    "启用/禁用同时接受多个连接（Windows 特有）
     tcp: TCP 句柄
     enable?: 是否启用"
    (when (handle-closed? tcp)
      (error 'uv-tcp-simultaneous-accepts! "tcp handle is closed"))
    (with-uv-check uv-tcp-simultaneous-accepts
      (%ffi-uv-tcp-simultaneous-accepts (handle-ptr tcp) (if enable? 1 0))))

  ;; ========================================
  ;; 地址信息
  ;; ========================================

  (define (uv-tcp-getsockname tcp)
    "获取本地地址
     返回: (ip . port) 点对"
    (when (handle-closed? tcp)
      (error 'uv-tcp-getsockname "tcp handle is closed"))
    ;; 分配足够大的缓冲区（可能是 IPv6）
    (let* ([addr-ptr (foreign-alloc sockaddr-in6-size)]
           [len-ptr (foreign-alloc (foreign-sizeof 'int))])
      (foreign-set! 'int len-ptr 0 sockaddr-in6-size)
      (guard (e [else
                 (foreign-free addr-ptr)
                 (foreign-free len-ptr)
                 (raise e)])
        (with-uv-check uv-tcp-getsockname
          (%ffi-uv-tcp-getsockname (handle-ptr tcp) addr-ptr len-ptr))
        (let* ([family (sockaddr-get-family addr-ptr)]
               [result (if (= family AF_INET)
                           (cons (sockaddr-in-addr addr-ptr)
                                 (sockaddr-in-port addr-ptr))
                           (cons (sockaddr-in6-addr addr-ptr)
                                 (sockaddr-in6-port addr-ptr)))])
          (foreign-free addr-ptr)
          (foreign-free len-ptr)
          result))))

  (define (uv-tcp-getpeername tcp)
    "获取远程地址
     返回: (ip . port) 点对"
    (when (handle-closed? tcp)
      (error 'uv-tcp-getpeername "tcp handle is closed"))
    ;; 分配足够大的缓冲区
    (let* ([addr-ptr (foreign-alloc sockaddr-in6-size)]
           [len-ptr (foreign-alloc (foreign-sizeof 'int))])
      (foreign-set! 'int len-ptr 0 sockaddr-in6-size)
      (guard (e [else
                 (foreign-free addr-ptr)
                 (foreign-free len-ptr)
                 (raise e)])
        (with-uv-check uv-tcp-getpeername
          (%ffi-uv-tcp-getpeername (handle-ptr tcp) addr-ptr len-ptr))
        (let* ([family (sockaddr-get-family addr-ptr)]
               [result (if (= family AF_INET)
                           (cons (sockaddr-in-addr addr-ptr)
                                 (sockaddr-in-port addr-ptr))
                           (cons (sockaddr-in6-addr addr-ptr)
                                 (sockaddr-in6-port addr-ptr)))])
          (foreign-free addr-ptr)
          (foreign-free len-ptr)
          result))))

) ; end library
