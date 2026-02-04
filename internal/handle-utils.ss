;;; internal/handle-utils.ss - 句柄操作工具
;;;
;;; 本模块提供句柄操作的通用工具，减少 low-level 模块中的重复代码：
;;;
;;; 1. 句柄状态检查宏
;;;    - check-handle-not-closed!: 检查句柄未关闭，否则报错
;;;    - with-handle-check: 检查句柄后执行操作
;;;
;;; 使用示例：
;;;   ;; 检查句柄状态
;;;   (check-handle-not-closed! uv-timer-start! timer)
;;;
;;;   ;; 带检查的操作
;;;   (with-handle-check timer uv-timer-stop!
;;;     (%ffi-uv-timer-stop (handle-ptr timer)))

(library (chez-async internal handle-utils)
  (export
    ;; 句柄状态检查
    check-handle-not-closed!
    with-handle-check
    )
  (import (chezscheme)
          (chez-async low-level handle-base))

  ;; ========================================
  ;; 句柄状态检查
  ;; ========================================
  ;;
  ;; 这些宏用于统一处理"句柄已关闭"的错误检查模式。
  ;; 在 60+ 处代码中存在类似的检查，使用这些宏可以：
  ;; - 减少代码重复
  ;; - 统一错误消息格式
  ;; - 提高可维护性

  ;; check-handle-not-closed!: 检查句柄未关闭
  ;;
  ;; 用法：
  ;;   (check-handle-not-closed! operation-name handle)
  ;;
  ;; 展开为：
  ;;   (when (handle-closed? handle)
  ;;     (error 'operation-name "handle is closed"))
  ;;
  ;; 如果句柄已关闭，抛出带有操作名的错误
  (define-syntax check-handle-not-closed!
    (syntax-rules ()
      [(_ op-name handle)
       (when (handle-closed? handle)
         (error 'op-name "handle is closed"))]))

  ;; with-handle-check: 检查句柄后执行操作
  ;;
  ;; 用法：
  ;;   (with-handle-check handle op-name body ...)
  ;;
  ;; 展开为：
  ;;   (begin
  ;;     (check-handle-not-closed! op-name handle)
  ;;     body ...)
  ;;
  ;; 先检查句柄未关闭，然后执行 body 表达式
  ;; 返回 body 的最后一个表达式的值
  (define-syntax with-handle-check
    (syntax-rules ()
      [(_ handle op-name body ...)
       (begin
         (check-handle-not-closed! op-name handle)
         body ...)]))

) ; end library
