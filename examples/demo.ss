#!/usr/bin/env scheme-script
;;; examples/demo.ss - chez-async 新栈综合演示（C++ task 运行时）
;;;
;;; 运行：
;;;   bake runtime   # 先建 native/<mt>/chez-async-rt.so（或 native/build.sh）
;;;   LD_LIBRARY_PATH=native/ta6le scheme --libdirs . --program examples/demo.ss

(import (chezscheme)
        (chez-async))

(printf "=== chez-async demo（skiff C++ task 运行时）===~n~n")

(io-runtime-start!)

;; 1. async/await + 并发：两个文件并发写，再并发读
(printf "1) async/await 并发文件 I/O~n")
(run-async
  (lambda ()
    ;; 并发写两个文件
    (await-all (list (async (lambda () (io-write-file "/tmp/demo-a.txt" (string->utf8 "hello A"))))
                     (async (lambda () (io-write-file "/tmp/demo-b.txt" (string->utf8 "hello B"))))))
    ;; 并发读回
    (let ([contents (await-all (list (async (lambda () (io-read-file "/tmp/demo-a.txt")))
                                     (async (lambda () (io-read-file "/tmp/demo-b.txt")))))])
      (for-each (lambda (bv) (printf "   读到: ~s~n" (utf8->string bv))) contents))
    (io-unlink "/tmp/demo-a.txt")
    (io-unlink "/tmp/demo-b.txt")))

;; 2. 并发的真实性：两个 100ms sleep 并行 ≈100ms
(printf "~n2) 并发验证：两个 100ms sleep~n")
(let ([t0 (real-time)])
  (run-async
    (lambda ()
      (await-all (list (async (lambda () (io-sleep 100)))
                       (async (lambda () (io-sleep 100)))))))
  (printf "   用时 ~ams（并行，非串行 200ms）~n" (- (real-time) t0)))

;; 3. 子进程
(printf "~n3) 子进程 io-run/output~n")
(let ([r (io-run/output "/bin/echo" "chez-async" "🚀")])
  (printf "   echo 退出码 ~a，输出 ~s~n" (car r) (utf8->string (cdr r))))

;; 4. DNS
(printf "~n4) DNS 解析~n")
(printf "   localhost → ~a~n" (io-dns-resolve "localhost"))

(io-runtime-stop!)
(printf "~n=== demo 结束 ===~n")
