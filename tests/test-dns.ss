#!/usr/bin/env scheme-script
;;; tests/test-dns.ss - DNS 功能测试

(import (chezscheme)
        (chez-async tests framework)
        (chez-async high-level event-loop)
        (chez-async low-level dns)
        (chez-async low-level sockaddr)
        (chez-async ffi types)
        (chez-async ffi dns))

;; 辅助函数（必须在测试之前定义）
(define (string-contains? str char-or-str)
  "检查字符串是否包含指定字符或子串"
  (let ([c (if (string? char-or-str)
               (string-ref char-or-str 0)
               char-or-str)])
    (let loop ([i 0])
      (cond
        [(>= i (string-length str)) #f]
        [(char=? (string-ref str i) c) #t]
        [else (loop (+ i 1))]))))

(define (all-satisfy? pred lst)
  "检查列表中所有元素是否满足谓词"
  (or (null? lst)
      (and (pred (car lst))
           (all-satisfy? pred (cdr lst)))))

(test-group "DNS Tests"

  (test "resolve-localhost"
    (let* ([loop (uv-loop-init)]
           [resolved #f]
           [got-error #f])
      ;; 解析 localhost
      (resolve-hostname loop "localhost"
        (lambda (addrs err)
          (if err
              (set! got-error err)
              (set! resolved addrs))))
      ;; 运行事件循环
      (uv-run loop 'default)
      ;; 验证
      (assert-false got-error "should not have error")
      (assert-true (and resolved (pair? resolved)) "should have results")
      (assert-true (member "127.0.0.1" resolved) "should contain 127.0.0.1")
      ;; 清理
      (uv-loop-close loop)))

  (test "resolve-ipv4-only"
    (let* ([loop (uv-loop-init)]
           [resolved #f]
           [got-error #f])
      ;; 只解析 IPv4
      (resolve-hostname loop "localhost" 'ipv4
        (lambda (addrs err)
          (if err
              (set! got-error err)
              (set! resolved addrs))))
      ;; 运行事件循环
      (uv-run loop 'default)
      ;; 验证
      (assert-false got-error "should not have error")
      (assert-true (and resolved (pair? resolved)) "should have results")
      ;; 所有结果应该是 IPv4 地址（不包含 ":"）
      (assert-true (all-satisfy? (lambda (addr)
                              (not (string-contains? addr ":")))
                            resolved)
                   "all addresses should be IPv4")
      ;; 清理
      (uv-loop-close loop)))

  (test "getaddrinfo-with-service"
    (let* ([loop (uv-loop-init)]
           [results #f]
           [got-error #f])
      ;; 解析带服务名的地址
      (uv-getaddrinfo loop "localhost" "80"
        (lambda (entries err)
          (if err
              (set! got-error err)
              (set! results entries))))
      ;; 运行事件循环
      (uv-run loop 'default)
      ;; 验证
      (assert-false got-error "should not have error")
      (assert-true (and results (pair? results)) "should have results")
      ;; 检查结果结构
      (let ([entry (car results)])
        (assert-true (addrinfo-entry? entry) "should be addrinfo-entry")
        (assert-true (pair? (addrinfo-entry-addr entry)) "addr should be pair")
        (assert-equal 80 (cdr (addrinfo-entry-addr entry)) "port should be 80"))
      ;; 清理
      (uv-loop-close loop)))

  (test "resolve-invalid-hostname"
    (let* ([loop (uv-loop-init)]
           [resolved #f]
           [got-error #f])
      ;; 解析不存在的主机名
      (resolve-hostname loop "this-hostname-should-not-exist-12345.invalid"
        (lambda (addrs err)
          (if err
              (set! got-error err)
              (set! resolved addrs))))
      ;; 运行事件循环
      (uv-run loop 'default)
      ;; 验证应该有错误
      (assert-true got-error "should have error for invalid hostname")
      ;; 清理
      (uv-loop-close loop)))

  (test "resolve-ip-address"
    (let* ([loop (uv-loop-init)]
           [resolved #f]
           [got-error #f])
      ;; 解析 IP 地址（应该直接返回）
      (resolve-hostname loop "8.8.8.8"
        (lambda (addrs err)
          (if err
              (set! got-error err)
              (set! resolved addrs))))
      ;; 运行事件循环
      (uv-run loop 'default)
      ;; 验证
      (assert-false got-error "should not have error")
      (assert-true (and resolved (pair? resolved)) "should have results")
      (assert-true (member "8.8.8.8" resolved) "should contain 8.8.8.8")
      ;; 清理
      (uv-loop-close loop)))

  (test "resolve-hostname-sync"
    (let* ([loop (uv-loop-init)]
           [addrs (resolve-hostname-sync loop "localhost")])
      ;; 验证
      (assert-true (and addrs (pair? addrs)) "should have results")
      (assert-true (member "127.0.0.1" addrs) "should contain 127.0.0.1")
      ;; 清理
      (uv-loop-close loop)))

) ; end test-group

(run-tests)
