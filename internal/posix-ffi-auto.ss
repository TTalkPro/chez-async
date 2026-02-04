;;; internal/posix-ffi-auto.ss - 自动加载 libc 的 POSIX FFI 包装器
;;;
;;; 这个版本会自动尝试加载 libc，然后提供 POSIX 函数绑定

(library (chez-async internal posix-ffi-auto)
  (export
    ;; 系统调用包装器
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
    "尝试加载系统的 libc"
    (when (not libc-loaded?)
      (guard (e [else
                  (set! libc-load-error e)
                  (set! libc-loaded? #f)
                  #f])
        ;; Chez Scheme 的 machine-type 格式是 ta6le (threaded adipic6 little-endian)
        ;; 对于不同的系统，我们需要用不同的方法检测
        ;; 方法：尝试按顺序加载不同平台的 libc
        (cond
          ;; 尝试 Linux (最常见的)
          [(guard (e [else #f])
             (load-shared-object "/lib64/libc.so.6")
             #t)
           (set! libc-loaded? #t)]
          ;; 尝试 Linux 32位
          [(guard (e [else #f])
             (load-shared-object "/lib/libc.so.6")
             #t)
           (set! libc-loaded? #t)]
          ;; 尝试 FreeBSD
          [(guard (e [else #f])
             (load-shared-object "/lib/libc.so.7")
             #t)
           (set! libc-loaded? #t)]
          ;; 尝试 FreeBSD 新版本
          [(guard (e [else #f])
             (load-shared-object "/usr/lib/libc.so.7")
             #t)
           (set! libc-loaded? #t)]
          ;; 尝试 macOS
          [(guard (e [else #f])
             (load-shared-object "/usr/lib/libc.dylib")
             #t)
           (set! libc-loaded? #t)]
          ;; 都失败了
          [else
           (set! libc-load-error "Could not find libc on any known path")
           #f]))))

  ;; 移除不再需要的 string-contains
  (define (string-contains str substr)
    (let ([str-len (string-length str)]
          [sub-len (string-length substr)])
      (let loop ([i 0])
        (cond
          [(> (+ i sub-len) str-len) #f]
          [(string=? (substring str i (+ i sub-len)) substr) #t]
          [else (loop (+ i 1))]))))

  ;; ========================================
  ;; POSIX 函数定义（惰性加载）
  ;; ========================================

  (define posix-pipe
    (lambda args
      (try-load-libc)
      (if libc-loaded?
          ((foreign-procedure "pipe" (uptr) int) (car args))
          (error 'posix-pipe "libc not available"))))

  (define posix-close
    (lambda args
      (try-load-libc)
      (if libc-loaded?
          ((foreign-procedure "close" (int) int) (car args))
          (error 'posix-close "libc not available"))))

  (define posix-write
    (lambda args
      (try-load-libc)
      (if libc-loaded?
          ((foreign-procedure "write" (int uptr uptr) ssize_t)
           (car args) (cadr args) (caddr args))
          (error 'posix-write "libc not available"))))

  (define posix-read
    (lambda args
      (try-load-libc)
      (if libc-loaded?
          ((foreign-procedure "read" (int uptr uptr) ssize_t)
           (car args) (cadr args) (caddr args))
          (error 'posix-read "libc not available"))))

  (define posix-kill
    (lambda args
      (try-load-libc)
      (if libc-loaded?
          ((foreign-procedure "kill" (int int) int)
           (car args) (cadr args))
          (error 'posix-kill "libc not available"))))

  (define posix-isatty
    (lambda args
      (try-load-libc)
      (if libc-loaded?
          ((foreign-procedure "isatty" (int) int) (car args))
          (error 'posix-isatty "libc not available"))))

  (define posix-getpid
    (lambda ()
      (try-load-libc)
      (if libc-loaded?
          ((foreign-procedure "getpid" () int))
          (error 'posix-getpid "libc not available"))))

  ;; ========================================
  ;; 可用性检查
  ;; ========================================

  (define (posix-ffi-available?)
    "检查 POSIX FFI 是否可用"
    (try-load-libc)
    libc-loaded?)

  ;; ========================================
  ;; 常量
  ;; ========================================

  (define O_RDONLY 0)
  (define O_WRONLY 1)
  (define O_RDWR 2)
  (define O_CREAT 64)
  (define O_TRUNC 512)

  ) ; end library
