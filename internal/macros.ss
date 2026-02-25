;;; internal/macros.ss - 通用宏定义
;;;
;;; 本模块提供减少代码重复的宏工具：
;;; - FFI 绑定宏
;;; - 错误处理宏
;;; - 资源管理宏
;;; - 回调工厂宏（使用统一注册表）
;;; - 请求操作宏
;;; - 句柄操作宏（新增）
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
    define-handle-size-fn    ; 新增：句柄大小函数宏

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

    ;; 句柄操作宏（新增）
    define-handle-init       ; 句柄初始化宏
    define-handle-start!     ; 句柄启动宏
    define-handle-stop!      ; 句柄停止宏
    call-user-callback-with-error  ; 错误回调辅助宏

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
  ;; 句柄大小函数宏（新增）
  ;; ========================================
  ;;
  ;; define-handle-size-fn: 生成句柄大小查询函数
  ;;
  ;; 消除 ffi/handles.ss 中 14 个相似的大小查询函数
  ;;
  ;; 用法：
  ;;   (define-handle-size-fn %ffi-uv-timer-size timer)
  ;;
  ;; 展开为：
  ;;   (define (%ffi-uv-timer-size)
  ;;     "获取 uv_timer_t 结构大小"
  ;;     (%ffi-uv-handle-size (uv-handle-type->int 'timer)))

  (define-syntax define-handle-size-fn
    (syntax-rules ()
      [(_ fn-name type-symbol handle-size-fn type->int-fn)
       (define (fn-name)
         (handle-size-fn (type->int-fn 'type-symbol)))]))

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
  ;; 句柄操作宏（新增）
  ;; ========================================
  ;;
  ;; 这些宏用于减少 low-level 模块中的重复代码模式

  ;; define-handle-init: 句柄初始化宏
  ;;
  ;; 消除重复的句柄初始化模式（~50 实例）
  ;;
  ;; 用法：
  ;;   (define-handle-init init-name handle-type size-fn ffi-init-fn)
  ;;
  ;; 展开为标准的句柄初始化函数：
  ;;   (define (init-name loop)
  ;;     (let* ([size (size-fn)]
  ;;            [ptr (allocate-handle size)]
  ;;            [loop-ptr (uv-loop-ptr loop)])
  ;;       (with-uv-check/cleanup init-name
  ;;         (ffi-init-fn loop-ptr ptr)
  ;;         (lambda () (foreign-free ptr)))
  ;;       (make-handle ptr 'handle-type loop)))
  ;;
  ;; 示例：
  ;;   (define-handle-init uv-timer-init timer
  ;;     %ffi-uv-timer-size %ffi-uv-timer-init)

  (define-syntax define-handle-init
    (syntax-rules ()
      [(_ init-name handle-type size-fn ffi-init-fn
          uv-loop-ptr-fn allocate-fn make-handle-fn)
       (define (init-name loop)
         (let* ([size (size-fn)]
                [ptr (allocate-fn size)]
                [loop-ptr (uv-loop-ptr-fn loop)])
           (with-uv-check/cleanup init-name
             (ffi-init-fn loop-ptr ptr)
             (lambda () (foreign-free ptr)))
           (make-handle-fn ptr 'handle-type loop)))]))

  ;; define-handle-start!: 句柄启动宏
  ;;
  ;; 标准化句柄启动模式（~30 实例）
  ;;
  ;; 用法：
  ;;   (define-handle-start! start!-name ffi-start-fn callback-getter
  ;;     handle-ptr-fn handle-data-fn handle-data-set-fn handle-closed?-fn)
  ;;
  ;; 展开为标准的句柄启动函数，支持可变参数
  ;;
  ;; 示例：
  ;;   (define-handle-start! uv-timer-start! %ffi-uv-timer-start get-timer-callback
  ;;     handle-ptr handle-data handle-data-set! handle-closed?)

  (define-syntax define-handle-start!
    (syntax-rules ()
      [(_ start!-name ffi-start-fn callback-getter
          handle-ptr-fn handle-data-fn handle-data-set-fn handle-closed?-fn)
       (define (start!-name handle callback . args)
         (when (handle-closed?-fn handle)
           (error 'start!-name "handle is closed"))
         ;; 释放旧回调
         (let ([old-data (handle-data-fn handle)])
           (when old-data (unlock-object old-data)))
         ;; 保存用户回调
         (handle-data-set-fn handle callback)
         (lock-object callback)
         ;; 启动句柄
         (with-uv-check start!-name
           (apply ffi-start-fn
                  (handle-ptr-fn handle)
                  (callback-getter)
                  args)))]))

  ;; define-handle-stop!: 句柄停止宏
  ;;
  ;; 标准化句柄停止和清理模式
  ;;
  ;; 用法：
  ;;   (define-handle-stop! stop!-name ffi-stop-fn
  ;;     handle-ptr-fn handle-data-fn handle-data-set-fn handle-closed?-fn)
  ;;
  ;; 展开为标准的句柄停止函数，包含回调清理
  ;;
  ;; 示例：
  ;;   (define-handle-stop! uv-timer-stop! %ffi-uv-timer-stop
  ;;     handle-ptr handle-data handle-data-set! handle-closed?)

  (define-syntax define-handle-stop!
    (syntax-rules ()
      [(_ stop!-name ffi-stop-fn
          handle-ptr-fn handle-data-fn handle-data-set-fn handle-closed?-fn)
       (define (stop!-name handle)
         (when (handle-closed?-fn handle)
           (error 'stop!-name "handle is closed"))
         (with-uv-check stop!-name
           (ffi-stop-fn (handle-ptr-fn handle))))]))

  ;; call-user-callback-with-error: 错误回调辅助宏
  ;;
  ;; 统一回调错误处理模式（~40 实例）
  ;;
  ;; 用法：
  ;;   (call-user-callback-with-error callback status operation-name)
  ;;   (call-user-callback-with-error callback status operation-name extra-arg)
  ;;
  ;; 展开为带错误检查的回调调用：
  ;;   当 status < 0 时，调用 callback 并传递错误对象
  ;;   当 status >= 0 时，调用 callback 并传递 #f 表示无错误

  (define-syntax call-user-callback-with-error
    (syntax-rules ()
      ;; 单参数版本：callback 只接收错误或 #f
      [(_ callback status operation-name err-name-fn make-error-fn)
       (when callback
         (if (< status 0)
             (callback (make-error-fn status (err-name-fn status) 'operation-name))
             (callback #f)))]
      ;; 双参数版本：callback 接收额外参数和错误或 #f
      [(_ callback status operation-name extra-arg err-name-fn make-error-fn)
       (when callback
         (if (< status 0)
             (callback extra-arg (make-error-fn status (err-name-fn status) 'operation-name))
             (callback extra-arg #f)))]))


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
