;;; examples/async-await-demo.ss - async/await 简化版演示
;;;
;;; 演示 chez-async 的轻量级 async/await 语法糖用法
;;;
;;; 注意：这个示例使用 async-await-simple（简化版）
;;; 完整功能请参考 async-await-cc-demo.ss
;;;
;;; 目前支持的功能：
;;; 1. 简单的 async 块
;;; 2. await Promise（顶层表达式）
;;; 3. async* 带参数的异步函数
;;;
;;; 限制：
;;; - let/let* 中的 await（需要更复杂的宏展开）
;;; - 多表达式的序列执行
;;; - if/cond/case 等控制结构中的 await

(import (chezscheme)
        (chez-async high-level event-loop)
        (chez-async high-level promise)
        (chez-async high-level async-await-simple))

;; ========================================
;; 示例 1: 简单的 async 块
;; ========================================

(format #t "~%=== 示例 1: 简单的 async 块 ===~%")

(define p1 (async 42))
(format #t "结果: ~a~%" (promise-wait p1))

;; ========================================
;; 示例 2: await Promise
;; ========================================

(format #t "~%=== 示例 2: await Promise ===~%")

(define p2 (async
             (await (promise-resolved 100))))
(format #t "结果: ~a~%" (promise-wait p2))

;; ========================================
;; 示例 3: 带参数的异步函数 (async*)
;; ========================================

(format #t "~%=== 示例 3: 带参数的异步函数 ===~%")

(define fetch-data
  (async* (x)
    (await (promise-resolved (* x 2)))))

(format #t "fetch-data(5) = ~a~%" (promise-wait (fetch-data 5)))

;; ========================================
;; 示例 4: async 块中的表达式计算
;; ========================================

(format #t "~%=== 示例 4: async 块中的表达式计算 ===~%")

(define p4 (async
             (+ 10 20 30)))
(format #t "结果: ~a~%" (promise-wait p4))

;; ========================================
;; 完成
;; ========================================

(format #t "~%=== 所有示例完成 ===~%")
(format #t "~%注意：当前的 async/await 实现是一个基础版本。~%")
(format #t "完整的功能（如 let 绑定中的 await、序列执行等）~%")
(format #t "需要更复杂的宏展开实现，将在后续版本中完善。~%")
