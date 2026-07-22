;;; io-runtime-gate.ss — S2 验证:经 internal/io-runtime 绑定层（非裸 foreign）
;;; 使用 C++ task 运行时。覆盖 timer / fs 往返 / dns / 错误路径 / cq / 泄漏。
;;; 运行:
;;;   LD_LIBRARY_PATH=native/ta6le scheme --libdirs .:.. --program tests/scratch/io-runtime-gate.ss

(import (chezscheme)
        (chez-async internal io-runtime))

(define O_RDONLY 0) (define O_WRONLY 1) (define O_CREAT 64) (define O_TRUNC 512)

(define fail 0)
(define (check name ok?) (printf "  ~a ~a~n" (if ok? "✓" "✗") name) (unless ok? (set! fail (+ fail 1))))

;; bytevector → 新 foreign 缓冲（调用方 foreign-free）
(define (bv->foreign bv)
  (let* ([n (bytevector-length bv)] [p (foreign-alloc (max 1 n))])
    (let cp ([i 0]) (when (< i n) (foreign-set! 'unsigned-8 p i (bytevector-u8-ref bv i)) (cp (+ i 1))))
    p))
(define (foreign->bv p n)
  (let ([bv (make-bytevector n 0)])
    (let cp ([i 0]) (when (< i n) (bytevector-u8-set! bv i (foreign-ref 'unsigned-8 p i)) (cp (+ i 1))))
    bv))

(printf "S2 io-runtime 绑定层 gate…~n")
(io-runtime-start!)

;; ① timer（io-sleep → task-run-void）
(let ([t0 (real-time)])
  (io-sleep 30)
  (check "io-sleep 30 起码耗时 ~25ms" (>= (- (real-time) t0) 25)))

;; ② fs 往返（经绑定层 submit-* + task-run）
(let* ([path "/tmp/io-runtime-gate.txt"]
       [msg (string->utf8 "io-runtime 绑定层 round-trip 你好")]
       [len (bytevector-length msg)]
       [src (bv->foreign msg)])
  (let ([fd (task-run 'open-w (submit-fs-open path (bitwise-ior O_WRONLY O_CREAT O_TRUNC) #o644))])
    (check "submit-fs-open(write)→fd≥0" (>= fd 0))
    (check "submit-fs-write 字节数正确" (= len (task-run 'write (submit-fs-write fd src 0 len -1))))
    (task-run-void 'close-w (submit-fs-close fd)))
  ;; stat（手动 await 以读 stat-size）
  (let ([st (submit-fs-stat path)])
    (let ([r (task-await st)])
      (check "fs-stat 成功" (>= r 0))
      (check "stat-size = 写入长度" (= len (task-stat-size st)))
      (check "stat 是普通文件" (task-stat-file? st))
      (task-free st)))
  ;; 读回
  (let ([fd (task-run 'open-r (submit-fs-open path O_RDONLY 0))])
    (let* ([dst (foreign-alloc len)]
           [rt (submit-fs-read fd len -1)]
           [n (task-await rt)])
      (check "fs-read 字节数正确" (= n len))
      (task-read-into! rt dst 0)
      (task-free rt)
      (check "读回内容一致" (bytevector=? (foreign->bv dst len) msg))
      (foreign-free dst))
    (task-run-void 'close-r (submit-fs-close fd)))
  (foreign-free src)
  (task-run-void 'unlink (submit-fs-unlink path)))

;; ③ dns（task-run-str）
(let ([ip (task-run-str 'dns (submit-dns-resolve "localhost"))])
  (printf "    localhost → ~a~n" ip)
  (check "dns 回环地址" (or (string=? ip "127.0.0.1") (string=? ip "::1"))))

;; ④ 错误路径:打开不存在目录下的文件 → &io-error（负 errno）
(check "task-run 负 errno 抛 &io-error"
       (guard (e [(io-error? e)
                  (printf "    捕获 &io-error: ~a (errno ~a)~n" (io-error-name e) (io-error-errno e))
                  #t]
                 [else #f])
         (task-run 'open-bad (submit-fs-open "/nonexistent-dir-xyz/f" O_RDONLY 0))
         #f))

;; ⑤ completion queue 批量收割:N timer → 一个 cq → 收 N 次
(let ([cq (make-completion-queue)] [n 12])
  (let loop ([i 0]) (when (< i n) (submit-timer (+ 8 (* (modulo i 4) 6)) cq) (loop (+ i 1))))
  (let reap ([k 0])
    (if (= k n)
        (check "cq 收割 N 个 timer" #t)
        (let ([t (completion-queue-wait cq)]) (task-free t) (reap (+ k 1)))))
  (check "收完 cq 空" (not (completion-queue-try-pop cq)))
  (completion-queue-free cq))

;; ⑥ 泄漏
(check "无 task 泄漏(live=0)" (= 0 (io-live-tasks)))

(io-runtime-stop!)
(if (= fail 0)
    (begin (printf "~n✅ S2 gate 通过 —— io-runtime 绑定层（timer/fs/dns/err/cq）全通。~n") (exit 0))
    (begin (printf "~n❌ ~a 项失败。~n" fail) (exit 1)))
