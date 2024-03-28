(library (chez-async loop)
  (export
    create-event-loop
    close-event-loop
    run-event-loop
    stop-event-loop
    register-status-callback
    CALLBACK-ON-READ
    CALLBACK-ON-WRITE
    CALLBACK-ON-SEND
    CALLBACK-ON-CONNECTED
    CALLBACK-ON-ACCEPTED
    CALLBACK-ON-SHUTDOWN
    CALLBACK-ON-SIGNAL
    CALLBACK-ON-CLOSE
    CALLBACK-ON-TIMER
    CALLBACK-ON-PREPARE
    CALLBACK-ON-CHECK
    CALLBACK-ON-IDLE
    CALLBACK-ON-ASYNC
    CALLBACK-ON-RECV
    CALLBACK-ON-FS-EVENT)

  (import
    (chezscheme)
    (chez-async base))
  ;;带状态函数
  (define CALLBACK-ON-READ 0)
  (define CALLBACK-ON-WRITE 1)
  (define CALLBACK-ON-SEND 2)
  (define CALLBACK-ON-CONNECTED 3)
  (define CALLBACK-ON-ACCEPTED 4)
  (define CALLBACK-ON-SHUTDOWN 5)
  (define CALLBACK-ON-SIGNAL 6)
  ;;直接性质的回调
  (define CALLBACK-ON-CLOSE 0)
  (define CALLBACK-ON-TIMER 1)
  (define CALLBACK-ON-PREPARE 2)
  (define CALLBACK-ON-CHECK 3)
  (define CALLBACK-ON-IDLE 4)
  (define CALLBACK-ON-ASYNC 5)
  ;;带上下文的回调
  (define CALLBACK-ON-RECV 0)
  (define CALLBACK-ON-FS-EVENT 1)


  (define create-event-loop
    (foreign-procedure "createEventLoop"
      () void*))

  (define close-event-loop
    (foreign-procedure "closeEventLoop"
      (void*) boolean))

  (define run-event-loop
    (foreign-procedure "runEventLoop"
      (void*) int))

  (define stop-event-loop
    (foreign-procedure "stopEventLoop"
      (void*) void))

  (define register-status-callback
    (foreign-procedure "registerStatusCallback"
      (void* void* int) void*))
)
