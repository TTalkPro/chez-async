;;; low-level/buffer.ss - 缓冲区管理
;;;
;;; 提供 uv_buf_t 和 Scheme bytevector 之间的转换

(library (chez-async low-level buffer)
  (export
    ;; 缓冲区创建
    make-uv-buf
    make-uv-buf-array
    free-uv-buf
    free-uv-buf-array

    ;; 缓冲区读取
    uv-buf->bytevector
    uv-buf-array->bytevectors

    ;; 默认 alloc 回调
    make-default-alloc-callback
    )
  (import (chezscheme)
          (chez-async ffi types))

  ;; ========================================
  ;; 缓冲区创建和释放
  ;; ========================================

  (define (make-uv-buf bv)
    "将 Scheme bytevector 转换为 uv_buf_t*
     注意：调用者负责锁定 bytevector 并在使用后解锁"
    (let* ([len (bytevector-length bv)]
           [buf-ptr (foreign-alloc (ftype-sizeof uv-buf-t))])
      ;; 锁定 bytevector 防止 GC 移动
      (lock-object bv)
      ;; 设置 uv_buf_t 字段
      (ftype-set! uv-buf-t (base) buf-ptr
                  (foreign-ref 'void*
                               (foreign-alloc (foreign-sizeof 'void*))
                               0))
      ;; 复制 bytevector 地址
      (let ([base-ptr (ftype-ref uv-buf-t (base) buf-ptr)])
        (foreign-set! 'void* base-ptr 0
                      (+ (foreign-ref 'void* (foreign-alloc (foreign-sizeof 'void*)) 0)
                         0)))
      ;; 实际上应该直接使用 bytevector 的内部指针
      ;; 但 Chez 不直接暴露，需要通过技巧获取
      (ftype-set! uv-buf-t (len) buf-ptr len)
      (cons buf-ptr bv)))  ; 返回 cons 以保持 bv 引用

  ;; 更简单的实现：使用预分配的 C 缓冲区
  (define (make-uv-buf-from-c-memory size)
    "创建使用 C 内存的 uv_buf_t"
    (let ([buf-ptr (foreign-alloc (ftype-sizeof uv-buf-t))]
          [data-ptr (foreign-alloc size)])
      (ftype-set! uv-buf-t (base) buf-ptr data-ptr)
      (ftype-set! uv-buf-t (len) buf-ptr size)
      buf-ptr))

  (define (make-uv-buf-array bvs)
    "将 Scheme bytevector 列表转换为 uv_buf_t 数组"
    (let* ([count (length bvs)]
           [array-size (* count (ftype-sizeof uv-buf-t))]
           [array-ptr (foreign-alloc array-size)])
      ;; 为每个 bytevector 创建 uv_buf_t
      (let loop ([i 0] [bvs bvs] [locked '()])
        (if (null? bvs)
            (cons array-ptr locked)
            (let* ([bv (car bvs)]
                   [len (bytevector-length bv)]
                   [offset (* i (ftype-sizeof uv-buf-t))]
                   [buf-ptr (+ array-ptr offset)])
              (lock-object bv)
              ;; 这里需要获取 bytevector 的实际内存地址
              ;; 暂时使用占位符，实际实现需要平台特定代码
              (ftype-set! uv-buf-t (base) buf-ptr 0)
              (ftype-set! uv-buf-t (len) buf-ptr len)
              (loop (+ i 1) (cdr bvs) (cons bv locked)))))))

  (define (free-uv-buf buf-bv-pair)
    "释放 uv_buf_t 并解锁 bytevector"
    (let ([buf-ptr (car buf-bv-pair)]
          [bv (cdr buf-bv-pair)])
      (unlock-object bv)
      (foreign-free buf-ptr)))

  (define (free-uv-buf-array array-locked-pair)
    "释放 uv_buf_t 数组并解锁所有 bytevector"
    (let ([array-ptr (car array-locked-pair)]
          [locked-bvs (cdr array-locked-pair)])
      (for-each unlock-object locked-bvs)
      (foreign-free array-ptr)))

  ;; ========================================
  ;; 缓冲区读取
  ;; ========================================

  (define (uv-buf->bytevector buf-ptr)
    "从 uv_buf_t* 读取数据到新的 bytevector"
    (let* ([base (ftype-ref uv-buf-t (base) buf-ptr)]
           [len (ftype-ref uv-buf-t (len) buf-ptr)]
           [bv (make-bytevector len)])
      ;; 从 C 内存复制到 bytevector
      (let loop ([i 0])
        (when (< i len)
          (bytevector-u8-set! bv i (foreign-ref 'unsigned-8 base i))
          (loop (+ i 1))))
      bv))

  (define (uv-buf-array->bytevectors array-ptr count)
    "从 uv_buf_t 数组读取所有数据"
    (let loop ([i 0] [result '()])
      (if (= i count)
          (reverse result)
          (let* ([offset (* i (ftype-sizeof uv-buf-t))]
                 [buf-ptr (+ array-ptr offset)]
                 [bv (uv-buf->bytevector buf-ptr)])
            (loop (+ i 1) (cons bv result))))))

  ;; ========================================
  ;; 默认 alloc 回调
  ;; ========================================

  (define *temp-buffers* (make-eq-hashtable))

  (define (store-temp-buffer! handle bv)
    "临时存储缓冲区（用于 alloc 回调）"
    (hashtable-set! *temp-buffers* handle bv))

  (define (get-temp-buffer handle)
    "获取并移除临时缓冲区"
    (let ([bv (hashtable-ref *temp-buffers* handle #f)])
      (when bv
        (hashtable-delete! *temp-buffers* handle))
      bv))

  (define (make-default-alloc-callback suggested-size)
    "创建默认的内存分配回调
     suggested-size: 建议的缓冲区大小"
    (lambda (handle size buf-ptr)
      ;; 分配 C 内存而不是使用 Scheme bytevector
      ;; 这样避免 GC 问题
      (let ([data-ptr (foreign-alloc suggested-size)])
        (ftype-set! uv-buf-t (base) buf-ptr data-ptr)
        (ftype-set! uv-buf-t (len) buf-ptr suggested-size)
        ;; 存储指针以便后续释放
        (store-temp-buffer! handle data-ptr))))

) ; end library
