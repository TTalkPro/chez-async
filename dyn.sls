(library (chez-async dyn)
  (export get-dynamic-ext load-lib)
  (import (chezscheme))

  (define (get-dynamic-ext)
    (case (machine-type)
      [(arm32le) (list ".so")]
      [(a6nt i3nt ta6nt ti3nt) (list ".dll")]
      [(a6osx i3osx ta6osx ti3osx) (list ".dylib" ".so")]
      [(a6le i3le ta6le ti3le) (list ".so")]))

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
