#!/usr/bin/env scheme-script
;;; tests/test-runtime.ss - 后台 runtime 线程 + Task 化（TASK.md R 组）

(import (chezscheme)
        (chez-async tests framework)
        (chez-async high-level runtime)
        (chez-async high-level promise)
        (chez-async high-level async-await))

;; 建在 runtime 自己 loop 上的可 await 定时器
(define (sleep-on rt ms)
  (let ([loop (runtime-loop rt)])
    (make-promise loop
      (lambda (resolve reject)
        (run-after loop ms (lambda () (resolve ms)))))))

;; 等所有工作线程结束（轮询谓词）
(define (join-until pred?)
  (let wait () (unless (pred?) (wait))))

(test-group "Runtime Thread Tests"

  (test "start/stop lifecycle"
    (let ([rt (make-runtime)])
      (runtime-start! rt)
      (assert-true (runtime-running? rt) "started runtime should be running")
      (runtime-stop! rt)
      (assert-false (runtime-running? rt) "stopped runtime not running")))

  (test "submit pure thunk, await value"
    (let ([rt (make-runtime)])
      (runtime-start! rt)
      (assert-equal 42 (runtime-await (runtime-submit! rt (lambda () (+ 40 2))))
                    "await returns thunk value")
      (runtime-stop! rt)))

  (test "main thread free while runtime runs timer"
    (let ([rt (make-runtime)])
      (runtime-start! rt)
      (let ([cell (runtime-submit! rt (lambda () (await (sleep-on rt 80)) 'done))]
            [t0 (real-time)])
        ;; 主线程立刻能算完自己的活，不被 runtime 的 80ms 定时器挡住
        (let ([s (let loop ([i 1] [acc 0]) (if (> i 1000) acc (loop (+ i 1) (+ acc i))))])
          (assert-equal 500500 s "main computed independently")
          (assert-true (< (- (real-time) t0) 60) "main not blocked by runtime timer"))
        (assert-equal 'done (runtime-await cell) "runtime task completed")
        (assert-true (>= (- (real-time) t0) 75) "timer really took ~80ms"))
      (runtime-stop! rt)))

  (test "await propagates exception across threads"
    (let ([rt (make-runtime)])
      (runtime-start! rt)
      (let ([cell (runtime-submit! rt (lambda () (error 'task "boom" 7)))])
        (assert-error (lambda () (runtime-await cell)) "await re-raises task error"))
      (runtime-stop! rt)))

  (test "poll three states"
    (let ([rt (make-runtime)])
      (runtime-start! rt)
      (let ([ok (runtime-submit! rt (lambda () 'v))]
            [bad (runtime-submit! rt (lambda () (error 'x "y")))])
        (runtime-await ok)
        (guard (e [else #t]) (runtime-await bad))
        (assert-equal '(done . v) (runtime-poll ok) "poll done state")
        (assert-equal 'failed (car (runtime-poll bad)) "poll failed state"))
      (runtime-stop! rt)))

  (test "await chained I/O (sync-style on background thread)"
    (let ([rt (make-runtime)])
      (runtime-start! rt)
      (let ([cell (runtime-submit! rt
                    (lambda ()
                      (let ([a (await (sleep-on rt 40))]
                            [b (await (sleep-on rt 30))])
                        (+ a b))))])
        (assert-equal 70 (runtime-await cell) "two serial awaits sum"))
      (runtime-stop! rt)))

  (test "concurrent submit from 4 threads"
    (let ([rt (make-runtime)])
      (runtime-start! rt)
      (let ([results (make-vector 4 #f)])
        (for-each
          (lambda (i)
            (fork-thread
              (lambda ()
                (let loop ([j 0] [sum 0])
                  (if (= j 50)
                      (vector-set! results i sum)
                      (loop (+ j 1)
                            (+ sum (runtime-await
                                     (runtime-submit! rt (lambda () (* i j)))))))))))
          '(0 1 2 3))
        (join-until (lambda () (let a ([k 0]) (or (= k 4) (and (vector-ref results k) (a (+ k 1)))))))
        (assert-equal '(0 1225 2450 3675) (vector->list results)
                      "each thread's 50 tasks summed correctly"))
      (runtime-stop! rt)))

  (test "shutdown drain: queued tasks complete"
    (let ([rt (make-runtime)])
      (runtime-start! rt)
      ;; 快速塞入多个短任务，随即 drain 停机——全部应成功完成
      (let ([cells (map (lambda (i) (runtime-submit! rt (lambda () (* i i))))
                        '(1 2 3 4 5))])
        (runtime-stop! rt)                 ; 默认 drain? #t
        (assert-equal '(1 4 9 16 25) (map runtime-await cells)
                      "all queued tasks drained to completion"))))

  (test "shutdown non-drain: every cell settled (none left pending)"
    (let ([rt (make-runtime)])
      (runtime-start! rt)
      (let ([cells (map (lambda (i) (runtime-submit! rt (lambda () i))) '(1 2 3 4 5))])
        (runtime-stop! rt 'drain? #f)
        ;; 不管成功还是 &runtime-stopped，绝不能有 cell 永远 pending
        (for-each
          (lambda (c)
            (assert-false (eq? 'pending (runtime-poll c))
                          "no cell left pending after non-drain stop")
            (guard (e [else #t]) (runtime-await c)))
          cells))))

  (test "submit after stop is rejected"
    (let ([rt (make-runtime)])
      (runtime-start! rt)
      (runtime-stop! rt)
      (assert-error (lambda () (runtime-submit! rt (lambda () 1)))
                    "submit after stop raises")))

  (test "no handle leak: loop closes cleanly after stop"
    ;; runtime-stop! 内部若 uv-loop-close 因残留句柄失败会打印警告；
    ;; 这里跑一次完整生命周期 + I/O，确认停机后可再启一个新 runtime（loop 未泄漏卡住）
    (let ([rt (make-runtime)])
      (runtime-start! rt)
      (runtime-await (runtime-submit! rt (lambda () (await (sleep-on rt 20)) 'ok)))
      (runtime-stop! rt)
      (let ([rt2 (make-runtime)])
        (runtime-start! rt2)
        (assert-equal 'ok2 (runtime-await (runtime-submit! rt2 (lambda () 'ok2)))
                      "second runtime works after first stopped")
        (runtime-stop! rt2))))
)

(run-tests)
