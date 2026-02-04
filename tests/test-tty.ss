#!/usr/bin/env scheme-script
;;; tests/test-tty.ss - TTY 功能测试
;;;
;;; 注意：TTY 测试需要在真实终端中运行。
;;; 某些测试可能在非交互环境（如 CI）中跳过。

(import (chezscheme)
        (chez-async tests framework)
        (chez-async high-level event-loop)
        (chez-async low-level tty)
        (chez-async low-level handle-base))

;; 辅助函数：检查是否在 TTY 中运行
(define %isatty
  (foreign-procedure "isatty" (int) int))

(define (is-tty? fd)
  (not (= 0 (%isatty fd))))

(test-group "TTY Tests"

  (test "tty-constants"
    ;; 验证常量定义正确
    (assert-equal 0 UV_TTY_MODE_NORMAL "UV_TTY_MODE_NORMAL should be 0")
    (assert-equal 1 UV_TTY_MODE_RAW "UV_TTY_MODE_RAW should be 1")
    (assert-equal 2 UV_TTY_MODE_IO "UV_TTY_MODE_IO should be 2")
    (assert-equal 0 STDIN_FILENO "STDIN_FILENO should be 0")
    (assert-equal 1 STDOUT_FILENO "STDOUT_FILENO should be 1")
    (assert-equal 2 STDERR_FILENO "STDERR_FILENO should be 2"))

  ;; 以下测试只在真实 TTY 中运行
  (when (is-tty? 1)  ; 检查 stdout 是否是 TTY
    (test "tty-init-stdout"
      (let* ([loop (uv-loop-init)]
             [tty (uv-tty-init-stdout loop)])
        ;; 验证 TTY 句柄创建成功
        (assert-true (handle? tty) "should be a handle")
        (assert-equal 'tty (handle-type tty) "should be tty type")
        ;; 清理
        (uv-handle-close! tty)
        (uv-run loop 'default)
        (uv-loop-close loop)))

    (test "tty-get-winsize"
      (let* ([loop (uv-loop-init)]
             [tty (uv-tty-init-stdout loop)])
        ;; 获取窗口大小
        (let ([size (uv-tty-get-winsize tty)])
          (assert-true (pair? size) "should return a pair")
          (assert-true (> (car size) 0) "width should be positive")
          (assert-true (> (cdr size) 0) "height should be positive")
          (printf "  [Info] Terminal size: ~ax~a~n" (car size) (cdr size)))
        ;; 清理
        (uv-handle-close! tty)
        (uv-run loop 'default)
        (uv-loop-close loop)))

    (test "tty-set-mode"
      (let* ([loop (uv-loop-init)]
             [tty (uv-tty-init-stdout loop)])
        ;; 设置正常模式
        (uv-tty-set-mode! tty UV_TTY_MODE_NORMAL)
        ;; 清理
        (uv-handle-close! tty)
        (uv-run loop 'default)
        (uv-loop-close loop)))

    (test "tty-reset-mode"
      ;; 重置模式不需要 TTY 句柄
      (uv-tty-reset-mode!))

    (test "tty-write"
      (let* ([loop (uv-loop-init)]
             [tty (uv-tty-init-stdout loop)]
             [write-complete? #f])
        ;; 写入测试消息
        (uv-write! tty "  [TTY Write Test] Hello from TTY!\n"
          (lambda (err)
            (set! write-complete? #t)
            (when err
              (printf "Write error: ~a~n" err))))
        ;; 运行事件循环
        (uv-run loop 'default)
        ;; 验证写入完成
        (assert-true write-complete? "write should complete")
        ;; 清理
        (uv-handle-close! tty)
        (uv-run loop 'default)
        (uv-loop-close loop))))

  ;; 非 TTY 环境的提示
  (unless (is-tty? 1)
    (printf "~n[Note] Some TTY tests were skipped (not running in a terminal)~n"))

) ; end test-group

(run-tests)
