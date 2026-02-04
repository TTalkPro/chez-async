;;; ffi/types.ss - C 类型定义和映射
;;;
;;; 定义所有与 libuv 交互所需的 C 类型

(library (chez-async ffi types)
  (export
    ;; 不透明指针类型
    uv-loop-t uv-handle-t uv-req-t
    uv-timer-t uv-tcp-t uv-udp-t uv-stream-t
    uv-connect-t uv-write-t uv-shutdown-t
    uv-fs-t uv-getaddrinfo-t
    uv-pipe-t uv-tty-t uv-poll-t uv-signal-t
    uv-process-t uv-async-t uv-prepare-t uv-check-t uv-idle-t

    ;; 结构体类型 (仅导出类型名，使用 ftype-ref/ftype-set! 访问字段)
    uv-buf-t
    sockaddr-in
    sockaddr-in6
    uv-stat-t
    uv-timespec-t

    ;; 平台相关辅助函数
    sockaddr-family-offset    ; 地址族字段的偏移量
    sockaddr-get-family       ; 从 sockaddr 获取地址族
    bsd-style-sockaddr?       ; 是否是 BSD 风格的 sockaddr

    ;; 枚举类型
    uv-run-mode uv-run-mode->int
    uv-handle-type uv-handle-type->int

    ;; 常量
    AF_INET AF_INET6
    SOCK_STREAM SOCK_DGRAM
    UV_READABLE UV_WRITABLE UV_DISCONNECT
    )
  (import (chezscheme))

  ;; ========================================
  ;; 不透明指针类型
  ;; ========================================

  ;; 所有 libuv 句柄和请求都使用 void* 表示
  ;; 这些类型仅作为文档说明，实际都是 void*
  (define uv-loop-t 'void*)
  (define uv-handle-t 'void*)
  (define uv-req-t 'void*)

  ;; 句柄类型
  (define uv-timer-t 'void*)
  (define uv-tcp-t 'void*)
  (define uv-udp-t 'void*)
  (define uv-stream-t 'void*)
  (define uv-pipe-t 'void*)
  (define uv-tty-t 'void*)
  (define uv-poll-t 'void*)
  (define uv-signal-t 'void*)
  (define uv-process-t 'void*)
  (define uv-async-t 'void*)
  (define uv-prepare-t 'void*)
  (define uv-check-t 'void*)
  (define uv-idle-t 'void*)

  ;; 请求类型
  (define uv-connect-t 'void*)
  (define uv-write-t 'void*)
  (define uv-shutdown-t 'void*)
  (define uv-fs-t 'void*)
  (define uv-getaddrinfo-t 'void*)

  ;; ========================================
  ;; 结构体类型
  ;; ========================================

  ;; uv_buf_t - 缓冲区结构
  (define-ftype uv-buf-t
    (struct
      [base void*]     ; char* 指针
      [len size_t]))   ; 长度

  ;; sockaddr_in - IPv4 地址结构
  (define-ftype sockaddr-in
    (struct
      [sin-family unsigned-16]           ; sa_family_t
      [sin-port unsigned-16]             ; in_port_t (网络字节序)
      [sin-addr unsigned-32]             ; struct in_addr (网络字节序)
      [sin-zero (array 8 unsigned-8)])) ; 填充到 16 字节

  ;; sockaddr_in6 - IPv6 地址结构
  (define-ftype sockaddr-in6
    (struct
      [sin6-family unsigned-16]          ; sa_family_t
      [sin6-port unsigned-16]            ; in_port_t (网络字节序)
      [sin6-flowinfo unsigned-32]        ; IPv6 flow information
      [sin6-addr (array 16 unsigned-8)]  ; IPv6 地址
      [sin6-scope-id unsigned-32]))      ; Scope ID

  ;; uv_timespec_t - 时间结构
  (define-ftype uv-timespec-t
    (struct
      [tv-sec long]     ; 秒
      [tv-nsec long]))  ; 纳秒

  ;; uv_stat_t - 文件状态结构
  (define-ftype uv-stat-t
    (struct
      [st-dev unsigned-64]      ; 设备 ID
      [st-mode unsigned-64]     ; 文件模式
      [st-nlink unsigned-64]    ; 硬链接数
      [st-uid unsigned-64]      ; 用户 ID
      [st-gid unsigned-64]      ; 组 ID
      [st-rdev unsigned-64]     ; 设备 ID（如果是特殊文件）
      [st-ino unsigned-64]      ; inode 号
      [st-size unsigned-64]     ; 文件大小（字节）
      [st-blksize unsigned-64]  ; 块大小
      [st-blocks unsigned-64]   ; 分配的块数
      [st-flags unsigned-64]    ; 标志
      [st-gen unsigned-64]      ; 文件生成号
      [st-atim uv-timespec-t]   ; 最后访问时间
      [st-mtim uv-timespec-t]   ; 最后修改时间
      [st-ctim uv-timespec-t]   ; 最后状态改变时间
      [st-birthtim uv-timespec-t])) ; 创建时间

  ;; ========================================
  ;; 枚举类型
  ;; ========================================

  ;; uv_run_mode
  (define uv-run-mode
    '((default . 0)
      (once . 1)
      (nowait . 2)))

  (define (uv-run-mode->int mode)
    (cond
      [(assq mode uv-run-mode) => cdr]
      [else (error 'uv-run-mode->int "invalid run mode" mode)]))

  ;; uv_handle_type
  (define uv-handle-type
    '((unknown . 0)
      (async . 1)
      (check . 2)
      (fs-event . 3)
      (fs-poll . 4)
      (handle . 5)
      (idle . 6)
      (named-pipe . 7)
      (poll . 8)
      (prepare . 9)
      (process . 10)
      (stream . 11)
      (tcp . 12)
      (timer . 13)
      (tty . 14)
      (udp . 15)
      (signal . 16)
      (file . 17)))

  (define (uv-handle-type->int type)
    (cond
      [(assq type uv-handle-type) => cdr]
      [else (error 'uv-handle-type->int "invalid handle type" type)]))

  ;; ========================================
  ;; 平台检测辅助函数
  ;; ========================================

  ;; BSD 系统的 sockaddr 结构有 sin_len 字段在 sin_family 之前
  ;; Linux 系统没有 sin_len 字段
  (define bsd-style-sockaddr?
    (case (machine-type)
      ;; BSD 系统: macOS, FreeBSD, OpenBSD, NetBSD
      [(i3osx ti3osx a6osx ta6osx arm64osx tarm64osx   ; macOS
        i3fb ti3fb a6fb ta6fb                          ; FreeBSD
        i3ob ti3ob a6ob ta6ob arm64ob tarm64ob         ; OpenBSD
        i3nb ti3nb a6nb ta6nb)                         ; NetBSD
       #t]
      ;; Linux, Windows 使用无 sin_len 的布局
      [else #f]))

  ;; 地址族字段的偏移量
  ;; BSD: 偏移 1 (sin_len 在偏移 0)
  ;; Linux: 偏移 0
  (define sockaddr-family-offset
    (if bsd-style-sockaddr? 1 0))

  ;; 从 sockaddr 指针获取地址族
  (define (sockaddr-get-family addr-ptr)
    "从 sockaddr 结构获取地址族
     addr-ptr: sockaddr 结构的指针
     返回: 地址族值 (AF_INET, AF_INET6 等)"
    (if bsd-style-sockaddr?
        ;; BSD: sin_family 是 uint8_t 在偏移 1
        (foreign-ref 'unsigned-8 addr-ptr 1)
        ;; Linux: sin_family 是 uint16_t 在偏移 0
        (foreign-ref 'unsigned-16 addr-ptr 0)))

  ;; ========================================
  ;; 常量
  ;; ========================================

  ;; 地址族 - 平台相关
  ;; AF_INET 在所有平台都是 2
  ;; AF_INET6 在不同平台有不同值:
  ;;   - Linux: 10
  ;;   - macOS/iOS: 30
  ;;   - FreeBSD: 28
  ;;   - OpenBSD: 24
  ;;   - NetBSD: 24
  ;;   - Windows: 23
  (define AF_INET 2)
  (define AF_INET6
    (case (machine-type)
      ;; Linux
      [(i3le ti3le a6le ta6le arm32le arm64le ppc32le ppc64le)
       10]
      ;; macOS
      [(i3osx ti3osx a6osx ta6osx arm64osx tarm64osx)
       30]
      ;; FreeBSD
      [(i3fb ti3fb a6fb ta6fb)
       28]
      ;; OpenBSD
      [(i3ob ti3ob a6ob ta6ob arm64ob tarm64ob)
       24]
      ;; NetBSD
      [(i3nb ti3nb a6nb ta6nb)
       24]
      ;; Windows
      [(i3nt ti3nt a6nt ta6nt)
       23]
      ;; 默认使用 Linux 值
      [else 10]))

  ;; 套接字类型
  (define SOCK_STREAM 1)
  (define SOCK_DGRAM 2)

  ;; Poll 事件标志
  (define UV_READABLE 1)
  (define UV_WRITABLE 2)
  (define UV_DISCONNECT 4)

) ; end library
