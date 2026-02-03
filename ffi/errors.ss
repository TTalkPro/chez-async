;;; ffi/errors.ss - 错误处理和条件类型
;;;
;;; 定义 libuv 错误处理机制

(library (chez-async ffi errors)
  (export
    ;; 条件类型
    &uv-error make-uv-error uv-error?
    uv-error-code uv-error-name uv-error-operation

    ;; 错误处理函数
    raise-uv-error
    check-uv-result
    check-uv-result/cleanup

    ;; FFI 函数
    %ffi-uv-err-name
    %ffi-uv-strerror

    ;; 常见错误码
    UV_E2BIG UV_EACCES UV_EADDRINUSE UV_EADDRNOTAVAIL
    UV_EAFNOSUPPORT UV_EAGAIN UV_EAI_ADDRFAMILY UV_EAI_AGAIN
    UV_ECONNREFUSED UV_EEXIST UV_EINVAL UV_ENOENT UV_ENOMEM
    UV_ENOTDIR UV_EPIPE UV_ETIMEDOUT UV_EOF
    )
  (import (chezscheme))

  ;; ========================================
  ;; FFI 绑定
  ;; ========================================

  (define libuv-lib
    (load-shared-object "libuv.so.1"))

  (define %ffi-uv-err-name
    (foreign-procedure "uv_err_name" (int) string))

  (define %ffi-uv-strerror
    (foreign-procedure "uv_strerror" (int) string))

  ;; ========================================
  ;; 错误条件类型
  ;; ========================================

  (define-condition-type &uv-error &error
    make-uv-error uv-error?
    (code uv-error-code)          ; libuv 错误码（负数）
    (name uv-error-name)          ; 错误名称（如 "EAGAIN"）
    (operation uv-error-operation)) ; 操作名称

  ;; ========================================
  ;; 错误处理函数
  ;; ========================================

  (define (raise-uv-error code who)
    "抛出 libuv 错误异常"
    (let ([name (%ffi-uv-err-name code)]
          [message (%ffi-uv-strerror code)])
      (raise
        (condition
          (make-uv-error code name who)
          (make-message-condition message)
          (make-who-condition who)))))

  (define (check-uv-result result who)
    "检查 libuv 返回值，负数表示错误"
    (if (< result 0)
        (raise-uv-error result who)
        result))

  (define (check-uv-result/cleanup result who cleanup-proc)
    "检查 libuv 返回值，出错时执行清理函数"
    (if (< result 0)
        (begin
          (cleanup-proc)
          (raise-uv-error result who))
        result))

  ;; ========================================
  ;; 常见错误码
  ;; ========================================
  ;;
  ;; 这些值在不同平台可能不同，这里提供负数形式
  ;; 实际使用时应该通过 uv_err_name 比较名称

  (define UV_E2BIG -7)
  (define UV_EACCES -13)
  (define UV_EADDRINUSE -98)
  (define UV_EADDRNOTAVAIL -99)
  (define UV_EAFNOSUPPORT -97)
  (define UV_EAGAIN -11)
  (define UV_EAI_ADDRFAMILY -3000)
  (define UV_EAI_AGAIN -3001)
  (define UV_ECONNREFUSED -111)
  (define UV_EEXIST -17)
  (define UV_EINVAL -22)
  (define UV_ENOENT -2)
  (define UV_ENOMEM -12)
  (define UV_ENOTDIR -20)
  (define UV_EPIPE -32)
  (define UV_ETIMEDOUT -110)
  (define UV_EOF -4095)

) ; end library
