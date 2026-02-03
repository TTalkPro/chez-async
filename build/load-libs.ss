;;; build/load-libs.ss - 加载所有库
;;;
;;; 用于交互式开发和测试

;; 添加库搜索路径
(library-directories
  (cons "."
        (cons ".."
              (library-directories))))

;; 加载所有库
(import (chez-async))

(printf "chez-async loaded successfully!~n")
(printf "libuv version: ~a~n" (uv-version-string))
(printf "~n")
(printf "Available APIs:~n")
(printf "  Event Loop: uv-loop-init, uv-run, uv-stop, etc.~n")
(printf "  Timer: uv-timer-init, uv-timer-start!, etc.~n")
(printf "~n")
(printf "Try: (define loop (uv-loop-init))~n")
