#!/usr/bin/env scheme-script
;;; examples/async-await-cc-demo.ss - async/await (call/cc version) demo
;;;
;;; Demonstrates the use of async/await syntax with call/cc-based coroutines

(library-directories
  '(("." . ".")
    ("../internal" . "../internal")
    ("../high-level" . "../high-level")
    ("../low-level" . "../low-level")
    ("../ffi" . "../ffi")))

(import (chezscheme)
        (chez-async high-level async-await-cc)
        (chez-async high-level promise)
        (chez-async high-level event-loop)
        (chez-async low-level timer)
        (chez-async low-level handle-base))

(format #t "~%╔════════════════════════════════════════╗~%")
(format #t "║  async/await Demo (call/cc version)   ║~%")
(format #t "╚════════════════════════════════════════╝~%~%")

;; ========================================
;; Example 1: Basic async value
;; ========================================

(format #t "Example 1: Basic async value~%")
(format #t "─────────────────────────────~%")

(define result1
  (run-async
    (async 42)))

(format #t "Result: ~a~%~%" result1)

;; ========================================
;; Example 2: await a Promise
;; ========================================

(format #t "Example 2: await a Promise~%")
(format #t "────────────────────────────~%")

(define result2
  (run-async
    (async
      (let ([value (await (promise-resolved (uv-default-loop) 100))])
        (* value 2)))))

(format #t "Result: ~a~%~%" result2)

;; ========================================
;; Example 3: Multiple awaits
;; ========================================

(format #t "Example 3: Multiple awaits~%")
(format #t "─────────────────────────────~%")

(define result3
  (run-async
    (async
      (let* ([a (await (promise-resolved (uv-default-loop) 10))]
             [b (await (promise-resolved (uv-default-loop) 20))]
             [c (await (promise-resolved (uv-default-loop) 12))])
        (format #t "  a=~a, b=~a, c=~a~%" a b c)
        (+ a b c)))))

(format #t "Result: ~a~%~%" result3)

;; ========================================
;; Example 4: Async function with async*
;; ========================================

(format #t "Example 4: Async function (async*)~%")
(format #t "────────────────────────────────────~%")

(define fetch-data
  (async* (url)
    (format #t "  Fetching ~a...~%" url)
    (let ([data (await (promise-resolved (uv-default-loop)
                                          (format "Data from ~a" url)))])
      data)))

(define result4
  (run-async (fetch-data "https://example.com")))

(format #t "Result: ~a~%~%" result4)

;; ========================================
;; Example 5: Async delay function
;; ========================================

(format #t "Example 5: Async delay~%")
(format #t "──────────────────────~%")

(define (delay-value ms value)
  "Create a Promise that resolves after ms milliseconds"
  (make-promise (uv-default-loop)
    (lambda (resolve reject)
      (let ([timer (uv-timer-init (uv-default-loop))])
        (uv-timer-start! timer ms 0
          (lambda (t)
            (uv-handle-close! t)
            (resolve value)))))))

(define result5
  (run-async
    (async
      (format #t "  Starting...~%")
      (let ([x (await (delay-value 50 10))])
        (format #t "  After 50ms: x=~a~%" x)
        (let ([y (await (delay-value 50 20))])
          (format #t "  After another 50ms: y=~a~%" y)
          (+ x y))))))

(format #t "Result: ~a~%~%" result5)

;; ========================================
;; Example 6: Error handling
;; ========================================

(format #t "Example 6: Error handling~%")
(format #t "────────────────────────────~%")

(define result6
  (run-async
    (async
      (guard (ex
              [else
               (format #t "  Caught error: ~a~%" (if (message-condition? ex)
                                                      (condition-message ex)
                                                      "Unknown error"))
               'recovered])
        (await (promise-rejected (uv-default-loop) "Simulated error"))))))

(format #t "Result: ~a~%~%" result6)

;; ========================================
;; Example 7: Complex async workflow
;; ========================================

(format #t "Example 7: Complex workflow~%")
(format #t "──────────────────────────────~%")

(define (process-data data)
  (async
    (format #t "  Processing ~a...~%" data)
    (await (delay-value 30 (format "Processed: ~a" data)))))

(define result7
  (run-async
    (async
      (let* ([data1 (await (delay-value 20 "input1"))]
             [processed1 (await (process-data data1))]
             [data2 (await (delay-value 20 "input2"))]
             [processed2 (await (process-data data2))])
        (format #t "  ~a~%" processed1)
        (format #t "  ~a~%" processed2)
        (list processed1 processed2)))))

(format #t "Result: ~a~%~%" result7)

;; ========================================
;; Summary
;; ========================================

(format #t "~%╔════════════════════════════════════════╗~%")
(format #t "║       All examples completed! ✓        ║~%")
(format #t "╚════════════════════════════════════════╝~%~%")

(format #t "Key features demonstrated:~%")
(format #t "  • async blocks return Promises~%")
(format #t "  • await suspends and resumes coroutines~%")
(format #t "  • Multiple awaits work sequentially~%")
(format #t "  • async* creates async functions~%")
(format #t "  • Error handling with guard~%")
(format #t "  • Complex async workflows~%~%")
