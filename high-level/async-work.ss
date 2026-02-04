;;; high-level/async-work.ss - 异步任务 API
;;;
;;; 提供用户友好的后台任务接口
;;;
;;; 线程池存储在 uv-loop 记录中（per-loop），避免全局变量

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
          (chez-async high-level event-loop)
          (chez-async low-level threadpool))

  ;; ========================================
  ;; 线程池配置
  ;; ========================================

  (define *default-threadpool-size* 4)

  ;; ========================================
  ;; 每个 loop 关联一个线程池（Per-loop）
  ;; ========================================
  ;;
  ;; 线程池存储在 uv-loop 记录的 threadpool 字段中
  ;; 懒初始化：首次访问时创建

  (define (loop-threadpool loop)
    "获取或创建 loop 的线程池（默认 4 个工作线程）"
    (or (uv-loop-threadpool loop)
        (let ([pool (make-threadpool loop *default-threadpool-size*)])
          (threadpool-start! pool)
          (uv-loop-threadpool-set! loop pool)
          pool)))

  (define (loop-set-threadpool! loop pool)
    "设置 loop 的线程池"
    (uv-loop-threadpool-set! loop pool))

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
