;;; internal/buffer.ss - bytevector <-> foreign 内存桥接（(chezscheme)-only）
;;;
;;; 新 I/O 栈（io-fs/io-net/io-proc）用它在 Scheme bytevector 与 foreign 内存
;;; 之间搬字节（C++ 运行时的 buffer ABI 收裸 foreign 指针）。8 字节一组批量
;;; 复制（原生字节序两端一致，字节完全保真），尾部逐字节，约 8× 提速（G1）。
;;;
;;; 从旧 internal/foreign 提炼而来，只依赖 (chezscheme)——不牵连旧 ffi 栈。

(library (chez-async internal buffer)
  (export
    bytevector->foreign           ; (bv) → (values ptr len)；需手动 foreign-free ptr
    foreign->bytevector           ; (ptr len) → 新 bytevector
    copy-bytevector-to-foreign!   ; (bv ptr) → void
    copy-foreign-to-bytevector!)  ; (ptr bv len) → void
  (import (chezscheme))

  (define (copy-bytevector-to-foreign! bv ptr)
    (let* ([len (bytevector-length bv)]
           [n8 (fxand len (fxnot 7))])   ; len 向下取整到 8 的倍数
      (let loop ([i 0])
        (when (fx< i n8)
          (foreign-set! 'unsigned-64 ptr i (bytevector-u64-native-ref bv i))
          (loop (fx+ i 8))))
      (let loop ([i n8])
        (when (fx< i len)
          (foreign-set! 'unsigned-8 ptr i (bytevector-u8-ref bv i))
          (loop (fx+ i 1))))))

  (define (copy-foreign-to-bytevector! ptr bv len)
    (let ([n8 (fxand len (fxnot 7))])
      (let loop ([i 0])
        (when (fx< i n8)
          (bytevector-u64-native-set! bv i (foreign-ref 'unsigned-64 ptr i))
          (loop (fx+ i 8))))
      (let loop ([i n8])
        (when (fx< i len)
          (bytevector-u8-set! bv i (foreign-ref 'unsigned-8 ptr i))
          (loop (fx+ i 1))))))

  (define (bytevector->foreign bv)
    (let ([len (bytevector-length bv)])
      (if (= len 0)
          (values 0 0)
          (let ([ptr (foreign-alloc len)])
            (copy-bytevector-to-foreign! bv ptr)
            (values ptr len)))))

  (define (foreign->bytevector ptr length)
    (if (or (not ptr) (<= length 0))
        #vu8()
        (let ([bv (make-bytevector length)])
          (copy-foreign-to-bytevector! ptr bv length)
          bv)))

) ; end library
