// Vendored from skiff src/runtime @ 93e0fd6 (2026-07-22).
// namespace skiff -> cart; C ABI skiff_* -> rt_*. See docs/skiff-aligned-io-design.md.
// Persistent libuv handles that live on the loop thread and outlive the
// individual Tasks operating on them: Stream (TCP socket / pipe / TTY),
// Listener (server socket), Process (child), Watcher (fs events). Only the
// loop thread touches these; Scheme holds them as opaque uintptr_t handles.
#pragma once

#include <deque>
#include <string>
#include <utility>

#include <uv.h>

#include "task.hpp"  // Counted, Task

namespace cart {

// CRTP base for a persistent loop-thread handle. Each derived type owns one
// concrete uv_*_t, exposes it via handle() (with its .data set to `this`), and
// is destroyed asynchronously: Close() begins uv_close, and once the handle is
// fully closed the object is deleted and its close task (if any) completed.
// Deriving through Counted<Derived> also gives each type a live-instance
// counter. All members are loop-thread only.
template <class Derived>
class LoopHandle : public Counted<Derived> {
 public:
  uv_loop_t* loop = nullptr;  // the runtime's loop, set at creation

  // Begin closing the handle. `close_task` may be null (a cleanup close, e.g.
  // after a failed connect); otherwise it is completed with 0 once this object
  // has been destroyed.
  void Close(Task* close_task) {
    close_task_ = close_task;
    uv_close(self()->handle(), &LoopHandle::OnClosed);
  }

 protected:
  LoopHandle() = default;
  ~LoopHandle() = default;

 private:
  Derived* self() { return static_cast<Derived*>(this); }

  static void OnClosed(uv_handle_t* h) {
    auto* self = static_cast<Derived*>(h->data);
    Task* close_task = self->close_task_;
    delete self;
    if (close_task) close_task->Complete(0);
  }

  Task* close_task_ = nullptr;
};

// A connected byte stream — a TCP socket, a pipe end (child-process stdio), or
// a TTY. The uv handle union is the first member so a uv_handle_t* from a close
// callback recovers a Stream*; generic read/write/close go through uv_stream_t,
// which every variant shares.
struct Stream : LoopHandle<Stream> {
  union Handle {
    uv_tcp_t tcp;
    uv_pipe_t pipe;
    uv_tty_t tty;
    Handle() {}  // initialized by uv_{tcp,pipe,tty}_init
  } h;
  uv_connect_t connect_req{};

  uv_stream_t* stream() { return reinterpret_cast<uv_stream_t*>(&h); }
  uv_handle_t* handle() { return reinterpret_cast<uv_handle_t*>(&h); }

  // Read-on-demand: a read is active on the socket only while read tasks are
  // queued here; the front task's buffer is the read destination. Concurrent
  // readers are served FIFO; draining the queue stops the read (backpressure);
  // EOF / errors fan out to every queued task.
  std::deque<Task*> read_queue;
  bool read_active = false;
};

// A listening TCP socket. Accepted-but-not-yet-consumed connections queue here
// until an accept task claims them.
struct Listener : LoopHandle<Listener> {
  uv_tcp_t tcp{};

  uv_handle_t* handle() { return reinterpret_cast<uv_handle_t*>(&tcp); }

  std::deque<Stream*> accepted;        // ready connections awaiting an accept task
  std::deque<Task*> pending_accepts;   // accept tasks awaiting a connection, FIFO
                                       // (several worker threads may wait at once)
};

// A spawned child process. The exit callback records the status; a wait task
// completes then, or immediately if the process has already exited.
struct Process : LoopHandle<Process> {
  uv_process_t proc{};

  uv_handle_t* handle() { return reinterpret_cast<uv_handle_t*>(&proc); }

  bool exited = false;
  std::int64_t exit_status = 0;
  int term_signal = 0;

  // Pipe ends when spawned with stdio capture (null when stdio inherited).
  // Owned like any Stream: closed by their own StreamClose tasks.
  Stream* stdin_s = nullptr;
  Stream* stdout_s = nullptr;
  Stream* stderr_s = nullptr;

  Task* wait_task = nullptr;  // completed when the process exits
};

// A filesystem watcher (uv_fs_event). Events arriving while no next-task is
// pending queue here (same shape as Listener's accepted backlog).
struct Watcher : LoopHandle<Watcher> {
  uv_fs_event_t ev{};

  uv_handle_t* handle() { return reinterpret_cast<uv_handle_t*>(&ev); }

  // (filename, uv events bitmask | negative errno) pairs awaiting a next-task.
  std::deque<std::pair<std::string, std::int64_t>> events;
  Task* pending_next = nullptr;  // a next-task waiting for an event
};

}  // namespace cart
