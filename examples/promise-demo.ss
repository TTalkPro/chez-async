#!/usr/bin/env scheme-script
;;; examples/promise-demo.ss - Promise 使用示例
;;;
;;; 演示 Promise 的基本用法和组合器

(import (chezscheme)
        (chez-async high-level event-loop)
        (chez-async high-level promise)
        (chez-async low-level timer)
        (chez-async low-level handle-base))

(define loop (uv-loop-init))

;; ========================================
;; 示例 1: 基本 Promise
;; ========================================

(display "=== 示例 1: 基本 Promise ===\n")

;; 创建一个延迟完成的 Promise
(define (delay-value loop ms value)
  (make-promise loop
    (lambda (resolve reject)
      (let ([timer (uv-timer-init loop)])
        (uv-timer-start! timer ms 0
          (lambda (t)
            (uv-handle-close! t)
            (resolve value)))))))

;; 使用 then 处理结果
(promise-then (delay-value loop 100 "Hello")
  (lambda (value)
    (display (format "收到: ~a\n" value))))

;; ========================================
;; 示例 2: Promise 链式调用
;; ========================================

(display "\n=== 示例 2: Promise 链式调用 ===\n")

(promise-then
  (promise-then
    (promise-then
      (promise-resolved loop 1)
      (lambda (x)
        (display (format "步骤 1: ~a -> ~a\n" x (+ x 1)))
        (+ x 1)))
    (lambda (x)
      (display (format "步骤 2: ~a -> ~a\n" x (* x 2)))
      (* x 2)))
  (lambda (x)
    (display (format "最终结果: ~a\n" x))))

;; ========================================
;; 示例 3: 错误处理
;; ========================================

(display "\n=== 示例 3: 错误处理 ===\n")

(promise-catch
  (promise-then
    (promise-rejected loop "出错了!")
    (lambda (v)
      (display "这不会执行\n")
      v))
  (lambda (reason)
    (display (format "捕获错误: ~a\n" reason))))

;; ========================================
;; 示例 4: promise-all
;; ========================================

(display "\n=== 示例 4: promise-all ===\n")

(promise-then
  (promise-all
    (list
      (delay-value loop 100 "A")
      (delay-value loop 50 "B")
      (delay-value loop 150 "C")))
  (lambda (values)
    (display (format "所有结果: ~a\n" values))))

;; ========================================
;; 示例 5: promise-race
;; ========================================

(display "\n=== 示例 5: promise-race ===\n")

(promise-then
  (promise-race
    (list
      (delay-value loop 100 "慢")
      (delay-value loop 10 "快")))
  (lambda (winner)
    (display (format "获胜者: ~a\n" winner))))

;; ========================================
;; 示例 6: promise-finally
;; ========================================

(display "\n=== 示例 6: promise-finally ===\n")

(promise-then
  (promise-finally
    (promise-resolved loop "完成")
    (lambda ()
      (display "清理资源...\n")))
  (lambda (v)
    (display (format "值: ~a\n" v))))

;; ========================================
;; 运行事件循环
;; ========================================

(display "\n开始运行事件循环...\n\n")
(uv-run loop 'default)

(display "\n所有 Promise 已完成!\n")
(uv-loop-close loop)
