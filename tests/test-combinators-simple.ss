#!/usr/bin/env scheme-script
;;; tests/test-combinators-simple.ss - 简单组合器测试

(library-directories
  '(("." . ".")
    ("../internal" . "../internal")
    ("../high-level" . "../high-level")
    ("../low-level" . "../low-level")
    ("../ffi" . "../ffi")))

(import (chezscheme)
        (chez-async high-level async-await)
        (chez-async high-level async-combinators)
        (chez-async high-level promise)
        (chez-async high-level event-loop))

(format #t "~%=== Async Combinators Simple Tests ===~%~%")

;; Test 1: async-sleep
(format #t "Test 1: async-sleep ... ")
(run-async
  (async
    (await (async-sleep 50))
    (format #t "✓~%")))

;; Test 2: async-all
(format #t "Test 2: async-all ... ")
(let ([result (run-async
                (async
                  (await (async-all
                           (list (async 1)
                                 (async 2)
                                 (async 3))))))])
  (if (equal? result '(1 2 3))
      (format #t "✓~%")
      (format #t "✗ Expected (1 2 3), got ~a~%" result)))

;; Test 3: async-race
(format #t "Test 3: async-race ... ")
(let ([result (run-async
                (async
                  (await (async-race
                           (list (async (await (async-sleep 100)) 'slow)
                                 (async 'fast))))))])
  (if (eq? result 'fast)
      (format #t "✓~%")
      (format #t "✗ Expected 'fast, got ~a~%" result)))

;; Test 4: async-timeout (success)
(format #t "Test 4: async-timeout (completes) ... ")
(let ([result (run-async
                (async
                  (await (async-timeout
                           (async (await (async-sleep 50)) 'done)
                           200))))])
  (if (eq? result 'done)
      (format #t "✓~%")
      (format #t "✗ Expected 'done, got ~a~%" result)))

;; Test 5: async-timeout (timeout)
(format #t "Test 5: async-timeout (times out) ... ")
(guard (ex
        [(timeout-error? ex)
         (format #t "✓~%")]
        [else
         (format #t "✗ Unexpected error: ~a~%" ex)])
  (run-async
    (async
      (await (async-timeout
               (async (await (async-sleep 200)) 'done)
               50)))))

;; Test 6: async-delay
(format #t "Test 6: async-delay ... ")
(let ([result (run-async
                (async
                  (await (async-delay 50
                           (lambda () (async 'delayed))))))])
  (if (eq? result 'delayed)
      (format #t "✓~%")
      (format #t "✗ Expected 'delayed, got ~a~%" result)))

(format #t "~%=== All Simple Tests Completed ===~%")
