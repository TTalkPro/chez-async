// extern "C" 实现 chez-async task-runtime 的 FFI 边界。
// 移植自 skiff src/runtime/ffi.cpp @ 93e0fd6，改动：
//   - 符号 skiff_* -> rt_*，命名空间 skiff -> cart。
//   - 去掉 pinned 零拷贝变体与 scheme.h 依赖（不 include Chez 头）。
//   - 写类/读类的 buffer 参数改为裸 foreign 指针（const void* / void*），
//     memcpy 直接拷贝——不碰 Scheme 对象。Scheme 侧负责 bytevector<->foreign。
//
// 提交与结果访问器在 activated 的 Scheme 线程上运行（普通 foreign call 不会被
// GC 打断，同步读写 foreign 内存安全）。只有 rt_await / rt_cq_wait 阻塞，且只收
// 整数句柄。

#include <sys/stat.h>

#include <cstdint>
#include <cstring>

#include "rt_runtime.h"

#include "net.hpp"
#include "runtime.hpp"
#include "task.hpp"

using cart::CompletionQueue;
using cart::Op;
using cart::Runtime;
using cart::Task;

namespace {

inline Task* as_task(uintptr_t h) { return reinterpret_cast<Task*>(h); }
inline CompletionQueue* as_cq(uintptr_t h) {
  return reinterpret_cast<CompletionQueue*>(h);
}
inline uintptr_t handle(void* p) { return reinterpret_cast<uintptr_t>(p); }

Task* new_task(Op op, uintptr_t cq) {
  auto* t = new Task(op);
  t->cq = as_cq(cq);
  if (t->cq) t->cq->Retain();  // released by Task::Complete after posting
  return t;
}

uintptr_t Submit(Task* t) {
  Runtime::Instance().Submit(t);
  return handle(t);
}

uintptr_t SubmitStreamOp(Op op, uintptr_t stream, uintptr_t cq) {
  Task* t = new_task(op, cq);
  t->stream = reinterpret_cast<cart::Stream*>(stream);
  return Submit(t);
}
uintptr_t SubmitListenerOp(Op op, uintptr_t listener, uintptr_t cq) {
  Task* t = new_task(op, cq);
  t->listener = reinterpret_cast<cart::Listener*>(listener);
  return Submit(t);
}
uintptr_t SubmitProcessOp(Op op, uintptr_t process, uintptr_t cq) {
  Task* t = new_task(op, cq);
  t->process = reinterpret_cast<cart::Process*>(process);
  return Submit(t);
}
uintptr_t SubmitWatcherOp(Op op, uintptr_t watcher, uintptr_t cq) {
  Task* t = new_task(op, cq);
  t->watcher = reinterpret_cast<cart::Watcher*>(watcher);
  return Submit(t);
}

}  // namespace

