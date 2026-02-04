;;; ffi/lib.ss - libuv 共享库加载
;;;
;;; 本模块提供 libuv 共享库的统一加载入口。
;;; 所有需要调用 libuv FFI 的模块都应导入此模块，
;;; 确保库被加载。
;;;
;;; 设计说明：
;;; - Chez Scheme 的 load-shared-object 对同一库多次调用是安全的
;;; - 但集中管理可以：
;;;   1. 方便未来支持不同平台的库名称
;;;   2. 提供统一的错误处理
;;;   3. 避免代码重复
;;;
;;; 注意：由于 Chez Scheme 库系统的限制，仅导入此模块
;;; 可能不足以使 FFI 符号在所有上下文中可用。
;;; 其他 FFI 模块应同时使用 load-libuv 宏来确保加载。

(library (chez-async ffi lib)
  (export
    ;; 库信息
    libuv-loaded?
    libuv-library-name
    ;; 加载函数（供其他模块调用）
    ensure-libuv-loaded)
  (import (chezscheme))

  ;; ========================================
  ;; 平台相关的库名称
  ;; ========================================

  (define libuv-library-name
    (case (machine-type)
      ;; Linux
      [(i3le ti3le a6le ta6le arm32le arm64le ppc32le ppc64le)
       "libuv.so.1"]
      ;; macOS
      [(i3osx ti3osx a6osx ta6osx arm64osx)
       "libuv.1.dylib"]
      ;; Windows
      [(i3nt ti3nt a6nt ta6nt)
       "uv.dll"]
      ;; FreeBSD
      [(i3fb ti3fb a6fb ta6fb)
       "libuv.so.1"]
      ;; 默认尝试 Linux 风格
      [else "libuv.so.1"]))

  ;; ========================================
  ;; 加载共享库
  ;; ========================================

  ;; 确保 libuv 已加载的函数
  ;; 可以安全地多次调用
  (define (ensure-libuv-loaded)
    (load-shared-object libuv-library-name))

  ;; 首次加载
  (define libuv-lib (ensure-libuv-loaded))

  ;; 加载状态标志
  (define libuv-loaded? #t)

) ; end library
