;;; runtime-await-io.ss — 验证在 runtime 提交里同步写法 await 真实 I/O
;;; 关键：I/O（timer promise）建在 runtime 自己的 loop 上（runtime-loop rt）。
(import (chezscheme)
        (chez-async high-level runtime)
        (chez-async high-level promise)      ; make-promise, run-after
        (chez-async high-level async-await)) ; await

(define (check name ok?) (printf "  ~a ~a~n" (if ok? "✓" "✗") name) (unless ok? (exit 1)))

(printf "runtime await-I/O 测试…~n")
(define rt (make-runtime))
(runtime-start! rt)

;; 提交一个「同步写法」的协程：睡 50ms 再睡 30ms，累计返回
;; awaitable 建在 runtime 的 loop 上
(define (sleep-on-runtime ms)
  (let ([loop (runtime-loop rt)])
    (make-promise loop
      (lambda (resolve reject)
        (run-after loop ms (lambda () (resolve ms)))))))

(define t0 (real-time))
(define cell
  (runtime-submit! rt
    (lambda ()
      (let ([a (await (sleep-on-runtime 50))]
            [b (await (sleep-on-runtime 30))])
        (+ a b)))))

;; 主线程此刻自由——它没有在跑事件循环
(check "await 前主线程不阻塞（立即到这）" (< (- (real-time) t0) 40))

;; 现在阻塞等结果
(check "两段 await 串行完成，返回 80" (= 80 (runtime-await cell)))
(let ([elapsed (- (real-time) t0)])
  (printf "  实际耗时 ~ams（期望 ≥80ms，两段串行）~n" elapsed)
  (check "耗时符合串行 sleep" (>= elapsed 75)))

;; 再来一发：await 中抛异常应传播回 await 方
(define cell2
  (runtime-submit! rt
    (lambda ()
      (await (sleep-on-runtime 10))
      (error 'io-task "failed after await" 99))))
(check "await 后抛异常传回主线程"
       (guard (e [(error? e) #t] [else #f]) (runtime-await cell2) #f))

(runtime-stop! rt)
(check "停机干净" (not (runtime-running? rt)))
(printf "~nawait-I/O 测试通过 —— 后台线程上的同步写法异步 I/O 成立。~n")
(exit 0)
