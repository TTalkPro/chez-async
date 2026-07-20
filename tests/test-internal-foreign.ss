#!/usr/bin/env scheme-script
;;; tests/test-internal-foreign.ss - internal/foreign 内存工具单元测试
;;;
;;; internal/foreign.ss 是关键的内存管理层，此前仅被上层间接覆盖。
;;; 本文件直接测试其边界行为：UTF-8 往返、NULL 处理、空数据、buf 读写。

(import (chezscheme)
        (chez-async tests framework)
        (chez-async internal foreign))

(test-group "internal/foreign Unit Tests"

  ;; ---- c-string 往返：ASCII 与 UTF-8 ----
  (test "c-string-roundtrip-ascii"
    (let ([ptr (string->c-string "hello world")])
      (assert-equal "hello world" (c-string->string ptr) "ASCII round-trip")
      (foreign-free ptr)))

  (test "c-string-roundtrip-utf8"
    (let ([ptr (string->c-string "你好，世界！🌏")])
      (assert-equal "你好，世界！🌏" (c-string->string ptr)
                    "multibyte UTF-8 round-trip should not corrupt")
      (foreign-free ptr)))

  (test "c-string-roundtrip-empty"
    (let ([ptr (string->c-string "")])
      (assert-equal "" (c-string->string ptr) "empty string round-trip")
      (foreign-free ptr)))

  ;; ---- c-string->string 的 NULL 处理 ----
  (test "c-string-null-handling"
    (assert-equal #f (c-string->string 0) "0 pointer should yield #f")
    (assert-equal #f (c-string->string #f) "#f pointer should yield #f"))

  ;; ---- safe-free 容忍空指针 ----
  (test "safe-free-tolerates-null"
    (safe-free #f)
    (safe-free 0)
    (let-values ([(ptr len) (bytevector->foreign (u8-list->bytevector '(1 2 3)))])
      (safe-free ptr))  ; 有效指针也应正常释放
    (assert-true #t "safe-free should not crash on #f/0/valid"))

  ;; ---- bytevector <-> foreign 往返 ----
  (test "bytevector-foreign-roundtrip"
    (let ([bv (u8-list->bytevector '(0 1 2 127 128 255))])
      (let-values ([(ptr len) (bytevector->foreign bv)])
        (assert-equal 6 len "length should match")
        (assert-equal bv (foreign->bytevector ptr len) "round-trip should be identical")
        (foreign-free ptr))))

  (test "bytevector-foreign-empty"
    (let-values ([(ptr len) (bytevector->foreign (make-bytevector 0))])
      (assert-equal 0 ptr "empty bytevector should yield null pointer")
      (assert-equal 0 len "empty length")))

  (test "foreign->bytevector-edge-cases"
    (assert-equal #vu8() (foreign->bytevector #f 10) "#f pointer yields empty")
    (assert-equal #vu8() (foreign->bytevector 0 0) "zero length yields empty")
    (let-values ([(ptr len) (bytevector->foreign (u8-list->bytevector '(9 8 7)))])
      (assert-equal #vu8() (foreign->bytevector ptr -1) "negative length yields empty")
      (foreign-free ptr)))

  ;; ---- allocate-zeroed 返回清零内存 ----
  (test "allocate-zeroed-is-zeroed"
    (let ([ptr (allocate-zeroed 32)])
      (assert-true (let check ([i 0])
                     (cond [(= i 32) #t]
                           [(= 0 (foreign-ref 'unsigned-8 ptr i)) (check (+ i 1))]
                           [else #f]))
                   "all 32 bytes should be zero")
      (foreign-free ptr)))

  ;; ---- make-uv-buf：正常数据 ----
  (test "make-uv-buf-with-data"
    (let-values ([(buf-ptr data-ptr len) (make-uv-buf "abc")])
      (assert-equal 3 len "len should be 3")
      (assert-equal 3 (uv-buf-len buf-ptr) "uv-buf-len should read back 3")
      (assert-equal data-ptr (uv-buf-base buf-ptr) "uv-buf-base should point at data")
      (assert-equal (char->integer #\a) (foreign-ref 'unsigned-8 data-ptr 0)
                    "first byte should be 'a'")
      (free-uv-buf buf-ptr data-ptr)))

  ;; ---- make-uv-buf：空数据不触发 (foreign-alloc 0) ----
  (test "make-uv-buf-with-empty-data"
    (let-values ([(buf-ptr data-ptr len) (make-uv-buf (make-bytevector 0))])
      (assert-equal 0 len "empty data should report len 0")
      (assert-equal 0 (uv-buf-len buf-ptr) "uv-buf-len should be 0")
      (assert-true (not (= data-ptr 0)) "data-ptr should still be a valid (1-byte) allocation")
      (free-uv-buf buf-ptr data-ptr)))

  ;; ---- copy-bytevector-to-foreign! / copy-foreign-to-bytevector! ----
  (test "copy-helpers-roundtrip"
    (let* ([src (u8-list->bytevector '(10 20 30 40))]
           [ptr (foreign-alloc 4)]
           [dst (make-bytevector 4 0)])
      (copy-bytevector-to-foreign! src ptr)
      (copy-foreign-to-bytevector! ptr dst 4)
      (assert-equal src dst "copy round-trip should be identical")
      (foreign-free ptr)))

  ;; ---- 8 字节批量拷贝：覆盖各种长度（0/7/8/9 及跨边界大块）----
  (test "copy-helpers-various-lengths"
    (for-each
      (lambda (len)
        (let ([src (make-bytevector len)]
              [ptr (foreign-alloc (max len 1))]
              [dst (make-bytevector len 0)])
          ;; 填充可区分的模式
          (do ([i 0 (+ i 1)]) ((= i len))
            (bytevector-u8-set! src i (modulo (* i 7) 256)))
          (copy-bytevector-to-foreign! src ptr)
          (copy-foreign-to-bytevector! ptr dst len)
          (assert-equal src dst
            (format "round-trip must be byte-exact at len=~a" len))
          (foreign-free ptr)))
      '(0 1 7 8 9 15 16 17 63 64 65 1003 4096)))

  )

(run-tests)
