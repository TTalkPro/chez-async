;;; high-level/async-await.ss - async/await 语法糖
;;;
;;; 提供 async/await 语法糖，简化异步代码编写

(library (chez-async high-level async-await)
  (export
    async
    await
    async*
    async-run)

  (import (chezscheme)
          (chez-async high-level promise)
          (chez-async high-level event-loop)
          (chez-async high-level async-work))

  ;; ========================================
  ;; await - 等待 Promise 完成的标记
  ;; ========================================
  ;;
  ;; await 必须在 async 块内使用
  ;; 它实际上是一个语法标记，由 async 宏处理

  (define-syntax await
    (syntax-rules ()
      [(await expr)
       #'expr]))

  ;; ========================================
  ;; async - 创建异步块
  ;; ========================================
  ;;
  ;; async 块会扫描其中的 await 表达式，并将它们转换为 Promise 链

  (define-syntax async
    (syntax-rules ()
      ;; Simple await - just return the promise
      [(_ (await expr))
       expr]
      ;; Multiple expressions in sequence
      [(_ expr1 expr2 expr3 ...)
       (make-promise
         (lambda (resolve reject)
           (let ([result (async expr1)])
             (promise-then result
               (lambda (_)
                 (let ([r2 (async expr2 expr3 ...)])
                   (promise-then r2
                     (lambda (v) (resolve v)))))))))]
      ;; Single expression - wrap in promise
      [(_ expr)
       (make-promise
         (lambda (resolve reject)
           (guard (e [else (reject e)])
             (resolve expr))))]))

  ;; ========================================
  ;; async* - 带参数的异步函数（语法糖）
  ;; ========================================

  (define-syntax async*
    (syntax-rules ()
      [(_ (args ...) body ...)
       (lambda (args ...)
         (async body ...))]))

  ;; ========================================
  ;; 高级 async 实用函数
  ;; ========================================

  (define (async-run thunk)
    "运行异步 thunk，返回 Promise

     thunk: 无参数函数，包含异步操作"
    (make-promise
      (lambda (resolve reject)
        ;; 在后台任务中执行
        (async-work (uv-default-loop)
          thunk
          (lambda (result)
            (resolve result))
          (lambda (err)
            (reject err))))))

  ) ; end library
