;;; low-level/sockaddr.ss - 网络地址处理
;;;
;;; 提供 sockaddr 结构的创建和解析功能

(library (chez-async low-level sockaddr)
  (export
    ;; sockaddr-in (IPv4)
    make-sockaddr-in
    make-sockaddr-in4
    sockaddr-in-port
    sockaddr-in-addr
    free-sockaddr

    ;; sockaddr-in6 (IPv6)
    make-sockaddr-in6
    sockaddr-in6-port
    sockaddr-in6-addr

    ;; 地址转换
    ip4-string->addr
    addr->ip4-string
    ip6-string->addr
    addr->ip6-string

    ;; 字符串解析
    parse-address
    sockaddr->string

    ;; FFI 辅助
    %ffi-uv-ip4-addr
    %ffi-uv-ip6-addr
    %ffi-uv-ip4-name
    %ffi-uv-ip6-name

    ;; 常量
    sockaddr-in-size
    sockaddr-in6-size
    )
  (import (chezscheme)
          (chez-async ffi types)
          (chez-async ffi errors)
          (chez-async internal macros)
          (only (chez-async internal foreign) c-string->string))

  ;; ========================================
  ;; FFI 绑定：地址转换
  ;; ========================================

  ;; int uv_ip4_addr(const char* ip, int port, struct sockaddr_in* addr)
  (define-ffi %ffi-uv-ip4-addr "uv_ip4_addr" (string int void*) int)

  ;; int uv_ip6_addr(const char* ip, int port, struct sockaddr_in6* addr)
  (define-ffi %ffi-uv-ip6-addr "uv_ip6_addr" (string int void*) int)

  ;; int uv_ip4_name(const struct sockaddr_in* src, char* dst, size_t size)
  (define-ffi %ffi-uv-ip4-name "uv_ip4_name" (void* void* size_t) int)

  ;; int uv_ip6_name(const struct sockaddr_in6* src, char* dst, size_t size)
  (define-ffi %ffi-uv-ip6-name "uv_ip6_name" (void* void* size_t) int)

  ;; ========================================
  ;; 结构体大小
  ;; ========================================

  (define sockaddr-in-size (ftype-sizeof sockaddr-in))
  (define sockaddr-in6-size (ftype-sizeof sockaddr-in6))

  ;; ========================================
  ;; IPv4 地址处理
  ;; ========================================

  (define (make-sockaddr-in ip port)
    "创建 IPv4 地址结构
     ip: IP 地址字符串（如 \"127.0.0.1\"）
     port: 端口号
     返回: sockaddr_in* 指针（需要手动释放）"
    (let ([addr-ptr (foreign-alloc sockaddr-in-size)])
      (let ([result (%ffi-uv-ip4-addr ip port addr-ptr)])
        (if (< result 0)
            (begin
              (foreign-free addr-ptr)
              (raise-uv-error result 'make-sockaddr-in))
            addr-ptr))))

  ;; 别名
  (define make-sockaddr-in4 make-sockaddr-in)

  (define (sockaddr-in-port addr-ptr)
    "获取 IPv4 地址的端口号"
    (let* ([fptr (make-ftype-pointer sockaddr-in addr-ptr)]
           [port-be (ftype-ref sockaddr-in (sin-port) fptr)])
      ;; 从网络字节序（big-endian）转换
      (let ([high (bitwise-and port-be #xff)]
            [low (bitwise-arithmetic-shift-right port-be 8)])
        (bitwise-ior (bitwise-arithmetic-shift-left high 8) low))))

  (define (sockaddr-in-addr addr-ptr)
    "获取 IPv4 地址（返回字符串）"
    (let* ([buf-size 16]
           [buf (foreign-alloc buf-size)])
      (let ([result (%ffi-uv-ip4-name addr-ptr buf buf-size)])
        (if (< result 0)
            (begin
              (foreign-free buf)
              (raise-uv-error result 'sockaddr-in-addr))
            (let ([str (c-string->string buf)])
              (foreign-free buf)
              str)))))

  ;; ========================================
  ;; IPv6 地址处理
  ;; ========================================

  (define (make-sockaddr-in6 ip port)
    "创建 IPv6 地址结构
     ip: IPv6 地址字符串（如 \"::1\"）
     port: 端口号
     返回: sockaddr_in6* 指针（需要手动释放）"
    (let ([addr-ptr (foreign-alloc sockaddr-in6-size)])
      (let ([result (%ffi-uv-ip6-addr ip port addr-ptr)])
        (if (< result 0)
            (begin
              (foreign-free addr-ptr)
              (raise-uv-error result 'make-sockaddr-in6))
            addr-ptr))))

  (define (sockaddr-in6-port addr-ptr)
    "获取 IPv6 地址的端口号"
    (let* ([fptr (make-ftype-pointer sockaddr-in6 addr-ptr)]
           [port-be (ftype-ref sockaddr-in6 (sin6-port) fptr)])
      (let ([high (bitwise-and port-be #xff)]
            [low (bitwise-arithmetic-shift-right port-be 8)])
        (bitwise-ior (bitwise-arithmetic-shift-left high 8) low))))

  (define (sockaddr-in6-addr addr-ptr)
    "获取 IPv6 地址（返回字符串）"
    (let* ([buf-size 46]  ; INET6_ADDRSTRLEN
           [buf (foreign-alloc buf-size)])
      (let ([result (%ffi-uv-ip6-name addr-ptr buf buf-size)])
        (if (< result 0)
            (begin
              (foreign-free buf)
              (raise-uv-error result 'sockaddr-in6-addr))
            (let ([str (c-string->string buf)])
              (foreign-free buf)
              str)))))

  ;; ========================================
  ;; 地址释放
  ;; ========================================

  (define (free-sockaddr addr-ptr)
    "释放 sockaddr 结构的内存"
    (foreign-free addr-ptr))

  ;; ========================================
  ;; 地址转换辅助函数
  ;; ========================================

  (define (ip4-string->addr ip)
    "将 IPv4 字符串转换为 32 位整数"
    (let ([parts (string-split ip #\.)])
      (if (= (length parts) 4)
          (let ([bytes (map string->number parts)])
            (if (and (all-match? (lambda (b) (and b (<= 0 b 255))) bytes))
                (apply bitwise-ior
                  (map (lambda (b i)
                         (bitwise-arithmetic-shift-left b (* i 8)))
                       bytes '(0 1 2 3)))
                #f))
          #f)))

  (define (addr->ip4-string addr)
    "将 32 位整数转换为 IPv4 字符串"
    (string-append
      (number->string (bitwise-and addr #xff)) "."
      (number->string (bitwise-and (bitwise-arithmetic-shift-right addr 8) #xff)) "."
      (number->string (bitwise-and (bitwise-arithmetic-shift-right addr 16) #xff)) "."
      (number->string (bitwise-and (bitwise-arithmetic-shift-right addr 24) #xff))))

  (define (ip6-string->addr ip)
    "将 IPv6 字符串转换为 16 字节的 bytevector"
    ;; 简化实现：使用 libuv 的解析功能
    (let ([addr-ptr (foreign-alloc sockaddr-in6-size)])
      (let ([result (%ffi-uv-ip6-addr ip 0 addr-ptr)])
        (if (< result 0)
            (begin (foreign-free addr-ptr) #f)
            (let* ([fptr (make-ftype-pointer sockaddr-in6 addr-ptr)]
                   [bv (make-bytevector 16)])
              (do ([i 0 (+ i 1)])
                  ((= i 16))
                (bytevector-u8-set! bv i
                  (ftype-ref sockaddr-in6 (sin6-addr i) fptr)))
              (foreign-free addr-ptr)
              bv)))))

  (define (addr->ip6-string addr-bv)
    "将 16 字节的 bytevector 转换为 IPv6 字符串"
    (let* ([addr-ptr (foreign-alloc sockaddr-in6-size)]
           [fptr (make-ftype-pointer sockaddr-in6 addr-ptr)])
      (ftype-set! sockaddr-in6 (sin6-family) fptr AF_INET6)
      (do ([i 0 (+ i 1)])
          ((= i 16))
        (ftype-set! sockaddr-in6 (sin6-addr i) fptr
                    (bytevector-u8-ref addr-bv i)))
      (guard (e [else (foreign-free addr-ptr) (raise e)])
        (let ([result (sockaddr-in6-addr addr-ptr)])
          (foreign-free addr-ptr)
          result))))

  ;; ========================================
  ;; 通用地址解析
  ;; ========================================

  (define (parse-address addr-string port)
    "解析地址字符串，自动检测 IPv4 或 IPv6
     返回 sockaddr 指针"
    (if (string-contains addr-string ":")
        (make-sockaddr-in6 addr-string port)
        (make-sockaddr-in addr-string port)))

  (define (sockaddr->string addr-ptr)
    "将 sockaddr 转换为字符串（ip:port 格式）"
    (let ([family (sockaddr-get-family addr-ptr)])
      (cond
        [(= family AF_INET)
         (let ([ip (sockaddr-in-addr addr-ptr)]
               [port (sockaddr-in-port addr-ptr)])
           (string-append ip ":" (number->string port)))]
        [(= family AF_INET6)
         (let ([ip (sockaddr-in6-addr addr-ptr)]
               [port (sockaddr-in6-port addr-ptr)])
           (string-append "[" ip "]:" (number->string port)))]
        [else
         (error 'sockaddr->string "unknown address family" family)])))

  ;; ========================================
  ;; 辅助函数
  ;; ========================================

  (define (string-split str delimiter)
    "按分隔符分割字符串"
    (let loop ([chars (string->list str)]
               [current '()]
               [result '()])
      (cond
        [(null? chars)
         (reverse (cons (list->string (reverse current)) result))]
        [(char=? (car chars) delimiter)
         (loop (cdr chars) '() (cons (list->string (reverse current)) result))]
        [else
         (loop (cdr chars) (cons (car chars) current) result)])))

  (define (string-contains str search-char)
    "检查字符串是否包含指定字符"
    (let ([c (if (string? search-char)
                 (string-ref search-char 0)
                 search-char)])
      (let loop ([chars (string->list str)])
        (cond
          [(null? chars) #f]
          [(char=? (car chars) c) #t]
          [else (loop (cdr chars))]))))

  (define (all-match? pred lst)
    "检查列表中所有元素是否满足谓词"
    (or (null? lst)
        (and (pred (car lst))
             (all-match? pred (cdr lst)))))

) ; end library
