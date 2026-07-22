;;; high-level/io-fs.ss - 基于 C++ task 运行时的文件系统 API（对齐 skiff/fs.ss）
;;;
;;; 建在 internal/io-runtime 的 submit-* + task-run 之上（S3）。所有操作是提交到
;;; 运行时 loop 线程的一次性 task；buffer 走 foreign 内存 + bytevector 桥接
;;; （internal/foreign），运行时 .so 从不碰 Scheme 堆。
;;;
;;; 阻塞语义：默认 task-await 阻塞调用线程（__collect_safe，不卡别的线程 GC）。
;;; async 上下文下由调度器重绑 await-hook 为 suspend 协程（S4）——同一套 API 通吃。
;;;
;;; buffer 生命周期要点：rt_fs_write 在 submit 调用内**同步** memcpy 源缓冲进 C++
;;; task，故 submit 返回后即可 free foreign 源（无挂起/泄漏隐患）。读则在 await 后
;;; 分配 foreign dst、read_into、转 bytevector。

(library (chez-async high-level io-fs)
  (export
    ;; fd 级 I/O
    io-open io-read io-write io-close
    O_RDONLY O_WRONLY O_RDWR O_CREAT O_TRUNC O_APPEND
    ;; 目录与元数据
    io-mkdir io-rmdir io-unlink io-rename io-realpath io-scandir
    io-stat io-exists?
    stat-info? stat-info-size stat-info-mtime stat-info-mode
    stat-info-dir? stat-info-file?
    ;; 整文件便捷
    io-read-file io-write-file
    ;; 监视
    io-watch io-watch-next io-watch-close
    watch-event-rename? watch-event-change?)
  (import (chezscheme)
          (chez-async internal io-runtime)
          (chez-async internal buffer))

  ;; --- open() 标志常量（Linux x86-64）---
  (define O_RDONLY 0)
  (define O_WRONLY 1)
  (define O_RDWR   2)
  (define O_CREAT  #o100)
  (define O_TRUNC  #o1000)
  (define O_APPEND #o2000)

  ;; --- buffer 桥接助手 ---

  ;; 已完成的 read task → bytevector（r>0）/ eof（r=0）/ 抛错（r<0）。
  ;; await 后分配 foreign dst，read_into，转 bytevector。
  (define (read-task->result who t)
    (let ([r (task-await t)])
      (cond
        [(< r 0) (task-free t) (raise-io-error who r)]
        [(= r 0) (task-free t) (eof-object)]
        [else
         (let ([fp (foreign-alloc r)])
           (task-read-into! t fp 0)
           (let ([bv (foreign->bytevector fp r)])
             (foreign-free fp)
             (task-free t)
             bv))])))

  ;; 用 bv 的 [start,start+n) 提交一个写类 op：整 bv 拷进 foreign，submit（C++ 同步
  ;; 拷走），立即 free foreign，再 task-run。submit-fn: (src start n) → task。
  (define (run-write who submit-fn bv start n)
    (let-values ([(fp _len) (bytevector->foreign bv)])
      (let ([t (submit-fn fp start n)])
        (foreign-free fp)                 ; C++ 已在 submit 内同步拷走，可立即释放
        (task-run who t))))

  ;; --- fd 级 I/O ---

  ;; 成功返回 fd，出错抛 &io-error。
  (define (io-open path flags mode)
    (task-run 'io-open (submit-fs-open path flags mode)))

  ;; 返回读到的 bytevector，文件尾返回 eof-object。
  (define (io-read fd n offset)
    (read-task->result 'io-read (submit-fs-read fd n offset)))

  ;; 返回写入字节数。3 参写整个 bv，5 参写 [start,start+n)。
  (define io-write
    (case-lambda
      [(fd bv offset) (io-write fd bv 0 (bytevector-length bv) offset)]
      [(fd bv start n offset)
       (run-write 'io-write
                  (lambda (src s nn) (submit-fs-write fd src s nn offset))
                  bv start n)]))

  (define (io-close fd) (task-run-void 'io-close (submit-fs-close fd)))

  ;; --- 目录与元数据 ---

  (define io-mkdir
    (case-lambda
      [(path) (io-mkdir path #o755)]
      [(path mode) (task-run-void 'io-mkdir (submit-fs-mkdir path mode))]))

  (define (io-rmdir path)  (task-run-void 'io-rmdir (submit-fs-rmdir path)))
  (define (io-unlink path) (task-run-void 'io-unlink (submit-fs-unlink path)))
  (define (io-rename old new) (task-run-void 'io-rename (submit-fs-rename old new)))
  (define (io-realpath path) (task-run-str 'io-realpath (submit-fs-realpath path)))

  ;; 目录项名列表（不含 "." 与 ".."）。
  (define (io-scandir path)
    (let* ([t (submit-fs-scandir path)]
           [r (task-await t)])
      (if (< r 0)
          (begin (task-free t) (raise-io-error 'io-scandir r))
          (let ([n (task-scandir-count t)])
            (let loop ([i 0] [acc '()])
              (if (fx>= i n)
                  (begin (task-free t) (reverse acc))
                  (loop (fx+ i 1) (cons (task-scandir-name t i) acc))))))))

  ;; 丰富 stat：size、mtime（epoch 秒）、mode、类型谓词。
  (define-record-type stat-info
    (fields size mtime mode dir? file?))

  (define (io-stat path)
    (let* ([t (submit-fs-stat path)]
           [r (task-await t)])
      (if (< r 0)
          (begin (task-free t) (raise-io-error 'io-stat r))
          (let ([info (make-stat-info (task-stat-size t) (task-stat-mtime t)
                                      (task-stat-mode t)
                                      (task-stat-dir? t) (task-stat-file? t))])
            (task-free t)
            info))))

  (define (io-exists? path)
    (guard (e [(io-error? e) #f]) (io-stat path) #t))

  ;; --- 整文件便捷 ---

  ;; 读整个文件到新 bytevector（顺序读，offset -1）。
  (define (io-read-file path)
    (let ([fd (io-open path O_RDONLY 0)])
      (let loop ([chunks '()] [total 0])
        (let ([chunk (io-read fd 65536 -1)])
          (if (eof-object? chunk)
              (begin
                (io-close fd)
                (let ([out (make-bytevector total)])
                  (let copy ([cs (reverse chunks)] [off 0])
                    (if (null? cs)
                        out
                        (let ([n (bytevector-length (car cs))])
                          (bytevector-copy! (car cs) 0 out off n)
                          (copy (cdr cs) (fx+ off n)))))))
              (loop (cons chunk chunks) (fx+ total (bytevector-length chunk))))))))

  ;; 写整个 bytevector 到 path（create/truncate）。
  (define io-write-file
    (case-lambda
      [(path bv) (io-write-file path bv #o644)]
      [(path bv mode)
       (let ([fd (io-open path (fxior O_WRONLY O_CREAT O_TRUNC) mode)])
         (io-write fd bv -1)
         (io-close fd)
         (void))]))

  ;; --- 监视（uv_fs_event）---

  (define UV_ECANCELED -125)

  ;; 开始监视 path（文件或目录），返回 watcher 句柄。
  (define (io-watch path) (task-run 'io-watch (submit-fs-watch path)))

  ;; 阻塞/挂起至下一个事件；返回 (filename . flags)（flags 是 uv 位掩码，用
  ;; watch-event-rename?/change? 测），watcher 关闭后返回 eof-object。
  (define (io-watch-next w)
    (let* ([t (submit-fs-watch-next w)]
           [r (task-await t)])
      (cond
        [(= r UV_ECANCELED) (task-free t) (eof-object)]
        [(< r 0) (task-free t) (raise-io-error 'io-watch-next r)]
        [else (let ([name (task-str-result t)]) (task-free t) (cons name r))])))

  (define (watch-event-rename? flags) (fx= 1 (fxand flags 1)))
  (define (watch-event-change? flags) (fx= 2 (fxand flags 2)))

  (define (io-watch-close w) (task-run-void 'io-watch-close (submit-fs-watch-close w)))

) ; end library
