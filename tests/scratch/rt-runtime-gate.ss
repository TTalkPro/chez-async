;;; rt-runtime-gate.ss — S1 验证:vendored 的 skiff 运行时(完整 op 集)经 Chez FFI 工作。
;;; 覆盖 timer / fs 往返(open+write+read+close+stat) / dns / 泄漏计数。
;;; 运行:LD_LIBRARY_PATH=native/build scheme --script tests/scratch/rt-runtime-gate.ss

(import (chezscheme))
(load-shared-object "libchez-async-rt.so")

;; --- C ABI 绑定（rt_ 前缀）---
(define rt-start (foreign-procedure "rt_runtime_start" () void))
(define rt-stop  (foreign-procedure "rt_runtime_stop" () void))
(define rt-timer (foreign-procedure "rt_timer" (unsigned-64 uptr) uptr))
(define rt-await (foreign-procedure __collect_safe "rt_await" (uptr) integer-64))
(define rt-task-result (foreign-procedure "rt_task_result" (uptr) integer-64))
(define rt-task-free (foreign-procedure "rt_task_free" (uptr) void))
(define rt-read-into (foreign-procedure "rt_read_into" (uptr void* unsigned-32) void))
(define rt-str-result (foreign-procedure "rt_str_result" (uptr) string))
(define rt-err-name (foreign-procedure "rt_err_name" (int) string))
;; fs
(define rt-fs-open  (foreign-procedure "rt_fs_open" (string int int uptr) uptr))
(define rt-fs-read  (foreign-procedure "rt_fs_read" (int unsigned-32 integer-64 uptr) uptr))
(define rt-fs-write (foreign-procedure "rt_fs_write" (int void* unsigned-32 unsigned-32 integer-64 uptr) uptr))
(define rt-fs-close (foreign-procedure "rt_fs_close" (int uptr) uptr))
(define rt-fs-stat  (foreign-procedure "rt_fs_stat" (string uptr) uptr))
(define rt-fs-unlink (foreign-procedure "rt_fs_unlink" (string uptr) uptr))
(define rt-stat-size (foreign-procedure "rt_stat_size" (uptr) unsigned-64))
;; dns
(define rt-dns-resolve (foreign-procedure "rt_dns_resolve" (string string int uptr) uptr))
;; leak
(define rt-live-tasks (foreign-procedure "rt_debug_live_tasks" () integer-32))

;; O_* 常量（Linux x86-64）
(define O_RDONLY 0) (define O_WRONLY 1) (define O_CREAT 64) (define O_TRUNC 512)

(define fail 0)
(define (check name ok?) (printf "  ~a ~a~n" (if ok? "✓" "✗") name) (unless ok? (set! fail (+ fail 1))))

;; run: 提交→await→free→返回结果(负 errno 报错)
(define (run who task)
  (let ([r (rt-await task)])
    (rt-task-free task)
    (when (< r 0) (error who (rt-err-name r)))
    r))

(printf "S1 vendored 运行时 gate…~n")
(rt-start)

;; ① timer
(let ([r (run 'timer (rt-timer 30 0))]) (check "timer await=0" (= r 0)))

;; ② fs 往返:写文件→读回→内容一致→stat 大小
(let* ([path "/tmp/rt-gate-test.txt"]
       [msg (string->utf8 "hello from vendored skiff runtime 你好")]
       [len (bytevector-length msg)]
       [src (foreign-alloc len)])
  ;; 把 bytevector 拷进 foreign 源缓冲
  (let cp ([i 0]) (when (< i len) (foreign-set! 'unsigned-8 src i (bytevector-u8-ref msg i)) (cp (+ i 1))))
  ;; 打开写、写、关
  (let ([fd (run 'open-w (rt-fs-open path (bitwise-ior O_WRONLY O_CREAT O_TRUNC) #o644 0))])
    (check "fs-open(write) 得到 fd" (>= fd 0))
    (let ([n (run 'write (rt-fs-write fd src 0 len -1 0))])
      (check "fs-write 字节数正确" (= n len)))
    (run 'close-w (rt-fs-close fd 0)))
  ;; stat 大小
  (let* ([st (rt-fs-stat path 0)] [_ (rt-await st)] [sz (rt-stat-size st)])
    (rt-task-free st)
    (check "fs-stat 大小=写入长度" (= sz len)))
  ;; 打开读、读回、比对
  (let ([fd (run 'open-r (rt-fs-open path O_RDONLY 0 0))])
    (let* ([dst (foreign-alloc len)]
           [rt (rt-fs-read fd len -1 0)]
           [n (rt-await rt)])
      (rt-read-into rt dst 0)
      (rt-task-free rt)
      (check "fs-read 字节数正确" (= n len))
      (let ([back (make-bytevector len 0)])
        (let cp ([i 0]) (when (< i len) (bytevector-u8-set! back i (foreign-ref 'unsigned-8 dst i)) (cp (+ i 1))))
        (check "读回内容与写入一致" (bytevector=? back msg)))
      (foreign-free dst))
    (run 'close-r (rt-fs-close fd 0)))
  (foreign-free src)
  (run 'unlink (rt-fs-unlink path 0)))

;; ③ dns 解析 localhost
(let* ([task (rt-dns-resolve "localhost" "" 0 0)]
       [r (rt-await task)]
       [ip (and (>= r 0) (rt-str-result task))])
  (rt-task-free task)
  (check "dns-resolve localhost 成功" (= r 0))
  (printf "    localhost → ~a~n" ip)
  (check "dns 返回回环地址" (and ip (or (string=? ip "127.0.0.1") (string=? ip "::1")))))

;; ④ 泄漏:所有 task 已 free,存活计数应为 0
(check "无 task 泄漏(live=0)" (= 0 (rt-live-tasks)))

(rt-stop)
(if (= fail 0)
    (begin (printf "~n✅ S1 gate 通过 —— vendored skiff 运行时(timer/fs/dns)经 Chez FFI 全通。~n") (exit 0))
    (begin (printf "~n❌ ~a 项失败。~n" fail) (exit 1)))
