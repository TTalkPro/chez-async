;;; internal/callback-registry.ss - 统一回调注册表
;;;
;;; 本模块提供统一的回调管理机制，用于：
;;; 1. 集中管理所有延迟初始化的回调
;;; 2. 消除分散在各模块中的全局回调变量
;;; 3. 提供类型安全的回调访问接口
;;;
;;; 设计原则：
;;; - 回调按类型键索引，支持延迟初始化
;;; - 一次注册，全局可用
;;; - 线程安全（Chez Scheme 的 hashtable 是线程安全的）
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
  ;; 内部数据结构
  ;; ========================================

  ;; 回调注册表：类型键 -> (factory . instance)
  ;; factory 是创建回调的 thunk
  ;; instance 是已创建的 foreign-callable（或 #f）
  (define *callback-registry* (make-eq-hashtable))

  ;; ========================================
  ;; 公开接口
  ;; ========================================

  ;; register-lazy-callback!: 注册回调工厂
  ;;
  ;; 参数：
  ;;   callback-key - 回调类型键（如 CALLBACK-TIMER）
  ;;   factory      - 创建回调的 thunk，返回 foreign-callable
  ;;
  ;; 说明：
  ;;   此函数仅注册工厂，实际回调在首次使用时创建
  (define (register-lazy-callback! callback-key factory)
    "注册延迟初始化的回调工厂"
    (hashtable-set! *callback-registry* callback-key (cons factory #f)))

  ;; get-callback-entry-point: 获取回调入口点
  ;;
  ;; 参数：
  ;;   callback-key - 回调类型键
  ;;
  ;; 返回：
  ;;   回调函数的 C 入口点地址
  ;;
  ;; 说明：
  ;;   如果回调尚未创建，会调用工厂创建它
  ;;   如果回调未注册，抛出错误
  (define (get-callback-entry-point callback-key)
    "获取回调入口点（延迟创建）"
    (let ([entry (hashtable-ref *callback-registry* callback-key #f)])
      (unless entry
        (error 'get-callback-entry-point
               "callback not registered" callback-key))
      (let ([factory (car entry)]
            [instance (cdr entry)])
        ;; 如果还没有创建实例，创建它
        (if instance
            (foreign-callable-entry-point instance)
            (let ([new-instance (factory)])
              ;; 更新注册表中的实例
              (hashtable-set! *callback-registry* callback-key
                              (cons factory new-instance))
              (foreign-callable-entry-point new-instance))))))

  ;; callback-registered?: 检查回调是否已注册
  ;;
  ;; 参数：
  ;;   callback-key - 回调类型键
  ;;
  ;; 返回：
  ;;   #t 如果已注册，否则 #f
  (define (callback-registered? callback-key)
    "检查回调是否已注册"
    (hashtable-contains? *callback-registry* callback-key))

) ; end library
