;;; internal/posix-ffi.ss - POSIX 系统调用封装
;;;
;;; 本模块提供常用 POSIX 系统调用的 FFI 绑定：
;;;
;;; 系统调用：
;;;   posix-pipe    - 创建管道 (pipe)
;;;   posix-close   - 关闭文件描述符 (close)
;;;   posix-write   - 写数据 (write)
;;;   posix-read    - 读数据 (read)
;;;   posix-kill    - 发送信号 (kill)
;;;   posix-isatty  - 检查终端 (isatty)
;;;   posix-getpid  - 获取进程 ID (getpid)
;;;
;;; 常量：
;;;   O_RDONLY, O_WRONLY, O_RDWR, O_CREAT, O_TRUNC
;;;
;;; 设计说明：
;;; - 采用懒加载策略，首次调用时自动检测并加载平台 libc
;;; - 支持 Linux（64/32 位、multiarch）、FreeBSD、macOS、OpenBSD
;;; - libc 加载状态封装在闭包中，不暴露全局变量
;;; - 使用 define-posix-call 宏消除 7 个函数包装器的重复模式

(library (chez-async internal posix-ffi)
  (export
    ;; 系统调用封装
    posix-pipe                ; (fd-array-ptr) → int
    posix-close               ; (fd) → int
    posix-write               ; (fd buf count) → ssize_t
    posix-read                ; (fd buf count) → ssize_t
    posix-kill                ; (pid signal) → int
    posix-isatty              ; (fd) → int
    posix-getpid              ; () → int

    ;; 可用性检查
    posix-ffi-available?      ; () → boolean

    ;; 文件操作常量
    O_RDONLY
    O_WRONLY
    O_RDWR
    O_CREAT
    O_TRUNC
    )
  (import (chezscheme)
          (chez-async internal foreign))

  ;; ========================================
  ;; POSIX 函数封装宏
  ;; ========================================
  ;;
  ;; libc 加载逻辑由 internal/foreign.ss 的 ensure-libc-loaded! 统一提供，
  ;; 避免重复的平台检测代码。
  ;;
  ;; define-posix-call 宏消除 7 个 POSIX 函数包装器的重复模式。
  ;; 每个包装器：
  ;; 1. 确保 libc 已加载（ensure-libc-loaded!）
  ;; 2. 懒创建 foreign-procedure（首次调用时）
  ;; 3. 将参数转发给 C 函数

  (define-syntax define-posix-call
    (syntax-rules ()
      [(_ name c-name (arg-types ...) return-type)
       (define name
         (let ([proc #f])
           (lambda args
             (ensure-libc-loaded!)
             (unless proc
               (set! proc (foreign-procedure c-name (arg-types ...) return-type)))
             (apply proc args))))]))

  ;; ========================================
  ;; POSIX 系统调用定义
  ;; ========================================

  ;; posix-pipe: 创建管道
  ;; 参数：fd-array-ptr - 指向 int[2] 的指针
  ;; 返回：成功时 0，失败时 -1
  (define-posix-call posix-pipe "pipe" (uptr) int)

  ;; posix-close: 关闭文件描述符
  ;; 参数：fd - 文件描述符
  ;; 返回：成功时 0，失败时 -1
  (define-posix-call posix-close "close" (int) int)

  ;; posix-write: 写入数据
  ;; 参数：fd - 文件描述符, buf - 缓冲区指针, count - 字节数
  ;; 返回：写入的字节数，失败时 -1
  (define-posix-call posix-write "write" (int uptr uptr) ssize_t)

  ;; posix-read: 读取数据
  ;; 参数：fd - 文件描述符, buf - 缓冲区指针, count - 字节数
  ;; 返回：读取的字节数，失败时 -1
  (define-posix-call posix-read "read" (int uptr uptr) ssize_t)

  ;; posix-kill: 发送信号
  ;; 参数：pid - 进程 ID, signal - 信号编号
  ;; 返回：成功时 0，失败时 -1
  (define-posix-call posix-kill "kill" (int int) int)

  ;; posix-isatty: 检查是否为终端
  ;; 参数：fd - 文件描述符
  ;; 返回：是终端时 1，否则 0
  (define-posix-call posix-isatty "isatty" (int) int)

  ;; posix-getpid: 获取当前进程 ID
  ;; 返回：进程 ID
  (define-posix-call posix-getpid "getpid" () int)

  ;; ========================================
  ;; 可用性检查
  ;; ========================================

  ;; posix-ffi-available?: 检查当前平台是否支持 POSIX FFI 调用
  ;;
  ;; 返回：
  ;;   #t 如果 libc 已成功加载，#f 如果加载失败
  ;;
  ;; 说明：
  ;;   此函数不会抛出异常，即使 libc 不可用也安全返回 #f。
  (define (posix-ffi-available?)
    (guard (e [else #f])
      (ensure-libc-loaded!)
      #t))

  ;; ========================================
  ;; 文件操作常量
  ;; ========================================
  ;;
  ;; 这些是 Linux/POSIX 标准的文件打开标志。
  ;; 注意：O_CREAT 和 O_TRUNC 的值在不同平台上可能不同，
  ;; 以下为 Linux x86/x86_64 的值。

  (define O_RDONLY 0)         ; 只读
  (define O_WRONLY 1)         ; 只写
  (define O_RDWR 2)           ; 读写
  (define O_CREAT 64)         ; 不存在时创建（octal 0100）
  (define O_TRUNC 512)        ; 截断已有内容（octal 01000）

) ; end library
