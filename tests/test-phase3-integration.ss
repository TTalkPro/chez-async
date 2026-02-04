#!/usr/bin/env scheme-script
;;; tests/test-phase3-integration.ss - Phase 3 integration tests
;;;
;;; Comprehensive tests for libuv integration with coroutines

(import (chezscheme)
        (chez-async high-level async-await-cc)
        (chez-async high-level promise)
        (chez-async high-level event-loop)
        (chez-async low-level timer)
        (chez-async low-level handle-base)
        (chez-async internal scheduler)
        (chez-async internal coroutine))

(define test-count 0)
(define passed-count 0)
(define failed-tests '())

(define-syntax test
  (syntax-rules ()
    [(test name body ...)
     (begin
       (set! test-count (+ test-count 1))
       (format #t "Test ~a: ~a ... " test-count name)
       (guard (ex
               [else
                (format #t "FAIL~%")
                (format #t "  Error: ~a~%"
                        (if (condition? ex)
                            (if (message-condition? ex)
                                (condition-message ex)
                                ex)
                            ex))
                (set! failed-tests (cons name failed-tests))])
         (begin body ...)
         (format #t "PASS~%")
         (set! passed-count (+ passed-count 1))))]))

(format #t "~%╔════════════════════════════════════════╗~%")
(format #t "║   Phase 3 Integration Tests            ║~%")
(format #t "╚════════════════════════════════════════╝~%~%")

;; ========================================
;; Test Suite 1: Timer Integration
;; ========================================

(format #t "Suite 1: Timer Integration~%")
(format #t "──────────────────────────~%")

(define (make-delay-promise ms value)
  "Create a Promise that resolves after ms milliseconds"
  (make-promise (uv-default-loop)
    (lambda (resolve reject)
      (let ([timer (uv-timer-init (uv-default-loop))])
        (uv-timer-start! timer ms 0
          (lambda (t)
            (uv-handle-close! t)
            (resolve value)))))))

(test "Single timer with await"
  (let ([result (run-async
                  (async
                    (await (make-delay-promise 10 42))))])
    (unless (= result 42)
      (error 'test "Expected 42, got" result))))

(test "Multiple sequential timers"
  (let ([result (run-async
                  (async
                    (let* ([a (await (make-delay-promise 10 10))]
                           [b (await (make-delay-promise 10 20))]
                           [c (await (make-delay-promise 10 12))])
                      (+ a b c))))])
    (unless (= result 42)
      (error 'test "Expected 42, got" result))))

(test "Concurrent timer promises"
  (let ([p1 (make-delay-promise 30 1)]
        [p2 (make-delay-promise 20 2)]
        [p3 (make-delay-promise 25 3)])
    (let ([result (run-async
                    (async
                      (let* ([r1 (await p1)]
                             [r2 (await p2)]
                             [r3 (await p3)])
                        (list r1 r2 r3))))])
      (unless (equal? result '(1 2 3))
        (error 'test "Expected (1 2 3), got" result)))))

(test "Zero delay timer"
  (let ([result (run-async
                  (async
                    (await (make-delay-promise 0 'immediate))))])
    (unless (eq? result 'immediate)
      (error 'test "Expected 'immediate, got" result))))

;; ========================================
;; Test Suite 2: Coroutine Management
;; ========================================

(format #t "~%Suite 2: Coroutine Management~%")
(format #t "─────────────────────────────~%")

(test "Coroutine state transitions"
  (let* ([loop (uv-default-loop)]
         [sched (get-scheduler loop)]
         [coro-ref #f])
    (let ([p (async
               (set! coro-ref (current-coroutine))
               (await (make-delay-promise 10 'done))
               'result)])
      (run-async p)
      ;; After completion, coroutine should exist
      (unless coro-ref
        (error 'test "Coroutine reference not captured")))))

(test "Multiple coroutines in scheduler"
  (let* ([results '()]
         [p1 (async
               (await (make-delay-promise 20 #t))
               (set! results (cons 1 results)))]
         [p2 (async
               (await (make-delay-promise 15 #t))
               (set! results (cons 2 results)))]
         [p3 (async
               (await (make-delay-promise 25 #t))
               (set! results (cons 3 results)))])
    (run-async p1)
    (run-async p2)
    (run-async p3)
    (unless (= (length results) 3)
      (error 'test "Expected 3 results, got" (length results)))))

(test "Nested async blocks"
  (let ([result (run-async
                  (async
                    (let ([inner (async
                                   (await (make-delay-promise 10 21)))])
                      (* 2 (await inner)))))])
    (unless (= result 42)
      (error 'test "Expected 42, got" result))))

;; ========================================
;; Test Suite 3: Error Handling
;; ========================================

(format #t "~%Suite 3: Error Handling~%")
(format #t "────────────────────────~%")

(test "Catch error in async block"
  (let ([result (run-async
                  (async
                    (guard (ex
                            [else 'caught])
                      (await (make-delay-promise 10 #t))
                      (error 'test "test error"))))])
    (unless (eq? result 'caught)
      (error 'test "Expected 'caught, got" result))))

(test "Error in nested await"
  (let ([result (run-async
                  (async
                    (guard (ex
                            [else 'recovered])
                      (let* ([x (await (make-delay-promise 10 10))]
                             [y (await (promise-rejected (uv-default-loop) "fail"))])
                        (+ x y)))))])
    (unless (eq? result 'recovered)
      (error 'test "Expected 'recovered, got" result))))

(test "Error propagates through multiple awaits"
  (let ([result (run-async
                  (async
                    (guard (ex
                            [else 'caught])
                      (let ([p1 (async
                                  (await (make-delay-promise 10 #t))
                                  (error 'inner "inner error"))])
                        (await p1)))))])
    (unless (eq? result 'caught)
      (error 'test "Expected 'caught, got" result))))

;; ========================================
;; Test Suite 4: Scheduler Behavior
;; ========================================

(format #t "~%Suite 4: Scheduler Behavior~%")
(format #t "────────────────────────────~%")

(test "Scheduler handles empty queue"
  (let* ([loop (uv-default-loop)]
         [sched (get-scheduler loop)])
    (run-scheduler loop)  ; Should not hang
    #t))

(test "Scheduler runnable queue operations"
  (let* ([loop (uv-default-loop)]
         [sched (get-scheduler loop)]
         [queue (scheduler-runnable-queue sched)])
    (unless (queue-empty? queue)
      (error 'test "Queue should be empty initially"))
    #t))

(test "Multiple run-scheduler calls"
  (let ([result1 (run-async (async (await (make-delay-promise 10 1))))]
        [result2 (run-async (async (await (make-delay-promise 10 2))))])
    (unless (and (= result1 1) (= result2 2))
      (error 'test "Expected 1 and 2, got" result1 result2))))

;; ========================================
;; Test Suite 5: Performance Characteristics
;; ========================================

(format #t "~%Suite 5: Performance Characteristics~%")
(format #t "─────────────────────────────────────~%")

(test "Many short-lived coroutines"
  (let ([results '()])
    (do ([i 0 (+ i 1)])
        ((= i 50))
      (let ([p (async
                 (await (make-delay-promise 5 i)))])
        (set! results (cons (run-async p) results))))
    (unless (= (length results) 50)
      (error 'test "Expected 50 results, got" (length results)))))

(test "Deep await chain"
  (define (make-chain n)
    (if (= n 0)
        (async 0)
        (async
          (let ([x (await (make-chain (- n 1)))])
            (+ x 1)))))

  (let ([result (run-async (make-chain 10))])
    (unless (= result 10)
      (error 'test "Expected 10, got" result))))

;; ========================================
;; Test Suite 6: Real-world Patterns
;; ========================================

(format #t "~%Suite 6: Real-world Patterns~%")
(format #t "────────────────────────────~%")

(test "Sequential data pipeline"
  (define (fetch) (async (await (make-delay-promise 10 '(1 2 3)))))
  (define (process data) (async (await (make-delay-promise 10 (map (lambda (x) (* x 2)) data)))))
  (define (save data) (async (await (make-delay-promise 10 'saved))))

  (let ([result (run-async
                  (async
                    (let* ([data (await (fetch))]
                           [processed (await (process data))]
                           [saved (await (save processed))])
                      processed)))])
    (unless (equal? result '(2 4 6))
      (error 'test "Expected (2 4 6), got" result))))

(test "Retry pattern"
  (let ([attempts 0])
    (define (unreliable-op)
      (async
        (set! attempts (+ attempts 1))
        (await (make-delay-promise 5 #t))
        (if (< attempts 3)
            (error 'op "Not yet")
            'success)))

    (define (retry op max-tries)
      (async
        (let loop ([n 0])
          (guard (ex
                  [else
                   (if (< n max-tries)
                       (begin
                         (await (make-delay-promise 5 #t))
                         (loop (+ n 1)))
                       (raise ex))])
            (await (op))))))

    (let ([result (run-async (retry unreliable-op 5))])
      (unless (eq? result 'success)
        (error 'test "Expected 'success, got" result)))))

(test "Concurrent operations pattern"
  (let* ([p1 (async (await (make-delay-promise 20 1)))]
         [p2 (async (await (make-delay-promise 15 2)))]
         [p3 (async (await (make-delay-promise 25 3)))])
    (let ([result (run-async
                    (async
                      (let* ([r1 (await p1)]
                             [r2 (await p2)]
                             [r3 (await p3)])
                        (+ r1 r2 r3))))])
      (unless (= result 6)
        (error 'test "Expected 6, got" result)))))

;; ========================================
;; Test Summary
;; ========================================

(format #t "~%╔════════════════════════════════════════╗~%")
(format #t "║           Test Summary                 ║~%")
(format #t "╚════════════════════════════════════════╝~%~%")

(format #t "Total tests:  ~a~%" test-count)
(format #t "Passed:       ~a~%" passed-count)
(format #t "Failed:       ~a~%" (- test-count passed-count))

(when (not (null? failed-tests))
  (format #t "~%Failed tests:~%")
  (for-each (lambda (name)
              (format #t "  - ~a~%" name))
            (reverse failed-tests)))

(format #t "~%")
(if (= passed-count test-count)
    (begin
      (format #t "✓ All tests passed! 🎉~%~%")
      (exit 0))
    (begin
      (format #t "✗ Some tests failed~%~%")
      (exit 1)))
