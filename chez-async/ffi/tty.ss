;;; ffi/tty.ss - TTY (终端) FFI 绑定
;;;
;;; 本模块提供 libuv TTY 句柄（uv_tty_t）的 FFI 绑定。
;;;
;;; TTY 句柄用于与终端设备交互，支持：
;;; - 终端读写
;;; - 终端模式设置（raw/normal）
;;; - 窗口大小查询
;;;
;;; TTY 继承自 Stream，因此也支持 stream 模块中的读写操作。
;;;
;;; 典型用例：
;;; - 交互式 CLI: init(stdin) -> read -> process -> init(stdout) -> write
;;; - 终端大小: get-winsize -> 调整输出格式

(library (chez-async ffi tty)
  (export
    ;; 初始化
    %ffi-uv-tty-init             ; 初始化 TTY 句柄

    ;; 模式设置
    %ffi-uv-tty-set-mode         ; 设置终端模式
    %ffi-uv-tty-reset-mode       ; 重置所有终端为原始模式

    ;; 窗口大小
    %ffi-uv-tty-get-winsize      ; 获取终端窗口大小

    ;; VT100 控制
    %ffi-uv-tty-set-vterm-state  ; 设置虚拟终端状态
    %ffi-uv-tty-get-vterm-state  ; 获取虚拟终端状态

    ;; 常量
    UV_TTY_MODE_NORMAL
    UV_TTY_MODE_RAW
    UV_TTY_MODE_IO

    ;; 虚拟终端状态
    UV_TTY_SUPPORTED
    UV_TTY_UNSUPPORTED
    )
  (import (chezscheme)
          (chez-async ffi lib)
          (chez-async internal macros))

  ;; 确保 libuv 库在此模块范围内已加载
  (define _libuv-loaded (ensure-libuv-loaded))

  ;; ========================================
  ;; TTY 模式常量
  ;; ========================================

  ;; uv_tty_mode_t
  (define UV_TTY_MODE_NORMAL 0)  ; 正常模式（行缓冲，回显）
  (define UV_TTY_MODE_RAW 1)     ; 原始模式（无缓冲，无回显）
  (define UV_TTY_MODE_IO 2)      ; 原始模式（仅 Windows，用于 IO）

  ;; uv_tty_vtermstate_t
  (define UV_TTY_SUPPORTED 0)    ; 支持虚拟终端
  (define UV_TTY_UNSUPPORTED 1)  ; 不支持虚拟终端

  ;; ========================================
  ;; TTY 初始化
  ;; ========================================

  ;; int uv_tty_init(uv_loop_t* loop, uv_tty_t* tty, uv_file fd, int unused)
  ;; 初始化 TTY 句柄
  ;; fd: 文件描述符（0=stdin, 1=stdout, 2=stderr）
  ;; unused: 不再使用，传 0
  (define-ffi %ffi-uv-tty-init "uv_tty_init" (void* void* int int) int)

  ;; ========================================
  ;; TTY 模式
  ;; ========================================

  ;; int uv_tty_set_mode(uv_tty_t* tty, uv_tty_mode_t mode)
  ;; 设置终端模式
  ;; mode: UV_TTY_MODE_NORMAL, UV_TTY_MODE_RAW, 或 UV_TTY_MODE_IO
  (define-ffi %ffi-uv-tty-set-mode "uv_tty_set_mode" (void* int) int)

  ;; int uv_tty_reset_mode(void)
  ;; 重置所有 TTY 句柄的终端模式
  ;; 用于程序退出前恢复终端状态
  (define-ffi %ffi-uv-tty-reset-mode "uv_tty_reset_mode" () int)

  ;; ========================================
  ;; 窗口大小
  ;; ========================================

  ;; int uv_tty_get_winsize(uv_tty_t* tty, int* width, int* height)
  ;; 获取终端窗口大小（字符数）
  (define-ffi %ffi-uv-tty-get-winsize "uv_tty_get_winsize" (void* void* void*) int)

  ;; ========================================
  ;; 虚拟终端 (Windows)
  ;; ========================================

  ;; void uv_tty_set_vterm_state(uv_tty_vtermstate_t state)
  ;; 设置虚拟终端状态（仅 Windows）
  (define %ffi-uv-tty-set-vterm-state
    (foreign-procedure "uv_tty_set_vterm_state" (int) void))

  ;; int uv_tty_get_vterm_state(uv_tty_vtermstate_t* state)
  ;; 获取虚拟终端状态（仅 Windows）
  (define-ffi %ffi-uv-tty-get-vterm-state "uv_tty_get_vterm_state" (void*) int)

) ; end library
