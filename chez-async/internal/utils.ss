;;; internal/utils.ss - 通用工具函数
;;;
;;; 本模块提供与外部接口无关的通用 Scheme 工具：
;;;
;;; 1. 列表操作 —— 标准库中缺少的常用高阶函数
;;;    - filter-map: 过滤并映射（合并 filter + map）
;;;    - take-while: 取满足谓词的前缀
;;;    - drop-while: 丢弃满足谓词的前缀
;;;
;;; 2. 对象生命周期管理 —— GC 锁定/解锁的 RAII 封装
;;;    - managed-object: 自动锁定的对象包装器
;;;    - with-managed-objects: 确保异常时正确解锁
;;;
;;; 设计说明：
;;; 内存分配工具（allocate-zeroed, safe-free）已移至 internal/foreign.ss。
;;; 调试工具（debug-log, debug-enabled?, trace-call）已移至 internal/debug.ss。
;;; 消费者应直接从对应模块导入。

(library (chez-async internal utils)
  (export
    ;; 列表操作
    filter-map                ; (proc lst) → list
    take-while                ; (pred lst) → list
    drop-while                ; (pred lst) → list

    ;; 对象生命周期管理
    managed-object            ; record type
    with-managed-objects      ; (objects proc) → result
    )
  (import (chezscheme))

  ;; ========================================
  ;; 列表操作
  ;; ========================================

  ;; filter-map: 过滤并映射列表
  ;;
  ;; 参数：
  ;;   proc - 单参数函数，返回非 #f 值表示保留，#f 表示过滤
  ;;   lst  - 输入列表
  ;;
  ;; 返回：
  ;;   proc 返回非 #f 值的结果列表（保持原序）
  ;;
  ;; 示例：
  ;;   (filter-map (lambda (x) (and (> x 2) (* x 10))) '(1 2 3 4))
  ;;   → '(30 40)
  (define (filter-map proc lst)
    (let loop ([lst lst] [result '()])
      (cond
        [(null? lst) (reverse result)]
        [(proc (car lst)) => (lambda (v) (loop (cdr lst) (cons v result)))]
        [else (loop (cdr lst) result)])))

  ;; take-while: 取满足谓词的前缀
  ;;
  ;; 参数：
  ;;   pred - 谓词函数
  ;;   lst  - 输入列表
  ;;
  ;; 返回：
  ;;   列表的最长前缀，其中所有元素满足 pred
  (define (take-while pred lst)
    (let loop ([lst lst] [result '()])
      (cond
        [(null? lst) (reverse result)]
        [(pred (car lst)) (loop (cdr lst) (cons (car lst) result))]
        [else (reverse result)])))

  ;; drop-while: 丢弃满足谓词的前缀
  ;;
  ;; 参数：
  ;;   pred - 谓词函数
  ;;   lst  - 输入列表
  ;;
  ;; 返回：
  ;;   从第一个不满足 pred 的元素开始的子列表
  (define (drop-while pred lst)
    (let loop ([lst lst])
      (cond
        [(null? lst) '()]
        [(pred (car lst)) (loop (cdr lst))]
        [else lst])))

  ;; ========================================
  ;; 对象生命周期管理
  ;; ========================================
  ;;
  ;; 当 Scheme 对象被 C 代码引用时，需要 lock-object 防止 GC 回收。
  ;; managed-object 和 with-managed-objects 提供自动化的锁定/解锁管理。

  ;; managed-object: 自动锁定的对象包装器
  ;;
  ;; 创建时自动调用 lock-object，通过 with-managed-objects 使用时
  ;; 自动在退出（含异常）时调用 unlock-object。
  (define-record-type managed-object
    (fields
      (immutable value)       ; 被管理的 Scheme 对象
      (mutable locked?))      ; 是否已锁定
    (protocol
      (lambda (new)
        (lambda (value)
          (let ([obj (new value #f)])
            (lock-object value)
            (managed-object-locked?-set! obj #t)
            obj)))))

  ;; with-managed-objects: 使用托管对象，确保异常时正确解锁
  ;;
  ;; 参数：
  ;;   objects - managed-object 列表
  ;;   proc    - 接受 objects 列表的函数
  ;;
  ;; 返回：
  ;;   proc 的返回值
  ;;
  ;; 说明：
  ;;   无论 proc 正常返回还是抛出异常，都会解锁所有托管对象。
  (define (with-managed-objects objects proc)
    (guard (e [else
               (for-each
                 (lambda (obj)
                   (when (managed-object-locked? obj)
                     (unlock-object (managed-object-value obj))
                     (managed-object-locked?-set! obj #f)))
                 objects)
               (raise e)])
      (let ([result (proc objects)])
        (for-each
          (lambda (obj)
            (when (managed-object-locked? obj)
              (unlock-object (managed-object-value obj))
              (managed-object-locked?-set! obj #f)))
          objects)
        result)))

) ; end library
