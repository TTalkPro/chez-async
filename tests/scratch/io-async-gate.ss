;;; io-async-gate.ss — S4/S5 验证:io-async 协程调度器（移植 skiff async）。
;;; run-async/async/await/await-all，阻塞写法的 io-* 在 async 内自动挂起、并发交错。
;;; 运行:
;;;   LD_LIBRARY_PATH=native/ta6le scheme --libdirs .:.. --program tests/scratch/io-async-gate.ss

(import (chezscheme)
        (chez-async internal io-runtime)
        (chez-async high-level io-fs)
        (chez-async high-level io-async))

(define fail 0)
(define (check name ok?) (printf "  ~a ~a~n" (if ok? "✓" "✗") name) (unless ok? (set! fail (+ fail 1))))

(printf "S5 io-async（skiff async 港）gate…~n")
(io-runtime-start!)

;; ① 基本:根协程串行 await + 返回值
(check "run-async 返回根值" (= 42 (run-async (lambda () (io-sleep 20) 42))))

;; ② in-async? 谓词
(check "async 内 in-async? = #t" (run-async (lambda () (in-async?))))
(check "async 外 in-async? = #f" (not (in-async?)))

;; ③ 并发:两个 future 各 sleep 100ms，await-all 并行 ≈100ms（串行则 200ms）
(let ([t0 (real-time)])
  (let ([vals (run-async
                (lambda ()
                  (let ([f1 (async (lambda () (io-sleep 100) 'a))]
                        [f2 (async (lambda () (io-sleep 100) 'b))])
                    (await-all (list f1 f2)))))])
    (let ([elapsed (- (real-time) t0)])
      (printf "    await-all 两个并发 100ms sleep 用时 ~ams，结果 ~s~n" elapsed vals)
      (check "await-all 结果正确" (equal? vals '(a b)))
      (check "并发 ≈100ms（非串行 200ms）" (< elapsed 160)))))

;; ④ future 嵌套:一个 future await 另一个
(check "future 嵌套 await"
       (= 30 (run-async
               (lambda ()
                 (let ([inner (async (lambda () (io-sleep 20) 30))])
                   (await inner))))))

;; ⑤ await 裸 task 句柄（submit-timer 返回句柄）——裸 await 需手动 free
(check "await 裸 task 句柄"
       (= 0 (run-async
              (lambda ()
                (let ([t (submit-timer 20 (current-cq))])
                  (let ([r (await t)]) (task-free t) r))))))

;; ⑥ fs 在协程内
(check "协程内 fs 往返"
       (run-async
         (lambda ()
           (let ([path "/tmp/io-async-gate.txt"] [msg (string->utf8 "async fs 你好")])
             (io-write-file path msg)
             (let ([back (io-read-file path)]) (io-unlink path) (bytevector=? back msg))))))

;; ⑦ 异常传播:根协程抛异常 → run-async 重抛
(check "根协程异常传播"
       (guard (e [(io-error? e) #t] [else #f])
         (run-async (lambda () (io-open "/nope/x" 0 0) 'unreached)) #f))

;; ⑧ 子 future 异常经 await 传播
(check "子 future 异常经 await 传播"
       (run-async
         (lambda ()
           (let ([f (async (lambda () (error 'child "boom")))])
             (guard (e [else #t]) (await f) #f)))))

;; ⑨ 大量并发 future
(check "50 并发 future await-all 求和"
       (= 1225 (run-async
                 (lambda ()
                   (let ([fs (let loop ([i 0] [acc '()])
                               (if (= i 50) (reverse acc)
                                   (loop (+ i 1)
                                         (cons (async (let ([i i]) (lambda () (io-sleep (+ 5 (modulo i 7))) i))) acc))))])
                     (apply + (await-all fs)))))))

;; ⑩ 泄漏
(check "无 task 泄漏" (= 0 (io-live-tasks)))
(check "无 cq 泄漏" (= 0 (io-live-cqs)))

(io-runtime-stop!)
(if (= fail 0)
    (begin (printf "~n✅ S5 io-async gate 通过。~n") (exit 0))
    (begin (printf "~n❌ ~a 项失败。~n" fail) (exit 1)))
