;;; tests/loop-identity-test.ss - 测试 loop 对象的一致性

(import (chezscheme)
        (chez-async high-level event-loop))

(format #t "~%=== Loop 对象一致性测试 ===~%~%")

;; 测试多次调用 uv-default-loop 是否返回相同的对象
(let ([loop1 (uv-default-loop)]
      [loop2 (uv-default-loop)]
      [loop3 (uv-default-loop)])

  (format #t "loop1: ~a~%" loop1)
  (format #t "loop2: ~a~%" loop2)
  (format #t "loop3: ~a~%" loop3)
  (format #t "~%")

  (format #t "loop1 eq? loop2: ~a~%" (eq? loop1 loop2))
  (format #t "loop2 eq? loop3: ~a~%" (eq? loop2 loop3))
  (format #t "~%")

  (format #t "loop1 ptr: ~a~%" (uv-loop-ptr loop1))
  (format #t "loop2 ptr: ~a~%" (uv-loop-ptr loop2))
  (format #t "loop3 ptr: ~a~%" (uv-loop-ptr loop3))
  (format #t "~%")

  (format #t "ptr1 = ptr2: ~a~%" (= (uv-loop-ptr loop1) (uv-loop-ptr loop2)))
  (format #t "ptr2 = ptr3: ~a~%" (= (uv-loop-ptr loop2) (uv-loop-ptr loop3))))

(format #t "~%=== 测试完成 ===~%")
