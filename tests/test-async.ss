#!/usr/bin/env scheme-script
;;; tests/test-async.ss - Async work 功能测试

(import (chezscheme)
        (chez-async tests framework)
        (chez-async high-level event-loop)
        (chez-async high-level async-work)
        (chez-async low-level async)
        (chez-async low-level handle-base)
        (chez-async low-level threadpool))

;; 辅助函数（必须在 tests 之前定义）
(define (string-contains str substr)
  "检查字符串是否包含子串"
  (let ([str-len (string-length str)]
        [sub-len (string-length substr)])
    (let loop ([i 0])
      (cond
        [(> (+ i sub-len) str-len) #f]
        [(string=? (substring str i (+ i sub-len)) substr) #t]
        [else (loop (+ i 1))]))))

(test-group "Async Work Tests"

  (test "async-handle-create-and-send"
    (let* ([loop (uv-loop-init)]
           [called? #f]
           [async-h (uv-async-init loop
                      (lambda (wrapper)
                        (set! called? #t)
                        (uv-handle-close! wrapper)))])
      ;; 发送异步通知
      (uv-async-send! async-h)
      ;; 运行事件循环
      (uv-run loop 'default)
      ;; 验证回调被调用
      (assert-true called? "async callback should be called")
      ;; 清理
      (uv-loop-close loop)))

  (test "simple-async-work"
    (let* ([loop (uv-loop-init)]
           [result #f])
      ;; 提交简单任务
      (async-work loop
        (lambda ()
          (+ 1 2 3))
        (lambda (value)
          (set! result value)
          (uv-stop loop)))
      ;; 运行事件循环
      (uv-run loop 'default)
      ;; 验证结果
      (assert-equal 6 result "result should be 6")
      ;; 清理：先关闭线程池，再运行一次事件循环让 async handle 完全关闭，最后关闭 loop
      (let ([pool (uv-loop-threadpool loop)])
        (when pool (threadpool-shutdown! pool)))
      (uv-run loop 'once)  ; 让 async handle 完全关闭
      (uv-loop-close loop)))

  (test "async-work-fibonacci"
    (let* ([loop (uv-loop-init)]
           [result #f])
      ;; 定义斐波那契函数
      (define (fib n)
        (if (<= n 1) n (+ (fib (- n 1)) (fib (- n 2)))))
      ;; 提交计算任务
      (async-work loop
        (lambda () (fib 10))
        (lambda (value)
          (set! result value)
          (uv-stop loop)))
      ;; 运行事件循环
      (uv-run loop 'default)
      ;; 验证结果
      (assert-equal 55 result "fib(10) should be 55")
      ;; 清理：先关闭线程池，再运行一次事件循环让 async handle 完全关闭，最后关闭 loop
      (let ([pool (uv-loop-threadpool loop)])
        (when pool (threadpool-shutdown! pool)))
      (uv-run loop 'once)  ; 让 async handle 完全关闭
      (uv-loop-close loop)))

  (test "async-work-error-handling"
    (let* ([loop (uv-loop-init)]
           [success-called? #f]
           [error-called? #f]
           [error-msg #f])
      ;; 提交会失败的任务
      (async-work/error loop
        (lambda ()
          (error 'test-task "intentional error"))
        (lambda (value)
          (set! success-called? #t))
        (lambda (err)
          (set! error-called? #t)
          (set! error-msg (if (condition? err)
                              (condition-message err)
                              "unknown error"))
          (uv-stop loop)))
      ;; 运行事件循环
      (uv-run loop 'default)
      ;; 验证错误处理
      (assert-false success-called? "success callback should not be called")
      (assert-true error-called? "error callback should be called")
      (assert-true (string-contains error-msg "intentional")
                   "error message should contain 'intentional'")
      ;; 清理：先关闭线程池，再运行一次事件循环让 async handle 完全关闭，最后关闭 loop
      (let ([pool (uv-loop-threadpool loop)])
        (when pool (threadpool-shutdown! pool)))
      (uv-run loop 'once)  ; 让 async handle 完全关闭
      (uv-loop-close loop)))

  (test "parallel-async-tasks"
    (let* ([loop (uv-loop-init)]
           [results '()]
           [expected 5])
      ;; 提交多个并行任务
      (let task-loop ([i 0])
        (when (< i expected)
          (async-work loop
            (lambda ()
              (let ([n i])
                (* n n))) ; 计算平方
            (lambda (value)
              (set! results (cons value results))
              (when (= (length results) expected)
                (uv-stop loop))))
          (task-loop (+ i 1))))
      ;; 运行事件循环
      (uv-run loop 'default)
      ;; 验证结果
      (assert-equal expected (length results)
                    "should have 5 results")
      (let ([sorted (list-sort < results)])
        (assert-equal '(0 1 4 9 16) sorted
                      "results should be squares of 0-4"))
      ;; 清理：先关闭线程池，再运行一次事件循环让 async handle 完全关闭，最后关闭 loop
      (let ([pool (uv-loop-threadpool loop)])
        (when pool (threadpool-shutdown! pool)))
      (uv-run loop 'once)  ; 让 async handle 完全关闭
      (uv-loop-close loop)))

  (test "threadpool-custom-size"
    (let* ([loop (uv-loop-init)]
           [pool (make-threadpool loop 2)]
           [result #f])
      ;; 启动线程池
      (threadpool-start! pool)
      (loop-set-threadpool! loop pool)
      ;; 提交任务
      (async-work loop
        (lambda () "custom pool")
        (lambda (value)
          (set! result value)
          (uv-stop loop)))
      ;; 运行事件循环
      (uv-run loop 'default)
      ;; 验证结果
      (assert-equal "custom pool" result
                    "should use custom threadpool")
      ;; 清理
      (threadpool-shutdown! pool)
      (uv-run loop 'once)  ; 让 async handle 完全关闭
      (uv-loop-close loop)))

  (test "async-work-with-data-passing"
    (let* ([loop (uv-loop-init)]
           [input-data '(1 2 3 4 5)]
           [output-data #f])
      ;; 提交数据处理任务
      (async-work loop
        (lambda ()
          (map (lambda (x) (* x 2)) input-data))
        (lambda (result)
          (set! output-data result)
          (uv-stop loop)))
      ;; 运行事件循环
      (uv-run loop 'default)
      ;; 验证结果
      (assert-equal '(2 4 6 8 10) output-data
                    "should double all elements")
      ;; 清理：先关闭线程池，再运行一次事件循环让 async handle 完全关闭，最后关闭 loop
      (let ([pool (uv-loop-threadpool loop)])
        (when pool (threadpool-shutdown! pool)))
      (uv-run loop 'once)  ; 让 async handle 完全关闭
      (uv-loop-close loop)))

  (test "async-work-success-handler"
    (let* ([loop (uv-loop-init)]
           [success? #f]
           [result #f])
      ;; 提交成功的任务
      (async-work/error loop
        (lambda () 42)
        (lambda (value)
          (set! success? #t)
          (set! result value)
          (uv-stop loop))
        (lambda (err)
          (set! success? #f)))
      ;; 运行事件循环
      (uv-run loop 'default)
      ;; 验证
      (assert-true success? "success handler should be called")
      (assert-equal 42 result "result should be 42")
      ;; 清理：先关闭线程池，再运行一次事件循环让 async handle 完全关闭，最后关闭 loop
      (let ([pool (uv-loop-threadpool loop)])
        (when pool (threadpool-shutdown! pool)))
      (uv-run loop 'once)  ; 让 async handle 完全关闭
      (uv-loop-close loop)))

) ; end test-group

(run-tests)
