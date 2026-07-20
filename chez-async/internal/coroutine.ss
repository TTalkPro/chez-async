;;; internal/coroutine.ss - 协程数据结构
;;;
;;; 本模块提供基于 call/cc 的协程数据类型和状态管理：
;;;
;;; 1. 协程记录类型 —— 包含 ID、状态、continuation、结果、关联事件循环
;;; 2. 当前协程 —— 线程局部参数，跟踪当前执行的协程
;;; 3. 状态查询 —— 便捷的状态判断函数
;;; 4. ID 生成 —— 线程安全的唯一 ID 生成器
;;;
;;; 协程状态流转：
;;;   created → running → suspended → running → completed
;;;                    ↘            ↗         ↘ failed
;;;
;;; 设计说明：
;;; 协程是可以暂停和恢复的执行单元，通过 call/cc 捕获 continuation 实现。
;;; 每个协程维护自己的执行状态和结果。ID 生成器使用闭包封装计数器和互斥锁。

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
    coroutine-awaiting-promise
    coroutine-awaiting-promise-set!

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
  ;;
  ;; 使用闭包封装计数器和互斥锁，避免模块级全局变量。
  ;; 生成格式为 coro-1, coro-2, ... 的唯一符号。

  (define generate-coroutine-id
    (let ([counter 0]
          [mutex (make-mutex)])
      (lambda ()
        (with-mutex mutex
          (set! counter (+ counter 1))
          (string->symbol (format "coro-~a" counter))))))

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
      (immutable loop)            ; 关联的 uv-loop
      (mutable awaiting-promise)) ; 当前等待的 Promise（用于 O(1) 反查）
    (protocol
      (lambda (new)
        (lambda (loop)
          "创建新协程
           loop: 关联的事件循环"
          (new (generate-coroutine-id) 'created #f #f loop #f)))))

  ;; ========================================
  ;; 当前协程（线程局部变量）
  ;; ========================================
  ;;
  ;; 使用 make-thread-parameter 创建线程局部参数：
  ;; - 每个线程有独立的副本（线程安全）
  ;; - 验证器确保值为 coroutine 或 #f
  ;; - 用于跟踪当前执行的协程，支持协程切换时的状态管理

  (define current-coroutine
    (make-thread-parameter #f
      (lambda (v)
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
