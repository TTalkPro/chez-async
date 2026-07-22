;;; io-fs-net-gate.ss — S3 验证:high-level io-fs / io-net 建在 C++ 运行时上。
;;; 运行:
;;;   LD_LIBRARY_PATH=native/ta6le scheme --libdirs .:.. --program tests/scratch/io-fs-net-gate.ss

(import (chezscheme)
        (chez-async internal io-runtime)
        (chez-async high-level io-fs)
        (chez-async high-level io-net))

(define fail 0)
(define (check name ok?) (printf "  ~a ~a~n" (if ok? "✓" "✗") name) (unless ok? (set! fail (+ fail 1))))

(printf "S3 io-fs / io-net gate…~n")
(io-runtime-start!)

;; ========== io-fs ==========
(printf "  -- io-fs --~n")
(let ([path "/tmp/io-fs-gate.txt"]
      [msg (string->utf8 "io-fs 整文件往返 你好 🚀")])
  (io-write-file path msg)
  (check "write-file / read-file 往返一致" (bytevector=? (io-read-file path) msg))
  (let ([st (io-stat path)])
    (check "stat-size 正确" (= (stat-info-size st) (bytevector-length msg)))
    (check "stat 是文件非目录" (and (stat-info-file? st) (not (stat-info-dir? st)))))
  (check "io-exists? #t" (io-exists? path))
  (io-rename path (string-append path ".2"))
  (check "rename 后旧路径不存在" (not (io-exists? path)))
  (check "rename 后新路径存在" (io-exists? (string-append path ".2")))
  (io-unlink (string-append path ".2"))
  (check "unlink 后不存在" (not (io-exists? (string-append path ".2")))))

;; 目录
(let ([dir "/tmp/io-fs-gate-dir"])
  (guard (e [(io-error? e) #t]) (io-rmdir dir))   ; 清残留
  (io-mkdir dir)
  (io-write-file (string-append dir "/a.txt") (string->utf8 "a"))
  (io-write-file (string-append dir "/b.txt") (string->utf8 "b"))
  (let ([entries (sort string<? (io-scandir dir))])
    (check "scandir 列出 2 项" (equal? entries '("a.txt" "b.txt"))))
  (io-unlink (string-append dir "/a.txt"))
  (io-unlink (string-append dir "/b.txt"))
  (io-rmdir dir)
  (check "rmdir 后目录不存在" (not (io-exists? dir))))

;; 错误路径
(check "打开不存在文件抛 &io-error"
       (guard (e [(io-error? e) #t] [else #f]) (io-open "/nope/x" O_RDONLY 0) #f))

;; ========== io-net ==========
(printf "  -- io-net --~n")
(check "dns-resolve localhost 回环"
       (let ([ip (io-dns-resolve "localhost")]) (or (string=? ip "127.0.0.1") (string=? ip "::1"))))
(check "dns-resolve-all 非空" (pair? (io-dns-resolve-all "localhost")))

;; TCP echo:server 线程 accept+echo，主线程 connect+write+read
(let ([port 19876]
      [payload (string->utf8 "hello tcp echo 你好")]
      [server-done #f] [sm (make-mutex)] [sc (make-condition)])
  (let ([listener (io-tcp-listen "127.0.0.1" port)])
    (fork-thread
      (lambda ()
        (guard (e [else (fprintf (current-error-port) "server err: ~a~n" e)])
          (let ([s (io-tcp-accept listener)])
            (let ([data (io-stream-read s)])
              (unless (eof-object? data) (io-stream-write s data)))  ; echo
            (io-stream-close s)))
        (with-mutex sm (set! server-done #t) (condition-signal sc))))
    ;; 客户端
    (let ([c (io-tcp-connect "127.0.0.1" port)])
      (io-stream-write c payload)
      (let ([reply (io-stream-read c)])
        (check "TCP echo 回显一致" (and (not (eof-object? reply)) (bytevector=? reply payload))))
      (io-stream-close c))
    (with-mutex sm (let w () (unless server-done (condition-wait sc sm) (w))))
    (io-listener-close listener)
    (check "listener 关闭后无 stream/listener 泄漏"
           (and (= 0 (io-live-streams)) (= 0 (io-live-listeners))))))

(check "无 task 泄漏(live=0)" (= 0 (io-live-tasks)))
(io-runtime-stop!)

(if (= fail 0)
    (begin (printf "~n✅ S3 gate 通过 —— io-fs / io-net 建在 C++ 运行时上，全通。~n") (exit 0))
    (begin (printf "~n❌ ~a 项失败。~n" fail) (exit 1)))
