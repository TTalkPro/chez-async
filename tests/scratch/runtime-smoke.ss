;;; runtime-smoke.ss — R5/R6/R7 冒烟：runtime 线程 + 提交/await/poll/停机
(import (chezscheme)
        (chez-async high-level runtime))

(define (check name ok?) (printf "  ~a ~a~n" (if ok? "✓" "✗") name) (unless ok? (exit 1)))

(printf "runtime 冒烟测试…~n")
(define rt (make-runtime))
(runtime-start! rt)
(check "启动后 running?" (runtime-running? rt))

;; 1. 纯计算提交 + await
(let ([cell (runtime-submit! rt (lambda () (+ 40 2)))])
  (check "await 返回 42" (= 42 (runtime-await cell))))

;; 2. 主线程在此期间自由（runtime 在别的线程）
(check "主线程自由计算" (= 500500 (let loop ([i 1] [s 0]) (if (> i 1000) s (loop (+ i 1) (+ s i))))))

;; 3. 抛异常的提交 → await re-raise
(let ([cell (runtime-submit! rt (lambda () (error 'task "boom" 7)))])
  (check "await re-raise 原异常"
         (guard (e [(error? e) #t] [else #f]) (runtime-await cell) #f)))

;; 4. poll 三态
(let ([cell (runtime-submit! rt (lambda () 'ok))])
  (runtime-await cell)
  (check "poll done" (equal? (runtime-poll cell) '(done . ok))))
(let ([cell (runtime-submit! rt (lambda () (error 'x "y")))])
  (guard (e [else #t]) (runtime-await cell))   ; 失败项 await 会 re-raise，吞掉
  (check "poll failed" (eq? 'failed (car (runtime-poll cell)))))

;; 5. 多线程并发提交
(define results (make-vector 4 #f))
(define threads
  (let loop ([i 0] [acc '()])
    (if (= i 4)
        acc
        (loop (+ i 1)
              (cons (fork-thread
                      (lambda ()
                        (let ([sum 0])
                          (let inner ([j 0])
                            (when (< j 50)
                              (set! sum (+ sum (runtime-await
                                                 (runtime-submit! rt (lambda () (* i j))))))
                              (inner (+ j 1))))
                          (vector-set! results i sum))))
                    acc)))))
;; 简单等待所有工作线程结束：轮询 results 全非 #f
(let wait ()
  (unless (let check-all ([k 0]) (or (= k 4) (and (vector-ref results k) (check-all (+ k 1)))))
    (wait)))
;; 每个线程 sum = i*(0+1+...+49) = i*1225
(check "并发提交结果正确"
       (equal? (vector->list results) (list 0 1225 2450 3675)))

;; 6. 停机（drain 默认）
(runtime-stop! rt)
(check "停机后 state=stopped" (not (runtime-running? rt)))

;; 7. 停机后提交被拒
(check "停机后提交抛 &runtime-stopped"
       (guard (e [(runtime-stopped-error? e) #t] [else #f])
         (runtime-submit! rt (lambda () 1)) #f))

(printf "~n所有冒烟检查通过。~n")
(exit 0)
