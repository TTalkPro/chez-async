;;; high-level/io-net.ss - 基于 C++ task 运行时的网络 API（对齐 skiff/net.ss）
;;;
;;; 建在 internal/io-runtime 之上（S3）。DNS / TCP / stream I/O。stream/listener
;;; 是运行时 loop 线程上的持久句柄（Scheme 侧持不透明 uptr）；读的按需/背压、
;;; accept 的停泊队列语义都在 C++ 侧（runtime.cpp/net.hpp）实现，Scheme 侧只是
;;; submit + await。
;;;
;;; 无 pinned 零拷贝（v1）：buffer 走 foreign + bytevector 桥接（同 io-fs）。

(library (chez-async high-level io-net)
  (export
    io-dns-resolve io-dns-resolve-all
    io-tcp-connect io-tcp-listen io-tcp-accept
    io-stream-read io-stream-write io-stream-close
    io-stream-pipe io-stream-write-queue-size
    io-listener-close)
  (import (chezscheme)
          (chez-async internal io-runtime)
          (chez-async internal buffer))

  ;; --- buffer 桥接助手（同 io-fs，保持模块独立）---

  (define (read-task->result who t)
    (let ([r (task-await t)])
      (cond
        [(< r 0) (task-free t) (raise-io-error who r)]
        [(= r 0) (task-free t) (eof-object)]
        [else
         (let ([fp (foreign-alloc r)])
           (task-read-into! t fp 0)
           (let ([bv (foreign->bytevector fp r)])
             (foreign-free fp)
             (task-free t)
             bv))])))

  (define (run-write who submit-fn bv start n)
    (let-values ([(fp _len) (bytevector->foreign bv)])
      (let ([t (submit-fn fp start n)])
        (foreign-free fp)              ; C++ 已在 submit 内同步拷走
        (task-run who t))))

  ;; --- DNS ---

  (define (family->int family)
    (case family [(any) 0] [(ipv4) 4] [(ipv6) 6]
      [else (error 'io-dns-resolve "bad family (want any/ipv4/ipv6)" family)]))

  ;; 解析为首个数字 IP 字符串。
  (define io-dns-resolve
    (case-lambda
      [(host) (io-dns-resolve host 'any)]
      [(host family)
       (task-run-str 'io-dns-resolve (submit-dns-resolve host "" (family->int family)))]))

  ;; 解析为全部 IP（OS 顺序，去重）。
  (define io-dns-resolve-all
    (case-lambda
      [(host) (io-dns-resolve-all host 'any)]
      [(host family)
       (let* ([t (submit-dns-resolve host "" (family->int family))]
              [r (task-await t)])
         (if (< r 0)
             (begin (task-free t) (raise-io-error 'io-dns-resolve-all r))
             (let ([n (task-scandir-count t)])
               (let loop ([i 0] [acc '()])
                 (if (fx>= i n)
                     (begin (task-free t) (reverse acc))
                     (loop (fx+ i 1) (cons (task-scandir-name t i) acc)))))))]))

  ;; --- client / server ---

  (define (try-connect ip port)
    (task-run 'io-tcp-connect (submit-tcp-connect ip port)))

  ;; 连接 host:port（host 可为名字或数字 v4/v6 字面量）。名字多地址时按序尝试。
  ;; 返回 stream 句柄或抛最后一个连接错误。
  (define (io-tcp-connect host port)
    (let loop ([ips (io-dns-resolve-all host)])
      (cond
        [(null? ips) (error 'io-tcp-connect "no addresses" host)]
        [(null? (cdr ips)) (try-connect (car ips) port)]
        [else (guard (e [(io-error? e) (loop (cdr ips))])
                (try-connect (car ips) port))])))

  ;; bind + listen，返回 listener 句柄或抛错。
  (define io-tcp-listen
    (case-lambda
      [(host port) (io-tcp-listen host port 128)]
      [(host port backlog)
       (task-run 'io-tcp-listen (submit-tcp-listen host port backlog))]))

  ;; 阻塞/挂起至下一个入站连接，返回 stream 句柄。
  (define (io-tcp-accept listener)
    (task-run 'io-tcp-accept (submit-tcp-accept listener)))

  ;; --- stream I/O ---

  ;; 读至多 maxlen 字节，返回 bytevector，EOF 返回 eof-object。
  (define io-stream-read
    (case-lambda
      [(stream) (io-stream-read stream 65536)]
      [(stream maxlen) (read-task->result 'io-stream-read (submit-stream-read stream maxlen))]))

  ;; 写 bytevector（或其区间），返回字节数或抛错。
  (define io-stream-write
    (case-lambda
      [(stream bv) (io-stream-write stream bv 0 (bytevector-length bv))]
      [(stream bv start n)
       (run-write 'io-stream-write
                  (lambda (src s nn) (submit-stream-write stream src s nn))
                  bv start n)]))

  ;; 把 src 泵到 dst 直到 EOF；await 的写即背压。返回总字节数。两端都不关闭。
  (define io-stream-pipe
    (case-lambda
      [(src dst) (io-stream-pipe src dst 65536)]
      [(src dst chunk)
       (let loop ([total 0])
         (let ([bv (io-stream-read src chunk)])
           (if (eof-object? bv)
               total
               (begin
                 (io-stream-write dst bv)
                 (loop (+ total (bytevector-length bv)))))))]))

  (define (io-stream-write-queue-size stream) (stream-write-queue-size stream))

  (define (io-stream-close stream)
    (task-run-void 'io-stream-close (submit-stream-close stream)))

  (define (io-listener-close listener)
    (task-run-void 'io-listener-close (submit-listener-close listener)))

) ; end library
