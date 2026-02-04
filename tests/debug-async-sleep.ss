#!/usr/bin/env scheme-script

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

(format #t "Testing async-sleep...~%")

;; 测试 1：直接调用 async-sleep
(format #t "Test 1: Direct async-sleep~%")
(guard (ex
        [else
         (format #t "Error: ~a~%" ex)
         (when (condition? ex)
           (format #t "  Message: ~a~%"
                   (if (message-condition? ex)
                       (condition-message ex)
                       "No message")))])
  (let ([p (async-sleep 100)])
    (format #t "Promise created: ~a~%" p)
    (format #t "Promise type: ~a~%" (promise? p))
    (run-async p)
    (format #t "Sleep completed!~%")))

(format #t "~%Test 2: async-sleep in async block~%")
(guard (ex
        [else
         (format #t "Error: ~a~%" ex)])
  (run-async
    (async
      (format #t "Before sleep~%")
      (await (async-sleep 100))
      (format #t "After sleep~%"))))
