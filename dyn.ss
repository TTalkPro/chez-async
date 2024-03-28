(library (chez-async dyn)
  (export get-dynamic-ext load-lib)
  (import (chezscheme))

  (define (get-dynamic-ext)
    (case (machine-type)
      [(a6nt  ta6nt) (list ".dll")]
      [(a6osx ta6osx) (list ".dylib" ".so")]
      [(ta6fb a6fb ta6ob a6ob 
	a6le ta6lf tarm64ob arm64ob)
       (list ".so")]))

  (define (load-lib name)
    (let loop ([libs (map car (library-directories))])
      (if (pair? libs)
        (begin
          (if (and (string? name)
                (file-exists? (string-append (car libs) "/" name)))
            (let ([libname (string-append (car libs) "/" name)])
              (load-shared-object libname))
            (loop (cdr libs)))))))
 )
