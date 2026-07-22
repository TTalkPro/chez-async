// Vendored from skiff src/runtime @ 93e0fd6 (2026-07-22).
// namespace skiff -> cart; C ABI skiff_* -> rt_*. See docs/skiff-aligned-io-design.md.
// Task and CompletionQueue: the units of work the runtime moves between Scheme
// threads (producers) and the single libuv loop thread (consumer).
//
// Threading contract: everything here is plain C++ synchronization. The loop
// thread only ever touches Task fields (params, buffer, result) — never the
// Scheme heap. Scheme threads fill params / read results while *activated*
// (a normal foreign call cannot be interrupted by GC), and block in await
// while *deactivated* (the await FFI is declared __collect_safe).
#pragma once

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <mutex>
#include <string>
#include <vector>

#include <uv.h>

namespace cart {

// CRTP mixin giving each derived type its own lock-free live-instance counter,
// bumped on construction and destruction. The Scheme test layer reads these
// (via rt_debug_live_*) as leak assertions — cheaper and quieter than
// ASan/valgrind, which flag Chez's own managed heap. Derive as
// `struct Foo : Counted<Foo>` and query with `Foo::live()`.
template <class Derived>
class Counted {
 public:
  static long live() { return counter().load(std::memory_order_relaxed); }

 protected:
  Counted() { counter().fetch_add(1, std::memory_order_relaxed); }
  ~Counted() { counter().fetch_sub(1, std::memory_order_relaxed); }
  Counted(const Counted&) = delete;
  Counted& operator=(const Counted&) = delete;

 private:
  static std::atomic<long>& counter() {
    static std::atomic<long> c{0};
    return c;
  }
};

enum class Op : std::uint32_t {
  Timer,
  FsOpen,
  FsRead,
  FsWrite,
  FsClose,
  FsStat,
  FsMkdir,
  FsRmdir,
  FsUnlink,
  FsRename,
  FsRealpath,
  FsScandir,
  TcpConnect,
  TcpListen,
  TcpAccept,
  StreamRead,
  StreamWrite,
  StreamClose,
  ListenerClose,
  DnsResolve,
  ProcSpawn,
  ProcWait,
  ProcKill,
  ProcClose,
  FsWatchOpen,
  FsWatchNext,
  FsWatchClose,
  StdioOpen,
};

struct Task;
struct Stream;
struct Listener;
struct Process;
struct Watcher;

// Batch-reaping completion sink: many tasks routed to one queue, drained by
// one waiter (the async scheduler's substrate).
//
// Lifetime: reference-counted. The creator holds one reference (dropped by
// rt_cq_free -> release()); every submitted task referencing the queue
// holds one (taken at submit, dropped after its completion posts). This keeps
// the queue alive until the last in-flight task has posted, even if the
// Scheme side frees it first (e.g. run-async exiting with a fire-and-forget
// task still pending) — posting to a destroyed queue would wedge the loop
// thread on a dead mutex.
class CompletionQueue : public Counted<CompletionQueue> {
 public:
  CompletionQueue() = default;

  // Reference counting. The creator holds one ref; the reader-facing handle
  // drops it via Release(). Callers must pair Retain()/Release().
  void Retain() { refs_.fetch_add(1, std::memory_order_relaxed); }
  void Release() {
    if (refs_.fetch_sub(1, std::memory_order_acq_rel) == 1) delete this;
  }

  // Enqueue a completed task and wake one waiter. Loop thread.
  void Post(Task* t) {
    {
      std::lock_guard<std::mutex> lk(m_);
      q_.push_back(t);
    }
    cv_.notify_one();
  }

  // Block until at least one task has completed, then pop and return it.
  Task* WaitOne() {
    std::unique_lock<std::mutex> lk(m_);
    cv_.wait(lk, [this] { return !q_.empty(); });
    Task* t = q_.front();
    q_.pop_front();
    return t;
  }

  // Non-blocking drain companion to WaitOne; nullptr when empty.
  Task* TryPop() {
    std::lock_guard<std::mutex> lk(m_);
    if (q_.empty()) return nullptr;
    Task* t = q_.front();
    q_.pop_front();
    return t;
  }

