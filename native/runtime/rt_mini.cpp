// rt_mini.cpp — S0 原型闸门用的最小 task 运行时。
//
// 忠实模仿 skiff src/runtime/{task.hpp,runtime.cpp} 的 timer 路径,只为证明整条
// 工具链:CMake/C++23 编成 .so → Chez 经 FFI 加载 → __collect_safe 的 rt_await
// 端到端 → 阻塞 await 期间别的线程能 GC → CompletionQueue 批量收割。
//
// 纯 C++/libuv,不含任何 Chez 头(scheme.h)——对齐设计文档 §1「runtime 内核对
// Chez 零耦合」。S1 起用真正 vendor 的 skiff runtime 取代本文件。
//
// C ABI 前缀 rt_(chez-async runtime),避免与真 skiff 符号冲突。

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <mutex>
#include <thread>
#include <vector>

#include <uv.h>

namespace {

enum class Op : std::uint32_t { Timer };

struct Task;

// 批量完成汇聚:多 task 路由到一个队列,单一等待者收割(调度器 substrate)。
// 引用计数:创建者持 1,每个提交的 task 持 1(提交时取、完成 post 后放)。
class CompletionQueue {
 public:
  void Retain() { refs_.fetch_add(1, std::memory_order_relaxed); }
  void Release() {
    if (refs_.fetch_sub(1, std::memory_order_acq_rel) == 1) delete this;
  }
  void Post(Task* t) {
    {
      std::lock_guard<std::mutex> lk(m_);
      q_.push_back(t);
    }
    cv_.notify_one();
  }
  Task* WaitOne() {
    std::unique_lock<std::mutex> lk(m_);
    cv_.wait(lk, [this] { return !q_.empty(); });
    Task* t = q_.front();
    q_.pop_front();
    return t;
  }
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
  std::atomic<long> refs_{1};
};

struct Task {
  explicit Task(Op o) : op(o) {}
  const Op op;
  std::uint64_t timeout_ms = 0;   // Timer
  std::int64_t result = 0;
  uv_timer_t timer{};             // loop 线程用的 libuv 请求存储(内嵌在 Task)
  CompletionQueue* cq = nullptr;

  // 记录结果并通知完成。loop 线程调用一次。
  void Complete(std::int64_t r) {
    CompletionQueue* q = cq;   // done_ 可见后 awaiter 可能立即 free 本 task
    {
      std::lock_guard<std::mutex> lk(m_);
      result = r;
      done_ = true;
    }
    cv_.notify_one();
    if (q) {
      q->Post(this);
      q->Release();
    }
  }

  // 阻塞至 Complete。awaiting 的 Scheme 线程 deactivated 状态下调用
  // (rt_await 在 Scheme 侧声明 __collect_safe)。
  void Wait() {
    std::unique_lock<std::mutex> lk(m_);
    cv_.wait(lk, [this] { return done_; });
  }

 private:
  std::mutex m_;
  std::condition_variable cv_;
  bool done_ = false;
};

// 拥有单一 libuv loop 及其专属 OS 线程。loop 线程从不作为 Chez 线程 activate、
// 从不碰 Scheme 堆,因此阻塞的 uv_run 不会卡住 Chez GC rendezvous。
class Runtime {
 public:
  static Runtime& Instance() {
    static Runtime rt;
    return rt;
  }

  void Start() {
    if (running_.exchange(true)) return;
    uv_loop_init(&loop_);
    uv_async_init(&loop_, &async_, &Runtime::OnAsyncThunk);
    async_.data = this;
    stopping_.store(false);
    thread_ = std::thread([this] { uv_run(&loop_, UV_RUN_DEFAULT); });
  }

  void Stop() {
    if (!running_.load()) return;
    stopping_.store(true, std::memory_order_release);
    uv_async_send(&async_);   // 唤醒 loop,让它 drain + close async 后退出
    if (thread_.joinable()) thread_.join();
    uv_loop_close(&loop_);
    running_.store(false);
  }

  void Submit(Task* t) {
    {
      std::lock_guard<std::mutex> lk(qmutex_);
      queue_.push_back(t);
    }
    uv_async_send(&async_);
  }

 private:
  static void OnAsyncThunk(uv_async_t* h) {
    static_cast<Runtime*>(h->data)->Drain();
  }

  void Drain() {
    std::vector<Task*> local;
    {
      std::lock_guard<std::mutex> lk(qmutex_);
      local.swap(queue_);
    }
    for (Task* t : local) Dispatch(t);
    if (stopping_.load(std::memory_order_acquire)) {
      uv_close(reinterpret_cast<uv_handle_t*>(&async_), nullptr);
    }
  }

  void Dispatch(Task* t) {
    switch (t->op) {
      case Op::Timer:
        t->timer.data = t;
        uv_timer_init(&loop_, &t->timer);
        uv_timer_start(&t->timer, &Runtime::OnTimer, t->timeout_ms, 0);
        break;
    }
  }

  static void OnTimer(uv_timer_t* h) {
    // 定时器触发:关闭句柄,close 回调里再 Complete(句柄内存在 Task 内,close
    // 完成后 Scheme 才可能 free,避免 UAF)。
    uv_close(reinterpret_cast<uv_handle_t*>(h), &Runtime::OnTimerClosed);
  }
  static void OnTimerClosed(uv_handle_t* h) {
    static_cast<Task*>(h->data)->Complete(0);
  }

  uv_loop_t loop_{};
  uv_async_t async_{};
  std::thread thread_;
  std::mutex qmutex_;
  std::vector<Task*> queue_;
  std::atomic<bool> running_{false};
  std::atomic<bool> stopping_{false};
};

inline Task* as_task(std::uintptr_t h) { return reinterpret_cast<Task*>(h); }
inline CompletionQueue* as_cq(std::uintptr_t h) {
  return reinterpret_cast<CompletionQueue*>(h);
}

}  // namespace

extern "C" {

void rt_runtime_start(void) { Runtime::Instance().Start(); }
void rt_runtime_stop(void) { Runtime::Instance().Stop(); }

std::uintptr_t rt_timer(std::uint64_t ms, std::uintptr_t cq) {
  Task* t = new Task(Op::Timer);
  t->timeout_ms = ms;
  t->cq = as_cq(cq);
  if (t->cq) t->cq->Retain();
  Runtime::Instance().Submit(t);
  return reinterpret_cast<std::uintptr_t>(t);
}

// 阻塞至 task 完成,返回结果。Scheme 侧声明 __collect_safe。
std::int64_t rt_await(std::uintptr_t task) {
  Task* t = as_task(task);
  t->Wait();
  return t->result;
}

std::int64_t rt_task_result(std::uintptr_t task) {
  return as_task(task)->result;
}
void rt_task_free(std::uintptr_t task) { delete as_task(task); }

std::uintptr_t rt_cq_create(void) {
  return reinterpret_cast<std::uintptr_t>(new CompletionQueue());
}
void rt_cq_free(std::uintptr_t cq) { as_cq(cq)->Release(); }
std::uintptr_t rt_cq_wait(std::uintptr_t cq) {   // __collect_safe on Scheme side
  return reinterpret_cast<std::uintptr_t>(as_cq(cq)->WaitOne());
}
std::uintptr_t rt_cq_try_pop(std::uintptr_t cq) {
  return reinterpret_cast<std::uintptr_t>(as_cq(cq)->TryPop());
}

}  // extern "C"
