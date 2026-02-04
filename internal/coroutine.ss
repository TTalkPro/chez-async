;;; internal/coroutine.ss - 协程数据结构
;;;
;;; 提供基于 call/cc 的协程支持
;;;
;;; 协程是可以暂停和恢复的执行单元，通过 call/cc 捕获 continuation 实现。
;;; 每个协程维护自己的执行状态和结果。

(library (chez-async internal coroutine)
  (export
    ;; 协程类型
    make-coroutine
    coroutine?
    coroutine-id
    coroutine-state
    coroutine-state-set!
    coroutine-continuation
    coroutine-continuation-set!
    coroutine-result
    coroutine-result-set!
    coroutine-loop

    ;; 当前协程（线程局部变量）
    current-coroutine

    ;; 状态查询
    coroutine-created?
    coroutine-running?
    coroutine-suspended?
    coroutine-completed?
    coroutine-failed?

    ;; 工具函数
    generate-coroutine-id)

  (import (chezscheme))

  ;; ========================================
  ;; 协程 ID 生成器
  ;; ========================================

  (define coroutine-counter 0)
  (define coroutine-counter-mutex (make-mutex))

  (define (generate-coroutine-id)
    "生成唯一的协程 ID"
    (with-mutex coroutine-counter-mutex
      (set! coroutine-counter (+ coroutine-counter 1))
      (string->symbol (format "coro-~a" coroutine-counter))))

  ;; ========================================
  ;; 协程记录类型
  ;; ========================================
  ;;
  ;; 协程状态：
  ;; - 'created:    已创建，尚未运行
  ;; - 'running:    正在运行
  ;; - 'suspended:  已暂停，等待事件
  ;; - 'completed:  成功完成
  ;; - 'failed:     执行失败

  (define-record-type coroutine
    (fields
      (immutable id)               ; 唯一标识符 (symbol)
      (mutable state)             ; 协程状态
      (mutable continuation)      ; call/cc 捕获的 continuation
      (mutable result)            ; 执行结果或错误
      (immutable loop))           ; 关联的 uv-loop
    (protocol
      (lambda (new)
        (lambda (loop)
          "创建新协程
           loop: 关联的事件循环"
          (new (generate-coroutine-id) 'created #f #f loop)))))

  ;; ========================================
  ;; 当前协程（线程局部变量）
  ;; ========================================

  (define current-coroutine
    (make-thread-parameter #f
      (lambda (v)
        "设置/获取当前协程"
        (unless (or (not v) (coroutine? v))
          (error 'current-coroutine "Value must be a coroutine or #f" v))
        v)))

  ;; ========================================
  ;; 状态查询辅助函数
  ;; ========================================

  (define (coroutine-created? coro)
    "检查协程是否处于已创建状态"
    (eq? (coroutine-state coro) 'created))

  (define (coroutine-running? coro)
    "检查协程是否正在运行"
    (eq? (coroutine-state coro) 'running))

  (define (coroutine-suspended? coro)
    "检查协程是否已暂停"
    (eq? (coroutine-state coro) 'suspended))

  (define (coroutine-completed? coro)
    "检查协程是否成功完成"
    (eq? (coroutine-state coro) 'completed))

  (define (coroutine-failed? coro)
    "检查协程是否失败"
    (eq? (coroutine-state coro) 'failed))

) ; end library
