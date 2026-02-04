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
  ;; OpenBSD 特殊处理
  ;; ========================================
  ;;
  ;; OpenBSD 上 libuv.so.5.2 依赖 __stderr 符号，
  ;; 但 Chez Scheme 加载共享库时无法解析该符号。
  ;; 这是 Chez Scheme 动态加载的限制，不是 libuv 的问题。
  ;; 尝试多个版本，返回第一个能加载的。

  (define (try-load-libuv-openbsd)
    "尝试加载 OpenBSD 上的 libuv 库，按优先级尝试多个版本"
    (let ([candidates '("/usr/local/lib/libuv.so.5.2"
                        "/usr/local/lib/libuv.so.4.2"
                        "/usr/local/lib/libuv.so"
                        "libuv.so")])
      (let loop ([libs candidates])
        (if (null? libs)
            ;; 全部失败，返回默认名称让后续报错
            "/usr/local/lib/libuv.so"
            (guard (e [else (loop (cdr libs))])
              ;; 尝试加载，成功则返回该库名
              (load-shared-object (car libs))
              (car libs))))))

  ;; ========================================
  ;; 平台相关的库名称
  ;; ========================================

  (define libuv-library-name
    (case (machine-type)
      ;; Linux
      [(i3le ti3le a6le ta6le arm32le arm64le ppc32le ppc64le)
       "libuv.so.1"]
      ;; macOS
      [(i3osx ti3osx a6osx ta6osx arm64osx tarm64osx)
       "libuv.1.dylib"]
      ;; Windows
      [(i3nt ti3nt a6nt ta6nt)
       "uv.dll"]
      ;; FreeBSD
      [(i3fb ti3fb a6fb ta6fb)
       "libuv.so.1"]
      ;; OpenBSD (uses major.minor versioning like libuv.so.5.2)
      ;; 注意：libuv.so.5.2 依赖 __stderr 符号，Chez Scheme 加载时无法解析
      ;; 这是 Chez Scheme 在 OpenBSD 上的限制，使用旧版本作为后备
      [(i3ob ti3ob a6ob ta6ob arm64ob tarm64ob)
       (try-load-libuv-openbsd)]
      ;; NetBSD
      [(i3nb ti3nb a6nb ta6nb)
       "libuv.so"]
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
