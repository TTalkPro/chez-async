#!/usr/bin/env scheme-script
;;; run-coroutine-tests.ss - 运行协程测试

(import (chezscheme))

;; 设置库路径
(library-directories
  '(("." . ".")
    ("./internal" . "./internal")
    ("./high-level" . "./high-level")
    ("./low-level" . "./low-level")
    ("./ffi" . "./ffi")))

;; 加载测试
(load "tests/test-coroutine.ss")
