;;; internal/buffer-utils.ss - 统一缓冲区工具
;;;
;;; 本模块提供：
;;; - 外部指针与 bytevector 之间的转换
;;; - uv_buf_t 结构的创建与访问
;;; - 缓冲区管理宏（自动分配/释放）
;;;
;;; 供 stream、UDP、DNS 等模块共用，确保缓冲区操作接口一致。

(library (chez-async internal buffer-utils)
  (export
    ;; 转换工具
    foreign->bytevector
    bytevector->foreign

    ;; uv_buf_t 工具
    make-uv-buf
    uv-buf-base
    uv-buf-len

    ;; 高层宏
    with-temp-buffer
    with-read-buffer
    with-write-buffers)

  (import (chezscheme)
          (chez-async ffi types))

  ;; ========================================
  ;; 外部指针 → Bytevector 转换
  ;; ========================================

  (define (foreign->bytevector ptr length)
    "将外部内存复制为 Scheme bytevector

     参数：
       ptr    - 外部内存指针
       length - 要复制的字节数

     返回：
       包含复制数据的 bytevector

     用途：读回调、DNS 响应、UDP 接收"
    (if (or (not ptr) (<= length 0))
        #vu8()  ; Empty bytevector for empty data
        (let ([bv (make-bytevector length)])
          (do ([i 0 (+ i 1)])
              ((= i length) bv)
            (bytevector-u8-set! bv i (foreign-ref 'unsigned-8 ptr i))))))

  ;; ========================================
  ;; Bytevector → 外部指针转换
  ;; ========================================

  (define (bytevector->foreign bv)
    "分配外部内存并复制 bytevector 内容

     参数：
       bv - Scheme bytevector

     返回：
       (values ptr length)
       ptr: 外部指针（调用者负责释放）
       length: 字节数

     用途：写操作、UDP 发送

     注意：调用者必须释放返回的指针"
    (let ([len (bytevector-length bv)])
      (if (= len 0)
          (values 0 0)  ; NULL pointer for empty data
          (let ([ptr (foreign-alloc len)])
            (do ([i 0 (+ i 1)])
                ((= i len))
              (foreign-set! 'unsigned-8 ptr i (bytevector-u8-ref bv i)))
            (values ptr len)))))

  ;; ========================================
  ;; uv_buf_t 工具函数
  ;; ========================================

  (define (make-uv-buf base len)
    "在外部内存中创建 uv_buf_t 结构

     参数：
       base - 缓冲区数据的外部指针
       len  - 缓冲区长度

     返回：
       指向 uv_buf_t 的外部指针（调用者负责释放）"
    (let* ([buf-size (foreign-sizeof 'uv-buf-t)]
           [buf-ptr (foreign-alloc buf-size)])
      (let ([buf-fptr (make-ftype-pointer uv-buf-t buf-ptr)])
        (ftype-set! uv-buf-t (base) buf-fptr base)
        (ftype-set! uv-buf-t (len) buf-fptr len)
        buf-ptr)))

  (define (uv-buf-base buf-ptr)
    "从 uv_buf_t 提取数据指针

     参数：
       buf-ptr - 指向 uv_buf_t 的外部指针

     返回：
       缓冲区数据的外部指针"
    (let ([buf-fptr (make-ftype-pointer uv-buf-t buf-ptr)])
      (ftype-ref uv-buf-t (base) buf-fptr)))

  (define (uv-buf-len buf-ptr)
    "从 uv_buf_t 提取长度

     参数：
       buf-ptr - 指向 uv_buf_t 的外部指针

     返回：
       缓冲区长度（整数）"
    (let ([buf-fptr (make-ftype-pointer uv-buf-t buf-ptr)])
      (ftype-ref uv-buf-t (len) buf-fptr)))

  ;; ========================================
  ;; 高层宏
  ;; ========================================

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

  (define-syntax with-read-buffer
    (syntax-rules ()
      [(with-read-buffer buf-ptr nread bv-var body ...)
       (let ([bv-var (if (> nread 0)
                         (foreign->bytevector (uv-buf-base buf-ptr) nread)
                         #vu8())])
         body ...)]))

  (define-syntax with-write-buffers
    (syntax-rules ()
      [(with-write-buffers ((buf-var ptr-var len-var) ...) from-bv body ...)
       (let-values ([(ptr-var len-var) (bytevector->foreign from-bv)] ...)
         (let ([buf-var (make-uv-buf ptr-var len-var)] ...)
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
