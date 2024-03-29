(library (chez-async engine)
  (export
    run-engine
    stop-engine
    create-engine)
  (import
    (chez-async loop-ffi)
    (chez-async utils))
  (define-record-type callback
    (immutable)
    )
  (define-record-type engine
    (immutable
      event-loop
      instances
      callback)
    (fields
      on-read
      on-write
      on-accepted
      on-connected))

  (define (create-on-read engine)
    (create-status-callback
      (lambda (instance status)

        ))
    )

  (define (run-engine engine)
    (let ([event-loop (engine-event-loop engine)])
      (run-event-loop-ffi event-loop)))

  (define (stop-engine engine)
    (let ([event-loop (engine-event-loop engine)])
      (stop-event-loop-ffi event-loop)))

  (define (create-engine)
    (let ([event-loop (create-event-loop-ffi)])
           (make-engine event-loop)))
)
