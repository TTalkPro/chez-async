#!/usr/bin/env scheme-script
;;; examples/simple-timer.ss - 最简单的 timer 示例

;; 添加库路径
(library-directories
  (cons ".."
        (library-directories)))

(import (chezscheme)
        (chez-async))

(printf "Starting simple timer example...~n")

;; 创建事件循环
(define loop (uv-loop-init))

;; 创建定时器
(define timer (uv-timer-init loop))

;; 启动 1 秒后触发的单次定时器
(uv-timer-start! timer 1000 0
  (lambda (t)
    (printf "Timer fired after 1 second!~n")
    (uv-handle-close! t)))

;; 运行事件循环
(printf "Running event loop...~n")
(uv-run loop 'default)

;; 清理
(uv-loop-close loop)

(printf "Done!~n")
