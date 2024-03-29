(library (chez-async tcp-ffi)
  (export
    create-tcp-ffi
    tcp-connect-ffi
    tcp-read-ffi
    tcp-write-ffi)
  (import
    (chezscheme)
    (chez-async base))

  (define create-tcp-ffi
    (foreign-procedure "createTcpInstance"
      (void*) void*))

  (define tcp-connect-ffi
    (foreign-procedure "tcpConnect"
      (void* string int) boolean))
  (define tcp-read-ffi
    (foreign-procedure "tcpRead"
      (void* u8* int) size_t))
  (define tcp-write-ffi
    (foregin-procedure "tcpWrite")
    (void* u8* int) int)

)
