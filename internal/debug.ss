;;; internal/debug.ss - 调试与追踪工具
;;;
;;; 本模块提供条件化的调试日志和函数追踪功能：
;;;
;;; - debug-enabled?: 全局开关参数，默认关闭
;;; - debug-log: 仅在 debug-enabled? 为 #t 时输出日志到 stderr
;;; - trace-call: 追踪函数调用的进入和退出（宏）
;;;
;;; 使用示例：
;;;   ;; 启用调试
;;;   (debug-enabled? #t)
;;;
;;;   ;; 输出调试日志
;;;   (debug-log "connecting to ~a:~a" host port)
;;;
;;;   ;; 追踪函数执行
;;;   (trace-call my-function
;;;     (do-something))

(library (chez-async internal debug)
  (export
    debug-enabled?            ; parameter: 调试开关，默认 #f
    debug-log                 ; (fmt arg ...) → void（输出到 stderr）
    trace-call                ; (trace-call name expr) — 追踪进入/退出
    )
  (import (chezscheme))

  ;; ========================================
  ;; 调试开关
  ;; ========================================

  ;; debug-enabled?: 控制 debug-log 和 trace-call 是否产生输出
  ;;
  ;; 用法：
  ;;   (debug-enabled? #t)   ; 启用
  ;;   (debug-enabled? #f)   ; 禁用（默认）
  ;;   (debug-enabled?)      ; 查询当前状态
  (define debug-enabled? (make-parameter #f))

  ;; ========================================
  ;; 调试日志
  ;; ========================================

  ;; debug-log: 条件调试日志输出
  ;;
  ;; 参数：
  ;;   fmt  - format 格式字符串（同 fprintf）
  ;;   args - 格式参数
  ;;
  ;; 说明：
  ;;   仅当 (debug-enabled?) 为 #t 时输出到 current-error-port，
  ;;   自动追加换行符。生产环境中零开销（参数不求值除外）。
  (define (debug-log fmt . args)
    (when (debug-enabled?)
      (apply fprintf (current-error-port) fmt args)
      (newline (current-error-port))))

  ;; ========================================
  ;; 函数追踪
  ;; ========================================

  ;; trace-call: 追踪表达式的进入和退出
  ;;
  ;; 用法：
  ;;   (trace-call operation-name
  ;;     (some-expression))
  ;;
  ;; 展开为：
  ;;   (begin
  ;;     (debug-log "[TRACE] operation-name: enter")
  ;;     (let ([result (some-expression)])
  ;;       (debug-log "[TRACE] operation-name: exit -> ~s" result)
  ;;       result))
  ;;
  ;; 说明：
  ;;   依赖 debug-enabled? 开关，关闭时仅有最小开销。
  (define-syntax trace-call
    (syntax-rules ()
      [(trace-call name expr)
       (begin
         (debug-log "[TRACE] ~a: enter" 'name)
         (let ([result expr])
           (debug-log "[TRACE] ~a: exit -> ~s" 'name result)
           result))]))

) ; end library
