(library (chez-async base)
  (export
    chez-async-loaded?
    chez-async-supported?)
  (import (chezscheme)
    (chez-async utils))
  (load-librarys "chez-async/libasync")

  (define (chez-async-supported?)
    (case (machine-type)
      [(ta6fb ta6le) #t]
      [else #f]))

  (define (chez-async-loaded?)
    (and
      (foreign-entry? "createTcpInstance")
      (foreign-entry? "uv_default_loop")))

)
