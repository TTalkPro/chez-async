(library (chez-async tcp)
  (export
    create-tcp-instance
    tcp-connect)
  (import
    (chezscheme)
    (chez-async base))

  (define create-tcp-instance
    (foreign-procedure "createTcpInstance"
      (void*) void*))

  (define tcp-connect
    (foreign-procedure "tcpConnect"
      (void* string int) boolean))
  (define tcp-read
    (foreign-procedure "tcpRead"
      (void* u8* int) size_t))
  (define tcp-write
    (foregin-procedure "tcpWrite")
    (void* u8* int) int)

)
