#!/usr/bin/env scheme-script
;;; tests/test-stream-reader.ss - F5 stream-reader / stream-pipe 重写回归测试
;;;
;;; 覆盖旧实现的缺陷修复：
;;; - stream-reader 连续读取正确累积数据直到 EOF（旧实现 buffer 是死字段）
;;; - 并发 stream-reader-read 按 FIFO 依次拿到数据（旧实现第二个读覆盖回调、第一个永不 settle）
;;; - stream-pipe 大数据传输完整（含背压 pause/resume 路径）

(import (chezscheme)
        (chez-async tests framework)
        (chez-async high-level event-loop)
        (chez-async high-level promise)
        (chez-async high-level stream)
        (chez-async low-level tcp)
        (chez-async low-level stream)
        (chez-async low-level handle-base))

;; ---- 辅助 ----
(define (make-payload n)
  "生成 n 字节、内容为 (i mod 256) 的 bytevector"
  (let ([bv (make-bytevector n)])
    (do ([i 0 (+ i 1)]) ((= i n) bv)
      (bytevector-u8-set! bv i (modulo i 256)))))

(define (bv-concat bvs)
  "拼接 bytevector 列表"
  (let* ([total (apply + (map bytevector-length bvs))]
         [out (make-bytevector total)])
    (let loop ([bvs bvs] [off 0])
      (if (null? bvs)
          out
          (let ([len (bytevector-length (car bvs))])
            (bytevector-copy! (car bvs) 0 out off len)
            (loop (cdr bvs) (+ off len)))))))

(define (with-tcp-pair on-server-conn on-client)
  "建立 TCP 环回连接对，分别回调 server 侧 conn 和 client 侧句柄。
   返回创建好的 loop（调用者负责 run + close）。"
  (let* ([loop (uv-loop-init)]
         [server (uv-tcp-init loop)]
         [client (uv-tcp-init loop)]
         [port 0])
    (uv-tcp-bind server "127.0.0.1" 0)
    (set! port (cdr (uv-tcp-getsockname server)))
    (uv-tcp-listen server 128
      (lambda (srv err)
        (unless err
          (let ([conn (uv-tcp-accept srv)])
            (uv-handle-close! srv)   ; 只接一个连接
            (on-server-conn conn)))))
    (uv-tcp-connect client "127.0.0.1" port
      (lambda (tcp err)
        (unless err (on-client client))))
    (values loop client)))

(test-group "Stream Reader / Pipe (F5)"

  ;; ---- 连续读取累积至 EOF ----
  (test "reader-continuous-read-until-eof"
    (let ([payload (make-payload 50000)]
          [result #f])
      (let-values ([(loop client)
                    (with-tcp-pair
                      ;; server: 发送整块 payload 后关闭
                      (lambda (conn)
                        (uv-write! conn (make-payload 50000)
                          (lambda (werr) (uv-handle-close! conn))))
                      ;; client: 用 reader 连续读取累积
                      (lambda (client)
                        (let ([rdr (make-stream-reader client)]
                              [chunks '()])
                          (define (loop-read)
                            (promise-then (stream-reader-read rdr)
                              (lambda (chunk)
                                (if chunk
                                    (begin (set! chunks (cons chunk chunks)) (loop-read))
                                    (begin (set! result (bv-concat (reverse chunks)))
                                           (uv-handle-close! client))))))
                          (loop-read))))])
        (uv-run loop 'default)
        (uv-loop-close loop))
      (assert-true (bytevector? result) "should have accumulated data")
      (assert-equal 50000 (bytevector-length result) "should receive all bytes")
      (assert-equal payload result "received bytes should match sent payload exactly")))

  ;; ---- 并发读取按 FIFO 派发（旧实现会互相覆盖）----
  (test "concurrent-reads-served-in-order"
    (let ([r1 'unset] [r2 'unset])
      (let-values ([(loop client)
                    (with-tcp-pair
                      ;; server: 发送小块 "hi" 后关闭
                      (lambda (conn)
                        (uv-write! conn (string->utf8 "hi")
                          (lambda (werr) (uv-handle-close! conn))))
                      ;; client: 数据到达前先发出两个读取
                      (lambda (client)
                        (let ([rdr (make-stream-reader client)])
                          (promise-then (stream-reader-read rdr)
                            (lambda (chunk) (set! r1 chunk)))
                          (promise-then (stream-reader-read rdr)
                            (lambda (chunk)
                              (set! r2 chunk)
                              (uv-handle-close! client))))))])
        (uv-run loop 'default)
        (uv-loop-close loop))
      ;; 第一个读拿到数据，第二个读在 EOF 时拿到 #f —— 两者都 settle，无覆盖
      (assert-true (bytevector? r1) "first read should get the data chunk")
      (assert-equal "hi" (utf8->string r1) "first read data should be 'hi'")
      (assert-equal #f r2 "second read should resolve #f at EOF (not hang / not overwritten)")))

  ;; ---- stream-pipe 大数据传输完整（含背压路径）----
  (test "pipe-transfers-large-payload"
    (let ([payload (make-payload 300000)]   ; > 256KB 高水位，触发 pause/resume
          [result #f])
      (let-values ([(loop client)
                    (with-tcp-pair
                      ;; server: echo pipe（conn → conn），源 EOF 且写完后关闭 conn
                      (lambda (conn)
                        (promise-then (stream-pipe conn conn)
                          (lambda (_) (uv-handle-close! conn))))
                      ;; client: 并发排空回显数据 + 写入后半关闭写端
                      (lambda (client)
                        (let ([rdr (make-stream-reader client)]
                              [chunks '()])
                          (define (drain)
                            (promise-then (stream-reader-read rdr)
                              (lambda (chunk)
                                (if chunk
                                    (begin (set! chunks (cons chunk chunks)) (drain))
                                    (begin (set! result (bv-concat (reverse chunks)))
                                           (uv-handle-close! client))))))
                          (drain)
                          (promise-then (stream-write client (make-payload 300000))
                            (lambda (_) (stream-shutdown client))))))])
        (uv-run loop 'default)
        (uv-loop-close loop))
      (assert-true (bytevector? result) "should have piped data back")
      (assert-equal 300000 (bytevector-length result) "all piped bytes should arrive")
      (assert-equal payload result "piped bytes should match original exactly")))

  )

(run-tests)
