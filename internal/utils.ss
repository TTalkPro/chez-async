;;; internal/utils.ss - 通用工具函数
;;;
;;; 本模块提供减少代码重复的通用工具函数：
;;; - 列表和集合操作
;;; - 对象生命周期管理
;;; - 调试和追踪工具
;;;
;;; 内存管理函数（allocate-zeroed, safe-free）从 foreign-utils 重新导出，
;;; 以保持向后兼容性。

(library (chez-async internal utils)
  (export
    ;; 内存管理（从 foreign-utils 重新导出）
    allocate-zeroed
    safe-free

    ;; 列表和集合操作
    filter-map
    take-while
    drop-while

    ;; 对象生命周期管理
    managed-object
    with-managed-objects

    ;; 调试工具
    debug-log
    debug-enabled?
    trace-call
    )
  (import (chezscheme)
          ;; 导入内存管理函数，避免重复定义
          (only (chez-async internal foreign-utils)
                allocate-zeroed
                safe-free))

  ;; ========================================
  ;; 列表和集合操作
  ;; ========================================

  (define (filter-map proc lst)
    "过滤并映射列表"
    (let loop ([lst lst] [result '()])
      (cond
        [(null? lst) (reverse result)]
        [(proc (car lst)) => (lambda (v) (loop (cdr lst) (cons v result)))]
        [else (loop (cdr lst) result)])))

  (define (take-while pred lst)
    "取满足谓词的前缀"
    (let loop ([lst lst] [result '()])
      (cond
        [(null? lst) (reverse result)]
        [(pred (car lst)) (loop (cdr lst) (cons (car lst) result))]
        [else (reverse result)])))

  (define (drop-while pred lst)
    "丢弃满足谓词的前缀"
    (let loop ([lst lst])
      (cond
        [(null? lst) '()]
        [(pred (car lst)) (loop (cdr lst))]
        [else lst])))

  ;; ========================================
  ;; 对象管理
  ;; ========================================

  (define-record-type managed-object
    (fields
      (immutable value)
      (mutable locked?))
    (protocol
      (lambda (new)
        (lambda (value)
          (let ([obj (new value #f)])
            (lock-object value)
            (managed-object-locked?-set! obj #t)
            obj)))))

  (define (with-managed-objects objects proc)
    "使用托管对象，确保正确解锁"
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

  ;; ========================================
  ;; 调试工具
  ;; ========================================

  (define debug-enabled? (make-parameter #f))

  (define (debug-log fmt . args)
    "条件调试日志"
    (when (debug-enabled?)
      (apply fprintf (current-error-port) fmt args)
      (newline (current-error-port))))

  (define-syntax trace-call
    (syntax-rules ()
      [(trace-call name expr)
       (begin
         (debug-log "[TRACE] ~a: enter" 'name)
         (let ([result expr])
           (debug-log "[TRACE] ~a: exit -> ~s" 'name result)
           result))]))

) ; end library
