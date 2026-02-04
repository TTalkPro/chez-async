;;; internal/buffer-utils.ss - Unified buffer utilities
;;;
;;; Consolidates buffer handling operations used across stream, UDP, DNS, etc.
;;; Provides consistent interface for foreign pointer ↔ bytevector conversions

(library (chez-async internal buffer-utils)
  (export
    ;; Conversion utilities
    foreign->bytevector
    bytevector->foreign

    ;; uv_buf_t utilities
    make-uv-buf
    uv-buf-base
    uv-buf-len

    ;; High-level macros
    with-temp-buffer
    with-read-buffer
    with-write-buffers)

  (import (chezscheme)
          (chez-async ffi types))

  ;; ========================================
  ;; Foreign → Bytevector Conversion
  ;; ========================================

  (define (foreign->bytevector ptr length)
    "Copy foreign memory to Scheme bytevector

     ptr: foreign pointer to memory
     length: number of bytes to copy

     Returns: bytevector containing copied data

     Used for: read callbacks, DNS responses, UDP recv"
    (if (or (not ptr) (<= length 0))
        #vu8()  ; Empty bytevector for empty data
        (let ([bv (make-bytevector length)])
          (do ([i 0 (+ i 1)])
              ((= i length) bv)
            (bytevector-u8-set! bv i (foreign-ref 'unsigned-8 ptr i))))))

  ;; ========================================
  ;; Bytevector → Foreign Conversion
  ;; ========================================

  (define (bytevector->foreign bv)
    "Allocate foreign memory and copy bytevector

     bv: Scheme bytevector

     Returns: (values ptr length)
       ptr: foreign pointer (caller must free)
       length: number of bytes

     Used for: write operations, UDP send

     IMPORTANT: Caller is responsible for freeing returned pointer"
    (let ([len (bytevector-length bv)])
      (if (= len 0)
          (values 0 0)  ; NULL pointer for empty data
          (let ([ptr (foreign-alloc len)])
            (do ([i 0 (+ i 1)])
                ((= i len))
              (foreign-set! 'unsigned-8 ptr i (bytevector-u8-ref bv i)))
            (values ptr len)))))

  ;; ========================================
  ;; uv_buf_t Utilities
  ;; ========================================

  (define (make-uv-buf base len)
    "Create uv_buf_t structure in foreign memory

     base: foreign pointer to buffer data
     len: buffer length

     Returns: foreign pointer to uv_buf_t (caller must free)"
    (let* ([buf-size (foreign-sizeof 'uv-buf-t)]
           [buf-ptr (foreign-alloc buf-size)])
      (let ([buf-fptr (make-ftype-pointer uv-buf-t buf-ptr)])
        (ftype-set! uv-buf-t (base) buf-fptr base)
        (ftype-set! uv-buf-t (len) buf-fptr len)
        buf-ptr)))

  (define (uv-buf-base buf-ptr)
    "Extract base pointer from uv_buf_t

     buf-ptr: foreign pointer to uv_buf_t

     Returns: foreign pointer to buffer data"
    (let ([buf-fptr (make-ftype-pointer uv-buf-t buf-ptr)])
      (ftype-ref uv-buf-t (base) buf-fptr)))

  (define (uv-buf-len buf-ptr)
    "Extract length from uv_buf_t

     buf-ptr: foreign pointer to uv_buf_t

     Returns: buffer length (integer)"
    (let ([buf-fptr (make-ftype-pointer uv-buf-t buf-ptr)])
      (ftype-ref uv-buf-t (len) buf-fptr)))

  ;; ========================================
  ;; High-Level Macros
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
