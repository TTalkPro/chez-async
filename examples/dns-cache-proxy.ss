#!/usr/bin/env scheme-script
;;; examples/dns-cache-proxy.ss - DNS 缓存代理服务器
;;;
;;; 使用 async/await 实现的 DNS 缓存代理，展示在长运行服务器中
;;; 如何结合回调式 I/O 和协程式业务逻辑。
;;;
;;; 核心设计：
;;; - 哨兵协程保持调度器活跃（永不 resolve 的 Promise）
;;; - UDP recv 回调中 spawn async 协程处理每个查询
;;; - 查询协程使用 await 等待上游 DNS 响应
;;;
;;; 用法：
;;;   scheme --libdirs .:.. --program examples/dns-cache-proxy.ss
;;;
;;; 测试：
;;;   dig @127.0.0.1 -p 15353 example.com
;;;   dig @127.0.0.1 -p 15353 example.com        # 缓存命中
;;;   dig @127.0.0.1 -p 15353 example.com AAAA   # 不同类型

(import (chezscheme)
        (chez-async high-level async-await)
        (chez-async high-level promise)
        (chez-async high-level event-loop)
        (chez-async high-level async-combinators)
        (chez-async low-level udp)
        (chez-async low-level timer)
        (chez-async low-level handle-base))

;; ========================================
;; 第 1 部分：配置
;; ========================================

(define *listen-port*      53)
(define *upstream-dns*     "219.148.204.66")
(define *upstream-port*    53)
(define *query-timeout-ms* 3000)
(define *negative-ttl*     60)

;; ========================================
;; 第 2 部分：字节操作工具
;; ========================================

(define (bv-u16-ref bv offset)
  "大端读 16 位无符号整数"
  (bitwise-ior
    (bitwise-arithmetic-shift-left (bytevector-u8-ref bv offset) 8)
    (bytevector-u8-ref bv (+ offset 1))))

