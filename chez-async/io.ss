;;; chez-async/io.ss - 新 I/O 运行时 API 的统一入口（S5）
;;;
;;; 一行 (import (chez-async io)) 即可用基于移植的 skiff C++ task 运行时的全部
;;; 高层 API：async/await 协程、fs、net、process、timer。
;;;
;;; 与旧 (chez-async)（promise + Scheme 侧 libuv）的关系：这是**新栈**，建在
;;; native/ 的 libchez-async-rt.so 上。import 本库即触发 load-shared-object，
;;; 故运行需 native .so 在路径上（LD_LIBRARY_PATH=native/<mt>，或已 bake install）。
;;;
;;; 用法：
;;;   (import (chez-async io))
;;;   (io-runtime-start!)
;;;   (run-async
;;;     (lambda ()
;;;       (let ([f1 (async (lambda () (io-read-file "a.txt")))]
;;;             [f2 (async (lambda () (io-read-file "b.txt")))])
;;;         (await-all (list f1 f2)))))     ; 两个文件并发读
;;;   (io-runtime-stop!)

(library (chez-async io)
  (export
    ;; 运行时生命周期
    io-runtime-start! io-runtime-stop!
    io-runtime-exit-on-signal! io-shutdown-timeout! io-shutdown-requested?
    ;; async/await 协程调度
    run-async async await await-all in-async? future?
    ;; 定时器
    io-sleep
    ;; 文件系统
    io-open io-read io-write io-close
    O_RDONLY O_WRONLY O_RDWR O_CREAT O_TRUNC O_APPEND
    io-mkdir io-rmdir io-unlink io-rename io-realpath io-scandir
    io-stat io-exists?
    stat-info? stat-info-size stat-info-mtime stat-info-mode
    stat-info-dir? stat-info-file?
    io-read-file io-write-file
    io-watch io-watch-next io-watch-close
    watch-event-rename? watch-event-change?
    ;; 网络
    io-dns-resolve io-dns-resolve-all
    io-tcp-connect io-tcp-listen io-tcp-accept
    io-stream-read io-stream-write io-stream-close
    io-stream-pipe io-stream-write-queue-size io-listener-close
    ;; 子进程
    io-spawn io-proc-wait io-proc-kill io-proc-close
    io-proc-stdin io-proc-stdout io-proc-stderr
    io-run io-run/output
    ;; 错误条件
    &io-error io-error? io-error-errno io-error-name raise-io-error
    ;; 低层 task 协议 + cq（进阶用）
    task-await task-free task-result submit-timer current-cq
    make-completion-queue completion-queue-free
    completion-queue-wait completion-queue-try-pop
    ;; 泄漏断言（测试用）
    io-live-tasks io-live-cqs io-live-streams io-live-listeners
    io-live-processes io-live-watchers)
  (import (chez-async internal io-runtime)
          (chez-async high-level io-async)
          (chez-async high-level io-fs)
          (chez-async high-level io-net)
          (chez-async high-level io-proc)))
