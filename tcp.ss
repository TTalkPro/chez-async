(library (chez-async tcp)
  (import
    (chez-async tcp-ffi)
    (chez-async engine))

  (define-record-type tcp
    (fields
      on-read
      on-write
      on-accepted
      on-connected
      on-close
      on-shutdown)
    (immutable handler))
  (define (create-tcp-with-handler handler))

  )