(define (bv-u16-set! bv offset val)
  "大端写 16 位无符号整数"
  (bytevector-u8-set! bv offset (bitwise-arithmetic-shift-right val 8))
  (bytevector-u8-set! bv (+ offset 1) (bitwise-and val #xff)))

(define (bv-u32-ref bv offset)
  "大端读 32 位无符号整数"
  (bitwise-ior
    (bitwise-arithmetic-shift-left (bytevector-u8-ref bv offset) 24)
    (bitwise-arithmetic-shift-left (bytevector-u8-ref bv (+ offset 1)) 16)
    (bitwise-arithmetic-shift-left (bytevector-u8-ref bv (+ offset 2)) 8)
    (bytevector-u8-ref bv (+ offset 3))))

(define (string-join strs sep)
  "用分隔符连接字符串列表"
  (if (null? strs) ""
      (let loop ([rest (cdr strs)] [acc (car strs)])
        (if (null? rest) acc
            (loop (cdr rest)
                  (string-append acc sep (car rest)))))))

(define (string-split str ch)
  "按字符分割字符串"
  (let loop ([chars (string->list str)] [current '()] [result '()])
    (cond
      [(null? chars)
       (reverse (cons (list->string (reverse current)) result))]
      [(char=? (car chars) ch)
       (loop (cdr chars) '()
             (cons (list->string (reverse current)) result))]
      [else
       (loop (cdr chars) (cons (car chars) current) result)])))

(define (str-downcase str)
  "转小写"
  (list->string (map char-downcase (string->list str))))

;; ========================================
;; 第 3 部分：DNS 协议解析（RFC 1035 最小子集）
;; ========================================

(define (dns-id bv)
  "读 Transaction ID"
  (bv-u16-ref bv 0))

(define (dns-flags bv)
  "读标志位"
  (bv-u16-ref bv 2))

(define (dns-qr? bv)
  "是否为应答（QR=1）"
  (not (= 0 (bitwise-and (bytevector-u8-ref bv 2) #x80))))

(define (dns-qdcount bv)
  "问题计数"
  (bv-u16-ref bv 4))

(define (dns-ancount bv)
  "应答计数"
  (bv-u16-ref bv 6))

(define (dns-rcode bv)
  "响应码"
  (bitwise-and (bytevector-u8-ref bv 3) #x0f))

(define (dns-set-id! bv id)
  "写 Transaction ID"
  (bv-u16-set! bv 0 id))

(define (dns-parse-name bv offset)
  "解析域名（含压缩指针），返回 (values name new-offset)"
  (let loop ([off offset] [labels '()] [jumped? #f] [end-offset #f])
    (let ([len (bytevector-u8-ref bv off)])
      (cond
        ;; 终止：长度为 0
        [(= len 0)
         (values (str-downcase (string-join (reverse labels) "."))
                 (if end-offset end-offset (+ off 1)))]
        ;; 压缩指针：高 2 位为 11
        [(= (bitwise-and len #xc0) #xc0)
         (let ([ptr (bitwise-ior
                      (bitwise-arithmetic-shift-left (bitwise-and len #x3f) 8)
                      (bytevector-u8-ref bv (+ off 1)))])
           (loop ptr labels #t (if end-offset end-offset (+ off 2))))]
        ;; 正常标签
        [else
         (let ([label (make-string len)])
           (do ([i 0 (+ i 1)])
               ((= i len))
             (string-set! label i
               (integer->char (bytevector-u8-ref bv (+ off 1 i)))))
           (loop (+ off 1 len) (cons label labels) jumped? end-offset))]))))

(define (dns-parse-question bv offset)
  "解析问题段，返回 (values qname qtype qclass new-offset)"
  (let-values ([(name new-off) (dns-parse-name bv offset)])
    (let ([qtype (bv-u16-ref bv new-off)]
          [qclass (bv-u16-ref bv (+ new-off 2))])
      (values name qtype qclass (+ new-off 4)))))

(define (dns-extract-min-ttl bv offset ancount)
  "从应答段提取最小 TTL，offset 指向应答段起始"
  (if (= ancount 0)
      *negative-ttl*
      (let loop ([i 0] [off offset] [min-ttl #xffffffff])
        (if (= i ancount)
            (if (= min-ttl #xffffffff) *negative-ttl* min-ttl)
            ;; 跳过 name
            (let-values ([(_ name-end) (dns-parse-name bv off)])
              ;; name-end 指向 type(2) + class(2) + ttl(4) + rdlength(2) + rdata
              (let* ([ttl (bv-u32-ref bv (+ name-end 4))]
                     [rdlength (bv-u16-ref bv (+ name-end 8))]
                     [next-off (+ name-end 10 rdlength)])
                (loop (+ i 1) next-off (min min-ttl ttl))))))))

(define (dns-type->string type)
  "类型码转可读字符串"
  (case type
    [(1)  "A"]
    [(2)  "NS"]
    [(5)  "CNAME"]
    [(6)  "SOA"]
    [(12) "PTR"]
    [(15) "MX"]
    [(16) "TXT"]
    [(28) "AAAA"]
    [(33) "SRV"]
    [(255) "ANY"]
    [else (format "TYPE~a" type)]))

(define (encode-dns-name labels)
  "编码域名标签列表为 DNS 线格式 bytevector"
  (let* ([parts (map (lambda (label)
                       (let* ([bv-label (string->utf8 label)]
                              [len (bytevector-length bv-label)]
                              [part (make-bytevector (+ 1 len))])
                         (bytevector-u8-set! part 0 len)
                         (bytevector-copy! bv-label 0 part 1 len)
                         part))
                     labels)]
         ;; 加上末尾的 0 长度字节
         [total (+ (apply + (map bytevector-length parts)) 1)]
         [result (make-bytevector total 0)])
    (let loop ([ps parts] [off 0])
      (if (null? ps)
          result
          (let ([p (car ps)])
            (bytevector-copy! p 0 result off (bytevector-length p))
            (loop (cdr ps) (+ off (bytevector-length p))))))))

(define (build-dns-query domain qtype)
  "构造 DNS 查询包（用于测试）"
  (let* ([labels (string-split domain #\.)]
         [name-bv (encode-dns-name labels)]
         [name-len (bytevector-length name-bv)]
         ;; header(12) + name + type(2) + class(2)
         [total (+ 12 name-len 4)]
         [pkt (make-bytevector total 0)])
    ;; Transaction ID = random
    (bv-u16-set! pkt 0 (random 65536))
    ;; Flags: standard query, recursion desired
    (bv-u16-set! pkt 2 #x0100)
    ;; QDCOUNT = 1
    (bv-u16-set! pkt 4 1)
    ;; Question section: name
    (bytevector-copy! name-bv 0 pkt 12 name-len)
    ;; QTYPE
    (bv-u16-set! pkt (+ 12 name-len) qtype)
    ;; QCLASS = IN (1)
    (bv-u16-set! pkt (+ 12 name-len 2) 1)
    pkt))

;; ========================================
;; 第 4 部分：缓存层
;; ========================================

(define *dns-cache* (make-hashtable string-hash string=?))
(define *cache-hits*   0)
(define *cache-misses* 0)

(define (current-time-ms)
  "当前毫秒时间戳"
  (let ([t (current-time 'time-monotonic)])
    (+ (* (time-second t) 1000)
       (div (time-nanosecond t) 1000000))))

(define (cache-key domain qtype)
  "生成缓存键"
  (string-append (str-downcase domain) ":" (number->string qtype)))

(define (cache-lookup domain qtype)
  "查缓存，过期自动删除，返回 bv 或 #f"
  (let* ([key (cache-key domain qtype)]
         [entry (hashtable-ref *dns-cache* key #f)])
    (cond
      [(not entry) #f]
      [(> (current-time-ms) (cdr entry))
       ;; 过期，删除
       (hashtable-delete! *dns-cache* key)
       #f]
      [else (car entry)])))

(define (cache-store! domain qtype response ttl)
  "写缓存，ttl 单位秒"
  (let ([key (cache-key domain qtype)]
        [expiry (+ (current-time-ms) (* (max ttl 1) 1000))])
    (hashtable-set! *dns-cache* key (cons (bytevector-copy response) expiry))))

;; ========================================
;; 第 5 部分：UDP Promise 包装器
;; ========================================

(define (udp-send-async udp data addr port)
  "包装 uv-udp-send! 为 Promise"
  (make-promise (uv-default-loop)
    (lambda (resolve reject)
      (guard (ex [else (reject ex)])
        (uv-udp-send! udp data addr port
          (lambda (err)
            (if err (reject err) (resolve #t))))))))

(define (query-upstream query-bv)
  "转发查询到上游 DNS，返回 Promise<bytevector>"
  (let ([loop (uv-default-loop)])
    (make-promise loop
      (lambda (resolve reject)
        (let ([tmp-udp (uv-udp-init loop)]
              [timer (uv-timer-init loop)]
              [done? #f])

          ;; 清理所有资源的辅助函数
          (define (cleanup!)
            (uv-handle-close! timer)
            (uv-udp-recv-stop! tmp-udp)
            (uv-handle-close! tmp-udp))

          ;; 启动接收等待上游响应
          (uv-udp-recv-start! tmp-udp
            (lambda (udp data-or-error sender-addr flags)
              (when (and (not done?) (bytevector? data-or-error)
                         (>= (bytevector-length data-or-error) 12))
                (set! done? #t)
                (cleanup!)
                (resolve data-or-error))))

          ;; 启动超时定时器
          (uv-timer-start! timer *query-timeout-ms* 0
            (lambda (t)
              (unless done?
                (set! done? #t)
                (cleanup!)
                (reject (condition
                         (make-error)
                         (make-message-condition "upstream query timeout"))))))

          ;; 发送查询到上游
          (uv-udp-send! tmp-udp query-bv *upstream-dns* *upstream-port*
            (lambda (err)
              (when (and err (not done?))
                (set! done? #t)
                (cleanup!)
                (reject err)))))))))

;; ========================================
;; 第 6 部分：查询处理器（async/await 核心）
;; ========================================

(define (handle-query server-udp query-bv client-addr)
  "处理单个 DNS 查询，在 async 协程中运行"
  (async
    (guard (ex
            [else
             (format #t "[ERROR] ~a~%"
                     (if (message-condition? ex)
                         (condition-message ex)
                         ex))])
      (let-values ([(qname qtype qclass _) (dns-parse-question query-bv 12)])
        (format #t "[QUERY] ~a ~a from ~a:~a"
                qname (dns-type->string qtype)
                (car client-addr) (cdr client-addr))
        (let ([cached (cache-lookup qname qtype)])
          (if cached
              ;; 缓存命中：改写 Transaction ID 后直接回复
              (begin
                (set! *cache-hits* (+ *cache-hits* 1))
                (format #t " -> CACHE HIT~%")
                (let ([response (bytevector-copy cached)])
                  (dns-set-id! response (dns-id query-bv))
                  (await (udp-send-async server-udp response
                           (car client-addr) (cdr client-addr)))))
              ;; 缓存未命中：转发 → 缓存 → 回复
              (begin
                (set! *cache-misses* (+ *cache-misses* 1))
                (format #t " -> CACHE MISS, forwarding to ~a~%" *upstream-dns*)
                (let ([response (await (query-upstream query-bv))])
                  ;; 提取 TTL 并缓存
                  (let ([rcode (dns-rcode response)]
                        [ancount (dns-ancount response)])
                    (let-values ([(_ _t _c ans-offset) (dns-parse-question response 12)])
                      (let ([ttl (if (> ancount 0)
                                     (dns-extract-min-ttl response ans-offset ancount)
                                     *negative-ttl*)])
                        (cache-store! qname qtype response ttl)
                        (format #t "[CACHED] ~a ~a TTL=~as rcode=~a answers=~a~%"
                                qname (dns-type->string qtype)
                                ttl rcode ancount))))
                  ;; 回复客户端
                  (await (udp-send-async server-udp response
                           (car client-addr) (cdr client-addr)))))))))))

;; ========================================
;; 第 7 部分：服务器启动
;; ========================================

(define (start-dns-proxy)
  "启动 DNS 代理服务器"
  (let* ([loop (uv-default-loop)]
         [server (uv-udp-init loop)])
    (uv-udp-bind server "0.0.0.0" *listen-port*)
    (let ([addr (uv-udp-getsockname server)])
      (format #t "DNS proxy listening on ~a:~a (UDP)~%" (car addr) (cdr addr)))
    ;; 接收 UDP 包，验证后 spawn async 协程
    (uv-udp-recv-start! server
      (lambda (udp data-or-error sender-addr flags)
        (when (and (bytevector? data-or-error)
                   (>= (bytevector-length data-or-error) 12)
                   (not (dns-qr? data-or-error)))  ; 只处理查询，忽略应答
          (handle-query udp data-or-error sender-addr))))
    server))

;; ========================================
;; 第 8 部分：统计定时器 + 主入口
;; ========================================

(define (start-stats-timer)
  "每 30 秒打印缓存统计"
  (let ([timer (uv-timer-init (uv-default-loop))])
    (uv-timer-start! timer 30000 30000
      (lambda (t)
        (let ([total (+ *cache-hits* *cache-misses*)]
              [entries (hashtable-size *dns-cache*)])
          (format #t "[STATS] queries=~a hits=~a misses=~a hit-rate=~a% cache-entries=~a~%"
                  total *cache-hits* *cache-misses*
                  (if (> total 0)
                      (round (* 100.0 (/ *cache-hits* total)))
                      0)
                  entries))))
    timer))

(define (main)
  (format #t "=== chez-async: DNS Cache Proxy ===~%")
  (format #t "libuv version: ~a~%~%" (uv-version-string))
  (format #t "Configuration:~%")
  (format #t "  Listen port:    ~a~%" *listen-port*)
  (format #t "  Upstream DNS:   ~a:~a~%" *upstream-dns* *upstream-port*)
  (format #t "  Query timeout:  ~ams~%" *query-timeout-ms*)
  (format #t "  Negative TTL:   ~as~%~%" *negative-ttl*)

  (start-dns-proxy)
  (start-stats-timer)

  (format #t "Press Ctrl+C to stop~%")
  (format #t "Test with: dig @127.0.0.1 -p ~a example.com~%~%" *listen-port*)

  ;; 哨兵协程：永不 resolve 的 Promise 保持调度器活跃
  (async (await (make-promise (uv-default-loop) (lambda (resolve reject) (void)))))

  ;; 启动调度器（永不退出）
  (run-async-loop))

;; 运行
(main)
