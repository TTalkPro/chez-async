#!/usr/bin/env scheme-script
;;; tests/test-task.ss - Task / CompletionQueue 层（TASK.md R11-R12）

(import (chezscheme)
        (chez-async tests framework)
        (chez-async high-level runtime)
        (chez-async high-level task)
        (chez-async high-level cancellation)
        (chez-async high-level promise)
        (chez-async high-level async-await))

(define (sleep-on rt ms)
  (let ([loop (runtime-loop rt)])
    (make-promise loop
      (lambda (resolve reject)
        (run-after loop ms (lambda () (resolve ms)))))))

(test-group "Task / CompletionQueue Tests"

  (test "task-submit / task-await value"
    (let ([rt (make-runtime)])
      (runtime-start! rt)
      (let ([tk (task-submit! rt (lambda () (* 6 7)))])
        (assert-equal 42 (task-await tk) "task-await returns value")
        (assert-equal 'task (task-op tk) "default op label"))
      (runtime-stop! rt)))

  (test "task op label"
    (let ([rt (make-runtime)])
      (runtime-start! rt)
      (let ([tk (task-submit! rt (lambda () 1) 'op 'fs-read)])
        (task-await tk)
        (assert-equal 'fs-read (task-op tk) "custom op label preserved"))
      (runtime-stop! rt)))

  (test "task-poll three states"
    (let ([rt (make-runtime)])
      (runtime-start! rt)
      (let ([ok (task-submit! rt (lambda () 'v))]
            [bad (task-submit! rt (lambda () (error 'e "m")))])
        (task-await ok)
        (guard (e [else #t]) (task-await bad))
        (assert-equal '(done . v) (task-poll ok) "poll done")
        (assert-equal 'failed (car (task-poll bad)) "poll failed"))
      (runtime-stop! rt)))

  (test "completion queue reaps N tasks, no dup/loss"
    (let ([rt (make-runtime)])
      (runtime-start! rt)
      (let ([cq (make-completion-queue)]
            [n 20])
        ;; 提交 N 个错开完成时间的 task，全部路由到一个 cq
        (let loop ([i 0])
          (when (< i n)
            (task-submit! rt
              (lambda () (await (sleep-on rt (modulo (* i 7) 30))) (* i i))
              'cq cq)
            (loop (+ i 1))))
        ;; 用 cq-wait-one 收割 N 次，收集每个 task 的结果
        (let reap ([k 0] [seen '()])
          (if (= k n)
              (assert-equal (sort < (map (lambda (i) (* i i)) (iota n)))
                            (sort < seen)
                            "reaped exactly the N results, no dup/loss")
              (let ([tk (cq-wait-one cq)])
                (reap (+ k 1) (cons (task-await tk) seen))))))
      (runtime-stop! rt)))

  (test "task-cancel! rejects cancellable await"
    (let ([rt (make-runtime)])
      (runtime-start! rt)
      ;; task 睡较久，其 await 用 token 包装；主线程随即取消
      (let ([tk (task-submit! rt
                  (lambda ()
                    (await (async-cancellable (task-current-token)
                                              (sleep-on rt 5000)))
                    'should-not-reach))])
        ;; 给协程一点时间进入 await（提交并起协程）
        (let spin ([i 0]) (when (< i 50000) (spin (+ i 1))))
        (task-cancel! tk)
        (assert-true (task-cancelled? tk) "task marked cancelled")
        (assert-error (lambda () (task-await tk)) "cancelled await rejects"))
      (runtime-stop! rt 'drain? #f)))

  (test "cq-try-pop non-blocking"
    (let ([rt (make-runtime)])
      (runtime-start! rt)
      (let ([cq (make-completion-queue)])
        ;; 初始空
        (assert-false (cq-try-pop cq) "empty cq try-pop returns #f")
        (let ([tk (task-submit! rt (lambda () 99) 'cq cq)])
          (task-await tk)                 ; 确保完成并已 post
          ;; 完成后 try-pop 应拿到它（可能有微小调度延迟，轮询一小会）
          (let spin ([i 0] [got #f])
            (cond
              [got (assert-equal 99 (task-await got) "try-pop returned the completed task")]
              [(< i 100000) (spin (+ i 1) (cq-try-pop cq))]
              [else (assert-true #f "try-pop never returned the task")]))))
      (runtime-stop! rt)))
)

(run-tests)
