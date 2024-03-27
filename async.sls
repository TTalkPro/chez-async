(library (chez-async async)
  (export chez-async-loaded?)
  (import (chezscheme))

 (define (load-lib name)
    (let loop ([libs (map car (library-directories))])
      (if (pair? libs)
          (begin
            (if (and (string? name)
                     (file-exists? (string-append (car libs) "/" name)))
                (let ([libname (string-append (car libs) "/" name)])
                  (load-shared-object libname))
            (loop (cdr libs)))))))

(define (init-chez-async)
  (case (machine-type)
    [(ta6le)
      (load-lib "chez-async/libasync.so")
      (load-shared-object "libuv.so")]
    [(ta6fb)
      (load-lib "chez-async/libasync.so")
      (load-shared-object "libuv.so")]
    [else (error 'chez-async
                   "currently unsupoorted on ~s" (machine-type))]))

  (define (chez-async-loaded?)
    (foreign-entry? "createTcpInstance")
    )
(init-chez-async)
)
