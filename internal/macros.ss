;;; internal/macros.ss - 通用宏定义
;;;
;;; 提供减少代码重复的宏工具

(library (chez-async internal macros)
  (export
    ;; FFI 绑定宏
    define-ffi
    define-ffi-size

    ;; 错误处理宏
    with-uv-check
    with-uv-check/cleanup

    ;; 资源管理宏
    with-locked
    with-locked*
    with-resource

    ;; 回调宏
    define-c-callback

    ;; 句柄工厂宏
    define-handle-init
    )
  (import (chezscheme)
          (chez-async ffi errors))

  ;; ========================================
  ;; FFI 绑定宏
  ;; ========================================

  (define-syntax define-ffi
    (syntax-rules ()
      [(define-ffi name c-name arg-types return-type)
       (define name
         (foreign-procedure c-name arg-types return-type))]
      [(define-ffi name c-name arg-types return-type doc)
       (begin
         (define name
           (foreign-procedure c-name arg-types return-type))
         (void))]))  ; doc可以用于生成文档

  (define-syntax define-ffi-size
    (syntax-rules ()
      [(define-ffi-size name c-name)
       (define (name)
         ((foreign-procedure c-name () size_t)))]))

  ;; ========================================
  ;; 错误处理宏
  ;; ========================================

  (define-syntax with-uv-check
    (syntax-rules ()
      [(with-uv-check who expr)
       (check-uv-result expr 'who)]))

  (define-syntax with-uv-check/cleanup
    (syntax-rules ()
      [(with-uv-check/cleanup who expr cleanup)
       (check-uv-result/cleanup expr 'who cleanup)]))

  ;; ========================================
  ;; 资源管理宏
  ;; ========================================

  (define-syntax with-locked
    (syntax-rules ()
      [(with-locked obj body ...)
       (dynamic-wind
         (lambda () (lock-object obj))
         (lambda () body ...)
         (lambda () (unlock-object obj)))]))

  (define-syntax with-locked*
    (syntax-rules ()
      [(with-locked* (obj ...) body ...)
       (dynamic-wind
         (lambda () (begin (lock-object obj) ...))
         (lambda () body ...)
         (lambda () (begin (unlock-object obj) ...)))]))

  (define-syntax with-resource
    (syntax-rules ()
      [(with-resource (var init-expr) body ... cleanup-expr)
       (let ([var init-expr])
         (guard (e [else (begin cleanup-expr (raise e))])
           (let ([result (begin body ...)])
             cleanup-expr
             result)))]))

  ;; ========================================
  ;; 回调宏
  ;; ========================================

  (define-syntax define-c-callback
    (syntax-rules ()
      [(define-c-callback name signature scheme-proc)
       (define name
         (foreign-callable scheme-proc signature void))]))

  ;; ========================================
  ;; 句柄工厂宏
  ;; ========================================

  (define-syntax define-handle-init
    (syntax-rules ()
      [(define-handle-init name handle-type size-fn init-fn)
       (define (name loop . args)
         "创建并初始化句柄"
         (let* ([size (size-fn)]
                [ptr (foreign-alloc size)])
           ;; 初始化内存为 0
           (let loop-zero ([i 0])
             (when (< i size)
               (foreign-set! 'unsigned-8 ptr i 0)
               (loop-zero (+ i 1))))
           ;; 初始化句柄
           (with-resource (ptr ptr)
             (with-uv-check name
               (apply init-fn (cons (uv-loop-ptr loop) (cons ptr args))))
             (make-uv-handle-wrapper ptr 'handle-type loop)
             (foreign-free ptr))))]))

) ; end library
