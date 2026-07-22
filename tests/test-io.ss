#!/usr/bin/env scheme-script
;;; tests/test-io.ss - 新 I/O 运行时（移植的 skiff C++ task 运行时）测试套件（S5）
;;;
;;; 需 native/<mt>/chez-async-rt.so 在 LD_LIBRARY_PATH（run-tests.sh 已处理）。

(import (chezscheme)
        (chez-async tests framework)
        (chez-async))

(io-runtime-start!)

(test-group "IO Runtime (C++ task runtime)"

  ;; ---- fs ----
  (test "fs write-file / read-file 往返"
    (let ([path "/tmp/test-io-fs.txt"]
          [msg (string->utf8 "chez-async io 你好 🚀")])
      (io-write-file path msg)
      (let ([back (io-read-file path)])
        (io-unlink path)
        (assert-true (bytevector=? back msg) "read-back equals written"))))

  (test "fs stat 大小与类型"
    (let ([path "/tmp/test-io-stat.txt"]
          [msg (string->utf8 "1234567890")])
      (io-write-file path msg)
      (let ([st (io-stat path)])
        (io-unlink path)
        (assert-equal 10 (stat-info-size st) "size = 10")
        (assert-true (stat-info-file? st) "is file")
        (assert-false (stat-info-dir? st) "not dir"))))

  (test "fs mkdir / scandir / rmdir"
    (let ([dir "/tmp/test-io-dir"])
      (guard (e [(io-error? e) #t]) (io-rmdir dir))
      (io-mkdir dir)
      (io-write-file (string-append dir "/x") (string->utf8 "x"))
      (io-write-file (string-append dir "/y") (string->utf8 "y"))
      (let ([entries (sort string<? (io-scandir dir))])
        (io-unlink (string-append dir "/x"))
        (io-unlink (string-append dir "/y"))
        (io-rmdir dir)
        (assert-equal '("x" "y") entries "scandir lists both"))))

  (test "fs 错误路径抛 &io-error"
    (assert-error (lambda () (io-open "/nonexistent-dir-zzz/f" O_RDONLY 0))
                  "open nonexistent raises"))

  ;; ---- pinned 零拷贝 fs ----
  (test "pinned io-write! / io-read! 往返（零拷贝）"
    (let ([path "/tmp/test-io-pinned.txt"]
          [msg (string->utf8 "pinned 零拷贝 你好 🚀")])
      ;; 写：pinned 写整个 bytevector
      (let ([fd (io-open path (fxior O_WRONLY O_CREAT O_TRUNC) #o644)])
        (io-write! fd msg 0)
        (io-close fd))
      ;; 读：pinned 读进调用方 bytevector
      (let* ([len (bytevector-length msg)]
             [buf (make-bytevector len 0)]
             [fd (io-open path O_RDONLY 0)])
        (let ([n (io-read! fd buf 0 len -1)])
          (io-close fd)
          (io-unlink path)
          (assert-equal len n "pinned read count")
          (assert-true (bytevector=? buf msg) "pinned round-trip equals")))))

  (test "pinned io-read! EOF"
    (let ([path "/tmp/test-io-pinned-eof.txt"])
      (io-write-file path (string->utf8 "ab"))
      (let ([fd (io-open path O_RDONLY 0)] [buf (make-bytevector 8 0)])
        (io-read! fd buf 0 8 -1)                ; 读到 "ab"
        (let ([r (io-read! fd buf 0 8 -1)])     ; 再读 → EOF
          (io-close fd)
          (io-unlink path)
          (assert-true (eof-object? r) "second pinned read is EOF")))))

  ;; ---- net ----
  (test "dns-resolve localhost 回环"
    (let ([ip (io-dns-resolve "localhost")])
      (assert-true (or (string=? ip "127.0.0.1") (string=? ip "::1")) "loopback ip")))

  (test "TCP echo（server/client 分线程）"
    (let ([port 19911]
          [payload (string->utf8 "tcp echo 你好")]
          [done #f] [m (make-mutex)] [c (make-condition)])
      (let ([listener (io-tcp-listen "127.0.0.1" port)])
        (fork-thread
          (lambda ()
            (guard (e [else (void)])
              (let ([s (io-tcp-accept listener)])
                (let ([data (io-stream-read s)])
                  (unless (eof-object? data) (io-stream-write s data)))
                (io-stream-close s)))
            (with-mutex m (set! done #t) (condition-signal c))))
        (let ([conn (io-tcp-connect "127.0.0.1" port)])
          (io-stream-write conn payload)
          (let ([reply (io-stream-read conn)])
            (io-stream-close conn)
            (with-mutex m (let w () (unless done (condition-wait c m) (w))))
            (io-listener-close listener)
            (assert-true (and (not (eof-object? reply)) (bytevector=? reply payload))
                         "echo matches"))))))

  ;; ---- process ----
  (test "process io-run true/false"
    (begin
      (assert-equal 0 (io-run "/bin/true") "true → 0")
      (assert-false (= 0 (io-run "/bin/false")) "false → nonzero")))

  (test "process io-run/output 捕获 stdout"
    (let ([r (io-run/output "/bin/echo" "hi" "世界")])
      (assert-equal 0 (car r) "exit 0")
      (assert-equal "hi 世界\n" (utf8->string (cdr r)) "captured stdout")))

  ;; ---- async/await ----
  (test "run-async 返回根值"
    (assert-equal 42 (run-async (lambda () (io-sleep 10) 42)) "root returns 42"))

  (test "await-all 并发（两个 80ms sleep ≈80ms 非 160ms）"
    (let ([t0 (real-time)])
      (let ([vals (run-async
                    (lambda ()
                      (await-all (list (async (lambda () (io-sleep 80) 'a))
                                       (async (lambda () (io-sleep 80) 'b))))))])
        (assert-equal '(a b) vals "both futures resolved")
        (assert-true (< (- (real-time) t0) 140) "ran concurrently"))))

  (test "async 根异常传播"
    (assert-error (lambda () (run-async (lambda () (io-open "/nope/x" 0 0))))
                  "root error re-raised"))

  (test "async 子 future 异常经 await 传播"
    (assert-true
      (run-async
        (lambda ()
          (let ([f (async (lambda () (error 'child "boom")))])
            (guard (e [else #t]) (await f) #f))))
      "child error propagates through await"))

  ;; ---- 泄漏 ----
  (test "无 task / stream / listener 泄漏"
    (begin
      (assert-equal 0 (io-live-tasks) "no task leak")
      (assert-equal 0 (io-live-streams) "no stream leak")
      (assert-equal 0 (io-live-listeners) "no listener leak")))
)

(io-runtime-stop!)
(run-tests)
