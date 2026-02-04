;;; internal/macro-enhancements.ss - Additional macro utilities
;;;
;;; Provides enhanced macros for common patterns not covered in macros.ss

(library (chez-async internal macro-enhancements)
  (export
    ;; Error handling
    with-error-check

    ;; Handle validation
    with-open-handle
    ensure-handle-open

    ;; Resource management
    with-managed-resource
    with-locked-objects

    ;; Callback patterns
    define-simple-callback
    define-status-callback)

  (import (chezscheme)
          (chez-async ffi errors)
          (chez-async low-level handle-base))

  ;; ========================================
  ;; Error Handling Macros
  ;; ========================================

  (define-syntax with-error-check
    (syntax-rules ()
      [(with-error-check op-name status-expr body ...)
       (let ([status status-expr])
         (if (< status 0)
             (raise (make-uv-error status op-name))
             (begin body ...)))]))

  ;; ========================================
  ;; Handle Validation Macros
  ;; ========================================

  (define-syntax with-open-handle
    (syntax-rules ()
      [(with-open-handle op-name handle body ...)
       (begin
         (when (handle-closed? handle)
           (error 'op-name "operation on closed handle" handle))
         body ...)]))

  (define-syntax ensure-handle-open
    (syntax-rules ()
      [(ensure-handle-open handle)
       (when (handle-closed? handle)
         (error 'ensure-handle-open "handle is closed" handle))]))

  ;; ========================================
  ;; Resource Management Macros
  ;; ========================================

  (define-syntax with-managed-resource
    (syntax-rules ()
      [(with-managed-resource (var alloc-expr) cleanup-expr body ...)
       (let ([var alloc-expr])
         (guard (ex
                 [else
                  cleanup-expr
                  (raise ex)])
           (let ([result (begin body ...)])
             cleanup-expr
             result)))]))

  (define-syntax with-locked-objects
    (syntax-rules ()
      [(with-locked-objects (obj ...) body ...)
       (begin
         (lock-object obj) ...
         (guard (ex
                 [else
                  (unlock-object obj) ...
                  (raise ex)])
           (let ([result (begin body ...)])
             (unlock-object obj) ...
             result)))]))

  ;; ========================================
  ;; Callback Pattern Macros
  ;; ========================================

  (define-syntax define-simple-callback
    (syntax-rules ()
      [(define-simple-callback callback-name (param ...) body ...)
       (define callback-name
         (lambda (param ...)
           (guard (ex
                   [else
                    (format #t "[Callback Error] ~a: ~a~%"
                            'callback-name ex)])
             body ...)))]))

  (define-syntax define-status-callback
    (syntax-rules ()
      [(define-status-callback callback-name (wrapper-param status-param . other-params)
         success-body ...
         error-body ...)
       (define callback-name
         (lambda (wrapper-param status-param . other-params)
           (let ([user-callback (handle-data wrapper-param)])
             (when user-callback
               (if (< status-param 0)
                   (begin error-body ... (user-callback wrapper-param (make-uv-error status-param)))
                   (begin success-body ... (user-callback wrapper-param #f . other-params)))))))]))

) ; end library
