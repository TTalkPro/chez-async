;;; io-async-gate.ss — S4 验证:io-async 协程调度器（cq 驱动）。
;;; 阻塞写法的 io-* 在 async 块里自动变协程挂起、并发交错。
;;; 运行:
;;;   LD_LIBRARY_PATH=native/ta6le scheme --libdirs .:.. --program tests/scratch/io-async-gate.ss

(import (chezscheme)
        (chez-async internal io-runtime)
        (chez-async high-level io-fs)
        (chez-async high-level io-async))

(define fail 0)
(define (check name ok?) (printf "  ~a ~a~n" (if ok? "✓" "✗") name) (unless ok? (set! fail (+ fail 1))))

(printf "S4 io-async 协程调度器 gate…~n")
(io-runtime-start!)

;; ① 基本:协程内串行 await + 返回值
(check "io-run-async 返回根协程值"
       (= 42 (io-run-async (lambda () (io-sleep 20) 42))))

;; ② in-io-async? 上下文谓词
(check "async 内 in-io-async? = #t" (io-run-async (lambda () (in-io-async?))))
(check "async 外 in-io-async? = #f" (not (in-io-async?)))

;; ③ 并发:两个协程各 sleep 100ms，并行应 ≈100ms（串行则 ≈200ms）
(let ([t0 (real-time)])
  (io-run-async
    (lambda ()
      (let ([done (make-vector 2 #f)])
        (io-spawn-async (lambda () (io-sleep 100) (vector-set! done 0 #t)))
        (io-spawn-async (lambda () (io-sleep 100) (vector-set! done 1 #t)))
        (let wait () (unless (and (vector-ref done 0) (vector-ref done 1))
                       (io-sleep 5) (wait)))
        'both-done)))
  (let ([elapsed (- (real-time) t0)])
    (printf "    两个并发 100ms sleep 用时 ~ams~n" elapsed)
    (check "并发 sleep ≈100ms（非串行 200ms）" (< elapsed 160))))

;; ④ fs 在协程内（每个 fs 操作都挂起）
(check "协程内 fs 往返"
       (io-run-async
         (lambda ()
           (let ([path "/tmp/io-async-gate.txt"]
                 [msg (string->utf8 "async 协程内文件 你好")])
             (io-write-file path msg)
             (let ([back (io-read-file path)])
               (io-unlink path)
               (bytevector=? back msg))))))

;; ⑤ 异常传播:根协程抛异常 → io-run-async 重抛
(check "根协程异常传播"
       (guard (e [(io-error? e) #t] [else #f])
         (io-run-async (lambda () (io-open "/nope/x" 0 0) 'unreached))
         #f))

;; ⑥ 多协程并发计数:10 个协程各 sleep 一点后 +1
(check "10 并发协程结果汇总"
       (= 10 (io-run-async
               (lambda ()
                 (let ([n 10] [done (make-vector 10 #f)])
                   (let spawn ([i 0])
                     (when (< i n)
                       (io-spawn-async
                         (let ([i i]) (lambda () (io-sleep (+ 10 (* i 3))) (vector-set! done i #t))))
                       (spawn (+ i 1))))
                   (let wait ()
                     (unless (let all ([k 0]) (or (= k n) (and (vector-ref done k) (all (+ k 1)))))
                       (io-sleep 5) (wait)))
                   n)))))

;; ⑦ 泄漏
(check "无 task 泄漏(live=0)" (= 0 (io-live-tasks)))
(check "无 cq 泄漏(live=0)" (= 0 (io-live-cqs)))

(io-runtime-stop!)
(if (= fail 0)
    (begin (printf "~n✅ S4 gate 通过 —— io-async 协程调度器（并发/fs/异常）全通。~n") (exit 0))
    (begin (printf "~n❌ ~a 项失败。~n" fail) (exit 1)))
