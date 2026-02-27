;;; internal/foreign.ss - 外部内存与缓冲区操作
;;;
;;; 本模块统一提供与外部 C 代码交互时所需的全部工具函数：
;;;
;;; 1. C 字符串操作 —— Scheme 字符串与以 NULL 结尾的 C 字符串之间的转换
;;;    - c-string->string: C 指针 → Scheme 字符串
;;;    - string->c-string: Scheme 字符串 → C 指针（需手动释放）
;;;    - with-c-string: 临时 C 字符串的 RAII 封装
;;;
;;; 2. 内存分配 —— 提供比 foreign-alloc 更安全的分配/释放接口
;;;    - allocate-zeroed: 分配并清零内存（基于 calloc）
;;;    - safe-free: 允许 #f/0 的安全释放
;;;
;;; 3. 字节向量转换 —— Scheme bytevector 与外部内存之间的双向复制
;;;    - bytevector->foreign / foreign->bytevector: 高层接口
;;;    - copy-bytevector-to-foreign! / copy-foreign-to-bytevector!: 底层复制
;;;
;;; 4. uv_buf_t 操作 —— libuv I/O 缓冲区结构的创建与管理
;;;    - make-uv-buf / free-uv-buf / with-uv-buf: 高层接口（接受 bytevector/string）
;;;    - make-uv-buf-from-ptrs / uv-buf-base / uv-buf-len: 底层指针操作
;;;
;;; 5. 缓冲区管理宏 —— 自动分配/释放的资源管理
;;;    - with-temp-buffer: 临时外部内存
;;;    - with-read-buffer: 读回调中提取 bytevector
;;;    - with-write-buffers: 写操作的缓冲区准备
;;;
;;; 设计说明：
;;; 本模块合并了原 buffer-utils.ss 和 foreign-utils.ss，消除重复定义，
;;; 统一"外部内存操作"这一职责。供 stream、UDP、DNS、FS 等模块共用。

