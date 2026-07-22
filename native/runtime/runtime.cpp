// Vendored from skiff src/runtime @ 93e0fd6 (2026-07-22).
// namespace skiff -> cart; C ABI skiff_* -> rt_*. See docs/skiff-aligned-io-design.md.
#include "runtime.hpp"

#include <netdb.h>
#include <netinet/in.h>

#include <algorithm>
#include <cassert>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#include "net.hpp"

namespace cart {

Runtime& Runtime::Instance() {
  static Runtime rt;
  return rt;
}

// --- libuv completion callbacks (loop thread only; no Scheme heap access) ---

namespace {

void on_fs_done(uv_fs_t* req) {
  auto* t = static_cast<Task*>(req->data);
  std::int64_t r = req->result;
  switch (t->op) {
    case Op::FsStat:
      if (r == 0) t->statbuf = req->statbuf;
      break;
    case Op::FsRealpath:
      if (r == 0) t->str_out = static_cast<const char*>(req->ptr);
      break;
    case Op::FsScandir:
      if (r >= 0) {
        uv_dirent_t ent;
        while (uv_fs_scandir_next(req, &ent) == 0) t->names.emplace_back(ent.name);
      }
      break;
    default:
      break;
  }
  uv_fs_req_cleanup(req);
  t->Complete(r);
}

// Timer handles are embedded in the Task, so the Task must outlive the close.
// Complete only once the handle is fully closed.
void on_timer_closed(uv_handle_t* h) {
  auto* t = static_cast<Task*>(h->data);
  t->Complete(0);
}

void on_timer(uv_timer_t* h) {
  uv_timer_stop(h);
  uv_close(reinterpret_cast<uv_handle_t*>(h), on_timer_closed);
}

// --- net callbacks (loop thread; no Scheme heap access) ---

inline std::int64_t as_result(void* p) {
  return static_cast<std::int64_t>(reinterpret_cast<std::uintptr_t>(p));
}

// Streams with at least one queued read task (loop thread only). Graceful
// shutdown's Phase 3 sweep cancels exactly these: an idle keep-alive / h2 /
// WebSocket connection is a fiber parked in a stream read, and completing the
// read with ECANCELED is what wakes it to say its protocol goodbye. Writes
// and timers are never cancelled — the goodbye itself (GOAWAY, WS Close) is a
// write, and an in-flight handler sleeping before its response must finish.
std::unordered_set<Stream*> reading_streams;

// Wake every parked reader with ECANCELED and stop the uv-level reads.
void cancel_pending_reads() {
  for (Stream* s : reading_streams) {
    if (s->read_active) {
      uv_read_stop(s->stream());
      s->read_active = false;
    }
    while (!s->read_queue.empty()) {
      Task* p = s->read_queue.front();
      s->read_queue.pop_front();
      p->Complete(UV_ECANCELED);
    }
  }
  reading_streams.clear();
}

// I/O destination/source of a task: the pinned bytevector bytes when the
// zero-copy path is in use, the C++-owned buffer otherwise.
inline char* task_data(Task* t) {
  return reinterpret_cast<char*>(t->ext_data ? t->ext_data : t->buffer.data());
}

void on_connect(uv_connect_t* req, int status) {
  auto* t = static_cast<Task*>(req->data);
  auto* s = t->stream;
  if (status < 0) {
    t->stream = nullptr;
    s->Close(nullptr);  // discard the half-open socket
    t->Complete(status);
  } else {
    t->Complete(as_result(s));
  }
}

void on_connection(uv_stream_t* server, int status) {
  auto* l = static_cast<Listener*>(server->data);
  if (status < 0) return;
  auto* s = new Stream();
  s->loop = l->loop;
  uv_tcp_init(l->loop, &s->h.tcp);
  s->handle()->data = s;
  if (uv_accept(server, s->stream()) != 0) {
    s->Close(nullptr);
    return;
  }
  if (!l->pending_accepts.empty()) {
    Task* t = l->pending_accepts.front();
    l->pending_accepts.pop_front();
    t->Complete(as_result(s));
  } else {
    l->accepted.push_back(s);
  }
}

void on_alloc(uv_handle_t* h, size_t /*suggested*/, uv_buf_t* buf) {
  auto* s = static_cast<Stream*>(h->data);
  if (!s->read_queue.empty()) {
    Task* t = s->read_queue.front();
    buf->base = task_data(t);
    buf->len = t->nbytes;
  } else {
    buf->base = nullptr;
    buf->len = 0;
  }
}

void on_read(uv_stream_t* stream, ssize_t nread, const uv_buf_t* /*buf*/) {
  auto* s = static_cast<Stream*>(stream->data);
  if (nread == 0) return;  // EAGAIN: nothing available right now
  if (s->read_queue.empty()) {
    uv_read_stop(stream);
    s->read_active = false;
    reading_streams.erase(s);
    return;
  }
  if (nread > 0) {
    // Deliver the chunk to the front reader; keep reading while more are
    // queued, otherwise stop (read-on-demand backpressure).
    Task* t = s->read_queue.front();
    s->read_queue.pop_front();
    if (s->read_queue.empty()) {
      uv_read_stop(stream);
      s->read_active = false;
      reading_streams.erase(s);
    }
    t->Complete(nread);
  } else {
    // EOF / error is terminal: fan out to every queued reader.
    std::int64_t r = nread == UV_EOF ? 0 : nread;
    uv_read_stop(stream);
    s->read_active = false;
    reading_streams.erase(s);
    while (!s->read_queue.empty()) {
      Task* t = s->read_queue.front();
      s->read_queue.pop_front();
      t->Complete(r);
    }
  }
}

void on_write(uv_write_t* req, int status) {
  auto* t = static_cast<Task*>(req->data);
  t->Complete(status < 0 ? status : static_cast<std::int64_t>(t->nbytes));
}

// --- DNS callback (loop thread) ---

void on_getaddrinfo(uv_getaddrinfo_t* req, int status, struct addrinfo* res) {
  auto* t = static_cast<Task*>(req->data);
  if (status == 0) {
    // Collect every distinct address, OS preference order. First one also
    // lands in str_out for the single-result API.
    for (struct addrinfo* ai = res; ai; ai = ai->ai_next) {
      char ip[INET6_ADDRSTRLEN] = {0};
      if (ai->ai_family == AF_INET) {
        uv_ip4_name(reinterpret_cast<sockaddr_in*>(ai->ai_addr), ip, sizeof(ip));
      } else if (ai->ai_family == AF_INET6) {
        uv_ip6_name(reinterpret_cast<sockaddr_in6*>(ai->ai_addr), ip, sizeof(ip));
      } else {
        continue;
      }
      if (std::find(t->names.begin(), t->names.end(), ip) == t->names.end())
        t->names.emplace_back(ip);
    }
    if (t->names.empty()) status = UV_EAI_NONAME;
    else t->str_out = t->names.front();
  }
  if (res) uv_freeaddrinfo(res);
  t->Complete(status);
}

// Parse a numeric IPv4 or IPv6 literal into storage usable as sockaddr*.
int parse_ip_addr(const char* host, int port, sockaddr_storage* out) {
  int r = uv_ip4_addr(host, port, reinterpret_cast<sockaddr_in*>(out));
  if (r < 0) r = uv_ip6_addr(host, port, reinterpret_cast<sockaddr_in6*>(out));
  return r;
}

// Split `count` NUL-terminated strings packed contiguously in `buf` into a
// null-terminated array of pointers into buf, as uv_process_options expects
// for args/env.
void UnpackStrings(std::vector<std::uint8_t>& buf, int count,
                   std::vector<char*>& out) {
  out.reserve(count + 1);
  char* base = reinterpret_cast<char*>(buf.data());
  std::size_t off = 0;
  for (int i = 0; i < count; ++i) {
    out.push_back(base + off);
    off += std::strlen(base + off) + 1;
  }
  out.push_back(nullptr);
}

// --- fs-watch callbacks (loop thread) ---

// Deliver one event into a next-task: filename via str_out, events/errno via
// the result integer.
void deliver_watch_event(Task* t, const std::string& name, std::int64_t ev) {
  t->str_out = name;
  t->Complete(ev);
}

void on_fs_event(uv_fs_event_t* handle, const char* filename, int events,
                 int status) {
  auto* w = static_cast<Watcher*>(handle->data);
  std::string name = filename ? filename : "";
  std::int64_t ev = status < 0 ? status : events;
  if (w->pending_next) {
    Task* t = w->pending_next;
    w->pending_next = nullptr;
    deliver_watch_event(t, name, ev);
  } else {
    w->events.emplace_back(std::move(name), ev);
  }
}

// Begin closing a listener: drop unconsumed connections, wake every parked
// acceptor with ECANCELED (their tcp-accept raises, the worker's accept loop
// exits — the cascade graceful shutdown rides on), then close the uv handle.
// Shared by the ListenerClose task and the signal path.
void abort_listener(Listener* l, Task* close_task) {
  for (Stream* s : l->accepted) s->Close(nullptr);  // drop unconsumed conns
  l->accepted.clear();
  while (!l->pending_accepts.empty()) {  // wake parked acceptors
    Task* p = l->pending_accepts.front();
    l->pending_accepts.pop_front();
    p->Complete(UV_ECANCELED);
  }
  l->Close(close_task);
}

void on_process_exit(uv_process_t* proc, int64_t exit_status, int term_signal) {
  auto* p = static_cast<Process*>(proc->data);
  p->exited = true;
  p->exit_status = exit_status;
  p->term_signal = term_signal;
  if (p->wait_task) {
    Task* t = p->wait_task;
    p->wait_task = nullptr;
    t->Complete(exit_status);
  }
}

}  // namespace

// --- Loop thread ------------------------------------------------------------

void Runtime::LoopMain() { uv_run(&loop_, UV_RUN_DEFAULT); }

void Runtime::OnAsync(uv_async_t* h) {
  static_cast<Runtime*>(h->data)->Drain();
}

// SIGINT/SIGTERM caught on the loop thread. This runs as an ordinary libuv
// callback (not async-signal context), so plain calls are safe.
//
// Graceful shutdown (designs/graceful-shutdown.md, Phase 1): the first signal
// with open listeners closes them all — parked accepts complete with
// ECANCELED, the Scheme workers' accept loops exit, their schedulers finish
// in-flight connection fibers, web-serve joins and returns, the script ends,
// and main.cpp's rt_runtime_stop() winds the loop down. Nothing here
// touches the Scheme heap; the whole Scheme-side exit rides the existing
// listener-close cascade. A shutdown timer backstops the window (default 30s):
// if the process is still alive at the deadline, _Exit(128+signum).
//
// Hard exit stays for the cases where graceful has nothing to drain or the
// user insists: no open listeners (a plain script parked in some blocking
// task — nothing to wind down, and Chez's interrupt can't fire there), or a
// second signal (^C^C). _Exit skips atexit/static destructors (which would
// try to join *this* loop thread from within it); flush C stdio first so
// buffered output isn't lost.
void Runtime::OnSignal(uv_signal_t* h, int signum) {
  auto* rt = static_cast<Runtime*>(h->data);
  if (rt->shutdown_signaled_.exchange(true, std::memory_order_acq_rel) ||
      rt->listeners_.empty()) {
    std::fflush(nullptr);
    std::_Exit(128 + signum);
  }
  rt->shutdown_signum_ = signum;
  for (Listener* l : rt->listeners_) abort_listener(l, nullptr);
  rt->listeners_.clear();
  // Phase 3: wake idle connections. Every parked stream read completes with
  // ECANCELED; the serve loops treat that as EOF and say their protocol
  // goodbye (h2 GOAWAY, WS Close 1001) on the still-working write side.
  cancel_pending_reads();
  uv_timer_init(&rt->loop_, &rt->shutdown_timer_);
  rt->shutdown_timer_.data = rt;
  rt->shutdown_timer_started_ = true;
  uv_timer_start(&rt->shutdown_timer_, OnShutdownTimer,
                 rt->shutdown_timeout_ms_.load(std::memory_order_relaxed), 0);
}

// The graceful window expired with the process still alive (a worker stuck in
// an in-flight handler, an idle keep-alive connection parked in a read, ...).
// No more negotiation — same contract as K8s SIGKILL after the grace period.
void Runtime::OnShutdownTimer(uv_timer_t* h) {
  auto* rt = static_cast<Runtime*>(h->data);
  std::fflush(nullptr);
  std::_Exit(128 + rt->shutdown_signum_);
}

void Runtime::Drain() {
  std::vector<Task*> local;
  {
    std::lock_guard<std::mutex> lk(qmutex_);
    local.swap(queue_);
  }
  for (Task* t : local) Dispatch(t);

  if (stopping_.load(std::memory_order_acquire)) {
    // No new work will be accepted; closing the async lets uv_run() return
    // once outstanding operations finish. The signal handles (if installed)
    // and a running shutdown timer are active and would otherwise keep the
    // loop alive (deadlocking the graceful path's runtime_stop join), so
    // close them too.
    uv_close(reinterpret_cast<uv_handle_t*>(&async_), nullptr);
    if (exit_on_signal_.load(std::memory_order_relaxed)) {
      uv_close(reinterpret_cast<uv_handle_t*>(&sig_int_), nullptr);
      uv_close(reinterpret_cast<uv_handle_t*>(&sig_term_), nullptr);
    }
    if (shutdown_timer_started_) {
      shutdown_timer_started_ = false;
      uv_timer_stop(&shutdown_timer_);
      uv_close(reinterpret_cast<uv_handle_t*>(&shutdown_timer_), nullptr);
    }
  }
}

void Runtime::Dispatch(Task* t) {
  t->fs_req.data = t;
  t->timer.data = t;
  switch (t->op) {
    case Op::Timer:
      uv_timer_init(&loop_, &t->timer);
      uv_timer_start(&t->timer, on_timer, t->timeout_ms, 0);
      break;
    case Op::FsOpen:
      uv_fs_open(&loop_, &t->fs_req, t->path.c_str(), t->flags, t->mode,
                 on_fs_done);
      break;
    case Op::FsRead: {
      uv_buf_t buf = uv_buf_init(task_data(t), t->nbytes);
      uv_fs_read(&loop_, &t->fs_req, t->fd, &buf, 1, t->offset, on_fs_done);
      break;
    }
    case Op::FsWrite: {
      uv_buf_t buf = uv_buf_init(task_data(t), t->nbytes);
      uv_fs_write(&loop_, &t->fs_req, t->fd, &buf, 1, t->offset, on_fs_done);
      break;
    }
    case Op::FsClose:
      uv_fs_close(&loop_, &t->fs_req, t->fd, on_fs_done);
      break;
    case Op::FsStat:
      uv_fs_stat(&loop_, &t->fs_req, t->path.c_str(), on_fs_done);
      break;
    case Op::FsMkdir:
      uv_fs_mkdir(&loop_, &t->fs_req, t->path.c_str(), t->mode, on_fs_done);
      break;
    case Op::FsRmdir:
      uv_fs_rmdir(&loop_, &t->fs_req, t->path.c_str(), on_fs_done);
      break;
    case Op::FsUnlink:
      uv_fs_unlink(&loop_, &t->fs_req, t->path.c_str(), on_fs_done);
      break;
    case Op::FsRename:
      uv_fs_rename(&loop_, &t->fs_req, t->path.c_str(), t->new_path.c_str(),
                   on_fs_done);
      break;
    case Op::FsRealpath:
      uv_fs_realpath(&loop_, &t->fs_req, t->path.c_str(), on_fs_done);
      break;
    case Op::FsScandir:
      uv_fs_scandir(&loop_, &t->fs_req, t->path.c_str(), 0, on_fs_done);
      break;
    case Op::TcpConnect: {
      auto* s = new Stream();
      s->loop = &loop_;
      uv_tcp_init(&loop_, &s->h.tcp);
      s->handle()->data = s;
      t->stream = s;
      s->connect_req.data = t;
      struct sockaddr_storage addr;
      int r = parse_ip_addr(t->path.c_str(), t->port, &addr);
      if (r == 0)
        r = uv_tcp_connect(&s->connect_req, &s->h.tcp,
                           reinterpret_cast<const sockaddr*>(&addr), on_connect);
      if (r < 0) {
        t->stream = nullptr;
        s->Close(nullptr);
        t->Complete(r);
      }
      break;
    }
    case Op::TcpListen: {
      auto* l = new Listener();
      l->loop = &loop_;
      uv_tcp_init(&loop_, &l->tcp);
      l->tcp.data = l;
      struct sockaddr_storage addr;
      int r = parse_ip_addr(t->path.c_str(), t->port, &addr);
      if (r == 0)
        r = uv_tcp_bind(&l->tcp, reinterpret_cast<const sockaddr*>(&addr), 0);
      if (r == 0)
        r = uv_listen(reinterpret_cast<uv_stream_t*>(&l->tcp), t->backlog,
                      on_connection);
      if (r < 0) {
        l->Close(nullptr);
        t->Complete(r);
      } else {
        listeners_.insert(l);  // visible to the graceful-shutdown signal path
        t->Complete(as_result(l));
      }
      break;
    }
    case Op::TcpAccept: {
      auto* l = t->listener;
      if (!l->accepted.empty()) {
        Stream* s = l->accepted.front();
        l->accepted.pop_front();
        t->Complete(as_result(s));
      } else {
        l->pending_accepts.push_back(t);
      }
      break;
    }
    case Op::StreamRead: {
      // During graceful shutdown reads fail fast: parked ones were cancelled
      // by the signal sweep, and letting new ones park would only re-create
      // the wait the sweep just broke. Writes stay live for the goodbyes.
      if (shutdown_signaled_.load(std::memory_order_acquire)) {
        t->Complete(UV_ECANCELED);
        break;
      }
      auto* s = t->stream;
      s->read_queue.push_back(t);
      if (!s->read_active) {
        int r = uv_read_start(s->stream(), on_alloc, on_read);
        if (r < 0) {
          s->read_queue.pop_back();
          t->Complete(r);
        } else {
          s->read_active = true;
        }
      }
      if (!s->read_queue.empty()) reading_streams.insert(s);
      break;
    }
    case Op::StreamWrite: {
      auto* s = t->stream;
      uv_buf_t buf = uv_buf_init(task_data(t), t->nbytes);
      t->write_req.data = t;
      int r = uv_write(&t->write_req, s->stream(),
                       &buf, 1, on_write);
      if (r < 0) t->Complete(r);
      break;
    }
    case Op::StreamClose: {
      auto* s = t->stream;
      if (s->read_active) {
        uv_read_stop(s->stream());
        s->read_active = false;
      }
      while (!s->read_queue.empty()) {  // wake parked readers before teardown
        Task* p = s->read_queue.front();
        s->read_queue.pop_front();
        p->Complete(UV_ECANCELED);
      }
      reading_streams.erase(s);
      s->Close(t);
      break;
    }
    case Op::ListenerClose: {
      auto* l = t->listener;
      // Not in the registry means the close already began elsewhere — the
      // graceful-shutdown signal path closed it (the object may already be
      // gone). Complete without touching the pointer.
      if (listeners_.erase(l) == 0) {
        t->Complete(0);
        break;
      }
      abort_listener(l, t);
      break;
    }
    case Op::DnsResolve: {
      struct addrinfo hints{};
      hints.ai_family = t->family == 4   ? AF_INET
                        : t->family == 6 ? AF_INET6
                                         : AF_UNSPEC;
      hints.ai_socktype = SOCK_STREAM;
      t->addr_req.data = t;
      const char* service = t->service.empty() ? nullptr : t->service.c_str();
      int r = uv_getaddrinfo(&loop_, &t->addr_req, on_getaddrinfo,
                             t->path.c_str(), service, &hints);
      if (r < 0) t->Complete(r);
      break;
    }
    case Op::ProcSpawn: {
      auto* p = new Process();
      p->loop = &loop_;
      p->proc.data = p;

      // Unpack NUL-separated argv (and optionally envp) from the task buffers.
      std::vector<char*> argv;
      UnpackStrings(t->buffer, t->argc, argv);
      std::vector<char*> envp;
      if (t->envc >= 0) UnpackStrings(t->env_buf, t->envc, envp);

      uv_stdio_container_t stdio[3];
      if (t->stdio_mode == 1) {
        // Capture: create a pipe Stream per fd. From the child's perspective
        // stdin is readable, stdout/stderr are writable.
        Stream* pipes[3];
        for (int i = 0; i < 3; ++i) {
          auto* s = new Stream();
          s->loop = &loop_;
          uv_pipe_init(&loop_, &s->h.pipe, 0);
          s->handle()->data = s;
          pipes[i] = s;
          stdio[i].flags = static_cast<uv_stdio_flags>(
              UV_CREATE_PIPE |
              (i == 0 ? UV_READABLE_PIPE : UV_WRITABLE_PIPE));
          stdio[i].data.stream = s->stream();
        }
        p->stdin_s = pipes[0];
        p->stdout_s = pipes[1];
        p->stderr_s = pipes[2];
      } else {
        for (int i = 0; i < 3; ++i) {
          stdio[i].flags = UV_INHERIT_FD;
          stdio[i].data.fd = i;
        }
      }

      uv_process_options_t options{};
      options.exit_cb = on_process_exit;
      options.file = argv[0];
      options.args = argv.data();
      options.env = t->envc >= 0 ? envp.data() : nullptr;
      options.cwd = t->cwd.empty() ? nullptr : t->cwd.c_str();
      options.stdio_count = 3;
      options.stdio = stdio;

      int r = uv_spawn(&loop_, &p->proc, &options);
      if (r < 0) {
        for (Stream* s : {p->stdin_s, p->stdout_s, p->stderr_s}) {
          if (s) s->Close(nullptr);
        }
        p->Close(nullptr);
        t->Complete(r);
      } else {
        t->Complete(as_result(p));
      }
      break;
    }
    case Op::ProcWait: {
      auto* p = t->process;
      if (p->exited) {
        t->Complete(p->exit_status);
      } else {
        p->wait_task = t;  // completed by on_process_exit
      }
      break;
    }
    case Op::ProcKill: {
      int r = uv_process_kill(&t->process->proc, t->signum);
      t->Complete(r);
      break;
    }
    case Op::ProcClose: {
      t->process->Close(t);
      break;
    }
    case Op::FsWatchOpen: {
      auto* w = new Watcher();
      w->loop = &loop_;
      uv_fs_event_init(&loop_, &w->ev);
      w->ev.data = w;
      int r = uv_fs_event_start(&w->ev, on_fs_event, t->path.c_str(), 0);
      if (r < 0) {
        w->Close(nullptr);
        t->Complete(r);
      } else {
        t->Complete(as_result(w));
      }
      break;
    }
    case Op::FsWatchNext: {
      auto* w = t->watcher;
      if (w->pending_next) {
        t->Complete(UV_EBUSY);  // one waiter at a time
      } else if (!w->events.empty()) {
        auto [name, ev] = std::move(w->events.front());
        w->events.pop_front();
        deliver_watch_event(t, name, ev);
      } else {
        w->pending_next = t;
      }
      break;
    }
    case Op::StdioOpen: {
      // Wrap an inherited fd (0/1/2) as a Stream when libuv can stream it.
      // Regular files can't be uv streams: complete with 0 (never a valid
      // handle) so the Scheme layer falls back to fd-based fs I/O.
      uv_handle_type kind = uv_guess_handle(t->fd);
      if (kind != UV_TTY && kind != UV_NAMED_PIPE) {
        t->Complete(0);  // not streamable: caller uses fd-based fs I/O
        break;
      }
      auto* s = new Stream();
      s->loop = &loop_;
      int r;
      if (kind == UV_TTY) {
        r = uv_tty_init(&loop_, &s->h.tty, t->fd, 0);
      } else {  // UV_NAMED_PIPE
        r = uv_pipe_init(&loop_, &s->h.pipe, 0);
        if (r == 0) r = uv_pipe_open(&s->h.pipe, t->fd);
      }
      s->handle()->data = s;
      if (r < 0) {
        s->Close(nullptr);
        t->Complete(r);
      } else {
        t->Complete(as_result(s));
      }
      break;
    }
    case Op::FsWatchClose: {
      auto* w = t->watcher;
      if (w->pending_next) {  // wake the parked waiter before tearing down
        Task* p = w->pending_next;
        w->pending_next = nullptr;
        p->Complete(UV_ECANCELED);
      }
      uv_fs_event_stop(&w->ev);
      w->Close(t);
      break;
    }
  }
}

// --- Lifecycle & submission (called from Scheme threads) --------------------

void Runtime::Start() {
  bool expected = false;
  if (!running_.compare_exchange_strong(expected, true)) return;
  stopping_.store(false, std::memory_order_release);
  shutdown_signaled_.store(false, std::memory_order_release);
  shutdown_timer_started_ = false;
  reading_streams.clear();
  uv_loop_init(&loop_);
  uv_async_init(&loop_, &async_, OnAsync);
  async_.data = this;
  // Set up before spawning the loop thread (the loop isn't running yet, so this
  // is just handle initialization). Starting the uv_signal handles installs
  // libuv's process signal handler, which — because Start() runs after
  // Sbuild_heap — supersedes Chez's own SIGINT handler, so ^C reaches us here
  // instead of eventually aborting the kernel.
  if (exit_on_signal_.load(std::memory_order_relaxed)) {
    uv_signal_init(&loop_, &sig_int_);
    uv_signal_init(&loop_, &sig_term_);
    sig_int_.data = this;
    sig_term_.data = this;
    uv_signal_start(&sig_int_, OnSignal, SIGINT);
    uv_signal_start(&sig_term_, OnSignal, SIGTERM);
  }
  thread_ = std::thread(&Runtime::LoopMain, this);
}

void Runtime::Stop() {
  bool expected = true;
  if (!running_.compare_exchange_strong(expected, false)) return;
  stopping_.store(true, std::memory_order_release);
  uv_async_send(&async_);
  thread_.join();
  uv_loop_close(&loop_);
}

void Runtime::Submit(Task* t) {
  assert(running_.load(std::memory_order_acquire) &&
         "submit() before start()/after stop()");
  {
    std::lock_guard<std::mutex> lk(qmutex_);
    queue_.push_back(t);
  }
  uv_async_send(&async_);
}

}  // namespace cart
