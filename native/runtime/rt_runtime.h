/* chez-async task-runtime C ABI（移植自 skiff src/runtime @ 93e0fd6，符号
 * skiff_* -> rt_*）。
 *
 * chez-async 的 Scheme 层经 foreign-procedure 绑定这层 flat extern-"C" 边界。
 * 句柄（task / completion-queue / stream / listener / process / watcher）以
 * uintptr_t 整数跨界。
 *
 * 与 skiff 的两点差异（见 docs/skiff-aligned-io-design.md §1）：
 *   1. 无 pinned 零拷贝变体——chez-async 宿主是 stock scheme + 加载 .so，
 *      Slock_object 未必可解析；buffer 走 foreign 内存。
 *   2. 写类/读类的 buffer 参数是**裸 foreign 指针**（const void* / void*），
 *      不是 Scheme bytevector——Scheme 侧先做 bytevector<->foreign 拷贝。
 *      因此本运行时零 Chez 头依赖（不 include scheme.h）。
 *
 * rt_await / rt_cq_wait 会阻塞，Scheme 侧必须声明 __collect_safe（调用线程在
 * 等待期间 deactivate，GC-safe）；它们只收整数句柄。
 */
#ifndef RT_RUNTIME_H
#define RT_RUNTIME_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 生命周期（幂等）。 */
void rt_runtime_start(void);
void rt_runtime_stop(void);
void rt_runtime_exit_on_signal(int on);
void rt_shutdown_timeout(uint32_t ms);
int rt_shutdown_requested(void);

/* 提交。每个返回 task 句柄（0 仅表示分配失败）。尾参 cq 是 completion-queue
 * 句柄，或 0 表示逐 task await。 */
uintptr_t rt_timer(uint64_t ms, uintptr_t cq);

uintptr_t rt_fs_open(const char* path, int flags, int mode, uintptr_t cq);
uintptr_t rt_fs_read(int fd, uint32_t nbytes, int64_t offset, uintptr_t cq);
/* src 是裸 foreign 指针（非 Scheme bytevector）；从 src+start 拷 nbytes。 */
uintptr_t rt_fs_write(int fd, const void* src, uint32_t start, uint32_t nbytes,
                      int64_t offset, uintptr_t cq);
uintptr_t rt_fs_close(int fd, uintptr_t cq);
uintptr_t rt_fs_stat(const char* path, uintptr_t cq);
uintptr_t rt_fs_mkdir(const char* path, int mode, uintptr_t cq);
uintptr_t rt_fs_rmdir(const char* path, uintptr_t cq);
uintptr_t rt_fs_unlink(const char* path, uintptr_t cq);
uintptr_t rt_fs_rename(const char* path, const char* new_path, uintptr_t cq);
uintptr_t rt_fs_realpath(const char* path, uintptr_t cq);
uintptr_t rt_fs_scandir(const char* path, uintptr_t cq);

/* stat 访问器（await 后调用）。 */
uint64_t rt_stat_size(uintptr_t task);
uint64_t rt_stat_mtime(uintptr_t task);
uint32_t rt_stat_mode(uintptr_t task);
int rt_stat_is_dir(uintptr_t task);
int rt_stat_is_file(uintptr_t task);

/* scandir 结果（await 后）。 */
int rt_scandir_count(uintptr_t task);
const char* rt_scandir_name(uintptr_t task, int index);

/* realpath / dns / watch filename 的字符串结果（await 后）。 */
const char* rt_str_result(uintptr_t task);

uintptr_t rt_stdio_open(int fd, uintptr_t cq);
uintptr_t rt_fs_watch(const char* path, uintptr_t cq);
uintptr_t rt_fs_watch_next(uintptr_t watcher, uintptr_t cq);
uintptr_t rt_fs_watch_close(uintptr_t watcher, uintptr_t cq);

/* TCP。connect/listen/accept 以 Stream/Listener 句柄为结果（或负 errno）。
 * 地址为数字 IPv4/IPv6 字面量（名字解析走 rt_dns_resolve）。 */
uintptr_t rt_tcp_connect(const char* host, int port, uintptr_t cq);
uintptr_t rt_tcp_listen(const char* host, int port, int backlog, uintptr_t cq);
uintptr_t rt_tcp_accept(uintptr_t listener, uintptr_t cq);

