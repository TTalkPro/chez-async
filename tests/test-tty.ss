#!/usr/bin/env scheme-script
;;; tests/test-tty.ss - TTY 功能测试

(import (chezscheme)
        (chez-async tests framework)
        (chez-async high-level event-loop)
        (chez-async low-level tty)
        (chez-async low-level handle-base)
        (chez-async internal posix-ffi))

;; 辅助函数：检查是否在 TTY 中运行
(define (is-tty? fd)
  (and (posix-ffi-available?)
       (not (= 0 (posix-isatty fd)))))

(test-group "TTY Tests"

  (test "tty-constants"
    ;; 验证常量定义正确（不需要 TTY）
    (assert-equal 0 UV_TTY_MODE_NORMAL "UV_TTY_MODE_NORMAL should be 0")
    (assert-equal 1 UV_TTY_MODE_RAW "UV_TTY_MODE_RAW should be 1")
    (assert-equal 2 UV_TTY_MODE_IO "UV_TTY_MODE_IO should be 2")
    (assert-equal 0 STDIN_FILENO "STDIN_FILENO should be 0")
    (assert-equal 1 STDOUT_FILENO "STDOUT_FILENO should be 1")
    (assert-equal 2 STDERR_FILENO "STDERR_FILENO should be 2"))

  ;; 如果在交互式终端中，运行更多测试
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
          (assert-true (> (cdr size) 0) "height should be positive"))
        ;; 清理
        (uv-handle-close! tty)
        (uv-run loop 'default)
        (uv-loop-close loop)))

    (test "tty-set-mode"
      (let* ([loop (uv-loop-init)]
             [tty (uv-tty-init-stdout loop)])
        ;; 设置为原始模式
        (uv-tty-set-mode! tty UV_TTY_MODE_RAW)
        ;; 恢复正常模式
        (uv-tty-set-mode! tty UV_TTY_MODE_NORMAL)
        ;; 清理
        (uv-handle-close! tty)
        (uv-run loop 'default)
        (uv-loop-close loop)))

    (test "tty-reset"
      (let* ([loop (uv-loop-init)]
             [tty (uv-tty-init-stdout loop)])
        ;; 重置所有终端为原始模式
        (uv-tty-reset-mode!)
        ;; 清理
        (uv-handle-close! tty)
        (uv-run loop 'default)
        (uv-loop-close loop)))

    ;; 非交互式环境中的测试
    (test "tty-init-non-terminal"
      ;; 在非终端文件描述符上也能初始化（会失败但测试了 API）
      (let* ([loop (uv-loop-init)]
             [result (guard (e [else e])
                        (uv-tty-init loop 0))])  ; stdin
        ;; 非终端中初始化会失败，这是预期的
        (printf "Note: TTY init on non-terminal: ~a~n"
                (if (condition? result) "failed (expected)" "succeeded"))
        ;; 清理
        (uv-run loop 'default)
        (uv-loop-close loop))))

  ) ; end test-group

(run-tests)
