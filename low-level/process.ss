;;; low-level/process.ss - 进程管理低层封装
;;;
;;; 提供进程启动和管理的高层封装
;;;
;;; 设计说明：
;;; - uv_process_options_t 结构较复杂，需要手动构建
;;; - 支持 stdio 重定向到管道
;;; - 进程退出时自动清理资源

(library (chez-async low-level process)
  (export
    ;; 进程创建
    uv-spawn

    ;; 进程操作
    uv-process-kill!
    uv-process-get-pid

    ;; 全局进程函数
    uv-kill

    ;; 常量导出
    UV_PROCESS_SETUID
    UV_PROCESS_SETGID
    UV_PROCESS_DETACHED
    UV_PROCESS_WINDOWS_HIDE

    ;; stdio 标志
    UV_IGNORE
    UV_CREATE_PIPE
    UV_INHERIT_FD
    UV_INHERIT_STREAM
    UV_READABLE_PIPE
    UV_WRITABLE_PIPE

    ;; 辅助函数
    make-process-options
    free-process-options
    )
  (import (chezscheme)
          (chez-async ffi types)
          (chez-async ffi errors)
          (chez-async ffi handles)
          (chez-async ffi process)
          (chez-async ffi callbacks)
          (chez-async low-level handle-base)
          (chez-async low-level pipe)
          (chez-async high-level event-loop)
          (chez-async internal macros)
          (chez-async internal callback-registry)
          (chez-async internal utils))

  ;; ========================================
  ;; 进程退出回调
  ;; ========================================

  ;; 注册进程退出回调类型（如果尚未定义）
  ;; void (*uv_exit_cb)(uv_process_t* handle, int64_t exit_status, int term_signal)

  (define (make-exit-callback scheme-proc)
    "创建进程退出回调"
    (let ([wrapper
           (foreign-callable
             (lambda (handle-ptr exit-status term-signal)
               (guard (e [else (handle-callback-error e)])
                 (let ([wrapper (ptr->wrapper handle-ptr)])
                   (when wrapper
                     (scheme-proc wrapper exit-status term-signal)))))
             (void* integer-64 int) void)])
      (register-c-callback! (cons scheme-proc 'exit) wrapper)
      wrapper))

  ;; 全局退出回调
  (define *exit-callback* #f)

  (define (get-exit-callback)
    "获取全局退出回调（延迟创建）"
    (unless *exit-callback*
      (set! *exit-callback*
        (make-exit-callback
          (lambda (wrapper exit-status term-signal)
            (let ([user-callback (handle-data wrapper)])
              ;; 调用用户回调
              (when (and user-callback (procedure? user-callback))
                (user-callback wrapper exit-status term-signal))
              ;; 进程结束后自动关闭句柄
              (uv-handle-close! wrapper))))))
    (foreign-callable-entry-point *exit-callback*))

  ;; ========================================
  ;; 进程选项构建
  ;; ========================================

  ;; uv_process_options_t 结构布局（64位系统）:
  ;; offset 0:  exit_cb (void*)
  ;; offset 8:  file (char*)
  ;; offset 16: args (char**)
  ;; offset 24: env (char**)
  ;; offset 32: cwd (char*)
  ;; offset 40: flags (unsigned int)
  ;; offset 44: padding
  ;; offset 48: stdio_count (int)
  ;; offset 52: padding
  ;; offset 56: stdio (uv_stdio_container_t*)
  ;; offset 64: uid (uv_uid_t)
  ;; offset 68: gid (uv_gid_t)

  (define (string->c-string str)
    "将 Scheme 字符串转换为 C 字符串（malloc 分配）"
    (let* ([bv (string->utf8 str)]
           [len (bytevector-length bv)]
           [ptr (foreign-alloc (+ len 1))])
      (do ([i 0 (+ i 1)])
          ((= i len))
        (foreign-set! 'unsigned-8 ptr i (bytevector-u8-ref bv i)))
      (foreign-set! 'unsigned-8 ptr len 0)  ; null terminator
      ptr))

  (define (strings->c-string-array strs)
    "将字符串列表转换为 C 字符串数组（NULL 结尾）"
    (let* ([count (length strs)]
           [array-ptr (foreign-alloc (* (+ count 1) (foreign-sizeof 'void*)))]
           [c-strings (map string->c-string strs)])
      ;; 填充数组
      (let loop ([i 0] [strs c-strings])
        (if (null? strs)
            (foreign-set! 'void* array-ptr (* i (foreign-sizeof 'void*)) 0)
            (begin
              (foreign-set! 'void* array-ptr (* i (foreign-sizeof 'void*)) (car strs))
              (loop (+ i 1) (cdr strs)))))
      (cons array-ptr c-strings)))

  (define make-process-options
    (case-lambda
      [(file args)
       (make-process-options file args #f #f 0 0 0)]
      [(file args cwd)
       (make-process-options file args cwd #f 0 0 0)]
      [(file args cwd env)
       (make-process-options file args cwd env 0 0 0)]
      [(file args cwd env flags)
       (make-process-options file args cwd env flags 0 0)]
      [(file args cwd env flags uid gid)
       "创建进程选项结构
        file: 可执行文件路径
        args: 参数列表（第一个应该是程序名）
        cwd: 工作目录（可选）
        env: 环境变量列表（可选，格式 '(\"KEY=VALUE\" ...)）
        flags: 进程标志（可选）
        uid/gid: 用户/组 ID（需要 UV_PROCESS_SETUID/GID 标志）
        返回: (options-ptr . cleanup-data)"
    (let* ([opts-size (%ffi-uv-process-options-size)]
           [opts-ptr (allocate-zeroed opts-size)]
           [file-ptr (string->c-string file)]
           [args-data (strings->c-string-array (cons file args))]
           [args-ptr (car args-data)]
           [args-strings (cdr args-data)]
           [cwd-ptr (if cwd (string->c-string cwd) 0)]
           [env-data (if env (strings->c-string-array env) (cons 0 '()))]
           [env-ptr (car env-data)]
           [env-strings (cdr env-data)])
      ;; 设置结构体字段
      ;; exit_cb 将在 spawn 时设置
      (foreign-set! 'void* opts-ptr 0 0)  ; exit_cb (后设置)
      (foreign-set! 'void* opts-ptr 8 file-ptr)
      (foreign-set! 'void* opts-ptr 16 args-ptr)
      (foreign-set! 'void* opts-ptr 24 env-ptr)
      (foreign-set! 'void* opts-ptr 32 cwd-ptr)
      (foreign-set! 'unsigned-32 opts-ptr 40 flags)
      (foreign-set! 'int opts-ptr 48 0)  ; stdio_count (默认 0)
      (foreign-set! 'void* opts-ptr 56 0)  ; stdio (默认 NULL)
      (foreign-set! 'unsigned-32 opts-ptr 64 uid)
      (foreign-set! 'unsigned-32 opts-ptr 68 gid)
      ;; 返回选项指针和需要释放的数据
      (list opts-ptr
            file-ptr
            args-ptr args-strings
            cwd-ptr
            env-ptr env-strings))]))

  (define (free-process-options opts-data)
    "释放进程选项结构及相关内存"
    (let ([opts-ptr (list-ref opts-data 0)]
          [file-ptr (list-ref opts-data 1)]
          [args-ptr (list-ref opts-data 2)]
          [args-strings (list-ref opts-data 3)]
          [cwd-ptr (list-ref opts-data 4)]
          [env-ptr (list-ref opts-data 5)]
          [env-strings (list-ref opts-data 6)])
      ;; 释放字符串
      (foreign-free file-ptr)
      (for-each foreign-free args-strings)
      (foreign-free args-ptr)
      (when (not (= cwd-ptr 0))
        (foreign-free cwd-ptr))
      (when (not (= env-ptr 0))
        (for-each foreign-free env-strings)
        (foreign-free env-ptr))
      ;; 释放选项结构
      (foreign-free opts-ptr)))

  ;; ========================================
  ;; 进程操作
  ;; ========================================

  (define uv-spawn
    (case-lambda
      [(loop file args callback)
       (uv-spawn loop file args callback #f #f 0)]
      [(loop file args callback cwd)
       (uv-spawn loop file args callback cwd #f 0)]
      [(loop file args callback cwd env)
       (uv-spawn loop file args callback cwd env 0)]
      [(loop file args callback cwd env flags)
       "启动子进程
        loop: 事件循环
        file: 可执行文件路径
        args: 参数列表（不包括程序名，会自动添加）
        callback: 退出回调 (lambda (process exit-status term-signal) ...)
        cwd: 工作目录（可选）
        env: 环境变量列表（可选）
        flags: 进程标志（可选）
        返回: process 句柄"
       ;; 分配进程句柄
       (let* ([size (%ffi-uv-process-size)]
              [ptr (allocate-handle size)]
              [loop-ptr (uv-loop-ptr loop)]
              ;; 创建选项
              [opts-data (make-process-options file args cwd env flags)]
              [opts-ptr (car opts-data)])
         ;; 设置退出回调
         (foreign-set! 'void* opts-ptr 0 (get-exit-callback))
         ;; 创建句柄包装器
         (let ([wrapper (make-handle ptr 'process loop)])
           ;; 保存用户回调
           (handle-data-set! wrapper callback)
           (when callback (lock-object callback))
           ;; 启动进程
           (let ([result (%ffi-uv-spawn loop-ptr ptr opts-ptr)])
             ;; 释放选项内存（spawn 后不再需要）
             (free-process-options opts-data)
             (when (< result 0)
               ;; 启动失败，需要通过 uv_close 正确清理句柄
               ;; （libuv 可能已部分初始化了句柄）
               (when callback (unlock-object callback))
               (handle-data-set! wrapper #f)  ; 清除回调
               ;; 保存错误码，在关闭后再抛出
               (let ([err result])
                 (uv-handle-close! wrapper)
                 (raise-uv-error 'uv-spawn err)))
             wrapper)))]))

  (define (uv-process-kill! process signum)
    "发送信号给进程
     process: 进程句柄
     signum: 信号编号"
    (when (handle-closed? process)
      (error 'uv-process-kill! "process handle is closed"))
    (with-uv-check uv-process-kill
      (%ffi-uv-process-kill (handle-ptr process) signum)))

  (define (uv-process-get-pid process)
    "获取进程 PID
     process: 进程句柄
     返回: 进程 ID"
    (when (handle-closed? process)
      (error 'uv-process-get-pid "process handle is closed"))
    (%ffi-uv-process-get-pid (handle-ptr process)))

  (define (uv-kill pid signum)
    "发送信号给任意进程
     pid: 目标进程 ID
     signum: 信号编号"
    (with-uv-check uv-kill
      (%ffi-uv-kill pid signum)))

) ; end library
