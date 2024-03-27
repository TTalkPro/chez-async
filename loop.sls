(library (chez-async loop)
  (export
    create-event-loop
    close-event-loop
    run-event-loop
    stop-event-loop)
  (import
    (chezscheme)
    (chez-async async))

  (define create-event-loop
    (foreign-procedure "createEventLoop"
      () void*))

  (define close-event-loop
    (foreign-procedure "closeEventLoop"
      (void*) boolean))

  (define run-event-loop
    (foreign-procedure "runEventLoop"
      (void*) void))

  (define stop-event-loop
    (foreign-procedure "stopEventLoop"
      (void*) void))
)
