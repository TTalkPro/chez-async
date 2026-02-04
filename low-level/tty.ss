;;; low-level/tty.ss - TTY 低层封装
;;;
;;; 提供终端（TTY）的高层封装
;;;
;;; TTY 用于终端交互，支持：
;;; - 读取用户输入
;;; - 输出到终端
;;; - 原始模式（无缓冲、无回显）
;;; - 获取窗口大小

(library (chez-async low-level tty)
  (export
    ;; TTY 创建
    uv-tty-init
    uv-tty-init-stdin
    uv-tty-init-stdout
    uv-tty-init-stderr

    ;; 模式设置
    uv-tty-set-mode!
    uv-tty-reset-mode!

    ;; 窗口大小
    uv-tty-get-winsize

    ;; 虚拟终端
    uv-tty-set-vterm-state!
    uv-tty-get-vterm-state

    ;; Stream 操作（从 stream 模块重新导出）
    uv-read-start!
    uv-read-stop!
    uv-write!
    uv-try-write
    uv-shutdown!

    ;; 常量
    UV_TTY_MODE_NORMAL
    UV_TTY_MODE_RAW
    UV_TTY_MODE_IO
    UV_TTY_SUPPORTED
    UV_TTY_UNSUPPORTED

    ;; 标准文件描述符
    STDIN_FILENO
    STDOUT_FILENO
    STDERR_FILENO
    )
  (import (chezscheme)
          (chez-async ffi types)
          (chez-async ffi errors)
          (chez-async ffi handles)
          (chez-async ffi tty)
          (chez-async low-level handle-base)
          (chez-async low-level stream)
          (chez-async high-level event-loop)
          (chez-async internal macros))

  ;; ========================================
  ;; 标准文件描述符常量
  ;; ========================================

  (define STDIN_FILENO 0)
  (define STDOUT_FILENO 1)
  (define STDERR_FILENO 2)

  ;; ========================================
  ;; TTY 创建
  ;; ========================================

  (define (uv-tty-init loop fd)
    "创建 TTY 句柄
     loop: 事件循环
     fd: 文件描述符（0=stdin, 1=stdout, 2=stderr）"
    (let* ([size (%ffi-uv-tty-size)]
           [ptr (allocate-handle size)]
           [loop-ptr (uv-loop-ptr loop)])
      (with-uv-check/cleanup uv-tty-init
        (%ffi-uv-tty-init loop-ptr ptr fd 0)  ; 0 是 unused 参数
        (lambda () (foreign-free ptr)))
      (make-handle ptr 'tty loop)))

  (define (uv-tty-init-stdin loop)
    "创建标准输入 TTY 句柄"
    (uv-tty-init loop STDIN_FILENO))

  (define (uv-tty-init-stdout loop)
    "创建标准输出 TTY 句柄"
    (uv-tty-init loop STDOUT_FILENO))

  (define (uv-tty-init-stderr loop)
    "创建标准错误 TTY 句柄"
    (uv-tty-init loop STDERR_FILENO))

  ;; ========================================
  ;; TTY 模式
  ;; ========================================

  (define (uv-tty-set-mode! tty mode)
    "设置终端模式
     tty: TTY 句柄
     mode: UV_TTY_MODE_NORMAL（正常）、UV_TTY_MODE_RAW（原始）或 UV_TTY_MODE_IO"
    (when (handle-closed? tty)
      (error 'uv-tty-set-mode! "tty handle is closed"))
    (with-uv-check uv-tty-set-mode
      (%ffi-uv-tty-set-mode (handle-ptr tty) mode)))

  (define (uv-tty-reset-mode!)
    "重置所有终端为原始模式
     通常在程序退出前调用，恢复终端状态"
    (with-uv-check uv-tty-reset-mode
      (%ffi-uv-tty-reset-mode)))

  ;; ========================================
  ;; 窗口大小
  ;; ========================================

  (define (uv-tty-get-winsize tty)
    "获取终端窗口大小
     返回: (width . height) 点对（字符数）"
    (when (handle-closed? tty)
      (error 'uv-tty-get-winsize "tty handle is closed"))
    (let ([width-ptr (foreign-alloc (foreign-sizeof 'int))]
          [height-ptr (foreign-alloc (foreign-sizeof 'int))])
      (guard (e [else
                 (foreign-free width-ptr)
                 (foreign-free height-ptr)
                 (raise e)])
        (with-uv-check uv-tty-get-winsize
          (%ffi-uv-tty-get-winsize (handle-ptr tty) width-ptr height-ptr))
        (let ([width (foreign-ref 'int width-ptr 0)]
              [height (foreign-ref 'int height-ptr 0)])
          (foreign-free width-ptr)
          (foreign-free height-ptr)
          (cons width height)))))

  ;; ========================================
  ;; 虚拟终端（Windows）
  ;; ========================================

  (define (uv-tty-set-vterm-state! state)
    "设置虚拟终端状态（仅 Windows）
     state: UV_TTY_SUPPORTED 或 UV_TTY_UNSUPPORTED"
    (%ffi-uv-tty-set-vterm-state state))

  (define (uv-tty-get-vterm-state)
    "获取虚拟终端状态
     返回: UV_TTY_SUPPORTED 或 UV_TTY_UNSUPPORTED"
    (let ([state-ptr (foreign-alloc (foreign-sizeof 'int))])
      (guard (e [else
                 (foreign-free state-ptr)
                 (raise e)])
        (with-uv-check uv-tty-get-vterm-state
          (%ffi-uv-tty-get-vterm-state state-ptr))
        (let ([state (foreign-ref 'int state-ptr 0)])
          (foreign-free state-ptr)
          state))))

) ; end library
