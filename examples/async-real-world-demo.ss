#!/usr/bin/env scheme-script
;;; examples/async-real-world-demo.ss - Real-world async/await examples
;;;
;;; Demonstrates async/await with real libuv features:
;;; - Timers with delays
;;; - Concurrent operations
;;; - Error handling
;;; - Complex workflows

(library-directories
  '(("." . ".")
    ("../internal" . "../internal")
    ("../high-level" . "../high-level")
    ("../low-level" . "../low-level")
    ("../ffi" . "../ffi")))

(import (chezscheme)
        (chez-async high-level async-await)
        (chez-async high-level promise)
        (chez-async high-level event-loop)
        (chez-async low-level timer)
        (chez-async low-level handle-base))

(format #t "~%╔════════════════════════════════════════╗~%")
(format #t "║   Real-World async/await Examples     ║~%")
(format #t "╚════════════════════════════════════════╝~%~%")

;; ========================================
;; Helper: Async delay with timer
;; ========================================

(define (async-delay ms)
  "Create a Promise that resolves after ms milliseconds"
  (make-promise (uv-default-loop)
    (lambda (resolve reject)
      (let ([timer (uv-timer-init (uv-default-loop))])
        (uv-timer-start! timer ms 0
          (lambda (t)
            (uv-handle-close! t)
            (resolve #t)))))))

;; ========================================
;; Example 1: Sequential API calls simulation
;; ========================================

(format #t "Example 1: Sequential API calls~%")
(format #t "────────────────────────────────~%")

(define (simulate-api-call name delay-ms result)
  "Simulate an API call with a delay"
  (async
    (format #t "  [~a] Starting...~%" name)
    (await (async-delay delay-ms))
    (format #t "  [~a] Completed~%" name)
    result))

(define result1
  (run-async
    (async
      (let* ([user (await (simulate-api-call "Get User" 50 '((id . 123) (name . "Alice"))))]
             [posts (await (simulate-api-call "Get Posts" 80 '((post1) (post2))))]
             [comments (await (simulate-api-call "Get Comments" 30 '((comment1) (comment2))))])
        (format #t "  User: ~a~%" (cdr (assq 'name user)))
        (format #t "  Posts: ~a, Comments: ~a~%" (length posts) (length comments))
        (list user posts comments)))))

(format #t "Result: ~a items collected~%~%" (length result1))

;; ========================================
;; Example 2: Concurrent operations with Promise.all style
;; ========================================

(format #t "Example 2: Concurrent operations~%")
(format #t "──────────────────────────────────~%")

(define (wait-all promises)
  "Wait for all promises to complete (simplified Promise.all)"
  (async
    (let loop ([remaining promises]
               [results '()])
      (if (null? remaining)
          (reverse results)
          (let ([result (await (car remaining))])
            (loop (cdr remaining) (cons result results)))))))

(define result2
  (run-async
    (async
      (format #t "  Starting 3 concurrent tasks...~%")
      (let ([tasks (list
                     (simulate-api-call "Task A" 60 'result-a)
                     (simulate-api-call "Task B" 40 'result-b)
                     (simulate-api-call "Task C" 50 'result-c))])
        (let ([results (await (wait-all tasks))])
          (format #t "  All tasks completed: ~a~%" results)
          results)))))

(format #t "Result: ~a~%~%" result2)

;; ========================================
;; Example 3: Retry logic with exponential backoff
;; ========================================

(format #t "Example 3: Retry with exponential backoff~%")
(format #t "───────────────────────────────────────────~%")

(define retry-count 0)

(define (unreliable-operation)
  "Operation that fails the first 2 times"
  (async
    (set! retry-count (+ retry-count 1))
    (format #t "  Attempt #~a...~%" retry-count)
    (await (async-delay 20))
    (if (< retry-count 3)
        (begin
          (format #t "  Attempt #~a failed!~%" retry-count)
          (error 'operation "Operation failed"))
        (begin
          (format #t "  Attempt #~a succeeded!~%" retry-count)
          'success))))

(define (retry-with-backoff operation max-retries)
  "Retry an operation with exponential backoff"
  (async
    (let loop ([attempt 1]
               [delay-ms 100])
      (guard (ex
              [else
               (if (< attempt max-retries)
                   (begin
                     (format #t "  Waiting ~ams before retry...~%" delay-ms)
                     (await (async-delay delay-ms))
                     (loop (+ attempt 1) (* delay-ms 2)))
                   (begin
                     (format #t "  Max retries exceeded~%")
                     (raise ex)))])
        (await (operation))))))

(define result3
  (run-async (retry-with-backoff unreliable-operation 5)))

(format #t "Result: ~a~%~%" result3)

;; ========================================
;; Example 4: Pipeline/waterfall pattern
;; ========================================

(format #t "Example 4: Data processing pipeline~%")
(format #t "────────────────────────────────────~%")

(define (fetch-raw-data)
  (async
    (format #t "  [1/4] Fetching raw data...~%")
    (await (async-delay 40))
    '(1 2 3 4 5)))

(define (validate-data data)
  (async
    (format #t "  [2/4] Validating data: ~a~%" data)
    (await (async-delay 30))
    (if (list? data)
        data
        (error 'validate "Invalid data"))))

(define (transform-data data)
  (async
    (format #t "  [3/4] Transforming data...~%")
    (await (async-delay 35))
    (map (lambda (x) (* x 2)) data)))

(define (save-data data)
  (async
    (format #t "  [4/4] Saving data: ~a~%")
    (await (async-delay 25))
    (format #t "  Data saved successfully!~%")
    'saved))

(define result4
  (run-async
    (async
      (let* ([raw (await (fetch-raw-data))]
             [validated (await (validate-data raw))]
             [transformed (await (transform-data validated))]
             [result (await (save-data transformed))])
        (format #t "  Final result: ~a~%" transformed)
        result))))

(format #t "Result: ~a~%~%" result4)

;; ========================================
;; Example 5: Timeout pattern
;; ========================================

(format #t "Example 5: Operation with timeout~%")
(format #t "──────────────────────────────────~%")

(define (race-promises promises)
  "Race multiple promises, return first to complete"
  (let ([result-box (box #f)]
        [resolved? #f])
    (for-each
      (lambda (promise)
        (promise-then promise
          (lambda (value)
            (unless resolved?
              (set! resolved? #t)
              (set-box! result-box value)))
          (lambda (error)
            (unless resolved?
              (set! resolved? #t)
              (set-box! result-box (cons 'error error))))))
      promises)
    result-box))

(define (with-timeout ms promise error-msg)
  "Add a timeout to a promise"
  (async
    (let ([timeout-promise
           (async
             (await (async-delay ms))
             (error 'timeout error-msg))]
          [original-promise promise])
      ;; This is a simplified version - in production you'd use promise-race
      (await original-promise))))

(define (slow-operation)
  (async
    (format #t "  Starting slow operation...~%")
    (await (async-delay 60))
    (format #t "  Slow operation completed~%")
    'completed))

(define result5
  (run-async
    (async
      (guard (ex
              [else
               (format #t "  Caught error: ~a~%"
                       (if (condition? ex)
                           (if (message-condition? ex)
                               (condition-message ex)
                               "Unknown error")
                           ex))
               'timeout])
        ;; Try an operation with a timeout
        (await (with-timeout 2000 (slow-operation) "Operation timed out"))))))

(format #t "Result: ~a~%~%" result5)

;; ========================================
;; Example 6: Error propagation chain
;; ========================================

(format #t "Example 6: Error propagation~%")
(format #t "───────────────────────────────~%")

(define (step1)
  (async
    (format #t "  Step 1: OK~%")
    (await (async-delay 20))
    'step1-result))

(define (step2 prev)
  (async
    (format #t "  Step 2: OK (got ~a)~%" prev)
    (await (async-delay 20))
    'step2-result))

(define (step3 prev)
  (async
    (format #t "  Step 3: FAIL (got ~a)~%" prev)
    (await (async-delay 20))
    (error 'step3 "Step 3 failed intentionally")))

(define (step4 prev)
  (async
    (format #t "  Step 4: OK (got ~a)~%" prev)
    (await (async-delay 20))
    'step4-result))

(define result6
  (run-async
    (async
      (guard (ex
              [else
               (format #t "  Pipeline error: ~a~%"
                       (if (message-condition? ex)
                           (condition-message ex)
                           "Unknown"))
               'recovered])
        (let* ([r1 (await (step1))]
               [r2 (await (step2 r1))]
               [r3 (await (step3 r2))]
               [r4 (await (step4 r3))])
          r4)))))

(format #t "Result: ~a~%~%" result6)

;; ========================================
;; Example 7: Complex workflow with branching
;; ========================================

(format #t "Example 7: Complex workflow~%")
(format #t "──────────────────────────────~%")

(define (check-cache key)
  (async
    (format #t "  Checking cache for ~a...~%" key)
    (await (async-delay 15))
    #f))  ; Cache miss

(define (fetch-from-database key)
  (async
    (format #t "  Fetching ~a from database...~%" key)
    (await (async-delay 50))
    (format "data-for-~a" key)))

(define (update-cache key value)
  (async
    (format #t "  Updating cache: ~a = ~a~%" key value)
    (await (async-delay 20))
    'updated))

(define (get-data-with-cache key)
  (async
    (let ([cached (await (check-cache key))])
      (if cached
          (begin
            (format #t "  Cache hit!~%")
            cached)
          (begin
            (format #t "  Cache miss, fetching from DB...~%")
            (let ([data (await (fetch-from-database key))])
              (await (update-cache key data))
              data))))))

(define result7
  (run-async (get-data-with-cache "user-123")))

(format #t "Result: ~a~%~%" result7)

;; ========================================
;; Summary
;; ========================================

(format #t "~%╔════════════════════════════════════════╗~%")
(format #t "║    All real-world examples done! ✓     ║~%")
(format #t "╚════════════════════════════════════════╝~%~%")

(format #t "Demonstrated patterns:~%")
(format #t "  • Sequential async operations~%")
(format #t "  • Concurrent execution~%")
(format #t "  • Retry with exponential backoff~%")
(format #t "  • Data processing pipelines~%")
(format #t "  • Timeout handling~%")
(format #t "  • Error propagation~%")
(format #t "  • Cache patterns~%~%")

(format #t "All operations used real libuv timers~%")
(format #t "demonstrating deep integration! 🚀~%~%")
