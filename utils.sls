(library (chez-async utils)
  (export load-librarys)
  (import (chezscheme) (chez-async dyn))

  (define-syntax load-librarys
    (lambda (x)
      (import (chez-async dyn))
      (syntax-case x ()
        [(_ . args)
          #`(define lib
              #,(let loop ([arg (syntax->datum #'args)])
                  (if (pair? arg)
                    (begin
                      (let loop2 ([ext (get-dynamic-ext)])
                        (if (pair? ext)
                          (begin
                            (load-lib
                              (string-append (car arg) (car ext)))
                            (loop2 (cdr ext))))
                        (loop (cdr arg))))
                    #'1)))])))
  )
