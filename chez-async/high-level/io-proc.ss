;;; high-level/io-proc.ss - 基于 C++ task 运行时的子进程 API（对齐 skiff/process.ss）
;;;
;;; 建在 internal/io-runtime 之上（S3）。spawn 子进程、等退出、捕获 stdio。
;;; argv/env 打包成 NUL 分隔 bytevector→foreign，submit 后 C++ 同步拷走即可释放。

(library (chez-async high-level io-proc)
  (export
    io-spawn io-proc-wait io-proc-kill io-proc-close
    io-proc-stdin io-proc-stdout io-proc-stderr
    io-run io-run/output)
  (import (chezscheme)
          (chez-async internal io-runtime)
          (chez-async internal foreign)
          (chez-async high-level io-net))   ; io-stream-read/close 读捕获的 stdout

  ;; 把字符串列表打包成一个 NUL 分隔的 bytevector。
  (define (pack-strings strs)
    (let* ([parts (map string->utf8 strs)]
           [total (fold-left (lambda (a p) (fx+ a (bytevector-length p) 1)) 0 parts)]
           [out (make-bytevector (fxmax total 1) 0)])
      (let loop ([ps parts] [off 0])
        (if (null? ps)
            out
            (let ([n (bytevector-length (car ps))])
              (bytevector-copy! (car ps) 0 out off n)
              (bytevector-u8-set! out (fx+ off n) 0)
              (loop (cdr ps) (fx+ off n 1)))))))

  ;; spawn 子进程，返回 process 句柄。
  ;;   args : 非空字符串列表（argv[0] = 程序）
  ;;   env  : #f 继承父环境（默认），或字符串列表（"K=V"）
  ;;   stdio: 'inherit（默认，继承 0/1/2）| 'capture（捕获为 pipe stream）
  (define io-spawn
    (case-lambda
      [(args) (io-spawn args #f 'inherit)]
      [(args env) (io-spawn args env 'inherit)]
      [(args env stdio)
       (when (null? args) (error 'io-spawn "args must be non-empty"))
       (let-values ([(afp alen) (bytevector->foreign (pack-strings args))]
                    [(efp elen) (bytevector->foreign (pack-strings (or env '())))])
         (let ([envc (if env (length env) -1)]
               [mode (case stdio [(inherit) 0] [(capture pipe) 1]
                       [else (error 'io-spawn "bad stdio option" stdio)])])
           (let ([t (submit-spawn afp alen (length args) efp elen envc "" mode)])
             (foreign-free afp)              ; C++ 已在 submit 内同步拷走
             (foreign-free efp)
             (task-run 'io-spawn t))))]))

  ;; 等子进程退出，返回退出码。
  (define (io-proc-wait p) (task-run 'io-proc-wait (submit-proc-wait p)))
  (define (io-proc-kill p signum) (task-run-void 'io-proc-kill (submit-proc-kill p signum)))
  (define (io-proc-close p) (task-run-void 'io-proc-close (submit-proc-close p)))

  ;; 捕获的 stdio stream 句柄（未捕获时 C 返回 0 → #f）。
  (define (io-proc-stdin p)  (let ([h (proc-stdin p)])  (if (= h 0) #f h)))
  (define (io-proc-stdout p) (let ([h (proc-stdout p)]) (if (= h 0) #f h)))
  (define (io-proc-stderr p) (let ([h (proc-stderr p)]) (if (= h 0) #f h)))

  ;; 跑到退出，继承 stdio，返回退出码。args 为可变参。
  (define (io-run . args)
    (let ([p (io-spawn args)])
      (let ([code (io-proc-wait p)])
        (io-proc-close p)
        code)))

  ;; 跑到退出，捕获 stdout，返回 (退出码 . stdout-bytevector)。
  (define (io-run/output . args)
    (let ([p (io-spawn args #f 'capture)])
      (let ([out (io-proc-stdout p)])
        (let ([data (read-stream-to-eof out)])
          (io-stream-close out)
          (let ([code (io-proc-wait p)])
            (io-proc-close p)
            (cons code data))))))

  ;; 读一个 stream 直到 EOF，返回累计 bytevector。
  (define (read-stream-to-eof s)
    (let loop ([chunks '()] [total 0])
      (let ([chunk (io-stream-read s)])
        (if (eof-object? chunk)
            (let ([out (make-bytevector total)])
              (let copy ([cs (reverse chunks)] [off 0])
                (if (null? cs)
                    out
                    (let ([n (bytevector-length (car cs))])
                      (bytevector-copy! (car cs) 0 out off n)
                      (copy (cdr cs) (fx+ off n))))))
            (loop (cons chunk chunks) (fx+ total (bytevector-length chunk)))))))

) ; end library
