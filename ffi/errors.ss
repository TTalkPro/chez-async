;;; ffi/errors.ss - 错误处理和条件类型
;;;
;;; 本模块定义 libuv 错误处理机制：
;;; - &uv-error 条件类型
;;; - 错误检查和抛出函数
;;; - 常见错误码常量
;;;
;;; 设计说明：
;;; 使用 Chez Scheme 的条件系统（condition system）来表示 libuv 错误，
;;; 这样可以与标准的异常处理机制（guard、raise）无缝集成。

(library (chez-async ffi errors)
  (export
    ;; 条件类型
    &uv-error             ; 错误条件类型
    make-uv-error         ; 创建错误条件
    uv-error?             ; 错误条件谓词
    uv-error-code         ; 获取错误码
    uv-error-name         ; 获取错误名称
    uv-error-operation    ; 获取操作名称

    ;; 错误处理函数
    raise-uv-error        ; 抛出错误
    check-uv-result       ; 检查返回值
    check-uv-result/cleanup ; 检查返回值（带清理）

    ;; FFI 函数
    %ffi-uv-err-name      ; 错误码转名称
    %ffi-uv-strerror      ; 错误码转描述

    ;; 常见错误码
    UV_E2BIG UV_EACCES UV_EADDRINUSE UV_EADDRNOTAVAIL
    UV_EAFNOSUPPORT UV_EAGAIN UV_EAI_ADDRFAMILY UV_EAI_AGAIN
    UV_ECONNREFUSED UV_EEXIST UV_EINVAL UV_ENOENT UV_ENOMEM
    UV_ENOTDIR UV_EPIPE UV_ETIMEDOUT UV_EOF
    )
  (import (chezscheme)
          (chez-async ffi lib))

  ;; 确保 libuv 库在此模块范围内已加载
  (define _libuv-loaded (ensure-libuv-loaded))

  ;; ========================================
  ;; FFI 绑定
  ;; ========================================

  ;; const char* uv_err_name(int err)
  ;; 将错误码转换为名称字符串
  ;; 例如：-2 -> "ENOENT"
  (define %ffi-uv-err-name
    (foreign-procedure "uv_err_name" (int) string))

  ;; const char* uv_strerror(int err)
  ;; 将错误码转换为人类可读的描述
  ;; 例如：-2 -> "no such file or directory"
  (define %ffi-uv-strerror
    (foreign-procedure "uv_strerror" (int) string))

  ;; ========================================
  ;; 错误条件类型
  ;; ========================================
  ;;
  ;; &uv-error 是一个自定义条件类型，继承自 &error。
  ;; 它携带以下信息：
  ;; - code: libuv 错误码（负整数）
  ;; - name: 错误名称（如 "EAGAIN"）
  ;; - operation: 发生错误的操作名称

  (define-condition-type &uv-error &error
    make-uv-error uv-error?
    (code uv-error-code)            ; libuv 错误码（负数）
    (name uv-error-name)            ; 错误名称字符串
    (operation uv-error-operation)) ; 操作名称符号

  ;; ========================================
  ;; 错误处理函数
  ;; ========================================

  ;; raise-uv-error: 抛出 libuv 错误异常
  ;;
  ;; 参数：
  ;;   code - libuv 错误码（负整数）
  ;;   who  - 操作名称符号
  ;;
  ;; 说明：
  ;;   创建一个复合条件，包含：
  ;;   - &uv-error（libuv 特定信息）
  ;;   - &message-condition（人类可读描述）
  ;;   - &who-condition（操作名称）
  (define (raise-uv-error code who)
    "抛出 libuv 错误异常"
    (let ([name (%ffi-uv-err-name code)]
          [message (%ffi-uv-strerror code)])
      (raise
        (condition
          (make-uv-error code name who)
          (make-message-condition message)
          (make-who-condition who)))))

  ;; check-uv-result: 检查 libuv 返回值
  ;;
  ;; 参数：
  ;;   result - libuv 函数返回值
  ;;   who    - 操作名称符号
  ;;
  ;; 返回：
  ;;   如果 result >= 0，返回 result
  ;;   如果 result < 0，抛出 &uv-error
  (define (check-uv-result result who)
    "检查 libuv 返回值，负数表示错误"
    (if (< result 0)
        (raise-uv-error result who)
        result))

  ;; check-uv-result/cleanup: 检查返回值，出错时先执行清理
  ;;
  ;; 参数：
  ;;   result       - libuv 函数返回值
  ;;   who          - 操作名称符号
  ;;   cleanup-proc - 清理过程（无参数）
  ;;
  ;; 说明：
  ;;   与 check-uv-result 类似，但在抛出异常前执行清理函数
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
  ;; 这些值在不同平台可能不同，但 libuv 保证语义一致。
  ;; 在实际使用中，应该通过 uv_err_name 比较名称，
  ;; 而不是直接比较数值。

  (define UV_E2BIG -7)           ; 参数列表太长
  (define UV_EACCES -13)         ; 权限不足
  (define UV_EADDRINUSE -98)     ; 地址已被使用
  (define UV_EADDRNOTAVAIL -99)  ; 地址不可用
  (define UV_EAFNOSUPPORT -97)   ; 地址族不支持
  (define UV_EAGAIN -11)         ; 资源暂时不可用
  (define UV_EAI_ADDRFAMILY -3000) ; DNS: 地址族不支持
  (define UV_EAI_AGAIN -3001)    ; DNS: 临时失败
  (define UV_ECONNREFUSED -111)  ; 连接被拒绝
  (define UV_EEXIST -17)         ; 文件已存在
  (define UV_EINVAL -22)         ; 无效参数
  (define UV_ENOENT -2)          ; 文件或目录不存在
  (define UV_ENOMEM -12)         ; 内存不足
  (define UV_ENOTDIR -20)        ; 不是目录
  (define UV_EPIPE -32)          ; 管道断开
  (define UV_ETIMEDOUT -110)     ; 操作超时
  (define UV_EOF -4095)          ; 文件结束

) ; end library