extern "C" {

void rt_runtime_start(void) { Runtime::Instance().Start(); }
void rt_runtime_stop(void) { Runtime::Instance().Stop(); }
void rt_runtime_exit_on_signal(int on) {
  Runtime::Instance().ExitOnSignal(on != 0);
}
void rt_shutdown_timeout(uint32_t ms) {
  Runtime::Instance().SetShutdownTimeout(ms);
}
int rt_shutdown_requested(void) {
  return Runtime::Instance().ShutdownRequested() ? 1 : 0;
}

uintptr_t rt_timer(uint64_t ms, uintptr_t cq) {
  Task* t = new_task(Op::Timer, cq);
  t->timeout_ms = ms;
  return Submit(t);
}

uintptr_t rt_fs_open(const char* path, int flags, int mode, uintptr_t cq) {
  Task* t = new_task(Op::FsOpen, cq);
  t->path = path;
  t->flags = flags;
  t->mode = mode;
  return Submit(t);
}

uintptr_t rt_fs_read(int fd, uint32_t nbytes, int64_t offset, uintptr_t cq) {
  Task* t = new_task(Op::FsRead, cq);
  t->fd = fd;
  t->nbytes = nbytes;
  t->offset = offset;
  t->buffer.resize(nbytes);
  return Submit(t);
}

uintptr_t rt_fs_write(int fd, const void* src, uint32_t start, uint32_t nbytes,
                      int64_t offset, uintptr_t cq) {
  Task* t = new_task(Op::FsWrite, cq);
  t->fd = fd;
  t->nbytes = nbytes;
  t->offset = offset;
  t->buffer.resize(nbytes);
  // src 是裸 foreign 指针，直接拷贝（loop 线程从不见 Scheme 对象）。
  std::memcpy(t->buffer.data(),
              static_cast<const std::uint8_t*>(src) + start, nbytes);
  return Submit(t);
}

uintptr_t rt_fs_close(int fd, uintptr_t cq) {
  Task* t = new_task(Op::FsClose, cq);
  t->fd = fd;
  return Submit(t);
}

uintptr_t rt_fs_stat(const char* path, uintptr_t cq) {
  Task* t = new_task(Op::FsStat, cq);
  t->path = path;
  return Submit(t);
}

uintptr_t rt_fs_mkdir(const char* path, int mode, uintptr_t cq) {
  Task* t = new_task(Op::FsMkdir, cq);
  t->path = path;
  t->mode = mode;
  return Submit(t);
}

uintptr_t rt_fs_rmdir(const char* path, uintptr_t cq) {
  Task* t = new_task(Op::FsRmdir, cq);
  t->path = path;
  return Submit(t);
}

uintptr_t rt_fs_unlink(const char* path, uintptr_t cq) {
  Task* t = new_task(Op::FsUnlink, cq);
  t->path = path;
  return Submit(t);
}

uintptr_t rt_fs_rename(const char* path, const char* new_path, uintptr_t cq) {
  Task* t = new_task(Op::FsRename, cq);
  t->path = path;
  t->new_path = new_path;
  return Submit(t);
}

uintptr_t rt_fs_realpath(const char* path, uintptr_t cq) {
  Task* t = new_task(Op::FsRealpath, cq);
  t->path = path;
  return Submit(t);
}

uintptr_t rt_fs_scandir(const char* path, uintptr_t cq) {
  Task* t = new_task(Op::FsScandir, cq);
  t->path = path;
  return Submit(t);
}

uintptr_t rt_tcp_connect(const char* host, int port, uintptr_t cq) {
  Task* t = new_task(Op::TcpConnect, cq);
  t->path = host;
  t->port = port;
  return Submit(t);
}

uintptr_t rt_tcp_listen(const char* host, int port, int backlog, uintptr_t cq) {
  Task* t = new_task(Op::TcpListen, cq);
  t->path = host;
  t->port = port;
  t->backlog = backlog;
  return Submit(t);
}

uintptr_t rt_tcp_accept(uintptr_t listener, uintptr_t cq) {
  return SubmitListenerOp(Op::TcpAccept, listener, cq);
}

uintptr_t rt_stream_read(uintptr_t stream, uint32_t maxlen, uintptr_t cq) {
  Task* t = new_task(Op::StreamRead, cq);
  t->stream = reinterpret_cast<cart::Stream*>(stream);
  t->nbytes = maxlen;
  t->buffer.resize(maxlen);
  return Submit(t);
}

uintptr_t rt_stream_write(uintptr_t stream, const void* src, uint32_t start,
                          uint32_t nbytes, uintptr_t cq) {
  Task* t = new_task(Op::StreamWrite, cq);
  t->stream = reinterpret_cast<cart::Stream*>(stream);
  t->nbytes = nbytes;
  t->buffer.resize(nbytes);
  std::memcpy(t->buffer.data(),
              static_cast<const std::uint8_t*>(src) + start, nbytes);
  return Submit(t);
}

uintptr_t rt_stream_close(uintptr_t stream, uintptr_t cq) {
  return SubmitStreamOp(Op::StreamClose, stream, cq);
}

uintptr_t rt_listener_close(uintptr_t listener, uintptr_t cq) {
  return SubmitListenerOp(Op::ListenerClose, listener, cq);
}

uintptr_t rt_dns_resolve(const char* host, const char* service, int family,
                         uintptr_t cq) {
  Task* t = new_task(Op::DnsResolve, cq);
  t->path = host;
  t->service = service ? service : "";
  t->family = family;
  return Submit(t);
}

uintptr_t rt_spawn(const void* argbuf, uint32_t arglen, int argc,
                   const void* envbuf, uint32_t envlen, int envc,
                   const char* cwd, int stdio_mode, uintptr_t cq) {
  Task* t = new_task(Op::ProcSpawn, cq);
  t->argc = argc;
  t->buffer.resize(arglen);
  std::memcpy(t->buffer.data(), argbuf, arglen);
  t->envc = envc;
  if (envc >= 0) {
    t->env_buf.resize(envlen);
    std::memcpy(t->env_buf.data(), envbuf, envlen);
  }
  t->cwd = cwd;
  t->stdio_mode = stdio_mode;
  return Submit(t);
}

uintptr_t rt_proc_stdin(uintptr_t process) {
  return handle(reinterpret_cast<cart::Process*>(process)->stdin_s);
}
uintptr_t rt_proc_stdout(uintptr_t process) {
  return handle(reinterpret_cast<cart::Process*>(process)->stdout_s);
}
uintptr_t rt_proc_stderr(uintptr_t process) {
  return handle(reinterpret_cast<cart::Process*>(process)->stderr_s);
}

uintptr_t rt_proc_wait(uintptr_t process, uintptr_t cq) {
  return SubmitProcessOp(Op::ProcWait, process, cq);
}

uintptr_t rt_proc_kill(uintptr_t process, int signum, uintptr_t cq) {
  Task* t = new_task(Op::ProcKill, cq);
  t->process = reinterpret_cast<cart::Process*>(process);
  t->signum = signum;
  return Submit(t);
}

uintptr_t rt_proc_close(uintptr_t process, uintptr_t cq) {
  return SubmitProcessOp(Op::ProcClose, process, cq);
}

uint64_t rt_stream_write_queue_size(uintptr_t stream) {
  return reinterpret_cast<cart::Stream*>(stream)->stream()->write_queue_size;
}

uintptr_t rt_stdio_open(int fd, uintptr_t cq) {
  Task* t = new_task(Op::StdioOpen, cq);
  t->fd = fd;
  return Submit(t);
}

uintptr_t rt_fs_watch(const char* path, uintptr_t cq) {
  Task* t = new_task(Op::FsWatchOpen, cq);
  t->path = path;
  return Submit(t);
}

uintptr_t rt_fs_watch_next(uintptr_t watcher, uintptr_t cq) {
  return SubmitWatcherOp(Op::FsWatchNext, watcher, cq);
}

uintptr_t rt_fs_watch_close(uintptr_t watcher, uintptr_t cq) {
  return SubmitWatcherOp(Op::FsWatchClose, watcher, cq);
}

int64_t rt_await(uintptr_t task) {
  Task* t = as_task(task);
  t->Wait();
  return t->result;
}

int64_t rt_task_result(uintptr_t task) { return as_task(task)->result; }

void rt_read_into(uintptr_t task, void* dst, uint32_t start) {
  Task* t = as_task(task);
  if (t->result > 0) {
    // dst 是裸 foreign 指针（非 Scheme 对象）。
    std::memcpy(static_cast<std::uint8_t*>(dst) + start, t->buffer.data(),
                static_cast<size_t>(t->result));
  }
}

uint64_t rt_stat_size(uintptr_t task) {
  return static_cast<uint64_t>(as_task(task)->statbuf.st_size);
}
uint64_t rt_stat_mtime(uintptr_t task) {
  return static_cast<uint64_t>(as_task(task)->statbuf.st_mtim.tv_sec);
}
uint32_t rt_stat_mode(uintptr_t task) {
  return static_cast<uint32_t>(as_task(task)->statbuf.st_mode);
}
int rt_stat_is_dir(uintptr_t task) {
  return S_ISDIR(as_task(task)->statbuf.st_mode) ? 1 : 0;
}
int rt_stat_is_file(uintptr_t task) {
  return S_ISREG(as_task(task)->statbuf.st_mode) ? 1 : 0;
}

int rt_scandir_count(uintptr_t task) {
  return static_cast<int>(as_task(task)->names.size());
}
const char* rt_scandir_name(uintptr_t task, int index) {
  Task* t = as_task(task);
  if (index < 0 || static_cast<size_t>(index) >= t->names.size()) return "";
  return t->names[index].c_str();
}

const char* rt_str_result(uintptr_t task) {
  return as_task(task)->str_out.c_str();
}

void rt_task_free(uintptr_t task) {
  // 无 pinned 路径，直接删除（skiff 版此处 Sunlock_object，已随 pinned 去除）。
  delete as_task(task);
}

uintptr_t rt_cq_create(void) { return handle(new CompletionQueue()); }
void rt_cq_free(uintptr_t cq) { as_cq(cq)->Release(); }
uintptr_t rt_cq_wait(uintptr_t cq) { return handle(as_cq(cq)->WaitOne()); }
uintptr_t rt_cq_try_pop(uintptr_t cq) { return handle(as_cq(cq)->TryPop()); }

long rt_debug_live_tasks(void) { return cart::Task::live(); }
long rt_debug_live_cqs(void) { return cart::CompletionQueue::live(); }
long rt_debug_live_streams(void) { return cart::Stream::live(); }
long rt_debug_live_listeners(void) { return cart::Listener::live(); }
long rt_debug_live_processes(void) { return cart::Process::live(); }
long rt_debug_live_watchers(void) { return cart::Watcher::live(); }

const char* rt_err_name(int err) { return uv_err_name(err); }
const char* rt_err_str(int err) { return uv_strerror(err); }

}  // extern "C"
