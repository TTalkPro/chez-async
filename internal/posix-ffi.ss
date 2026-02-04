;;; internal/posix-ffi.ss - POSIX FFI wrapper for cross-platform compatibility
;;;
;;; Provides portable FFI bindings for common POSIX functions
;;;
;;; Note: On some platforms (e.g., FreeBSD), Chez Scheme may not automatically
;;; link against libc, making direct system calls unavailable. This module
;;; provides graceful fallback handling.

(library (chez-async internal posix-ffi)
  (export
    ;; System call wrappers (may not be available on all platforms)
    posix-pipe
    posix-close
    posix-write
    posix-read
    posix-kill
    posix-isatty
    posix-getpid

    ;; Availability check
    posix-ffi-available?

    ;; Constants
    O_RDONLY
    O_WRONLY
    O_RDWR
    O_CREAT
    O_TRUNC
    )
  (import (chezscheme))

  ;; ========================================
  ;; POSIX function wrappers
  ;; ========================================
  ;;
  ;; These try to bind to libc functions. On platforms where libc
  ;; is not automatically linked (e.g., FreeBSD with Chez Scheme),
  ;; these will throw an exception which we catch.

  (define posix-pipe
    (guard (e [else (lambda x (error 'posix-pipe "POSIX FFI not available"))])
      (foreign-procedure "pipe" (uptr) int)))

  (define posix-close
    (guard (e [else (lambda x (error 'posix-close "POSIX FFI not available"))])
      (foreign-procedure "close" (int) int)))

  (define posix-write
    (guard (e [else (lambda (fd buf len) (error 'posix-write "POSIX FFI not available"))])
      (foreign-procedure "write" (int uptr uptr) ssize_t)))

  (define posix-read
    (guard (e [else (lambda (fd buf len) (error 'posix-read "POSIX FFI not available"))])
      (foreign-procedure "read" (int uptr uptr) ssize_t)))

  (define posix-kill
    (guard (e [else (lambda (pid sig) (error 'posix-kill "POSIX FFI not available"))])
      (foreign-procedure "kill" (int int) int)))

  (define posix-isatty
    (guard (e [else (lambda (fd) (error 'posix-isatty "POSIX FFI not available"))])
      (foreign-procedure "isatty" (int) int)))

  (define posix-getpid
    (guard (e [else (lambda () (error 'posix-getpid "POSIX FFI not available"))])
      (foreign-procedure "getpid" () int)))

  ;; ========================================
  ;; Availability check
  ;; ========================================

  (define (posix-ffi-available?)
    "Check if POSIX FFI calls are available on this platform"
    (guard (e [else #f])
      ;; Try to call getpid - if it works, POSIX FFI is available
      ((foreign-procedure "getpid" () int))
      #t))

  ;; ========================================
  ;; Open flags (common across platforms)
  ;; ========================================

  (define O_RDONLY 0)
  (define O_WRONLY 1)
  (define O_RDWR 2)
  (define O_CREAT 64)    ; O_CREAT octal 0100
  (define O_TRUNC 512)   ; O_TRUNC octal 01000

  ) ; end library
