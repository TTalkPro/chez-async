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

  ;; ========================================
  ;; 当前协程（线程局部变量）
  ;; ========================================
  ;;
  ;; make-thread-parameter 是 Chez Scheme 的内置函数，用于创建线程局部参数
  ;; 这是一种特殊的动态作用域变量，具有以下特点：
  ;;
  ;; 1. 每个线程都有独立的副本（线程安全）
  ;; 2. 可以在线程内动态地设置和获取值
  ;; 3. 支持参数验证（通过传入的 lambda 函数）
  ;;
  ;; 函数签名：(make-thread-parameter initial-value [validator])
  ;;
  ;; 参数说明：
  ;;   - initial-value: 线程参数的初始值（默认值），这里设置为 #f 表示没有当前协程
  ;;   - validator: 可选的验证器/转换器函数，当设置新值时自动调用
  ;;
  ;; 工作原理：
  ;;   (current-coroutine)           ; 获取当前值
  ;;   (current-coroutine some-coro) ; 设置新值，返回新值
  ;;
  ;; 验证器逻辑：
  ;;   - 检查值是否为 #f 或 coroutine 类型
  ;;   - 非法值会触发错误
  ;;   - 验证通过后返回原值
  ;;
  ;; 在协程系统中的作用：
  ;;   - 跟踪当前执行的协程
  ;;   - 支持协程切换时的状态管理
  ;;   - 提供类型安全保证

  (define current-coroutine
    (make-thread-parameter #f
      (lambda (v)
        "验证器：检查值是否为 coroutine 或 #f"
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
