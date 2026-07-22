;;; internal/io-runtime.ss - C++ task 运行时的 Scheme 绑定层
;;;
;;; chez-async 最底层的 task-runtime 绑定，对齐 skiff/task.ss。绑定
;;; libchez-async-rt.so（移植自 skiff src/runtime；C ABI 见 native/runtime/
;;; rt_runtime.h）暴露的 flat extern-"C" 边界。
;;;
;;; 加载：Chez 宿主经 load-shared-object 加载独立 .so（skiff 是内嵌 Chez +
;;; dlopen(NULL)，我们是宿主加载）。查找顺序：
;;;   1. 环境变量 CHEZ_ASYNC_RT（显式路径，最高优先）；
;;;   2. 裸名 "chez-async-rt.so"（靠 LD_LIBRARY_PATH / 已安装到 ld 路径 /
;;;      bake 统一加载）。
;;;
;;; 阻塞入口（%await / %cq-wait）声明 __collect_safe：Chez 在等待期间 deactivate
;;; 调用线程，别的线程 GC 不被卡（R1/S0 已验证，阻塞点在 C++ 运行时的 cv 上）。
;;; 只收整数句柄，从不传 Scheme 对象。
;;;
;;; buffer 约定：写/读类的 buffer 参数是**裸 foreign 指针**（foreign-alloc 得到
;;; 的地址），不是 Scheme bytevector——上层（fs/net）负责 bytevector<->foreign
;;; 拷贝。运行时 .so 因此零 Chez 依赖。
;;;
;;; task-run / -void / -str 是 skiff define-osi 思路的移植：submit→await→free→
;;; raise 的单一 owner，避免每个 op 绑定各自重复。