 private:
  std::mutex m_;
  std::condition_variable cv_;
  std::deque<Task*> q_;
  std::atomic<long> refs_{1};  // creator's reference
};

struct Task : Counted<Task> {
  explicit Task(Op op) : op(op) {}

  const Op op;

  // --- Operation parameters (filled by the submitting Scheme thread) ---
  std::uint64_t timeout_ms = 0;   // Timer
  int fd = -1;                    // FsRead/FsWrite/FsClose
  std::int64_t offset = -1;       // FsRead/FsWrite (-1 = current position)
  std::uint32_t nbytes = 0;       // Fs/Stream read size or write length
  std::string path;               // FsOpen/FsStat path, or Tcp host (IP string)
  int flags = 0;                  // FsOpen
  int mode = 0;                   // FsOpen
  int port = 0;                   // TcpConnect/TcpListen
  int backlog = 0;                // TcpListen
  int signum = 0;                 // ProcKill
  int family = 0;                 // DnsResolve hint: 0 = any, 4, or 6
  int argc = 0;                   // ProcSpawn (count of NUL-packed args in buffer)
  int envc = -1;                  // ProcSpawn (-1 = inherit parent environment)
  int stdio_mode = 0;             // ProcSpawn (0 = inherit fds, 1 = capture pipes)
  std::vector<std::uint8_t> buffer;  // C++-owned: read dest / write src / packed argv

  // Pinned zero-copy path: when set, I/O goes directly to ext_data, which
  // points into a Scheme bytevector held immobile by Slock_object. pinned_obj
  // keeps the locked object (a Chez ptr) so rt_task_free — which runs on
  // an activated Scheme thread — can Sunlock_object it. The loop thread only
  // ever touches ext_data bytes, never the object.
  void* pinned_obj = nullptr;
  std::uint8_t* ext_data = nullptr;
  std::vector<std::uint8_t> env_buf; // ProcSpawn: NUL-packed environment (K=V)
  std::string new_path;           // FsRename target
  std::string service;            // DnsResolve service/port string
  std::string cwd;                // ProcSpawn working directory ("" = inherit)

  // Net / process / watch targets (persistent loop-thread handles, not owned
  // here).
  Stream* stream = nullptr;       // StreamRead/StreamWrite/StreamClose/TcpConnect
  Listener* listener = nullptr;   // TcpAccept/ListenerClose
  Process* process = nullptr;     // ProcWait/ProcKill/ProcClose
  Watcher* watcher = nullptr;     // FsWatchNext/FsWatchClose

  // --- Result (written by the loop thread before signalling) ---
  // bytes >= 0, fd (open), 0 (close/stat/eof), a handle (connect/listen/accept/
  // spawn), an entry count (scandir), an exit code (wait), or negative errno.
  std::int64_t result = 0;
  uv_stat_t statbuf{};            // FsStat
  std::string str_out;            // FsRealpath / DnsResolve result
  std::vector<std::string> names; // FsScandir entry names

  // --- libuv request storage (used on the loop thread) ---
  uv_fs_t fs_req{};
  uv_timer_t timer{};
  uv_write_t write_req{};         // StreamWrite
  uv_getaddrinfo_t addr_req{};    // DnsResolve

  // Optional batch-completion sink; per-task cv is always available too.
  CompletionQueue* cq = nullptr;

  // Record the result and signal completion. Loop thread, called once.
  void Complete(std::int64_t r) {
    // Cache the queue pointer first: the instant done_ is visible, a blocking
    // awaiter may wake and free this Task, so no member may be read afterward.
    CompletionQueue* q = cq;
    {
      std::lock_guard<std::mutex> lk(m_);
      result = r;
      done_ = true;
    }
    cv_.notify_one();
    if (q) {
      q->Post(this);
      q->Release();  // drop the reference taken at submit
    }
  }

  // Block until Complete() runs. Called by the awaiting Scheme thread while
  // deactivated (the await FFI is declared __collect_safe).
  void Wait() {
    std::unique_lock<std::mutex> lk(m_);
    cv_.wait(lk, [this] { return done_; });
  }

 private:
  std::mutex m_;
  std::condition_variable cv_;
  bool done_ = false;
};

}  // namespace cart
