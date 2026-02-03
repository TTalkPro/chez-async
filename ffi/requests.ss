;;; ffi/requests.ss - 请求基础操作
;;;
;;; 提供所有请求类型的通用操作和大小查询

(library (chez-async ffi requests)
  (export
    ;; 请求通用操作
    %ffi-uv-cancel

    ;; 请求大小查询（用于分配内存）
    %ffi-uv-req-size
    %ffi-uv-write-req-size
    %ffi-uv-connect-req-size
    %ffi-uv-shutdown-req-size
    %ffi-uv-fs-req-size
    %ffi-uv-getaddrinfo-req-size
    )
  (import (chezscheme)
          (chez-async ffi types))

  ;; ========================================
  ;; 请求通用操作
  ;; ========================================

  ;; int uv_cancel(uv_req_t* req)
  ;; 注意：只有某些请求类型支持取消（fs, getaddrinfo）
  (define %ffi-uv-cancel
    (foreign-procedure "uv_cancel" (void*) int))

  ;; ========================================
  ;; 请求大小查询
  ;; ========================================

  ;; size_t uv_req_size(uv_req_type type)
  (define %ffi-uv-req-size
    (foreign-procedure "uv_req_size" (int) size_t))

  ;; 请求类型枚举（与 uv_req_type 对应）
  (define uv-req-type
    '((unknown . 0)
      (req . 1)
      (connect . 2)
      (write . 3)
      (shutdown . 4)
      (udp-send . 5)
      (fs . 6)
      (work . 7)
      (getaddrinfo . 8)
      (getnameinfo . 9)))

  (define (uv-req-type->int type)
    (cond
      [(assq type uv-req-type) => cdr]
      [else (error 'uv-req-type->int "invalid request type" type)]))

  ;; 便捷函数：获取特定请求类型的大小
  (define (%ffi-uv-write-req-size)
    (%ffi-uv-req-size (uv-req-type->int 'write)))

  (define (%ffi-uv-connect-req-size)
    (%ffi-uv-req-size (uv-req-type->int 'connect)))

  (define (%ffi-uv-shutdown-req-size)
    (%ffi-uv-req-size (uv-req-type->int 'shutdown)))

  (define (%ffi-uv-fs-req-size)
    (%ffi-uv-req-size (uv-req-type->int 'fs)))

  (define (%ffi-uv-getaddrinfo-req-size)
    (%ffi-uv-req-size (uv-req-type->int 'getaddrinfo)))

) ; end library
