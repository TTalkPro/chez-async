;;; internal/callback-registry.ss - 统一回调注册表
;;;
;;; 本模块提供统一的回调管理机制：
;;;
;;; 1. 注册回调工厂 —— register-lazy-callback! 注册创建回调的 thunk
;;; 2. 获取入口点 —— get-callback-entry-point 延迟创建并返回 C 函数指针
;;; 3. 检查注册状态 —— callback-registered? 查询是否已注册
;;; 4. 回调类型常量 —— 20+ 个 CALLBACK-* 常量，按功能模块分组
;;;
;;; 设计说明：
;;; - 回调按类型键索引，支持延迟初始化（首次获取时创建）
;;; - 注册表封装在闭包中，通过函数接口访问
;;; - 线程安全（Chez Scheme 的 eq-hashtable 操作是原子的）
;;;
;;; 使用方式：
;;;   ;; 在模块顶层注册回调工厂
;;;   (register-lazy-callback! CALLBACK-TIMER
;;;     (lambda ()
;;;       (make-timer-callback ...)))
;;;
;;;   ;; 在需要时获取回调入口点
;;;   (get-callback-entry-point CALLBACK-TIMER)

(library (chez-async internal callback-registry)
  (export
    ;; 注册表操作
    register-lazy-callback!     ; 注册回调工厂
    get-callback-entry-point    ; 获取回调入口点
    callback-registered?        ; 检查回调是否已注册

    ;; 回调类型常量
    ;; 句柄回调
    CALLBACK-CLOSE              ; 关闭回调
    CALLBACK-TIMER              ; 定时器回调
    CALLBACK-ASYNC              ; 异步唤醒回调

    ;; 流回调
    CALLBACK-ALLOC              ; 内存分配回调
    CALLBACK-READ               ; 读取回调
    CALLBACK-WRITE              ; 写入回调
    CALLBACK-SHUTDOWN           ; 关闭流回调
    CALLBACK-CONNECTION         ; 连接监听回调

    ;; TCP 回调
    CALLBACK-CONNECT            ; TCP 连接回调

    ;; DNS 回调
    CALLBACK-GETADDRINFO        ; DNS 解析回调
    CALLBACK-GETNAMEINFO        ; 反向 DNS 回调

    ;; 文件系统回调
    CALLBACK-FS                 ; 通用 FS 回调
    CALLBACK-FS-STAT            ; FS stat 回调
    CALLBACK-FS-SCANDIR         ; FS scandir 回调
    CALLBACK-FS-READLINK        ; FS readlink 回调

    ;; UDP 回调
    CALLBACK-UDP-SEND           ; UDP 发送回调
    CALLBACK-UDP-RECV           ; UDP 接收回调

    ;; Signal 回调
    CALLBACK-SIGNAL             ; 信号处理回调

    ;; Poll 回调
    CALLBACK-POLL               ; 文件描述符轮询回调

    ;; 事件循环钩子回调
    CALLBACK-PREPARE            ; Prepare 回调（I/O 轮询前）
    CALLBACK-CHECK              ; Check 回调（I/O 轮询后）
    CALLBACK-IDLE               ; Idle 回调（空闲时）

    ;; 文件系统监视回调
    CALLBACK-FS-EVENT           ; FS Event 回调
    CALLBACK-FS-POLL            ; FS Poll 回调

    ;; 进程回调
    CALLBACK-PROCESS-EXIT       ; 进程退出回调
    )
  (import (chezscheme))

  ;; ========================================
  ;; 回调类型常量
  ;; ========================================
  ;;
  ;; 使用符号作为类型键，确保唯一性
  ;; 按功能模块分组

  ;; 句柄回调类型
  (define CALLBACK-CLOSE        'close)
  (define CALLBACK-TIMER        'timer)
  (define CALLBACK-ASYNC        'async)

  ;; 流回调类型
  (define CALLBACK-ALLOC        'alloc)
  (define CALLBACK-READ         'read)
  (define CALLBACK-WRITE        'write)
  (define CALLBACK-SHUTDOWN     'shutdown)
  (define CALLBACK-CONNECTION   'connection)

  ;; TCP 回调类型
  (define CALLBACK-CONNECT      'connect)

  ;; DNS 回调类型
  (define CALLBACK-GETADDRINFO  'getaddrinfo)
  (define CALLBACK-GETNAMEINFO  'getnameinfo)

  ;; 文件系统回调类型
  (define CALLBACK-FS           'fs)
  (define CALLBACK-FS-STAT      'fs-stat)
  (define CALLBACK-FS-SCANDIR   'fs-scandir)
  (define CALLBACK-FS-READLINK  'fs-readlink)

  ;; UDP 回调类型
  (define CALLBACK-UDP-SEND     'udp-send)
  (define CALLBACK-UDP-RECV     'udp-recv)

  ;; Signal 回调类型
  (define CALLBACK-SIGNAL       'signal)

  ;; Poll 回调类型
  (define CALLBACK-POLL         'poll)

  ;; 事件循环钩子回调类型
  (define CALLBACK-PREPARE      'prepare)
  (define CALLBACK-CHECK        'check)
  (define CALLBACK-IDLE         'idle)

  ;; 文件系统监视回调类型
  (define CALLBACK-FS-EVENT     'fs-event)
  (define CALLBACK-FS-POLL      'fs-poll)

  ;; 进程回调类型
  (define CALLBACK-PROCESS-EXIT 'process-exit)

  ;; ========================================
  ;; 注册表操作（封装在闭包中）
  ;; ========================================
  ;;
  ;; 回调注册表 hashtable 封装在闭包内部，通过三个函数访问：
  ;; - register-lazy-callback!: 注册工厂
  ;; - get-callback-entry-point: 获取/创建入口点
  ;; - callback-registered?: 查询注册状态
  ;;
  ;; 内部数据结构：类型键 → (factory . instance)
  ;; factory 是创建回调的 thunk，instance 是已创建的 foreign-callable（或 #f）

  (define-values (register-lazy-callback! get-callback-entry-point callback-registered?)
    (let ([registry (make-eq-hashtable)])

      ;; register-lazy-callback!: 注册回调工厂
      ;;
      ;; 参数：
      ;;   callback-key - 回调类型键（如 CALLBACK-TIMER）
      ;;   factory      - 创建回调的 thunk，返回 foreign-callable
      ;;
      ;; 说明：
      ;;   此函数仅注册工厂，实际回调在首次 get-callback-entry-point 时创建。
      (define (register! callback-key factory)
        (hashtable-set! registry callback-key (cons factory #f)))

      ;; get-callback-entry-point: 获取回调入口点
      ;;
      ;; 参数：
      ;;   callback-key - 回调类型键
      ;;
      ;; 返回：
      ;;   回调函数的 C 入口点地址（foreign-callable-entry-point）
      ;;
      ;; 说明：
      ;;   如果回调尚未创建，调用工厂创建它并缓存。
      ;;   如果回调未注册，抛出错误。
      (define (get-entry-point callback-key)
        (let ([entry (hashtable-ref registry callback-key #f)])
          (unless entry
            (error 'get-callback-entry-point
                   "callback not registered" callback-key))
          (let ([factory (car entry)]
                [instance (cdr entry)])
            (if instance
                (foreign-callable-entry-point instance)
                (let ([new-instance (factory)])
                  (hashtable-set! registry callback-key
                                  (cons factory new-instance))
                  (foreign-callable-entry-point new-instance))))))

      ;; callback-registered?: 检查回调是否已注册
      ;;
      ;; 参数：
      ;;   callback-key - 回调类型键
      ;;
      ;; 返回：
      ;;   #t 如果已注册，否则 #f
      (define (registered? callback-key)
        (hashtable-contains? registry callback-key))

      (values register! get-entry-point registered?)))

) ; end library
