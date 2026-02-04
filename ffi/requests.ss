;;; ffi/requests.ss - 请求（Request）基础操作 FFI 绑定
;;;
;;; 本模块提供 libuv 请求（uv_req_t）的通用操作。
;;;
;;; 请求（request）是 libuv 中短生命周期操作的抽象。
;;; 与句柄（handle）不同，请求通常代表一次性操作。
;;;
;;; 请求类型：
;;; - connect: TCP 连接请求
;;; - write: 写操作请求
;;; - shutdown: 优雅关闭请求
;;; - fs: 文件系统操作请求
;;; - getaddrinfo: DNS 正向解析请求
;;; - getnameinfo: DNS 反向解析请求
;;; - work: 线程池工作请求
;;;
;;; 本模块主要提供：
;;; - 请求取消操作
;;; - 各类型请求的大小查询（用于内存分配）

(library (chez-async ffi requests)
  (export
    ;; 请求通用操作
    %ffi-uv-cancel             ; 取消请求

    ;; 请求大小查询（用于分配内存）
    %ffi-uv-req-size           ; 通用大小查询
    %ffi-uv-write-req-size     ; write 请求大小
    %ffi-uv-connect-req-size   ; connect 请求大小
    %ffi-uv-shutdown-req-size  ; shutdown 请求大小
    %ffi-uv-fs-req-size        ; fs 请求大小
    %ffi-uv-getaddrinfo-req-size ; getaddrinfo 请求大小
    %ffi-uv-getnameinfo-req-size ; getnameinfo 请求大小
    )
  (import (chezscheme)
          (chez-async ffi lib)
          (chez-async ffi types))

  ;; 确保 libuv 库在此模块范围内已加载
  (define _libuv-loaded (ensure-libuv-loaded))

  ;; ========================================
  ;; 请求通用操作
  ;; ========================================

  ;; int uv_cancel(uv_req_t* req)
  ;; 取消正在进行的请求
  ;;
  ;; 返回值：
  ;;   0 表示成功
  ;;   UV_EBUSY 表示请求正在执行
  ;;   UV_EINVAL 表示请求类型不支持取消
  ;;
  ;; 支持取消的请求类型：
  ;;   - fs（文件系统操作）
  ;;   - getaddrinfo（DNS 正向解析）
  ;;   - getnameinfo（DNS 反向解析）
  ;;   - work（线程池工作）
  ;;
  ;; 注意：取消操作不一定能成功，如果操作已经在执行中，
  ;; 可能无法取消。取消后回调仍会被调用，但 status 会是 UV_ECANCELED。
  (define %ffi-uv-cancel
    (foreign-procedure "uv_cancel" (void*) int))

  ;; ========================================
  ;; 请求大小查询
  ;; ========================================
  ;;
  ;; 这些函数用于获取各类请求结构的大小，
  ;; 以便在 Scheme 中分配正确大小的内存。

  ;; size_t uv_req_size(uv_req_type type)
  ;; 获取指定类型请求的大小（字节）
  (define %ffi-uv-req-size
    (foreign-procedure "uv_req_size" (int) size_t))

  ;; 请求类型枚举（与 libuv 的 uv_req_type 对应）
  ;; 这些值应该与 libuv 头文件中的定义保持一致
  (define uv-req-type
    '((unknown . 0)      ; 未知类型
      (req . 1)          ; 基础请求类型
      (connect . 2)      ; TCP 连接请求
      (write . 3)        ; 写入请求
      (shutdown . 4)     ; 优雅关闭请求
      (udp-send . 5)     ; UDP 发送请求
      (fs . 6)           ; 文件系统请求
      (work . 7)         ; 线程池工作请求
      (getaddrinfo . 8)  ; DNS 正向解析请求
      (getnameinfo . 9)));DNS 反向解析请求

  ;; uv-req-type->int: 将请求类型符号转换为整数
  ;;
  ;; 参数：
  ;;   type - 请求类型符号（如 'fs, 'connect 等）
  ;;
  ;; 返回：
  ;;   对应的整数值
  ;;
  ;; 错误：
  ;;   如果类型无效，抛出异常
  (define (uv-req-type->int type)
    (cond
      [(assq type uv-req-type) => cdr]
      [else (error 'uv-req-type->int "无效的请求类型" type)]))

  ;; ========================================
  ;; 便捷函数：获取特定请求类型的大小
  ;; ========================================
  ;;
  ;; 这些函数是对 %ffi-uv-req-size 的封装，
  ;; 提供更方便的接口来获取常用请求类型的大小。

  (define (%ffi-uv-write-req-size)
    "获取 uv_write_t 结构大小"
    (%ffi-uv-req-size (uv-req-type->int 'write)))

  (define (%ffi-uv-connect-req-size)
    "获取 uv_connect_t 结构大小"
    (%ffi-uv-req-size (uv-req-type->int 'connect)))

  (define (%ffi-uv-shutdown-req-size)
    "获取 uv_shutdown_t 结构大小"
    (%ffi-uv-req-size (uv-req-type->int 'shutdown)))

  (define (%ffi-uv-fs-req-size)
    "获取 uv_fs_t 结构大小"
    (%ffi-uv-req-size (uv-req-type->int 'fs)))

  (define (%ffi-uv-getaddrinfo-req-size)
    "获取 uv_getaddrinfo_t 结构大小"
    (%ffi-uv-req-size (uv-req-type->int 'getaddrinfo)))

  (define (%ffi-uv-getnameinfo-req-size)
    "获取 uv_getnameinfo_t 结构大小"
    (%ffi-uv-req-size (uv-req-type->int 'getnameinfo)))

) ; end library
