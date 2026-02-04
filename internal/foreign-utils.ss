;;; internal/foreign-utils.ss - 外部接口工具函数
;;;
;;; 本模块提供与外部 C 代码交互时常用的工具函数：
;;; - C 字符串转换
;;; - 内存操作工具
;;; - 缓冲区管理
;;;
;;; 这些函数被多个模块共享，集中管理可避免重复代码。

(library (chez-async internal foreign-utils)
  (export
    ;; C 字符串操作
    c-string->string
    string->c-string
    with-c-string

    ;; 内存分配
    allocate-zeroed
    safe-free

    ;; 字节向量与 C 内存转换
    bytevector->foreign
    foreign->bytevector
    copy-bytevector-to-foreign!
    copy-foreign-to-bytevector!

    ;; uv_buf_t 操作
    make-uv-buf
    free-uv-buf
    with-uv-buf
    )
  (import (chezscheme)
          (chez-async ffi types))

  ;; ========================================
  ;; C 字符串操作
  ;; ========================================

  ;; c-string->string: 将 C 字符串指针转换为 Scheme 字符串
  ;;
  ;; 参数：
  ;;   ptr - C 字符串指针（以 NULL 结尾）
  ;;
  ;; 返回：
  ;;   Scheme 字符串，如果 ptr 为 0 则返回 #f
  ;;
  ;; 说明：
  ;;   此函数遍历内存直到遇到 NULL 字节，
  ;;   假设字符串为 UTF-8 编码（ASCII 兼容）
  (define (c-string->string ptr)
    "将 C 字符串指针转换为 Scheme 字符串"
    (if (or (not ptr) (= ptr 0))
        #f
        (let loop ([i 0] [chars '()])
          (let ([byte (foreign-ref 'unsigned-8 ptr i)])
            (if (= byte 0)
                ;; 遇到 NULL 终止符，构建字符串
                (list->string (reverse chars))
                ;; 继续读取下一个字节
                (loop (+ i 1)
                      (cons (integer->char byte) chars)))))))

  ;; string->c-string: 将 Scheme 字符串转换为 C 字符串
  ;;
  ;; 参数：
  ;;   str - Scheme 字符串
  ;;
  ;; 返回：
  ;;   指向新分配内存的指针（调用者负责释放）
  ;;
  ;; 注意：
  ;;   返回的内存必须使用 foreign-free 释放
  (define (string->c-string str)
    "将 Scheme 字符串转换为 C 字符串（需要手动释放）"
    (let* ([bv (string->utf8 str)]
           [len (bytevector-length bv)]
           [ptr (foreign-alloc (+ len 1))])  ; +1 for NULL terminator
      ;; 复制字节
      (do ([i 0 (+ i 1)])
          ((= i len))
        (foreign-set! 'unsigned-8 ptr i (bytevector-u8-ref bv i)))
      ;; 添加 NULL 终止符
      (foreign-set! 'unsigned-8 ptr len 0)
      ptr))

  ;; with-c-string: 在临时 C 字符串上执行操作
  ;;
  ;; 用法：
  ;;   (with-c-string (ptr "hello")
  ;;     (some-c-function ptr))
  ;;
  ;; 说明：
  ;;   自动分配和释放 C 字符串内存
  (define-syntax with-c-string
    (syntax-rules ()
      [(_ (var str) body ...)
       (let ([var (string->c-string str)])
         (dynamic-wind
           (lambda () #f)
           (lambda () body ...)
           (lambda () (foreign-free var))))]))

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
  (define (allocate-zeroed size)
    "分配指定大小的内存并初始化为零"
    (let ([ptr (foreign-alloc size)])
      ;; 初始化为零
      (do ([i 0 (+ i 1)])
          ((= i size))
        (foreign-set! 'unsigned-8 ptr i 0))
      ptr))

  ;; safe-free: 安全释放内存
  ;;
  ;; 参数：
  ;;   ptr - 要释放的指针
  ;;
  ;; 说明：
  ;;   如果 ptr 为 #f 或 0，则不执行任何操作
  (define (safe-free ptr)
    "安全释放内存（允许 #f 或 0）"
    (when (and ptr (not (= ptr 0)))
      (foreign-free ptr)))

  ;; ========================================
  ;; 字节向量与外部内存转换
  ;; ========================================

  ;; bytevector->foreign: 将字节向量复制到新分配的外部内存
  ;;
  ;; 参数：
  ;;   bv - 字节向量
  ;;
  ;; 返回：
  ;;   (values ptr len) - 指针和长度
  ;;
  ;; 注意：
  ;;   返回的内存必须使用 foreign-free 释放
  (define (bytevector->foreign bv)
    "将字节向量复制到外部内存（需要手动释放）"
    (let* ([len (bytevector-length bv)]
           [ptr (foreign-alloc len)])
      (copy-bytevector-to-foreign! bv ptr)
      (values ptr len)))

  ;; foreign->bytevector: 从外部内存创建字节向量
  ;;
  ;; 参数：
  ;;   ptr - 外部内存指针
  ;;   len - 要复制的字节数
  ;;
  ;; 返回：
  ;;   新创建的字节向量
  (define (foreign->bytevector ptr len)
    "从外部内存创建字节向量"
    (let ([bv (make-bytevector len)])
      (copy-foreign-to-bytevector! ptr bv len)
      bv))

  ;; copy-bytevector-to-foreign!: 将字节向量内容复制到外部内存
  ;;
  ;; 参数：
  ;;   bv  - 源字节向量
  ;;   ptr - 目标外部内存指针
  (define (copy-bytevector-to-foreign! bv ptr)
    "将字节向量内容复制到外部内存"
    (let ([len (bytevector-length bv)])
      (do ([i 0 (+ i 1)])
          ((= i len))
        (foreign-set! 'unsigned-8 ptr i (bytevector-u8-ref bv i)))))

  ;; copy-foreign-to-bytevector!: 将外部内存内容复制到字节向量
  ;;
  ;; 参数：
  ;;   ptr - 源外部内存指针
  ;;   bv  - 目标字节向量
  ;;   len - 要复制的字节数
  (define (copy-foreign-to-bytevector! ptr bv len)
    "将外部内存内容复制到字节向量"
    (do ([i 0 (+ i 1)])
        ((= i len))
      (bytevector-u8-set! bv i (foreign-ref 'unsigned-8 ptr i))))

  ;; ========================================
  ;; uv_buf_t 操作
  ;; ========================================
  ;;
  ;; uv_buf_t 是 libuv 中用于 I/O 操作的缓冲区结构
  ;; 它包含一个指向数据的指针和数据长度

  ;; make-uv-buf: 创建 uv_buf_t 结构
  ;;
  ;; 参数：
  ;;   data - 字节向量或字符串
  ;;
  ;; 返回：
  ;;   (values buf-ptr data-ptr len) - 缓冲区结构指针、数据指针、长度
  ;;
  ;; 注意：
  ;;   返回的两个指针都需要使用 foreign-free 释放
  (define (make-uv-buf data)
    "创建 uv_buf_t 结构"
    (let* ([bv (if (string? data)
                   (string->utf8 data)
                   data)]
           [len (bytevector-length bv)]
           [data-ptr (foreign-alloc len)]
           [buf-ptr (foreign-alloc (ftype-sizeof uv-buf-t))])
      ;; 复制数据
      (copy-bytevector-to-foreign! bv data-ptr)
      ;; 设置 uv_buf_t 字段
      (let ([buf-fptr (make-ftype-pointer uv-buf-t buf-ptr)])
        (ftype-set! uv-buf-t (base) buf-fptr data-ptr)
        (ftype-set! uv-buf-t (len) buf-fptr len))
      (values buf-ptr data-ptr len)))

  ;; free-uv-buf: 释放 uv_buf_t 及其数据
  ;;
  ;; 参数：
  ;;   buf-ptr  - uv_buf_t 结构指针
  ;;   data-ptr - 数据指针
  (define (free-uv-buf buf-ptr data-ptr)
    "释放 uv_buf_t 结构及其数据"
    (safe-free data-ptr)
    (safe-free buf-ptr))

  ;; with-uv-buf: 在临时缓冲区上执行操作
  ;;
  ;; 用法：
  ;;   (with-uv-buf (buf-ptr data-ptr len) data
  ;;     (some-operation buf-ptr))
  ;;
  ;; 说明：
  ;;   自动分配和释放缓冲区
  (define-syntax with-uv-buf
    (syntax-rules ()
      [(_ (buf-ptr data-ptr len) data body ...)
       (let-values ([(buf-ptr data-ptr len) (make-uv-buf data)])
         (dynamic-wind
           (lambda () #f)
           (lambda () body ...)
           (lambda () (free-uv-buf buf-ptr data-ptr))))]))

) ; end library
