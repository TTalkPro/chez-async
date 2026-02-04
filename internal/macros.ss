;;; internal/macros.ss - 通用宏定义
;;;
;;; 本模块提供减少代码重复的宏工具：
;;; - FFI 绑定宏
;;; - 错误处理宏
;;; - 资源管理宏
;;; - 回调工厂宏（使用统一注册表）
;;; - 请求操作宏
;;;
;;; 设计原则：
;;; 1. 宏应该简化常见模式，而不是隐藏复杂性
;;; 2. 错误信息应该清晰明确
;;; 3. 资源管理应该自动化

(library (chez-async internal macros)
  (export
    ;; FFI 绑定宏
    define-ffi
    define-ffi-size

    ;; 错误处理宏
    with-uv-check
    with-uv-check/cleanup

    ;; 资源管理宏
    with-locked
    with-locked*
    with-resource

    ;; 回调宏
    define-c-callback
    define-registered-callback

    ;; 请求操作宏
    with-uv-request

    ;; 同步操作宏
    define-sync-wrapper
    )
  (import (chezscheme)
          (chez-async ffi errors)
          (chez-async internal callback-registry))

  ;; ========================================
  ;; FFI 绑定宏
  ;; ========================================
  ;;
  ;; define-ffi: 定义外部函数绑定
  ;;
  ;; 用法：
  ;;   (define-ffi name "c_function_name" (arg-types ...) return-type)
  ;;
  ;; 示例：
  ;;   (define-ffi %ffi-uv-loop-init "uv_loop_init" (void*) int)

  (define-syntax define-ffi
    (syntax-rules ()
      [(_ name c-name arg-types return-type)
       (define name
         (foreign-procedure c-name arg-types return-type))]
      [(_ name c-name arg-types return-type doc)
       (begin
         (define name
           (foreign-procedure c-name arg-types return-type))
         (void))]))

  ;; define-ffi-size: 定义大小查询函数
  ;;
  ;; 用于获取 libuv 结构体的大小
  ;;
  ;; 用法：
  ;;   (define-ffi-size name "uv_size_function")

  (define-syntax define-ffi-size
    (syntax-rules ()
      [(_ name c-name)
       (define (name)
         ((foreign-procedure c-name () size_t)))]))

  ;; ========================================
  ;; 错误处理宏
  ;; ========================================
  ;;
  ;; with-uv-check: 检查 libuv 返回值
  ;;
  ;; 如果返回值 < 0，抛出 &uv-error 异常
  ;;
  ;; 用法：
  ;;   (with-uv-check operation-name expr)
  ;;
  ;; 示例：
  ;;   (with-uv-check uv-loop-init
  ;;     (%ffi-uv-loop-init ptr))

  (define-syntax with-uv-check
    (syntax-rules ()
      [(_ who expr)
       (check-uv-result expr 'who)]))

  ;; with-uv-check/cleanup: 检查返回值，出错时执行清理
  ;;
  ;; 用法：
  ;;   (with-uv-check/cleanup operation-name expr cleanup-thunk)

  (define-syntax with-uv-check/cleanup
    (syntax-rules ()
      [(_ who expr cleanup)
       (check-uv-result/cleanup expr 'who cleanup)]))

  ;; ========================================
  ;; 资源管理宏
  ;; ========================================
  ;;
  ;; with-locked: 在持有对象锁的情况下执行代码
  ;;
  ;; 防止 GC 回收被 C 代码引用的 Scheme 对象
  ;;
  ;; 用法：
  ;;   (with-locked obj
  ;;     body ...)

  (define-syntax with-locked
    (syntax-rules ()
      [(_ obj body ...)
       (dynamic-wind
         (lambda () (lock-object obj))
         (lambda () body ...)
         (lambda () (unlock-object obj)))]))

  ;; with-locked*: 同时锁定多个对象
  ;;
  ;; 用法：
  ;;   (with-locked* (obj1 obj2 obj3)
  ;;     body ...)

  (define-syntax with-locked*
    (syntax-rules ()
      [(_ (obj ...) body ...)
       (dynamic-wind
         (lambda () (begin (lock-object obj) ...))
         (lambda () body ...)
         (lambda () (begin (unlock-object obj) ...)))]))

  ;; with-resource: 资源获取与自动释放
  ;;
  ;; 类似于其他语言的 try-with-resources 或 RAII
  ;;
  ;; 用法：
  ;;   (with-resource (var init-expr) body ... cleanup-expr)
  ;;
  ;; 示例：
  ;;   (with-resource (ptr (foreign-alloc 100))
  ;;     (do-something ptr)
  ;;     (foreign-free ptr))

  (define-syntax with-resource
    (syntax-rules ()
      [(_ (var init-expr) body ... cleanup-expr)
       (let ([var init-expr])
         (guard (e [else (begin cleanup-expr (raise e))])
           (let ([result (begin body ...)])
             cleanup-expr
             result)))]))

  ;; ========================================
  ;; 回调宏
  ;; ========================================
  ;;
  ;; define-c-callback: 定义 C 回调函数
  ;;
  ;; 将 Scheme 过程包装为可被 C 代码调用的函数指针
  ;;
  ;; 用法：
  ;;   (define-c-callback name signature scheme-proc)

  (define-syntax define-c-callback
    (syntax-rules ()
      [(_ name signature scheme-proc)
       (define name
         (foreign-callable scheme-proc signature void))]))

  ;; define-registered-callback: 定义并注册到统一注册表的回调
  ;;
  ;; 这是推荐的新模式，回调存储在统一注册表中
  ;; 支持全局访问和集中管理
  ;;
  ;; 用法：
  ;;   (define-registered-callback getter-name callback-key factory-thunk)
  ;;
  ;; 参数：
  ;;   getter-name  - 获取回调入口点的函数名
  ;;   callback-key - 注册表中的键（如 CALLBACK-TIMER）
  ;;   factory-thunk - 创建回调的 thunk，返回 foreign-callable
  ;;
  ;; 工作原理：
  ;;   回调工厂在首次调用 getter 时注册（如果尚未注册）
  ;;   这避免了库加载顺序问题
  ;;
  ;; 示例：
  ;;   (define-registered-callback get-timer-callback CALLBACK-TIMER
  ;;     (lambda ()
  ;;       (make-timer-callback
  ;;         (lambda (wrapper) ...))))

  (define-syntax define-registered-callback
    (syntax-rules ()
      [(_ getter-name callback-key factory-thunk)
       (define (getter-name)
         ;; 首次调用时注册（如果尚未注册）
         (unless (callback-registered? callback-key)
           (register-lazy-callback! callback-key factory-thunk))
         ;; 获取回调入口点
         (get-callback-entry-point callback-key))]))


  ;; ========================================
  ;; 请求操作宏
  ;; ========================================
  ;;
  ;; with-uv-request: 分配请求、执行操作、处理错误
  ;;
  ;; 这是异步操作中最常见的模式，用于：
  ;; - DNS 解析
  ;; - 文件系统操作
  ;; - TCP 连接
  ;;
  ;; 用法：
  ;;   (with-uv-request (req req-type callback data size-fn)
  ;;     operation-expr ...)
  ;;
  ;; 参数：
  ;;   req      - 请求变量名
  ;;   req-type - 请求类型符号（如 'fs, 'getaddrinfo）
  ;;   callback - 用户回调函数
  ;;   data     - 附加数据（可以是 #f）
  ;;   size-fn  - 返回请求大小的函数
  ;;
  ;; 展开为：
  ;;   (let* ([req-size (size-fn)]
  ;;          [req-ptr (allocate-request req-size)]
  ;;          [req-wrapper (make-uv-request-wrapper ...)])
  ;;     (let ([result (begin operation-expr ...)])
  ;;       (when (< result 0)
  ;;         (cleanup-request-wrapper! req-wrapper)
  ;;         (raise-uv-error result 'operation))))

  (define-syntax with-uv-request
    (syntax-rules ()
      [(_ (req req-type callback data size-fn operation-name)
          body ...)
       (let* ([req-size (size-fn)]
              [req-ptr (allocate-request req-size)]
              [req-wrapper (make-uv-request-wrapper req-ptr req-type callback data)])
         (let ([result (begin body ...)])
           (when (< result 0)
             (cleanup-request-wrapper! req-wrapper)
             (raise-uv-error result 'operation-name))))]))

  ;; ========================================
  ;; 同步操作宏
  ;; ========================================
  ;;
  ;; define-sync-wrapper: 为异步操作生成同步版本
  ;;
  ;; 用法：
  ;;   (define-sync-wrapper sync-name async-fn)
  ;;
  ;; 生成的同步函数会：
  ;; 1. 调用异步函数
  ;; 2. 运行事件循环直到操作完成
  ;; 3. 返回结果或抛出错误
  ;;
  ;; 注意：这个宏假设异步函数的最后一个参数是回调函数

  (define-syntax define-sync-wrapper
    (syntax-rules ()
      [(_ sync-name async-fn)
       (define (sync-name loop . args)
         (let ([result #f]
               [error #f]
               [done #f])
           ;; 调用异步函数，添加回调
           (apply async-fn
                  (append (list loop)
                          args
                          (list (lambda (r e)
                                  (set! result r)
                                  (set! error e)
                                  (set! done #t)))))
           ;; 运行事件循环直到完成
           (let loop-run ()
             (unless done
               (uv-run loop 'once)
               (loop-run)))
           ;; 返回结果或抛出错误
           (if error
               (raise error)
               result)))]))

) ; end library