/* Stream I/O。read 完成=读到字节数（0=EOF），write=字节数，皆负 errno 出错。
 * read 按需（有 read task 排队才读，天然背压）；并发 reader FIFO。
 * src 是裸 foreign 指针。 */
uintptr_t rt_stream_read(uintptr_t stream, uint32_t maxlen, uintptr_t cq);
uintptr_t rt_stream_write(uintptr_t stream, const void* src, uint32_t start,
                          uint32_t nbytes, uintptr_t cq);
uint64_t rt_stream_write_queue_size(uintptr_t stream);
uintptr_t rt_stream_close(uintptr_t stream, uintptr_t cq);
uintptr_t rt_listener_close(uintptr_t listener, uintptr_t cq);

/* pinned 零拷贝变体（S6）：I/O 直接落在 bytevector 字节上，用 Slock_object 锁到
 * rt_task_free（在其解锁）。bytevector 作 scheme-object 传入（Scheme 侧绑
 * scheme-object；此处声明为 void*）。无中间 buffer、无拷贝。read 完成即为读到
 * 字节数（直接在 bytevector 里），不需 rt_read_into。 */
uintptr_t rt_fs_read_pinned(int fd, void* bytevector, uint32_t start,
                            uint32_t nbytes, int64_t offset, uintptr_t cq);
uintptr_t rt_fs_write_pinned(int fd, void* bytevector, uint32_t start,
                             uint32_t nbytes, int64_t offset, uintptr_t cq);
uintptr_t rt_stream_read_pinned(uintptr_t stream, void* bytevector,
                                uint32_t start, uint32_t nbytes, uintptr_t cq);
uintptr_t rt_stream_write_pinned(uintptr_t stream, void* bytevector,
                                 uint32_t start, uint32_t nbytes, uintptr_t cq);

/* DNS。host(+可选 service，""=无)→数字 IP：首个经 rt_str_result，全部经
 * rt_scandir_count/name。family：0=any/4/6。task 结果 0 或负 errno。 */
uintptr_t rt_dns_resolve(const char* host, const char* service, int family,
                         uintptr_t cq);

/* 进程。argbuf 是 argc 个 NUL 分隔字符串；结果=Process 句柄或负 errno。
 * envc<0 继承父环境；cwd ""继承。stdio_mode 0 继承 fd，1 捕获为 pipe Stream。 */
uintptr_t rt_spawn(const void* argbuf, uint32_t arglen, int argc,
                   const void* envbuf, uint32_t envlen, int envc,
                   const char* cwd, int stdio_mode, uintptr_t cq);
uintptr_t rt_proc_stdin(uintptr_t process);
uintptr_t rt_proc_stdout(uintptr_t process);
uintptr_t rt_proc_stderr(uintptr_t process);
uintptr_t rt_proc_wait(uintptr_t process, uintptr_t cq);
uintptr_t rt_proc_kill(uintptr_t process, int signum, uintptr_t cq);
uintptr_t rt_proc_close(uintptr_t process, uintptr_t cq);

/* 阻塞至 task 完成，返回结果。Scheme 侧声明 __collect_safe。 */
int64_t rt_await(uintptr_t task);

/* 结果查询（await 后、activated 时调用）。 */
int64_t rt_task_result(uintptr_t task);
/* 把已完成 read task 的字节拷进 dst+start。dst 是裸 foreign 指针。 */
void rt_read_into(uintptr_t task, void* dst, uint32_t start);
void rt_task_free(uintptr_t task);

/* Completion queue：批量收割（协程调度器 substrate）。 */
uintptr_t rt_cq_create(void);
void rt_cq_free(uintptr_t cq);
uintptr_t rt_cq_wait(uintptr_t cq);     /* 阻塞；Scheme 侧 __collect_safe */
uintptr_t rt_cq_try_pop(uintptr_t cq);  /* 非阻塞；0 表示空 */

/* 泄漏断言用的存活对象计数（0=平衡）。 */
long rt_debug_live_tasks(void);
long rt_debug_live_cqs(void);
long rt_debug_live_streams(void);
long rt_debug_live_listeners(void);
long rt_debug_live_processes(void);
long rt_debug_live_watchers(void);

/* libuv 错误名/消息（负 errno）。返回的字符串是静态/线程局部静态，FFI 边界拷贝。 */
const char* rt_err_name(int err);
const char* rt_err_str(int err);

#ifdef __cplusplus
}
#endif

#endif /* RT_RUNTIME_H */