(library (chez-async internal io-runtime)
  (export
    ;; 运行时生命周期
    io-runtime-start! io-runtime-stop!
    io-runtime-exit-on-signal! io-shutdown-timeout! io-shutdown-requested?
    ;; 低层 task 协议
    task-await task-free task-result task-read-into! task-str-result
    task-run task-run-void task-run-str
    ;; 提交（返回 task 句柄；cq 默认取 (current-cq)）
    submit-timer
    submit-fs-open submit-fs-read submit-fs-write submit-fs-close
    submit-fs-stat submit-fs-mkdir submit-fs-rmdir submit-fs-unlink
    submit-fs-rename submit-fs-realpath submit-fs-scandir
    submit-stdio-open submit-fs-watch submit-fs-watch-next submit-fs-watch-close
    submit-tcp-connect submit-tcp-listen submit-tcp-accept
    submit-stream-read submit-stream-write submit-stream-close
    submit-listener-close
    submit-dns-resolve
    submit-spawn submit-proc-wait submit-proc-kill submit-proc-close
    proc-stdin proc-stdout proc-stderr
    stream-write-queue-size
    ;; stat / scandir 结果访问器（await 后）
    task-stat-size task-stat-mtime task-stat-mode task-stat-dir? task-stat-file?
    task-scandir-count task-scandir-name
    ;; completion queue（批量收割）
    make-completion-queue completion-queue-free
    completion-queue-wait completion-queue-try-pop
    ;; 调度器集成缝（(chez-async ...) 协程调度器重绑）
    await-hook current-cq
    ;; 定时器便捷
    io-sleep
    ;; 错误条件
    &io-error make-io-error-condition io-error? io-error-errno io-error-name
    ;; 泄漏断言（测试用）
    io-live-tasks io-live-cqs io-live-streams io-live-listeners
    io-live-processes io-live-watchers)
  (import (chezscheme))

  ;; ========================================
  ;; 加载 .so
  ;; ========================================

  (define _rt-loaded
    (let ([override (getenv "CHEZ_ASYNC_RT")])
      (if (and override (> (string-length override) 0))
          (load-shared-object override)
          (load-shared-object "chez-async-rt.so"))))

  ;; ========================================
  ;; 原始 foreign 入口点
  ;; ========================================

  (define %rt-start (foreign-procedure "rt_runtime_start" () void))
  (define %rt-stop  (foreign-procedure "rt_runtime_stop" () void))
  (define %rt-exit-on-signal (foreign-procedure "rt_runtime_exit_on_signal" (int) void))
  (define %shutdown-timeout (foreign-procedure "rt_shutdown_timeout" (unsigned-32) void))
  (define %shutdown-requested (foreign-procedure "rt_shutdown_requested" () int))

  (define %timer (foreign-procedure "rt_timer" (unsigned-64 uptr) uptr))

  (define %fs-open  (foreign-procedure "rt_fs_open" (string int int uptr) uptr))
  (define %fs-read  (foreign-procedure "rt_fs_read" (int unsigned-32 integer-64 uptr) uptr))
  (define %fs-write (foreign-procedure "rt_fs_write" (int void* unsigned-32 unsigned-32 integer-64 uptr) uptr))
  (define %fs-close (foreign-procedure "rt_fs_close" (int uptr) uptr))
  (define %fs-stat  (foreign-procedure "rt_fs_stat" (string uptr) uptr))
  (define %fs-mkdir (foreign-procedure "rt_fs_mkdir" (string int uptr) uptr))
  (define %fs-rmdir (foreign-procedure "rt_fs_rmdir" (string uptr) uptr))
  (define %fs-unlink (foreign-procedure "rt_fs_unlink" (string uptr) uptr))
  (define %fs-rename (foreign-procedure "rt_fs_rename" (string string uptr) uptr))
  (define %fs-realpath (foreign-procedure "rt_fs_realpath" (string uptr) uptr))
  (define %fs-scandir (foreign-procedure "rt_fs_scandir" (string uptr) uptr))

  (define %stat-size (foreign-procedure "rt_stat_size" (uptr) unsigned-64))
  (define %stat-mtime (foreign-procedure "rt_stat_mtime" (uptr) unsigned-64))
  (define %stat-mode (foreign-procedure "rt_stat_mode" (uptr) unsigned-32))
  (define %stat-is-dir (foreign-procedure "rt_stat_is_dir" (uptr) int))
  (define %stat-is-file (foreign-procedure "rt_stat_is_file" (uptr) int))
  (define %scandir-count (foreign-procedure "rt_scandir_count" (uptr) int))
  (define %scandir-name (foreign-procedure "rt_scandir_name" (uptr int) string))

  (define %stdio-open (foreign-procedure "rt_stdio_open" (int uptr) uptr))
  (define %fs-watch (foreign-procedure "rt_fs_watch" (string uptr) uptr))
  (define %fs-watch-next (foreign-procedure "rt_fs_watch_next" (uptr uptr) uptr))
  (define %fs-watch-close (foreign-procedure "rt_fs_watch_close" (uptr uptr) uptr))

  (define %tcp-connect (foreign-procedure "rt_tcp_connect" (string int uptr) uptr))
  (define %tcp-listen (foreign-procedure "rt_tcp_listen" (string int int uptr) uptr))
  (define %tcp-accept (foreign-procedure "rt_tcp_accept" (uptr uptr) uptr))

  (define %stream-read (foreign-procedure "rt_stream_read" (uptr unsigned-32 uptr) uptr))
  (define %stream-write (foreign-procedure "rt_stream_write" (uptr void* unsigned-32 unsigned-32 uptr) uptr))
  (define %stream-wqsize (foreign-procedure "rt_stream_write_queue_size" (uptr) unsigned-64))
  (define %stream-close (foreign-procedure "rt_stream_close" (uptr uptr) uptr))
  (define %listener-close (foreign-procedure "rt_listener_close" (uptr uptr) uptr))

  (define %dns-resolve (foreign-procedure "rt_dns_resolve" (string string int uptr) uptr))

  (define %spawn (foreign-procedure "rt_spawn"
                   (void* unsigned-32 int void* unsigned-32 int string int uptr) uptr))
  (define %proc-stdin (foreign-procedure "rt_proc_stdin" (uptr) uptr))
  (define %proc-stdout (foreign-procedure "rt_proc_stdout" (uptr) uptr))
  (define %proc-stderr (foreign-procedure "rt_proc_stderr" (uptr) uptr))
  (define %proc-wait (foreign-procedure "rt_proc_wait" (uptr uptr) uptr))
  (define %proc-kill (foreign-procedure "rt_proc_kill" (uptr int uptr) uptr))
  (define %proc-close (foreign-procedure "rt_proc_close" (uptr uptr) uptr))

  ;; 阻塞：__collect_safe
  (define %await (foreign-procedure __collect_safe "rt_await" (uptr) integer-64))
  (define %cq-wait (foreign-procedure __collect_safe "rt_cq_wait" (uptr) uptr))

  (define %result (foreign-procedure "rt_task_result" (uptr) integer-64))
  (define %read-into (foreign-procedure "rt_read_into" (uptr void* unsigned-32) void))
  (define %str-result (foreign-procedure "rt_str_result" (uptr) string))
  (define %free (foreign-procedure "rt_task_free" (uptr) void))

  (define %cq-create (foreign-procedure "rt_cq_create" () uptr))
  (define %cq-free (foreign-procedure "rt_cq_free" (uptr) void))
  (define %cq-try-pop (foreign-procedure "rt_cq_try_pop" (uptr) uptr))

  (define %live-tasks (foreign-procedure "rt_debug_live_tasks" () integer-32))
  (define %live-cqs (foreign-procedure "rt_debug_live_cqs" () integer-32))
  (define %live-streams (foreign-procedure "rt_debug_live_streams" () integer-32))
  (define %live-listeners (foreign-procedure "rt_debug_live_listeners" () integer-32))
  (define %live-processes (foreign-procedure "rt_debug_live_processes" () integer-32))
  (define %live-watchers (foreign-procedure "rt_debug_live_watchers" () integer-32))

  (define %err-name (foreign-procedure "rt_err_name" (int) string))
  (define %err-str (foreign-procedure "rt_err_str" (int) string))

  ;; ========================================
  ;; 错误条件系统
  ;; ========================================

  (define-condition-type &io-error &error
    make-io-error-condition io-error?
    (errno io-error-errno)        ; 负 libuv errno
    (name io-error-name))         ; 符号名字符串，如 "ENOENT"

  (define (io-error who r)
    (raise
      (condition
        (make-io-error-condition r (%err-name r))
        (make-who-condition who)
        (make-message-condition (%err-str r)))))

  ;; ========================================
  ;; 运行时生命周期
  ;; ========================================

  (define (io-runtime-start!) (%rt-start))
  (define (io-runtime-stop!) (%rt-stop))
  (define (io-runtime-exit-on-signal! on) (%rt-exit-on-signal (if on 1 0)))
  (define (io-shutdown-timeout! ms) (%shutdown-timeout ms))
  (define (io-shutdown-requested?) (not (fx= 0 (%shutdown-requested))))

  ;; ========================================
  ;; 调度器集成缝
  ;; ========================================
  ;;
  ;; await-hook：task-await 如何阻塞——默认阻塞 FFI，async 上下文下由
  ;; (chez-async ...) 的协程调度器重绑为 suspend 协程。
  ;; current-cq：提交路由到的 completion queue（0 = 仅 per-task cv）。调度器
  ;; 把它重绑为自己的队列，完成集中收割。非 0 cq 不影响阻塞 await
  ;; （Task::Complete 无论如何都 signal cv）。

  (define await-hook (make-thread-parameter (lambda (t) (%await t))))
  (define current-cq (make-thread-parameter 0))

  ;; ========================================
  ;; 低层 task 协议
  ;; ========================================

  (define (task-await t) ((await-hook) t))
  (define (task-free t) (%free t))
  (define (task-result t) (%result t))
  ;; 把已完成 read task 的字节拷进裸 foreign 指针 dst（+start 偏移）
  (define (task-read-into! t dst start) (%read-into t dst start))
  (define (task-str-result t) (%str-result t))

  ;; await t，free 它，返回非负结果；负结果以 who 抛 &io-error。
  (define (task-run who t)
    (let ([r (task-await t)])
      (task-free t)
      (if (< r 0) (io-error who r) r)))

  (define (task-run-void who t)
    (task-run who t)
    (void))

  ;; 同 task-run，但取字符串结果。
  (define (task-run-str who t)
    (let ([r (task-await t)])
      (if (< r 0)
          (begin (task-free t) (io-error who r))
          (let ([s (task-str-result t)])
            (task-free t)
            s))))

  ;; ========================================
  ;; 提交（cq 默认 (current-cq)）
  ;; ========================================

  (define submit-timer
    (case-lambda [(ms) (%timer ms (current-cq))] [(ms cq) (%timer ms cq)]))

  (define (submit-fs-open path flags mode) (%fs-open path flags mode (current-cq)))
  (define (submit-fs-read fd nbytes offset) (%fs-read fd nbytes offset (current-cq)))
  ;; src：裸 foreign 指针；写 src+start 起 nbytes 字节
  (define (submit-fs-write fd src start nbytes offset)
    (%fs-write fd src start nbytes offset (current-cq)))
  (define (submit-fs-close fd) (%fs-close fd (current-cq)))
  (define (submit-fs-stat path) (%fs-stat path (current-cq)))
  (define (submit-fs-mkdir path mode) (%fs-mkdir path mode (current-cq)))
  (define (submit-fs-rmdir path) (%fs-rmdir path (current-cq)))
  (define (submit-fs-unlink path) (%fs-unlink path (current-cq)))
  (define (submit-fs-rename path new-path) (%fs-rename path new-path (current-cq)))
  (define (submit-fs-realpath path) (%fs-realpath path (current-cq)))
  (define (submit-fs-scandir path) (%fs-scandir path (current-cq)))
  (define (submit-stdio-open fd) (%stdio-open fd (current-cq)))
  (define (submit-fs-watch path) (%fs-watch path (current-cq)))
  (define (submit-fs-watch-next watcher) (%fs-watch-next watcher (current-cq)))
  (define (submit-fs-watch-close watcher) (%fs-watch-close watcher (current-cq)))

  (define (submit-tcp-connect host port) (%tcp-connect host port (current-cq)))
  (define (submit-tcp-listen host port backlog) (%tcp-listen host port backlog (current-cq)))
  (define (submit-tcp-accept listener) (%tcp-accept listener (current-cq)))
  (define (submit-stream-read stream maxlen) (%stream-read stream maxlen (current-cq)))
  (define (submit-stream-write stream src start nbytes)
    (%stream-write stream src start nbytes (current-cq)))
  (define (submit-stream-close stream) (%stream-close stream (current-cq)))
  (define (submit-listener-close listener) (%listener-close listener (current-cq)))
  (define (stream-write-queue-size stream) (%stream-wqsize stream))

  (define submit-dns-resolve
    (case-lambda
      [(host) (%dns-resolve host "" 0 (current-cq))]
      [(host service family) (%dns-resolve host service family (current-cq))]))

  ;; argbuf/envbuf：裸 foreign 指针（NUL 分隔字符串打包）
  (define (submit-spawn argbuf arglen argc envbuf envlen envc cwd stdio-mode)
    (%spawn argbuf arglen argc envbuf envlen envc cwd stdio-mode (current-cq)))
  (define (proc-stdin process) (%proc-stdin process))
  (define (proc-stdout process) (%proc-stdout process))
  (define (proc-stderr process) (%proc-stderr process))
  (define (submit-proc-wait process) (%proc-wait process (current-cq)))
  (define (submit-proc-kill process signum) (%proc-kill process signum (current-cq)))
  (define (submit-proc-close process) (%proc-close process (current-cq)))

  ;; ========================================
  ;; stat / scandir 结果访问器
  ;; ========================================

  (define (task-stat-size t) (%stat-size t))
  (define (task-stat-mtime t) (%stat-mtime t))
  (define (task-stat-mode t) (%stat-mode t))
  (define (task-stat-dir? t) (not (fx= 0 (%stat-is-dir t))))
  (define (task-stat-file? t) (not (fx= 0 (%stat-is-file t))))
  (define (task-scandir-count t) (%scandir-count t))
  (define (task-scandir-name t i) (%scandir-name t i))

  ;; ========================================
  ;; 便捷
  ;; ========================================

  (define (io-sleep ms) (task-run-void 'io-sleep (%timer ms (current-cq))))

  ;; ========================================
  ;; completion queue
  ;; ========================================

  (define (make-completion-queue) (%cq-create))
  (define (completion-queue-free cq) (%cq-free cq))
  (define (completion-queue-wait cq) (%cq-wait cq))
  (define (completion-queue-try-pop cq)
    (let ([h (%cq-try-pop cq)]) (if (= h 0) #f h)))

  ;; ========================================
  ;; 泄漏断言
  ;; ========================================

  (define (io-live-tasks) (%live-tasks))
  (define (io-live-cqs) (%live-cqs))
  (define (io-live-streams) (%live-streams))
  (define (io-live-listeners) (%live-listeners))
  (define (io-live-processes) (%live-processes))
  (define (io-live-watchers) (%live-watchers))

) ; end library
