#!/usr/bin/env scheme-script
;;; examples/dns-lookup.ss - DNS 查询示例
;;;
;;; 这个示例展示了如何使用 chez-async 进行 DNS 解析。

(import (chezscheme)
        (chez-async high-level event-loop)
        (chez-async low-level dns)
        (chez-async ffi dns)
        (chez-async ffi types))

;; ========================================
;; 示例 1: 简单域名解析
;; ========================================

(define (example-simple-resolve)
  (printf "~n=== Example 1: Simple hostname resolution ===~n")
  (let ([loop (uv-loop-init)])
    (resolve-hostname loop "localhost"
      (lambda (addrs error)
        (if error
            (printf "Error: ~a~n" error)
            (begin
              (printf "Resolved 'localhost' to:~n")
              (for-each (lambda (addr)
                          (printf "  ~a~n" addr))
                        addrs)))))
    (uv-run loop 'default)
    (uv-loop-close loop)))

;; ========================================
;; 示例 2: IPv4 和 IPv6 分别解析
;; ========================================

(define (example-ipv4-ipv6)
  (printf "~n=== Example 2: IPv4 vs IPv6 resolution ===~n")
  (let ([loop (uv-loop-init)]
        [pending 2])

    ;; 解析 IPv4
    (resolve-hostname loop "localhost" 'ipv4
      (lambda (addrs error)
        (printf "IPv4 addresses for 'localhost':~n")
        (if error
            (printf "  Error: ~a~n" error)
            (for-each (lambda (addr)
                        (printf "  ~a~n" addr))
                      addrs))
        (set! pending (- pending 1))))

    ;; 解析 IPv6
    (resolve-hostname loop "localhost" 'ipv6
      (lambda (addrs error)
        (printf "IPv6 addresses for 'localhost':~n")
        (if error
            (printf "  Error: ~a~n" error)
            (if (null? addrs)
                (printf "  (none)~n")
                (for-each (lambda (addr)
                            (printf "  ~a~n" addr))
                          addrs)))
        (set! pending (- pending 1))))

    ;; 等待两个解析都完成
    (let wait ()
      (when (> pending 0)
        (uv-run loop 'once)
        (wait)))

    (uv-loop-close loop)))

;; ========================================
;; 示例 3: 带服务名的解析
;; ========================================

(define (example-with-service)
  (printf "~n=== Example 3: Resolution with service name ===~n")
  (let ([loop (uv-loop-init)])
    (uv-getaddrinfo loop "localhost" "http"
      (lambda (results error)
        (if error
            (printf "Error: ~a~n" error)
            (begin
              (printf "Resolved 'localhost' with service 'http':~n")
              (for-each (lambda (entry)
                          (let ([addr (addrinfo-entry-addr entry)]
                                [family (addrinfo-entry-family entry)]
                                [socktype (addrinfo-entry-socktype entry)])
                            (printf "  ~a:~a (family=~a, socktype=~a)~n"
                                    (car addr) (cdr addr)
                                    (family->string family)
                                    (socktype->string socktype))))
                        results)))))
    (uv-run loop 'default)
    (uv-loop-close loop)))

;; ========================================
;; 示例 4: 解析公共 DNS
;; ========================================

(define (example-public-dns)
  (printf "~n=== Example 4: Resolve public hostnames ===~n")
  (let ([loop (uv-loop-init)]
        [hostnames '("google.com" "github.com" "example.com")]
        [pending 0])

    (set! pending (length hostnames))

    (for-each
      (lambda (hostname)
        (resolve-hostname loop hostname
          (lambda (addrs error)
            (printf "~a:~n" hostname)
            (if error
                (printf "  Error: ~a~n" error)
                (for-each (lambda (addr)
                            (printf "  ~a~n" addr))
                          (if (> (length addrs) 3)
                              (append (take addrs 3) '("..."))
                              addrs)))
            (set! pending (- pending 1)))))
      hostnames)

    ;; 等待所有解析完成
    (let wait ()
      (when (> pending 0)
        (uv-run loop 'once)
        (wait)))

    (uv-loop-close loop)))

;; ========================================
;; 示例 5: 同步解析
;; ========================================

(define (example-sync-resolve)
  (printf "~n=== Example 5: Synchronous resolution ===~n")
  (let ([loop (uv-loop-init)])
    (printf "Resolving 'localhost' synchronously...~n")
    (let ([addrs (resolve-hostname-sync loop "localhost")])
      (printf "Result: ~a~n" addrs))
    (uv-loop-close loop)))

;; ========================================
;; 辅助函数
;; ========================================

(define (family->string family)
  (cond
    [(= family AF_INET) "IPv4"]
    [(= family AF_INET6) "IPv6"]
    [else (format "~a" family)]))

(define (socktype->string socktype)
  (cond
    [(= socktype SOCK_STREAM) "STREAM"]
    [(= socktype SOCK_DGRAM) "DGRAM"]
    [else (format "~a" socktype)]))

(define (take lst n)
  "取列表前 n 个元素"
  (if (or (null? lst) (= n 0))
      '()
      (cons (car lst) (take (cdr lst) (- n 1)))))

;; ========================================
;; 主程序
;; ========================================

(define (main)
  (printf "=== chez-async: DNS Lookup Demo ===~n")
  (printf "libuv version: ~a~n" (uv-version-string))

  (example-simple-resolve)
  (example-ipv4-ipv6)
  (example-with-service)
  (example-public-dns)
  (example-sync-resolve)

  (printf "~n=== All DNS examples completed! ===~n"))

;; 运行
(main)
