;;; low-level/udp.ss - UDP 低层封装
;;;
;;; 提供 UDP 套接字的高层封装
;;;
;;; UDP 与 TCP 的关键区别：
;;; - recv 回调签名不同，包含发送方地址和 flags 参数
;;; - send 需要目标地址参数（除非已 connect）
;;; - 不使用 stream 的读写函数，有自己独立的接口

(library (chez-async low-level udp)
  (export
    ;; UDP 创建
    uv-udp-init
    uv-udp-init-ex
    uv-udp-open

    ;; UDP 绑定/连接
    uv-udp-bind
    uv-udp-connect
    uv-udp-disconnect

    ;; UDP 发送
    uv-udp-send!
    uv-udp-try-send

    ;; UDP 接收
    uv-udp-recv-start!
    uv-udp-recv-stop!

    ;; 地址信息
    uv-udp-getsockname
    uv-udp-getpeername

    ;; 选项设置
    uv-udp-set-broadcast!
    uv-udp-set-ttl!
    uv-udp-join-multicast-group!
    uv-udp-leave-multicast-group!
    uv-udp-set-multicast-loop!
    uv-udp-set-multicast-ttl!
    uv-udp-set-multicast-interface!

    ;; 队列状态
    uv-udp-send-queue-size
    uv-udp-send-queue-count

    ;; 常量
    UV_UDP_IPV6ONLY
    UV_UDP_REUSEADDR
    UV_UDP_PARTIAL
    UV_UDP_MMSG_CHUNK
    UV_UDP_MMSG_FREE
    UV_UDP_RECVMMSG
    )
  (import (chezscheme)
          (chez-async ffi types)
          (chez-async ffi errors)
          (chez-async ffi handles)
          (chez-async ffi udp)
          (chez-async ffi requests)
          (chez-async ffi callbacks)
          (chez-async low-level handle-base)
          (chez-async low-level request-base)
          (chez-async low-level sockaddr)
          (chez-async high-level event-loop)
          (chez-async internal macros)
          (chez-async internal callback-registry)
          (only (chez-async internal buffer-utils) foreign->bytevector)
          (chez-async internal utils))

  ;; ========================================
  ;; 常量
  ;; ========================================

  ;; UDP 绑定标志
  (define UV_UDP_IPV6ONLY 1)    ; 仅 IPv6
  (define UV_UDP_REUSEADDR 4)   ; 允许地址重用

  ;; UDP 接收标志
  (define UV_UDP_PARTIAL 2)     ; 数据报被截断
  (define UV_UDP_MMSG_CHUNK 8)  ; recvmmsg 分块中
  (define UV_UDP_MMSG_FREE 16)  ; 可释放 recvmmsg 缓冲区
  (define UV_UDP_RECVMMSG 256)  ; 使用 recvmmsg

  ;; 多播成员关系
  (define UV_JOIN_GROUP 0)
  (define UV_LEAVE_GROUP 1)

  ;; ========================================
  ;; 全局 UDP 回调（使用统一注册表管理）
  ;; ========================================

  ;; UDP Send 回调：处理发送完成
  (define-registered-callback get-udp-send-callback CALLBACK-UDP-SEND
    (lambda ()
      (make-udp-send-callback
        (lambda (req-wrapper status)
          (let ([user-callback (uv-request-wrapper-scheme-callback req-wrapper)]
                [send-data (uv-request-wrapper-scheme-data req-wrapper)])
            ;; 释放缓冲区内存
            (when (and send-data (pair? send-data))
              (let ([buf-ptr (car send-data)]
                    [data-ptr (cdr send-data)])
                (when data-ptr (foreign-free data-ptr))
                (when buf-ptr (foreign-free buf-ptr))))
            ;; 调用用户回调
            (call-user-callback-with-error user-callback status udp-send %ffi-uv-err-name make-uv-error)
            ;; 清理请求
            (cleanup-request-wrapper! req-wrapper))))))

  ;; UDP Recv 回调：处理接收，解析发送方地址
  (define-registered-callback get-udp-recv-callback CALLBACK-UDP-RECV
    (lambda ()
      (make-udp-recv-callback
        (lambda (wrapper nread buf-ptr addr-ptr flags)
          (let ([recv-data (handle-data wrapper)])
            (when (and recv-data (pair? recv-data))
              (let ([user-callback (car recv-data)]
                    [alloc-ptr (cadr recv-data)])
                ;; 释放 alloc 分配的内存
                (when alloc-ptr
                  (foreign-free alloc-ptr)
                  (set-car! (cdr recv-data) #f))
                ;; 调用用户回调
                (when user-callback
                  (cond
                    ;; 错误
                    [(< nread 0)
                     (if (= nread -4095)  ; UV_EOF
                         (user-callback wrapper #f #f flags)  ; EOF
                         (user-callback wrapper
                                        (make-uv-error nread (%ffi-uv-err-name nread) 'udp-recv)
                                        #f flags))]
                    ;; 空数据报（nread = 0 且 addr != NULL 是有效的空数据报）
                    [(and (= nread 0) (not (= addr-ptr 0)))
                     (let ([sender-addr (parse-sender-address addr-ptr)])
                       (user-callback wrapper (make-bytevector 0) sender-addr flags))]
                    ;; nread = 0 且 addr = NULL 表示没有更多数据
                    [(= nread 0)
                     (user-callback wrapper #f #f flags)]
                    ;; 正常接收数据
                    [else
                     (let* ([buf-fptr (make-ftype-pointer uv-buf-t buf-ptr)]
                            [base (ftype-ref uv-buf-t (base) buf-fptr)]
                            [bv (foreign->bytevector base nread)]
                            [sender-addr (if (= addr-ptr 0)
                                             #f
                                             (parse-sender-address addr-ptr))])
                       (user-callback wrapper bv sender-addr flags))])))))))))

  ;; 复用 stream 模块的 alloc 回调
  (define-registered-callback get-alloc-callback CALLBACK-ALLOC
    (lambda ()
      (make-alloc-callback
        (lambda (wrapper suggested-size buf-ptr)
          ;; 分配 C 内存缓冲区
          (let* ([size (min suggested-size 65536)]  ; 最大 64KB
                 [data-ptr (foreign-alloc size)]
                 [buf-fptr (make-ftype-pointer uv-buf-t buf-ptr)])
            (ftype-set! uv-buf-t (base) buf-fptr data-ptr)
            (ftype-set! uv-buf-t (len) buf-fptr size)
            ;; 存储指针以便后续释放
            (let ([recv-data (handle-data wrapper)])
              (when (pair? recv-data)
                (set-car! (cdr recv-data) data-ptr))))))))

  ;; ========================================
  ;; 辅助函数
  ;; ========================================

  (define (parse-sender-address addr-ptr)
    "解析发送方地址，返回 (ip . port) 点对"
    (let ([family (sockaddr-get-family addr-ptr)])
      (cond
        [(= family AF_INET)
         (cons (sockaddr-in-addr addr-ptr)
               (sockaddr-in-port addr-ptr))]
        [(= family AF_INET6)
         (cons (sockaddr-in6-addr addr-ptr)
               (sockaddr-in6-port addr-ptr))]
        [else
         (cons "unknown" 0)])))

  ;; ========================================
  ;; UDP 创建
  ;; ========================================

  (define (uv-udp-init loop)
    "创建 UDP 句柄
     loop: 事件循环"
    (let* ([size (%ffi-uv-udp-size)]
           [ptr (allocate-handle size)]
           [loop-ptr (uv-loop-ptr loop)])
      (with-uv-check/cleanup uv-udp-init
        (%ffi-uv-udp-init loop-ptr ptr)
        (lambda () (foreign-free ptr)))
      (make-handle ptr 'udp loop)))

  (define (uv-udp-init-ex loop flags)
    "创建 UDP 句柄（指定地址族）
     loop: 事件循环
     flags: 地址族标志（AF_INET 或 AF_INET6）"
    (let* ([size (%ffi-uv-udp-size)]
           [ptr (allocate-handle size)]
           [loop-ptr (uv-loop-ptr loop)])
      (with-uv-check/cleanup uv-udp-init-ex
        (%ffi-uv-udp-init-ex loop-ptr ptr flags)
        (lambda () (foreign-free ptr)))
      (make-handle ptr 'udp loop)))

  (define (uv-udp-open udp fd)
    "打开已存在的文件描述符作为 UDP 句柄
     udp: UDP 句柄
     fd: 文件描述符"
    (when (handle-closed? udp)
      (error 'uv-udp-open "udp handle is closed"))
    (with-uv-check uv-udp-open
      (%ffi-uv-udp-open (handle-ptr udp) fd)))

  ;; ========================================
  ;; UDP 绑定/连接
  ;; ========================================

  (define uv-udp-bind
    (case-lambda
      [(udp addr port)
       (uv-udp-bind udp addr port 0)]
      [(udp addr port flags)
       "绑定 UDP 套接字到地址
        udp: UDP 句柄
        addr: IP 地址字符串
        port: 端口号
        flags: 绑定标志（可选）"
       (when (handle-closed? udp)
         (error 'uv-udp-bind "udp handle is closed"))
       (let ([sockaddr (parse-address addr port)])
         (guard (e [else (free-sockaddr sockaddr) (raise e)])
           (with-uv-check uv-udp-bind
             (%ffi-uv-udp-bind (handle-ptr udp) sockaddr flags))
           (free-sockaddr sockaddr)))]))

  (define (uv-udp-connect udp addr port)
    "将 UDP 句柄连接到远程地址
     连接后可以不指定地址发送数据
     udp: UDP 句柄
     addr: 远程 IP 地址字符串
     port: 远程端口号"
    (when (handle-closed? udp)
      (error 'uv-udp-connect "udp handle is closed"))
    (let ([sockaddr (parse-address addr port)])
      (guard (e [else (free-sockaddr sockaddr) (raise e)])
        (with-uv-check uv-udp-connect
          (%ffi-uv-udp-connect (handle-ptr udp) sockaddr))
        (free-sockaddr sockaddr))))

  (define (uv-udp-disconnect udp)
    "断开 UDP 连接
     udp: UDP 句柄"
    (when (handle-closed? udp)
      (error 'uv-udp-disconnect "udp handle is closed"))
    (with-uv-check uv-udp-disconnect
      (%ffi-uv-udp-connect (handle-ptr udp) 0)))

  ;; ========================================
  ;; UDP 发送
  ;; ========================================

  (define uv-udp-send!
    (case-lambda
      [(udp data callback)
       ;; 无目标地址（必须已 connect）
       (uv-udp-send! udp data #f #f callback)]
      [(udp data addr port callback)
       "发送 UDP 数据报
        udp: UDP 句柄
        data: bytevector 或 string
        addr: 目标 IP 地址字符串（可选，如果已 connect）
        port: 目标端口号（可选，如果已 connect）
        callback: 回调函数 (lambda (error-or-#f) ...)"
       (when (handle-closed? udp)
         (error 'uv-udp-send! "udp handle is closed"))
       ;; 将数据转换为 bytevector
       (let* ([bv (if (string? data)
                      (string->utf8 data)
                      data)]
              [len (bytevector-length bv)]
              ;; 分配缓冲区结构和数据
              [buf-ptr (foreign-alloc (ftype-sizeof uv-buf-t))]
              [data-ptr (foreign-alloc len)]
              ;; 分配请求
              [req-size (%ffi-uv-udp-send-req-size)]
              [req-ptr (allocate-request req-size)])
         ;; 复制数据到 C 内存
         (do ([i 0 (+ i 1)])
             ((= i len))
           (foreign-set! 'unsigned-8 data-ptr i (bytevector-u8-ref bv i)))
         ;; 设置 uv_buf_t
         (let ([buf-fptr (make-ftype-pointer uv-buf-t buf-ptr)])
           (ftype-set! uv-buf-t (base) buf-fptr data-ptr)
           (ftype-set! uv-buf-t (len) buf-fptr len))
         ;; 创建请求包装器
         (let ([req-wrapper (make-uv-request-wrapper
                              req-ptr 'udp-send callback
                              (cons buf-ptr data-ptr))])
           ;; 解析目标地址（如果提供）
           (let ([sockaddr (if addr (parse-address addr port) 0)])
             (guard (e [else
                        (when (not (= sockaddr 0)) (free-sockaddr sockaddr))
                        (cleanup-request-wrapper! req-wrapper)
                        (foreign-free buf-ptr)
                        (foreign-free data-ptr)
                        (raise e)])
               ;; 执行发送
               (let ([result (%ffi-uv-udp-send req-ptr
                                                (handle-ptr udp)
                                                buf-ptr
                                                1  ; nbufs
                                                sockaddr
                                                (get-udp-send-callback))])
                 (when (not (= sockaddr 0))
                   (free-sockaddr sockaddr))
                 (when (< result 0)
                   ;; 发送失败，清理资源
                   (cleanup-request-wrapper! req-wrapper)
                   (foreign-free buf-ptr)
                   (foreign-free data-ptr)
                   (raise-uv-error 'uv-udp-send result)))))))]))

  (define uv-udp-try-send
    (case-lambda
      [(udp data)
       ;; 无目标地址（必须已 connect）
       (uv-udp-try-send udp data #f #f)]
      [(udp data addr port)
       "尝试同步发送 UDP 数据报（非阻塞）
        返回：发送的字节数，或负数表示错误
        注意：UV_EAGAIN 表示需要等待"
       (when (handle-closed? udp)
         (error 'uv-udp-try-send "udp handle is closed"))
       (let* ([bv (if (string? data)
                      (string->utf8 data)
                      data)]
              [len (bytevector-length bv)]
              [buf-ptr (foreign-alloc (ftype-sizeof uv-buf-t))]
              [data-ptr (foreign-alloc len)])
         ;; 复制数据
         (do ([i 0 (+ i 1)])
             ((= i len))
           (foreign-set! 'unsigned-8 data-ptr i (bytevector-u8-ref bv i)))
         ;; 设置 uv_buf_t
         (let ([buf-fptr (make-ftype-pointer uv-buf-t buf-ptr)])
           (ftype-set! uv-buf-t (base) buf-fptr data-ptr)
           (ftype-set! uv-buf-t (len) buf-fptr len))
         ;; 解析目标地址
         (let ([sockaddr (if addr (parse-address addr port) 0)])
           (guard (e [else
                      (when (not (= sockaddr 0)) (free-sockaddr sockaddr))
                      (foreign-free data-ptr)
                      (foreign-free buf-ptr)
                      (raise e)])
             ;; 尝试发送
             (let ([result (%ffi-uv-udp-try-send (handle-ptr udp) buf-ptr 1 sockaddr)])
               (when (not (= sockaddr 0))
                 (free-sockaddr sockaddr))
               (foreign-free data-ptr)
               (foreign-free buf-ptr)
               result))))]))

  ;; ========================================
  ;; UDP 接收
  ;; ========================================

  (define (uv-udp-recv-start! udp callback)
    "开始接收 UDP 数据
     udp: UDP 句柄
     callback: 回调函数 (lambda (udp data-or-error sender-addr flags) ...)
               data-or-error 为 bytevector（成功）、#f（无数据）或 error（错误）
               sender-addr 为 (ip . port) 点对或 #f"
    (when (handle-closed? udp)
      (error 'uv-udp-recv-start! "udp handle is closed"))
    ;; 保存回调和 alloc 缓冲区指针
    (let ([recv-data (list callback #f)])  ; (user-callback alloc-ptr)
      (handle-data-set! udp recv-data)
      (lock-object recv-data))
    ;; 开始接收
    (with-uv-check uv-udp-recv-start
      (%ffi-uv-udp-recv-start (handle-ptr udp)
                               (get-alloc-callback)
                               (get-udp-recv-callback))))

  (define (uv-udp-recv-stop! udp)
    "停止接收 UDP 数据"
    (when (handle-closed? udp)
      (error 'uv-udp-recv-stop! "udp handle is closed"))
    (with-uv-check uv-udp-recv-stop
      (%ffi-uv-udp-recv-stop (handle-ptr udp)))
    ;; 清理回调数据
    (let ([recv-data (handle-data udp)])
      (when recv-data
        (unlock-object recv-data)
        (handle-data-set! udp #f))))

  ;; ========================================
  ;; 地址信息
  ;; ========================================

  (define (uv-udp-getsockname udp)
    "获取本地地址
     返回: (ip . port) 点对"
    (when (handle-closed? udp)
      (error 'uv-udp-getsockname "udp handle is closed"))
    ;; 分配足够大的缓冲区（可能是 IPv6）
    (let* ([addr-ptr (foreign-alloc sockaddr-in6-size)]
           [len-ptr (foreign-alloc (foreign-sizeof 'int))])
      (foreign-set! 'int len-ptr 0 sockaddr-in6-size)
      (guard (e [else
                 (foreign-free addr-ptr)
                 (foreign-free len-ptr)
                 (raise e)])
        (with-uv-check uv-udp-getsockname
          (%ffi-uv-udp-getsockname (handle-ptr udp) addr-ptr len-ptr))
        (let* ([family (sockaddr-get-family addr-ptr)]
               [result (if (= family AF_INET)
                           (cons (sockaddr-in-addr addr-ptr)
                                 (sockaddr-in-port addr-ptr))
                           (cons (sockaddr-in6-addr addr-ptr)
                                 (sockaddr-in6-port addr-ptr)))])
          (foreign-free addr-ptr)
          (foreign-free len-ptr)
          result))))

  (define (uv-udp-getpeername udp)
    "获取远程地址（仅在连接模式有效）
     返回: (ip . port) 点对"
    (when (handle-closed? udp)
      (error 'uv-udp-getpeername "udp handle is closed"))
    ;; 分配足够大的缓冲区
    (let* ([addr-ptr (foreign-alloc sockaddr-in6-size)]
           [len-ptr (foreign-alloc (foreign-sizeof 'int))])
      (foreign-set! 'int len-ptr 0 sockaddr-in6-size)
      (guard (e [else
                 (foreign-free addr-ptr)
                 (foreign-free len-ptr)
                 (raise e)])
        (with-uv-check uv-udp-getpeername
          (%ffi-uv-udp-getpeername (handle-ptr udp) addr-ptr len-ptr))
        (let* ([family (sockaddr-get-family addr-ptr)]
               [result (if (= family AF_INET)
                           (cons (sockaddr-in-addr addr-ptr)
                                 (sockaddr-in-port addr-ptr))
                           (cons (sockaddr-in6-addr addr-ptr)
                                 (sockaddr-in6-port addr-ptr)))])
          (foreign-free addr-ptr)
          (foreign-free len-ptr)
          result))))

  ;; ========================================
  ;; UDP 选项
  ;; ========================================

  (define (uv-udp-set-broadcast! udp enable?)
    "启用/禁用 SO_BROADCAST
     udp: UDP 句柄
     enable?: 是否启用"
    (when (handle-closed? udp)
      (error 'uv-udp-set-broadcast! "udp handle is closed"))
    (with-uv-check uv-udp-set-broadcast
      (%ffi-uv-udp-set-broadcast (handle-ptr udp) (if enable? 1 0))))

  (define (uv-udp-set-ttl! udp ttl)
    "设置 IP_TTL
     udp: UDP 句柄
     ttl: TTL 值（1-255）"
    (when (handle-closed? udp)
      (error 'uv-udp-set-ttl! "udp handle is closed"))
    (unless (and (>= ttl 1) (<= ttl 255))
      (error 'uv-udp-set-ttl! "ttl must be between 1 and 255"))
    (with-uv-check uv-udp-set-ttl
      (%ffi-uv-udp-set-ttl (handle-ptr udp) ttl)))

  (define uv-udp-join-multicast-group!
    (case-lambda
      [(udp multicast-addr)
       (uv-udp-join-multicast-group! udp multicast-addr "0.0.0.0")]
      [(udp multicast-addr interface-addr)
       "加入多播组
        udp: UDP 句柄
        multicast-addr: 多播组地址
        interface-addr: 本地接口地址（可选）"
       (when (handle-closed? udp)
         (error 'uv-udp-join-multicast-group! "udp handle is closed"))
       (with-uv-check uv-udp-join-multicast-group
         (%ffi-uv-udp-set-membership (handle-ptr udp)
                                      multicast-addr
                                      interface-addr
                                      UV_JOIN_GROUP))]))

  (define uv-udp-leave-multicast-group!
    (case-lambda
      [(udp multicast-addr)
       (uv-udp-leave-multicast-group! udp multicast-addr "0.0.0.0")]
      [(udp multicast-addr interface-addr)
       "离开多播组
        udp: UDP 句柄
        multicast-addr: 多播组地址
        interface-addr: 本地接口地址（可选）"
       (when (handle-closed? udp)
         (error 'uv-udp-leave-multicast-group! "udp handle is closed"))
       (with-uv-check uv-udp-leave-multicast-group
         (%ffi-uv-udp-set-membership (handle-ptr udp)
                                      multicast-addr
                                      interface-addr
                                      UV_LEAVE_GROUP))]))

  (define (uv-udp-set-multicast-loop! udp enable?)
    "启用/禁用 IP_MULTICAST_LOOP
     udp: UDP 句柄
     enable?: 是否启用"
    (when (handle-closed? udp)
      (error 'uv-udp-set-multicast-loop! "udp handle is closed"))
    (with-uv-check uv-udp-set-multicast-loop
      (%ffi-uv-udp-set-multicast-loop (handle-ptr udp) (if enable? 1 0))))

  (define (uv-udp-set-multicast-ttl! udp ttl)
    "设置 IP_MULTICAST_TTL
     udp: UDP 句柄
     ttl: TTL 值（1-255）"
    (when (handle-closed? udp)
      (error 'uv-udp-set-multicast-ttl! "udp handle is closed"))
    (unless (and (>= ttl 1) (<= ttl 255))
      (error 'uv-udp-set-multicast-ttl! "ttl must be between 1 and 255"))
    (with-uv-check uv-udp-set-multicast-ttl
      (%ffi-uv-udp-set-multicast-ttl (handle-ptr udp) ttl)))

  (define (uv-udp-set-multicast-interface! udp interface-addr)
    "设置多播发送接口
     udp: UDP 句柄
     interface-addr: 本地接口地址"
    (when (handle-closed? udp)
      (error 'uv-udp-set-multicast-interface! "udp handle is closed"))
    (with-uv-check uv-udp-set-multicast-interface
      (%ffi-uv-udp-set-multicast-interface (handle-ptr udp) interface-addr)))

  ;; ========================================
  ;; 发送队列状态
  ;; ========================================

  (define (uv-udp-send-queue-size udp)
    "获取发送队列中待发送的字节数"
    (when (handle-closed? udp)
      (error 'uv-udp-send-queue-size "udp handle is closed"))
    (%ffi-uv-udp-get-send-queue-size (handle-ptr udp)))

  (define (uv-udp-send-queue-count udp)
    "获取发送队列中待发送的请求数"
    (when (handle-closed? udp)
      (error 'uv-udp-send-queue-count "udp handle is closed"))
    (%ffi-uv-udp-get-send-queue-count (handle-ptr udp)))

) ; end library
