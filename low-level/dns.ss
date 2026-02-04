;;; low-level/dns.ss - DNS 低层封装
;;;
;;; 提供 DNS 解析的高层封装

(library (chez-async low-level dns)
  (export
    ;; DNS 解析
    uv-getaddrinfo
    uv-getnameinfo

    ;; 便利函数
    resolve-hostname
    resolve-hostname-sync

    ;; addrinfo 结果处理
    addrinfo->list
    addrinfo-entry?
    addrinfo-entry-family
    addrinfo-entry-socktype
    addrinfo-entry-protocol
    addrinfo-entry-addr
    addrinfo-entry-canonname
    )
  (import (chezscheme)
          (chez-async ffi types)
          (chez-async ffi errors)
          (chez-async ffi dns)
          (chez-async ffi requests)
          (chez-async ffi callbacks)
          (chez-async low-level request-base)
          (chez-async low-level sockaddr)
          (chez-async high-level event-loop)
          (chez-async internal macros)
          (chez-async internal callback-registry)
          (only (chez-async internal foreign-utils) c-string->string)  ; 只导入 c-string->string
          (chez-async internal utils))

  ;; ========================================
  ;; 全局回调（使用统一注册表管理）
  ;; ========================================
  ;;
  ;; DNS 回调注册到统一注册表，在首次使用时延迟创建
  ;; c-string->string 从 foreign-utils 模块导入，避免重复定义

  ;; getaddrinfo 回调：处理 DNS 解析完成
  (define-registered-callback get-getaddrinfo-callback CALLBACK-GETADDRINFO
    (lambda ()
      (foreign-callable
        (lambda (req-ptr status addrinfo-ptr)
          (guard (e [else (handle-callback-error e)])
            (let ([wrapper (ptr->wrapper req-ptr)])
              (when wrapper
                (let ([user-callback (uv-request-wrapper-scheme-callback wrapper)])
                  (when user-callback
                    (if (< status 0)
                        (user-callback #f (make-uv-error status (%ffi-uv-err-name status) 'getaddrinfo))
                        (user-callback (addrinfo->list addrinfo-ptr) #f)))
                  ;; 释放 addrinfo
                  (when (and (>= status 0) (not (= addrinfo-ptr 0)))
                    (%ffi-uv-freeaddrinfo addrinfo-ptr))
                  ;; 清理请求
                  (cleanup-request-wrapper! wrapper))))))
        (void* int void*) void)))

  ;; getnameinfo 回调：处理反向 DNS 解析完成
  (define-registered-callback get-getnameinfo-callback CALLBACK-GETNAMEINFO
    (lambda ()
      (foreign-callable
        (lambda (req-ptr status hostname-ptr service-ptr)
          (guard (e [else (handle-callback-error e)])
            (let ([wrapper (ptr->wrapper req-ptr)])
              (when wrapper
                (let ([user-callback (uv-request-wrapper-scheme-callback wrapper)])
                  (when user-callback
                    (if (< status 0)
                        (user-callback #f #f (make-uv-error status (%ffi-uv-err-name status) 'getnameinfo))
                        (let ([hostname (if (= hostname-ptr 0) #f (c-string->string hostname-ptr))]
                              [service (if (= service-ptr 0) #f (c-string->string service-ptr))])
                          (user-callback hostname service #f)))))
                  ;; 清理请求
                  (cleanup-request-wrapper! wrapper)))))
        (void* int void* void*) void)))

  ;; ========================================
  ;; addrinfo 结果处理
  ;; ========================================

  ;; addrinfo 条目记录类型
  (define-record-type addrinfo-entry
    (fields
      (immutable family)     ; AF_INET or AF_INET6
      (immutable socktype)   ; SOCK_STREAM or SOCK_DGRAM
      (immutable protocol)   ; 协议号
      (immutable addr)       ; (ip . port) 点对
      (immutable canonname)) ; 规范名称（可能为 #f）
    (protocol
      (lambda (new)
        (lambda (family socktype protocol addr canonname)
          (new family socktype protocol addr canonname)))))

  (define (addrinfo->list addrinfo-ptr)
    "将 addrinfo 链表转换为 Scheme 列表"
    (let loop ([ptr addrinfo-ptr] [result '()])
      (if (or (not ptr) (= ptr 0))
          (reverse result)
          (let* ([family (addrinfo-ai-family ptr)]
                 [socktype (addrinfo-ai-socktype ptr)]
                 [protocol (addrinfo-ai-protocol ptr)]
                 [addr-ptr (addrinfo-ai-addr ptr)]
                 [canonname-ptr (addrinfo-ai-canonname ptr)]
                 [canonname (c-string->string canonname-ptr)]
                 [addr (extract-address addr-ptr family)]
                 [next (addrinfo-ai-next ptr)])
            (loop next
                  (cons (make-addrinfo-entry family socktype protocol addr canonname)
                        result))))))

  (define (extract-address addr-ptr family)
    "从 sockaddr 提取地址"
    (cond
      [(= family AF_INET)
       (cons (sockaddr-in-addr addr-ptr)
             (sockaddr-in-port addr-ptr))]
      [(= family AF_INET6)
       (cons (sockaddr-in6-addr addr-ptr)
             (sockaddr-in6-port addr-ptr))]
      [else (cons "unknown" 0)]))

  ;; ========================================
  ;; DNS 解析
  ;; ========================================

  (define uv-getaddrinfo
    (case-lambda
      [(loop hostname callback)
       (uv-getaddrinfo loop hostname #f 0 0 0 0 callback)]
      [(loop hostname service callback)
       (uv-getaddrinfo loop hostname service 0 0 0 0 callback)]
      [(loop hostname service family socktype protocol flags callback)
       "异步 DNS 解析
        loop: 事件循环
        hostname: 要解析的主机名（或 IP 地址字符串）
        service: 服务名或端口号字符串（可以为 #f）
        family: 地址族 (0=any, AF_INET, AF_INET6)
        socktype: 套接字类型 (0=any, SOCK_STREAM, SOCK_DGRAM)
        protocol: 协议 (通常为 0)
        flags: AI_* 标志
        callback: (lambda (results error) ...)
                  results 是 addrinfo-entry 列表"
       ;; 分配请求
       (let* ([req-size (%ffi-uv-getaddrinfo-req-size)]
              [req-ptr (allocate-request req-size)]
              [req-wrapper (make-uv-request-wrapper req-ptr 'getaddrinfo callback #f)]
              ;; 创建 hints（如果需要）
              [hints (if (and (= family 0) (= socktype 0) (= protocol 0) (= flags 0))
                         0  ; NULL hints
                         (make-addrinfo-hints family socktype protocol flags))]
              ;; 处理 service 参数
              [service-str (cond
                            [(not service) #f]
                            [(number? service) (number->string service)]
                            [else service])])
         ;; 执行解析
         (let ([result (%ffi-uv-getaddrinfo
                         (uv-loop-ptr loop)
                         req-ptr
                         (get-getaddrinfo-callback)
                         hostname
                         service-str
                         hints)])
           ;; 释放 hints
           (when (not (= hints 0))
             (free-addrinfo-hints hints))
           ;; 检查错误
           (when (< result 0)
             (cleanup-request-wrapper! req-wrapper)
             (raise-uv-error result 'uv-getaddrinfo))))]))

  (define uv-getnameinfo
    (case-lambda
      [(loop addr callback)
       (uv-getnameinfo loop addr 0 callback)]
      [(loop addr flags callback)
       "反向 DNS 解析（IP 到主机名）
        loop: 事件循环
        addr: sockaddr 指针
        flags: NI_* 标志
        callback: (lambda (hostname service error) ...)"
       ;; 分配请求
       (let* ([req-size (%ffi-uv-getnameinfo-req-size)]
              [req-ptr (allocate-request req-size)]
              [req-wrapper (make-uv-request-wrapper req-ptr 'getnameinfo callback #f)])
         ;; 执行解析
         (let ([result (%ffi-uv-getnameinfo
                         (uv-loop-ptr loop)
                         req-ptr
                         (get-getnameinfo-callback)
                         addr
                         flags)])
           ;; 检查错误
           (when (< result 0)
             (cleanup-request-wrapper! req-wrapper)
             (raise-uv-error result 'uv-getnameinfo))))]))

  ;; ========================================
  ;; 便利函数
  ;; ========================================

  (define resolve-hostname
    (case-lambda
      [(loop hostname callback)
       (resolve-hostname loop hostname 'any callback)]
      [(loop hostname family callback)
       "简化的主机名解析
        loop: 事件循环
        hostname: 主机名
        family: 'any, 'ipv4, 或 'ipv6
        callback: (lambda (addresses error) ...)
                  addresses 是 IP 地址字符串列表"
       (let ([fam (case family
                    [(any) 0]
                    [(ipv4) AF_INET]
                    [(ipv6) AF_INET6]
                    [else 0])])
         (uv-getaddrinfo loop hostname #f fam SOCK_STREAM 0 0
           (lambda (results error)
             (if error
                 (callback #f error)
                 (callback (map (lambda (entry)
                                  (car (addrinfo-entry-addr entry)))
                                results)
                           #f)))))]))

  (define (resolve-hostname-sync loop hostname)
    "同步解析主机名（阻塞直到完成）
     返回 IP 地址列表或抛出错误"
    (let ([result #f]
          [error #f]
          [done #f])
      (resolve-hostname loop hostname
        (lambda (addrs err)
          (set! result addrs)
          (set! error err)
          (set! done #t)))
      ;; 运行事件循环直到完成
      (let loop-run ()
        (unless done
          (uv-run loop 'once)
          (loop-run)))
      (if error
          (raise error)
          result)))

) ; end library