(library (chez-async internal foreign)
  (export
    ;; C 字符串操作
    c-string->string          ; (ptr) → string | #f
    string->c-string          ; (str) → ptr（需手动释放）
    with-c-string             ; (with-c-string (var str) body ...) — 自动释放

    ;; 内存分配
    allocate-zeroed           ; (size) → ptr（清零内存，失败则报错）
    safe-free                 ; (ptr) → void（允许 #f 或 0）

    ;; 字节向量与外部内存转换
    bytevector->foreign       ; (bv) → (values ptr len)（需手动释放 ptr）
    foreign->bytevector       ; (ptr len) → bytevector
    copy-bytevector-to-foreign!  ; (bv ptr) → void
    copy-foreign-to-bytevector!  ; (ptr bv len) → void

    ;; uv_buf_t 操作（高层：接受 bytevector/string）
    make-uv-buf               ; (data) → (values buf-ptr data-ptr len)
    free-uv-buf               ; (buf-ptr data-ptr) → void
    with-uv-buf               ; (with-uv-buf (buf data len) data body ...) — 自动释放

    ;; uv_buf_t 操作（底层：直接操作指针）
    make-uv-buf-from-ptrs     ; (base len) → buf-ptr
    uv-buf-base               ; (buf-ptr) → base-ptr
    uv-buf-len                ; (buf-ptr) → length

    ;; 缓冲区管理宏
    with-temp-buffer          ; (with-temp-buffer (var size) body ...) — 临时外部内存
    with-read-buffer          ; (with-read-buffer buf-ptr nread bv-var body ...)
    with-write-buffers        ; (with-write-buffers ((buf ptr len) ...) bv body ...)

    ;; libc 加载
    ensure-libc-loaded!       ; () → void（确保 libc 已加载，供 foreign-procedure 使用）
    )

  (import (chezscheme)
          (chez-async ffi types))

  ;; ========================================
  ;; C 字符串操作
  ;; ========================================

  ;; c-string->string: 将 C 字符串指针转换为 Scheme 字符串
  ;;
  ;; 参数：
  ;;   ptr - C 字符串指针（以 NULL 结尾），或 #f/0
  ;;
  ;; 返回：
  ;;   Scheme 字符串，如果 ptr 为 #f 或 0 则返回 #f
  ;;
  ;; 说明：
  ;;   逐字节读取直到遇到 NULL 终止符，假设 UTF-8 编码（ASCII 兼容）。
  ;;   注意：ffi/fs.ss 中有独立的同名定义，因为 ffi 层不能导入 internal 层。
  (define (c-string->string ptr)
    (if (or (not ptr) (= ptr 0))
        #f
        (let loop ([i 0] [chars '()])
          (let ([byte (foreign-ref 'unsigned-8 ptr i)])
            (if (= byte 0)
                (list->string (reverse chars))
                (loop (+ i 1)
                      (cons (integer->char byte) chars)))))))

  ;; string->c-string: 将 Scheme 字符串转换为 C 字符串
  ;;
  ;; 参数：
  ;;   str - Scheme 字符串
  ;;
  ;; 返回：
  ;;   指向新分配内存的指针（调用者负责用 foreign-free 释放）
  ;;
  ;; 说明：
  ;;   将字符串编码为 UTF-8 并追加 NULL 终止符。
  (define (string->c-string str)
    (let* ([bv (string->utf8 str)]
           [len (bytevector-length bv)]
           [ptr (foreign-alloc (+ len 1))])
      (do ([i 0 (+ i 1)])
          ((= i len))
        (foreign-set! 'unsigned-8 ptr i (bytevector-u8-ref bv i)))
      (foreign-set! 'unsigned-8 ptr len 0)
      ptr))

  ;; with-c-string: 在临时 C 字符串上执行操作
  ;;
  ;; 用法：
  ;;   (with-c-string (ptr "hello")
  ;;     (some-c-function ptr))
  ;;
  ;; 说明：
  ;;   通过 dynamic-wind 确保 C 字符串在退出时释放，
  ;;   即使发生异常或 continuation 跳出也能正确清理。
  (define-syntax with-c-string
    (syntax-rules ()
      [(_ (var str) body ...)
       (let ([var (string->c-string str)])
         (dynamic-wind
           (lambda () #f)
           (lambda () body ...)
           (lambda () (foreign-free var))))]))

  ;; ========================================
  ;; libc 加载
  ;; ========================================
  ;;
  ;; 某些平台（OpenBSD 等）的动态链接器不会将 libc 符号自动暴露给
  ;; foreign-procedure，需要先通过 load-shared-object 显式加载 libc。
  ;; ensure-libc-loaded! 按平台优先级尝试多个路径，首次成功后缓存状态。
  ;; 本函数同时被 allocate-zeroed 和 internal/posix-ffi.ss 使用。

  (define ensure-libc-loaded!
    (let ([loaded? #f])
      (lambda ()
        (unless loaded?
          (guard (e [else
                      (error 'ensure-libc-loaded! "libc not available or load failed")])
            (cond
              ;; Linux 64 位（最常见）
              [(guard (e [else #f])
                 (load-shared-object "/lib64/libc.so.6") #t)
               (set! loaded? #t)]
              ;; Linux 32 位
              [(guard (e [else #f])
                 (load-shared-object "/lib/libc.so.6") #t)
               (set! loaded? #t)]
              ;; Linux multiarch (Debian/Ubuntu)
              [(guard (e [else #f])
                 (load-shared-object "/lib/x86_64-linux-gnu/libc.so.6") #t)
               (set! loaded? #t)]
              ;; Linux aarch64 multiarch
              [(guard (e [else #f])
                 (load-shared-object "/lib/aarch64-linux-gnu/libc.so.6") #t)
               (set! loaded? #t)]
              ;; FreeBSD
              [(guard (e [else #f])
                 (load-shared-object "/lib/libc.so.7") #t)
               (set! loaded? #t)]
              [(guard (e [else #f])
                 (load-shared-object "/usr/lib/libc.so.7") #t)
               (set! loaded? #t)]
              ;; macOS
              [(guard (e [else #f])
                 (load-shared-object "/usr/lib/libc.dylib") #t)
               (set! loaded? #t)]
              ;; OpenBSD / NetBSD / 其他 — 交由动态链接器解析
              [(guard (e [else #f])
                 (load-shared-object "libc.so") #t)
               (set! loaded? #t)]
              ;; 所有尝试均失败
              [else
               (error 'ensure-libc-loaded! "libc not available or load failed")]))))))

  ;; ========================================
  ;; 内存分配工具
  ;; ========================================

  ;; allocate-zeroed: 分配并清零内存
  ;;
  ;; 参数：
  ;;   size - 要分配的字节数
  ;;
  ;; 返回：
  ;;   指向新分配内存的指针，所有字节初始化为 0
  ;;
  ;; 说明：
  ;;   基于 calloc(1, size) 实现，与 foreign-free/safe-free 兼容。
  ;;   分配失败时抛出 'allocate-zeroed 错误。
  ;;   首次调用时通过 ensure-libc-loaded! 确保 libc 已加载，
  ;;   然后懒创建 foreign-procedure 绑定。
  (define allocate-zeroed
    (let ([proc #f])
      (lambda (size)
        (unless proc
          (ensure-libc-loaded!)
          (set! proc (foreign-procedure "calloc" (size_t size_t) void*)))
        (let ([ptr (proc 1 size)])
          (when (= ptr 0)
            (error 'allocate-zeroed "out of memory" size))
          ptr))))

  ;; safe-free: 安全释放内存
  ;;
  ;; 参数：
  ;;   ptr - 要释放的指针，允许 #f 或 0
  ;;
  ;; 说明：
  ;;   仅当 ptr 非 #f 且非 0 时调用 foreign-free。
  ;;   用于简化清理代码中对空指针的检查。
  (define (safe-free ptr)
    (when (and ptr (not (= ptr 0)))
      (foreign-free ptr)))

  ;; ========================================
  ;; 字节向量与外部内存转换
  ;; ========================================

  ;; copy-bytevector-to-foreign!: 将字节向量内容逐字节复制到外部内存
  ;;
  ;; 参数：
  ;;   bv  - 源 Scheme bytevector
  ;;   ptr - 目标外部内存指针（必须已分配足够空间）
  (define (copy-bytevector-to-foreign! bv ptr)
    (let ([len (bytevector-length bv)])
      (do ([i 0 (+ i 1)])
          ((= i len))
        (foreign-set! 'unsigned-8 ptr i (bytevector-u8-ref bv i)))))

  ;; copy-foreign-to-bytevector!: 将外部内存内容逐字节复制到字节向量
  ;;
  ;; 参数：
  ;;   ptr - 源外部内存指针
  ;;   bv  - 目标 Scheme bytevector（必须已分配足够空间）
  ;;   len - 要复制的字节数
  (define (copy-foreign-to-bytevector! ptr bv len)
    (do ([i 0 (+ i 1)])
        ((= i len))
      (bytevector-u8-set! bv i (foreign-ref 'unsigned-8 ptr i))))

  ;; bytevector->foreign: 将字节向量复制到新分配的外部内存
  ;;
  ;; 参数：
  ;;   bv - Scheme bytevector
  ;;
  ;; 返回：
  ;;   (values ptr len)
  ;;   ptr: 外部指针（空 bytevector 时返回 0）
  ;;   len: 字节数
  ;;
  ;; 注意：
  ;;   调用者必须用 foreign-free 释放返回的指针（ptr 非 0 时）。
  (define (bytevector->foreign bv)
    (let ([len (bytevector-length bv)])
      (if (= len 0)
          (values 0 0)
          (let ([ptr (foreign-alloc len)])
            (copy-bytevector-to-foreign! bv ptr)
            (values ptr len)))))

  ;; foreign->bytevector: 从外部内存创建字节向量
  ;;
  ;; 参数：
  ;;   ptr    - 外部内存指针
  ;;   length - 要复制的字节数
  ;;
  ;; 返回：
  ;;   包含复制数据的 bytevector；ptr 为空或 length <= 0 时返回 #vu8()
  ;;
  ;; 用途：读回调、DNS 响应、UDP 接收等场景
  (define (foreign->bytevector ptr length)
    (if (or (not ptr) (<= length 0))
        #vu8()
        (let ([bv (make-bytevector length)])
          (copy-foreign-to-bytevector! ptr bv length)
          bv)))

  ;; ========================================
  ;; uv_buf_t 操作（高层接口）
  ;; ========================================
  ;;
  ;; uv_buf_t 是 libuv 中用于 I/O 操作的缓冲区结构，
  ;; 包含一个指向数据的指针（base）和数据长度（len）。

  ;; make-uv-buf: 从 bytevector 或 string 创建 uv_buf_t
  ;;
  ;; 参数：
  ;;   data - bytevector 或 string（string 自动转为 UTF-8）
  ;;
  ;; 返回：
  ;;   (values buf-ptr data-ptr len)
  ;;   buf-ptr:  指向 uv_buf_t 结构的指针
  ;;   data-ptr: 指向数据副本的指针
  ;;   len:      数据长度
  ;;
  ;; 注意：
  ;;   返回的 buf-ptr 和 data-ptr 都需要释放，推荐使用 free-uv-buf 或 with-uv-buf。
  (define (make-uv-buf data)
    (let* ([bv (if (string? data) (string->utf8 data) data)]
           [len (bytevector-length bv)]
           [data-ptr (foreign-alloc len)]
           [buf-ptr (foreign-alloc (ftype-sizeof uv-buf-t))])
      (copy-bytevector-to-foreign! bv data-ptr)
      (let ([buf-fptr (make-ftype-pointer uv-buf-t buf-ptr)])
        (ftype-set! uv-buf-t (base) buf-fptr data-ptr)
        (ftype-set! uv-buf-t (len) buf-fptr len))
      (values buf-ptr data-ptr len)))

  ;; free-uv-buf: 释放 uv_buf_t 结构及其数据
  ;;
  ;; 参数：
  ;;   buf-ptr  - uv_buf_t 结构指针
  ;;   data-ptr - 数据指针
  (define (free-uv-buf buf-ptr data-ptr)
    (safe-free data-ptr)
    (safe-free buf-ptr))

  ;; with-uv-buf: 在临时 uv_buf_t 上执行操作
  ;;
  ;; 用法：
  ;;   (with-uv-buf (buf-ptr data-ptr len) data
  ;;     (some-operation buf-ptr))
  ;;
  ;; 说明：
  ;;   通过 dynamic-wind 确保 buf-ptr 和 data-ptr 在退出时释放。
  (define-syntax with-uv-buf
    (syntax-rules ()
      [(_ (buf-ptr data-ptr len) data body ...)
       (let-values ([(buf-ptr data-ptr len) (make-uv-buf data)])
         (dynamic-wind
           (lambda () #f)
           (lambda () body ...)
           (lambda () (free-uv-buf buf-ptr data-ptr))))]))

  ;; ========================================
  ;; uv_buf_t 操作（底层指针接口）
  ;; ========================================
  ;;
  ;; 这些函数直接操作已有的外部指针，供内部宏和底层代码使用。

  ;; make-uv-buf-from-ptrs: 从已有指针创建 uv_buf_t 结构
  ;;
  ;; 参数：
  ;;   base - 缓冲区数据的外部指针
  ;;   len  - 缓冲区长度
  ;;
  ;; 返回：
  ;;   指向 uv_buf_t 的外部指针（调用者负责释放）
  ;;
  ;; 区别于 make-uv-buf：本函数不复制数据，不分配 data 内存。
  (define (make-uv-buf-from-ptrs base len)
    (let* ([buf-size (ftype-sizeof uv-buf-t)]
           [buf-ptr (foreign-alloc buf-size)])
      (let ([buf-fptr (make-ftype-pointer uv-buf-t buf-ptr)])
        (ftype-set! uv-buf-t (base) buf-fptr base)
        (ftype-set! uv-buf-t (len) buf-fptr len)
        buf-ptr)))

  ;; uv-buf-base: 从 uv_buf_t 提取数据指针
  ;;
  ;; 参数：
  ;;   buf-ptr - 指向 uv_buf_t 的外部指针
  ;;
  ;; 返回：
  ;;   缓冲区数据的外部指针（base 字段）
  (define (uv-buf-base buf-ptr)
    (let ([buf-fptr (make-ftype-pointer uv-buf-t buf-ptr)])
      (ftype-ref uv-buf-t (base) buf-fptr)))

  ;; uv-buf-len: 从 uv_buf_t 提取长度
  ;;
  ;; 参数：
  ;;   buf-ptr - 指向 uv_buf_t 的外部指针
  ;;
  ;; 返回：
  ;;   缓冲区长度（整数）
  (define (uv-buf-len buf-ptr)
    (let ([buf-fptr (make-ftype-pointer uv-buf-t buf-ptr)])
      (ftype-ref uv-buf-t (len) buf-fptr)))

  ;; ========================================
  ;; 缓冲区管理宏
  ;; ========================================

  ;; with-temp-buffer: 临时外部内存的 RAII 封装
  ;;
  ;; 用法：
  ;;   (with-temp-buffer (buf 1024)
  ;;     (some-c-function buf))
  ;;
  ;; 说明：
  ;;   分配指定大小的外部内存，在 body 执行完毕或异常时自动释放。
  (define-syntax with-temp-buffer
    (syntax-rules ()
      [(with-temp-buffer (buf-var size) body ...)
       (let ([buf-var (foreign-alloc size)])
         (guard (ex
                 [else
                  (foreign-free buf-var)
                  (raise ex)])
           (let ([result (begin body ...)])
             (foreign-free buf-var)
             result)))]))

  ;; with-read-buffer: 在读回调中提取 bytevector
  ;;
  ;; 用法：
  ;;   (with-read-buffer buf-ptr nread bv
  ;;     (process bv))
  ;;
  ;; 说明：
  ;;   从 uv_buf_t 的 base 指针处复制 nread 字节到新 bytevector。
  ;;   nread <= 0 时得到空 bytevector。
  (define-syntax with-read-buffer
    (syntax-rules ()
      [(with-read-buffer buf-ptr nread bv-var body ...)
       (let ([bv-var (if (> nread 0)
                         (foreign->bytevector (uv-buf-base buf-ptr) nread)
                         #vu8())])
         body ...)]))

  ;; with-write-buffers: 写操作的缓冲区准备
  ;;
  ;; 用法：
  ;;   (with-write-buffers ((buf ptr len)) bv
  ;;     (uv-write req stream buf 1 callback))
  ;;
  ;; 说明：
  ;;   将 bytevector 复制到外部内存，创建 uv_buf_t，
  ;;   在 body 执行完毕或异常时释放所有外部资源。
  (define-syntax with-write-buffers
    (syntax-rules ()
      [(with-write-buffers ((buf-var ptr-var len-var) ...) from-bv body ...)
       (let-values ([(ptr-var len-var) (bytevector->foreign from-bv)] ...)
         (let ([buf-var (make-uv-buf-from-ptrs ptr-var len-var)] ...)
           (guard (ex
                   [else
                    (begin
                      (when (not (= ptr-var 0)) (foreign-free ptr-var)) ...
                      (foreign-free buf-var) ...)
                    (raise ex)])
             (let ([result (begin body ...)])
               (begin
                 (when (not (= ptr-var 0)) (foreign-free ptr-var)) ...
                 (foreign-free buf-var) ...)
               result))))]))

) ; end library
