(library (chez-async tcp)
  (export
    create-tcp-instance
    tcp-connect)
  (import
    (chezscheme)
    (chez-async async))

  (define create-tcp-instance
    (foreign-procedure "createTcpInstance"
      (void*) void*))

  (define tcp-connect
    (foreign-procedure "tcpConnect"
      (void* string int) boolean))

)
