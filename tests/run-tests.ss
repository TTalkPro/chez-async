#!/usr/bin/env scheme-script
;;; tests/run-tests.ss - 测试运行器
;;;
;;; 加载所有库并运行测试

(import (chezscheme))

;; 设置库路径
(library-directories
  '(("." . ".")))

;; 加载所有库
(import (chez-async))
(import (chez-async tests framework))

;; 显示版本
(printf "chez-async test suite~n")
(printf "libuv version: ~a~n~n" (uv-version-string))

;; 运行测试文件
(define (run-test-file file)
  (printf "~n=== Running ~a ===~n" file)
  (load file))

;; 运行所有测试
(run-test-file "tests/test-timer.ss")
(run-test-file "tests/test-async.ss")

(printf "~n=== All tests completed ===~n")
