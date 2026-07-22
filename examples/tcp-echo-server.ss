#!/usr/bin/env scheme-script
;;; examples/tcp-echo-server.ss - TCP echo 服务器（chez-async 新栈）
;;;
;;; 每个连接一个协程并发处理；读到什么回写什么，直到对端关闭。
;;; 运行：
;;;   bake runtime
;;;   LD_LIBRARY_PATH=native/ta6le scheme --libdirs . --program examples/tcp-echo-server.ss
;;; 测试：  nc 127.0.0.1 8099

(import (chezscheme)
        (chez-async))

(define PORT 8099)

(io-runtime-start!)

(run-async
  (lambda ()
    (let ([listener (io-tcp-listen "127.0.0.1" PORT)])
      (printf "echo 服务器监听 127.0.0.1:~a（Ctrl-C 退出）~n" PORT)
      (let accept-loop ()
        (let ([conn (io-tcp-accept listener)])
          ;; 每个连接一个并发协程
          (async
            (lambda ()
              (guard (e [else (void)])
                (let echo ()
                  (let ([data (io-stream-read conn)])
                    (unless (eof-object? data)
                      (io-stream-write conn data)
                      (echo))))
                (io-stream-close conn))))
          (accept-loop))))))

(io-runtime-stop!)
