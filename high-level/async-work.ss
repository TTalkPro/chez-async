;;; high-level/async-work.ss - 异步任务 API
;;;
;;; 提供用户友好的后台任务接口

(library (chez-async high-level async-work)
  (export
    ;; 线程池管理
    loop-threadpool
    loop-set-threadpool!

    ;; 异步任务提交
    async-work
    async-work/error
    )
  (import (chezscheme)
          (chez-async low-level threadpool))

  ;; ========================================
  ;; 每个 loop 关联一个线程池
  ;; ========================================

  (define *loop-threadpools* (make-eq-hashtable))
  (define *default-threadpool-size* 4)

  (define (loop-threadpool loop)
    "获取或创建 loop 的线程池（默认 4 个工作线程）"
    (or (hashtable-ref *loop-threadpools* loop #f)
        (let ([pool (make-threadpool loop *default-threadpool-size*)])
          (threadpool-start! pool)
          (hashtable-set! *loop-threadpools* loop pool)
          pool)))

  (define (loop-set-threadpool! loop pool)
    "设置 loop 的线程池"
    (hashtable-set! *loop-threadpools* loop pool))

  ;; ========================================
  ;; 异步任务 API
  ;; ========================================

  (define (async-work loop work callback)
    "提交后台任务
     loop: uv-loop wrapper
     work: (lambda () ...) - 在工作线程执行
     callback: (lambda (result) ...) - 在主线程执行
     返回: task-id"
    (threadpool-submit! (loop-threadpool loop) work callback #f))

  (define (async-work/error loop work callback error-handler)
    "提交后台任务（带错误处理）
     loop: uv-loop wrapper
     work: (lambda () ...) - 在工作线程执行
     callback: (lambda (result) ...) - 成功时在主线程执行
     error-handler: (lambda (error) ...) - 失败时在主线程执行
     返回: task-id"
    (threadpool-submit! (loop-threadpool loop) work callback error-handler))

) ; end library
