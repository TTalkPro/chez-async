#!/usr/bin/env scheme-script
;;; tests/test-cancellation.ss - 取消令牌测试

(library-directories
  '(("." . ".")
    ("../internal" . "../internal")
    ("../high-level" . "../high-level")
    ("../low-level" . "../low-level")
    ("../ffi" . "../ffi")))

(import (chezscheme)
        (chez-async high-level async-await)
        (chez-async high-level async-combinators)
        (chez-async high-level cancellation)
        (chez-async high-level promise)
        (chez-async high-level event-loop))

(format #t "~%╔════════════════════════════════════════╗~%")
(format #t "║  Cancellation Token Tests             ║~%")
(format #t "╚════════════════════════════════════════╝~%~%")

;; ========================================
;; 辅助函数
;; ========================================

(define (test-passed name)
  (format #t "✓ ~a~%" name))

(define (test-failed name error)
  (format #t "✗ ~a: ~a~%" name error))

;; ========================================
;; 测试 1: 基本的 CancellationTokenSource
;; ========================================

(format #t "Test 1: Basic CancellationTokenSource~%")
(format #t "──────────────────────────────────────~%")

(let ([cts (make-cancellation-token-source)])
  (format #t "  Created CTS~%")
  (format #t "  Initial cancelled?: ~a~%" (cts-cancelled? cts))

  (if (cts-cancelled? cts)
      (test-failed "CTS initial state" "should not be cancelled")
      (begin
        ;; 取消
        (cts-cancel! cts)
        (format #t "  After cancel: ~a~%" (cts-cancelled? cts))

        (if (cts-cancelled? cts)
            (test-passed "Basic CancellationTokenSource")
            (test-failed "CTS cancel" "should be cancelled")))))

(format #t "~%")

;; ========================================
;; 测试 2: Token 回调注册
;; ========================================

(format #t "Test 2: Token callback registration~%")
(format #t "─────────────────────────────────────~%")

(let ([cts (make-cancellation-token-source)]
      [callback-called? #f])
  (let ([token (cts-token cts)])
    ;; 注册回调
    (token-register! token
      (lambda ()
        (format #t "  Callback invoked!~%")
        (set! callback-called? #t)))

    ;; 取消
    (format #t "  Cancelling...~%")
    (cts-cancel! cts)

    (if callback-called?
        (test-passed "Token callback registration")
        (test-failed "Token callback" "callback not called"))))

(format #t "~%")

;; ========================================
;; 测试 3: 已取消令牌的立即回调
;; ========================================

(format #t "Test 3: Immediate callback on cancelled token~%")
(format #t "──────────────────────────────────────────────~%")

(let ([cts (make-cancellation-token-source)]
      [callback-called? #f])
  ;; 先取消
  (cts-cancel! cts)
  (format #t "  Token already cancelled~%")

  ;; 然后注册回调（应该立即调用）
  (token-register! (cts-token cts)
    (lambda ()
      (format #t "  Immediate callback invoked!~%")
      (set! callback-called? #t)))

  (if callback-called?
      (test-passed "Immediate callback on cancelled token")
      (test-failed "Immediate callback" "callback not called")))

(format #t "~%")

;; ========================================
;; 测试 4: async-with-cancellation - 操作完成
;; ========================================

(format #t "Test 4: async-with-cancellation (completes)~%")
(format #t "──────────────────────────────────────────────~%")

(let ([cts (make-cancellation-token-source)])
  (guard (ex
          [else
           (test-failed "async-with-cancellation (completes)"
                       (format "unexpected error: ~a" ex))])
    (let ([result
           (run-async
             (async-with-cancellation (cts-token cts)
               (async
                 (await (async-sleep 50))
                 'completed)))])
      (format #t "  Result: ~a~%" result)
      (if (eq? result 'completed)
          (test-passed "async-with-cancellation (completes)")
          (test-failed "async-with-cancellation"
                      (format "expected 'completed, got ~a" result))))))

(format #t "~%")

;; ========================================
;; 测试 5: async-with-cancellation - 被取消
;; ========================================

(format #t "Test 5: async-with-cancellation (cancelled)~%")
(format #t "───────────────────────────────────────────────~%")

(let ([cts (make-cancellation-token-source)])
  ;; 启动操作
  (format #t "  Starting operation...~%")

  (guard (ex
          [(operation-cancelled? ex)
           (format #t "  Caught cancellation: ~a~%"
                   (if (message-condition? ex)
                       (condition-message ex)
                       "cancelled"))
           (test-passed "async-with-cancellation (cancelled)")]
          [else
           (test-failed "async-with-cancellation (cancelled)"
                       (format "unexpected error: ~a" ex))])

    ;; 先取消令牌
    (cts-cancel! cts)
    (format #t "  Token cancelled~%")

    ;; 尝试执行操作（应该立即失败）
    (run-async
      (async-with-cancellation (cts-token cts)
        (async
          (await (async-sleep 1000))
          'should-not-reach)))))

(format #t "~%")

;; ========================================
;; 测试 6: 操作中途取消
;; ========================================

(format #t "Test 6: Cancel during operation~%")
(format #t "─────────────────────────────────~%")

(let ([cts (make-cancellation-token-source)])
  (format #t "  Starting long operation...~%")

  ;; 100ms 后取消
  (run-async
    (async
      (await (async-sleep 100))
      (format #t "  Cancelling token...~%")
      (cts-cancel! cts)))

  ;; 尝试执行 200ms 的操作
  (guard (ex
          [(operation-cancelled? ex)
           (format #t "  Operation cancelled as expected~%")
           (test-passed "Cancel during operation")]
          [else
           (test-failed "Cancel during operation"
                       (format "unexpected error: ~a" ex))])
    (run-async
      (async-with-cancellation (cts-token cts)
        (async
          (await (async-sleep 200))
          'should-not-complete)))))

(format #t "~%")

;; ========================================
;; 测试 7: linked-token-source
;; ========================================

(format #t "Test 7: linked-token-source~%")
(format #t "─────────────────────────────~%")

(let* ([cts1 (make-cancellation-token-source)]
       [cts2 (make-cancellation-token-source)]
       [linked-cts (linked-token-source
                     (cts-token cts1)
                     (cts-token cts2))])

  (format #t "  Created linked token source~%")
  (format #t "  Initial state: ~a~%" (cts-cancelled? linked-cts))

  ;; 取消第一个父令牌
  (format #t "  Cancelling parent token 1...~%")
  (cts-cancel! cts1)

  ;; 链接的令牌应该自动取消
  (format #t "  Linked token cancelled?: ~a~%" (cts-cancelled? linked-cts))

  (if (cts-cancelled? linked-cts)
      (test-passed "linked-token-source")
      (test-failed "linked-token-source" "should be cancelled")))

(format #t "~%")

;; ========================================
;; 测试 8: 超时自动取消
;; ========================================

(format #t "Test 8: Timeout with cancellation~%")
(format #t "──────────────────────────────────~%")

(let ([cts (make-cancellation-token-source)])
  ;; 设置 100ms 超时
  (run-async
    (async
      (await (async-sleep 100))
      (format #t "  Timeout reached, cancelling...~%")
      (cts-cancel! cts)))

  ;; 执行操作
  (guard (ex
          [(operation-cancelled? ex)
           (format #t "  Operation cancelled by timeout~%")
           (test-passed "Timeout with cancellation")]
          [else
           (test-failed "Timeout with cancellation"
                       (format "unexpected error: ~a" ex))])
    (run-async
      (async-with-cancellation (cts-token cts)
        (async
          (await (async-sleep 200))
          'should-timeout)))))

(format #t "~%")

;; ========================================
;; 测试 9: 实战场景 - 可取消的下载
;; ========================================

(format #t "Test 9: Practical - Cancellable download~%")
(format #t "──────────────────────────────────────────~%")

(define (simulate-download cts-token url)
  "模拟可取消的下载"
  (async
    (format #t "  [Download] Starting: ~a~%" url)

    ;; 使用带取消的操作
    (await (async-with-cancellation cts-token
             (async
               ;; 模拟分块下载
               (let loop ([chunks 0])
                 (when (< chunks 5)
                   (format #t "  [Download] Chunk ~a/5~%" (+ chunks 1))
                   (await (async-sleep 50))
                   (loop (+ chunks 1))))
               'download-complete)))

    (format #t "  [Download] Completed!~%")
    'success))

(let ([cts (make-cancellation-token-source)])
  ;; 150ms 后取消（下载进行到一半）
  (run-async
    (async
      (await (async-sleep 150))
      (format #t "  [User] Clicked cancel button~%")
      (cts-cancel! cts)))

  ;; 尝试下载
  (guard (ex
          [(operation-cancelled? ex)
           (format #t "  [Download] Cancelled by user~%")
           (test-passed "Practical - Cancellable download")]
          [else
           (test-failed "Cancellable download"
                       (format "unexpected error: ~a" ex))])
    (run-async
      (simulate-download (cts-token cts) "http://example.com/large-file.zip"))))

(format #t "~%")

;; ========================================
;; 测试总结
;; ========================================

(format #t "╔════════════════════════════════════════╗~%")
(format #t "║  All Tests Completed                  ║~%")
(format #t "╚════════════════════════════════════════╝~%~%")

(format #t "Key Features Demonstrated:~%")
(format #t "  • CancellationTokenSource 创建和取消~%")
(format #t "  • Token 回调注册~%")
(format #t "  • async-with-cancellation 集成~%")
(format #t "  • 操作中途取消~%")
(format #t "  • linked-token-source 链接令牌~%")
(format #t "  • 超时自动取消~%")
(format #t "  • 实战场景：可取消的下载~%~%")
