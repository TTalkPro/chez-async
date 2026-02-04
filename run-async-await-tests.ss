#!/usr/bin/env scheme-script
;;; run-async-await-tests.ss - 运行 async/await 测试

(import (chezscheme))

;; 设置库路径
(library-directories
  '(("." . ".")
    ("./internal" . "./internal")
    ("./high-level" . "./high-level")
    ("./low-level" . "./low-level")
    ("./ffi" . "./ffi")))

;; 加载测试
(load "tests/test-async-await-cc.ss")
