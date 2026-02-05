;;; internal/posix-ffi.ss - POSIX 系统调用封装
;;;
;;; 本模块提供：
;;; - 常用 POSIX 系统调用的 FFI 绑定（pipe, close, read, write, kill 等）
;;; - 自动检测并加载平台 libc（支持 Linux, FreeBSD, macOS, OpenBSD）
;;; - 文件操作常量（O_RDONLY, O_WRONLY 等）
;;;
;;; 设计说明：
;;; - 采用懒加载策略，首次调用时自动加载 libc
;;; - 各平台路径按常见度排序尝试

(library (chez-async internal posix-ffi)
  (export
    ;; 系统调用封装
    posix-pipe
    posix-close
    posix-write
    posix-read
    posix-kill
    posix-isatty
    posix-getpid

    ;; 可用性检查
    posix-ffi-available?

    ;; 常量
    O_RDONLY
    O_WRONLY
    O_RDWR
    O_CREAT
    O_TRUNC
    )
  (import (chezscheme))

  ;; ========================================
  ;; 自动加载 libc
  ;; ========================================

  (define libc-loaded? #f)
  (define libc-load-error #f)

  (define (try-load-libc)
    "尝试自动加载系统 libc"
    (when (not libc-loaded?)
      (guard (e [else
                  (set! libc-load-error e)
                  (set! libc-loaded? #f)
                  #f])
        ;; 按平台路径依次尝试加载 libc
        (cond
          ;; Linux 64 位（最常见）
          [(guard (e [else #f])
             (load-shared-object "/lib64/libc.so.6")
             #t)
           (set! libc-loaded? #t)]
          ;; Linux 32 位
          [(guard (e [else #f])
             (load-shared-object "/lib/libc.so.6")
             #t)
           (set! libc-loaded? #t)]
          ;; Linux multiarch (Debian/Ubuntu)
          [(guard (e [else #f])
             (load-shared-object "/lib/x86_64-linux-gnu/libc.so.6")
             #t)
           (set! libc-loaded? #t)]
          ;; FreeBSD
          [(guard (e [else #f])
             (load-shared-object "/lib/libc.so.7")
             #t)
           (set! libc-loaded? #t)]
          ;; FreeBSD 较新版本
          [(guard (e [else #f])
             (load-shared-object "/usr/lib/libc.so.7")
             #t)
           (set! libc-loaded? #t)]
          ;; macOS
          [(guard (e [else #f])
             (load-shared-object "/usr/lib/libc.dylib")
             #t)
           (set! libc-loaded? #t)]
          ;; OpenBSD / NetBSD / 其他 BSD — 交由动态链接器解析
          [(guard (e [else #f])
             (load-shared-object "libc.so")
             #t)
           (set! libc-loaded? #t)]
          ;; 所有尝试均失败
          [else
           (set! libc-load-error "Could not find libc on any known path")
           #f]))))

  ;; ========================================
  ;; POSIX 函数封装（懒加载）
  ;; ========================================

  (define posix-pipe
    (lambda args
      (try-load-libc)
      (if libc-loaded?
          ((foreign-procedure "pipe" (uptr) int) (car args))
          (error 'posix-pipe "libc not available or load failed"))))

  (define posix-close
    (lambda args
      (try-load-libc)
      (if libc-loaded?
          ((foreign-procedure "close" (int) int) (car args))
          (error 'posix-close "libc not available or load failed"))))

  (define posix-write
    (lambda args
      (try-load-libc)
      (if libc-loaded?
          ((foreign-procedure "write" (int uptr uptr) ssize_t)
           (car args) (cadr args) (caddr args))
          (error 'posix-write "libc not available or load failed"))))

  (define posix-read
    (lambda args
      (try-load-libc)
      (if libc-loaded?
          ((foreign-procedure "read" (int uptr uptr) ssize_t)
           (car args) (cadr args) (caddr args))
          (error 'posix-read "libc not available or load failed"))))

  (define posix-kill
    (lambda args
      (try-load-libc)
      (if libc-loaded?
          ((foreign-procedure "kill" (int int) int)
           (car args) (cadr args))
          (error 'posix-kill "libc not available or load failed"))))

  (define posix-isatty
    (lambda args
      (try-load-libc)
      (if libc-loaded?
          ((foreign-procedure "isatty" (int) int) (car args))
          (error 'posix-isatty "libc not available or load failed"))))

  (define posix-getpid
    (lambda ()
      (try-load-libc)
      (if libc-loaded?
          ((foreign-procedure "getpid" () int))
          (error 'posix-getpid "libc not available or load failed"))))

  ;; ========================================
  ;; 可用性检查
  ;; ========================================

  (define (posix-ffi-available?)
    "检查当前平台是否支持 POSIX FFI 调用"
    (try-load-libc)
    libc-loaded?)

  ;; ========================================
  ;; 常量
  ;; ========================================

  (define O_RDONLY 0)
  (define O_WRONLY 1)
  (define O_RDWR 2)
  (define O_CREAT 64)    ; O_CREAT octal 0100
  (define O_TRUNC 512)   ; O_TRUNC octal 01000

  ) ; end library
