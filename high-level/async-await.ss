;;; high-level/async-await.ss - async/await 默认实现
;;;
;;; 默认导出基于 call/cc 的完整 async/await 实现
;;;
;;; 这个文件作为默认入口，导出 async-await-cc 的所有功能。
;;; 用户可以简单地导入 (chez-async high-level async-await) 获得
;;; 完整的协程功能。
;;;
;;; 可选导入：
;;; - (chez-async high-level async-await)        - 默认（本文件，指向 async-await-cc）
;;; - (chez-async high-level async-await-cc)     - 完整实现（显式导入）
;;; - (chez-async high-level async-await-simple) - 轻量级实现（Promise 宏）

(library (chez-async high-level async-await)
  (export
    ;; 核心宏
    async
    await
    async*

    ;; 运行函数
    run-async
    run-async-loop

    ;; 工具函数
    async-value
    async-error)

  ;; 直接导出 async-await-cc 的所有内容
  (import (chez-async high-level async-await-cc)))
