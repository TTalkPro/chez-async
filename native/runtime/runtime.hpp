// Vendored from skiff src/runtime @ 93e0fd6 (2026-07-22).
// namespace skiff -> cart; C ABI skiff_* -> rt_*. See docs/skiff-aligned-io-design.md.
// Runtime: owns the single libuv loop and its dedicated OS thread.
//
// The loop thread is never activated as a Chez thread and never touches the
// Scheme heap, so a blocked uv_run() cannot stall Chez's GC rendezvous.
// Scheme threads submit Tasks from any thread; the loop thread is woken by a
// uv_async handle, drains the MPSC queue, and starts the uv operations.
#pragma once

#include <atomic>
#include <cstdint>
#include <mutex>
#include <thread>
#include <unordered_set>
#include <vector>

#include <uv.h>

#include "task.hpp"

namespace cart {

struct Listener;

class Runtime {
 public:
  // The process-wide singleton.
  static Runtime& Instance();

  // Idempotent. Start() spawns the loop thread; Stop() drains and joins it.
  void Start();
  void Stop();

  // Request that the loop thread catch SIGINT/SIGTERM and exit the process
  // cleanly (exit code 128+signum). Must be called before Start(). Off by
  // default so an interactive REPL keeps Chez's own ^C (interrupt-to-prompt).
  // Non-REPL modes (--script/--program/--app) turn it on: the main Scheme
  // thread is usually parked in a blocking task (e.g. tcp-accept) where Chez's
  // interrupt can't fire, so without this ^C is ignored until the kernel aborts.
  void ExitOnSignal(bool on) {
    exit_on_signal_.store(on, std::memory_order_relaxed);
  }

  // Enqueue a task from any Scheme thread and wake the loop. Ownership of the
  // task passes to the runtime until it completes; the Scheme side frees it
  // after await.
  void Submit(Task* t);

  // Graceful-shutdown knobs (any thread). The timeout is the hard deadline
  // after the first SIGINT/SIGTERM: if the process hasn't exited by itself by
  // then (workers drained, script returned), the loop thread _Exits with the
  // conventional 128+signum. Default 30s, aligned with K8s
  // terminationGracePeriodSeconds.
  void SetShutdownTimeout(std::uint32_t ms) {
    shutdown_timeout_ms_.store(ms, std::memory_order_relaxed);
  }
  bool ShutdownRequested() const {
    return shutdown_signaled_.load(std::memory_order_acquire);
  }

 private:
  Runtime() = default;
  // A live loop thread at process teardown (e.g. an abnormal Scheme-kernel
  // exit that calls std::exit while a server is still running) would make the
  // std::thread destructor call std::terminate. Detach instead: the OS reaps
  // the thread as the process dies. Never terminate on the way out.
  ~Runtime() {
    if (thread_.joinable()) thread_.detach();
  }
  Runtime(const Runtime&) = delete;
  Runtime& operator=(const Runtime&) = delete;

  void LoopMain();           // the loop thread's body: uv_run
  void Drain();              // loop thread: pull queued tasks and dispatch
  void Dispatch(Task* t);    // loop thread: translate one task to uv calls

  static void OnAsync(uv_async_t* h);
  static void OnSignal(uv_signal_t* h, int signum);  // loop thread: SIGINT/TERM
  static void OnShutdownTimer(uv_timer_t* h);        // loop thread: deadline

  uv_loop_t loop_{};
  uv_async_t async_{};
  uv_signal_t sig_int_{};
  uv_signal_t sig_term_{};
  std::thread thread_;

  std::mutex qmutex_;
  std::vector<Task*> queue_;  // MPSC: many Scheme producers, one loop consumer

  std::atomic<bool> running_{false};
  std::atomic<bool> stopping_{false};
  std::atomic<bool> exit_on_signal_{false};

  // Graceful shutdown (see designs/graceful-shutdown.md, Phase 1). The signal
  // handler runs as a normal libuv callback on the loop thread — the same
  // thread that creates and closes Listeners in Dispatch() — so the registry
  // needs no lock. It holds every open, not-yet-closing listener; the first
  // signal closes them all, which cancels parked accepts (ECANCELED) and lets
  // the Scheme workers drain and exit on their own.
  std::unordered_set<Listener*> listeners_;    // loop thread only
  uv_timer_t shutdown_timer_{};                // loop thread only
  bool shutdown_timer_started_ = false;        // loop thread only
  int shutdown_signum_ = 0;                    // loop thread only
  std::atomic<bool> shutdown_signaled_{false};
  std::atomic<std::uint32_t> shutdown_timeout_ms_{30000};
};

}  // namespace cart
