# 移植 skiff C++ 运行时 —— Task-based I/O substrate 设计

状态：**已定架构（移植 skiff 运行时），待原型闸门 + 实现**
日期：2026-07-22
决策：经用户确认，I/O substrate **移植 skiff 的 C++ task 运行时**（把
`skiff/src/runtime/` 的 Task/CompletionQueue + C++ loop 线程 adapt 进 chez-async，
CMake/C++23 + bake 构建为共享库，chez-async 的 I/O 经 FFI 重绑到其 C ABI）。
放弃先前的纯 FFI 方案。
关联：TASK.md S 组；`docs/runtime-thread-design.md`（方案 A runtime 线程，
其纯 Scheme 版将被本方案取代）；skiff `src/runtime/{task.hpp,runtime.hpp,
runtime.cpp,net.hpp,ffi.cpp,skiff_runtime.h}` + `skiff/task.ss`。

---

## 0. 为什么现在选 C++（先前论证的反转）

先前纯 FFI 设计的 §0 论证是：skiff 的「opaque-ptr / `Slock_object` 钉 buffer /
loop 线程不碰 Scheme 堆」三件套只为解决「loop 线程是 C++ std::thread」这个
**我们没有的**约束，所以不该照抄。

**该论证的前提是「loop 线程是 Chez fork-thread」。一旦允许 C++ 并让 loop 线程
变成 C++ std::thread（真·skiff），这个约束我们就有了，skiff 的解法正是正解。**
而且它一举消掉纯 FFI 版明确接受的三条差距：

| 纯 FFI 版的差距 | 移植 C++ 后 |
|---|---|
| GC stop-the-world 暂停完成分发 | **消除**：C++ loop 线程不碰 Scheme 堆、不参与 Chez GC rendezvous，I/O 完成分发与 GC 完全解耦 |
| 每次完成回调 activate + 进 Scheme 的开销 | **消除**：完成回调是纯 C++，只写 Task 结构 + settle |
| 无零拷贝 | **可得**：`Slock_object` pinned 路径（v2，见 §5） |

代价：chez-async 从「纯 Scheme、import 即用、零构建」变为「带 CMake/C++23 共享库
产物」。经用户确认接受此身份转变。

---

## 1. 关键事实：skiff 运行时对 Chez **几乎零耦合**，可干净抽成 .so

审读 skiff 源码确认的耦合边界：

- **`task.hpp` / `runtime.hpp` / `runtime.cpp` / `net.hpp`**：纯 C++ task 运行时，
  只依赖 `<uv.h>` + 标准库,**不 include `scheme.h`**。runtime.hpp 原话：
  *"The loop thread is never activated as a Chez thread and never touches the
  Scheme heap."* → **直接照编。**
- **`ffi.cpp`**（extern-"C" 边界）：仅两处用 Chez `scheme.h`：
  ① pinned 零拷贝（`Slock_object`/`Sbytevector_u8_ref`/`Sunlock_object`）；
  ② 非 pinned 的 buffer 拷贝（`Sbytevector_data(bv)`，一个**布局宏**，非运行时符号）。

**chez-async 的宿主是 stock `scheme`，加载独立 .so**（不像 skiff 内嵌 Chez +
`-rdynamic` + `dlopen(NULL)`）。因此：

- **v1 丢掉 pinned 路径**（`Slock_object` 是内核函数，stock `scheme` 未必导出给
  .so 解析；且 chez-async 现状本就用 foreign buffer 拷贝）。
- **v1 的 buffer ABI 收 foreign `void*`**（不是 scheme-object），Scheme 侧用现有
  bytevector↔foreign 拷贝（G1 的 8 字节分块）桥接。→ **runtime .so 100% 纯
  C++/libuv，零 Chez 头依赖、零版本耦合。** v2 再考虑 scheme-object 直传省一次拷贝。

---

## 2. 架构：Chez 宿主 + FFI 调 C++ 运行时 .so

```
┌─ chez-async（Chez 宿主，纯 Scheme 层）────────────────────────┐
│  high-level/{fs,net,timer,...}  ——重建在 io-task 之上          │
│  internal/io-runtime.ss  ——FFI 绑定层（对齐 skiff/task.ss）    │
│    (load-shared-object "libchez-async-rt.so")                  │
│    task-run / task-run-void / task-run-str（submit→await→free）│
│    await-hook / current-cq（协程调度器集成缝）                 │
│    %await / %cq-wait 声明 __collect_safe                       │
└───────────────────────────────────────────────────────────────┘
                    │  C ABI（uintptr_t 句柄 + foreign void*）
                    ▼
┌─ libchez-async-rt.so（移植自 skiff/src/runtime，纯 C++/libuv）─┐
│  rt_runtime_start/stop   ——spawn/join C++ loop 线程            │
│  rt_timer / rt_fs_* / rt_tcp_* / rt_stream_* / rt_dns_* / ...  │
│      任意线程 Submit(Task*)：锁队列 push + uv_async_send        │
│  loop 线程：OnAsync→Drain→Dispatch(switch op → uv_* 调用)      │
│  完成回调（loop 线程，纯 C++）：写 Task 结果 + Complete()      │
│      → cv notify（唤醒 rt_await）+ cq->Post（批量收割）        │
│  rt_await / rt_cq_wait（阻塞；Scheme 侧 __collect_safe）        │
│  rt_task_result / rt_read_into / rt_task_free / rt_err_*       │
└───────────────────────────────────────────────────────────────┘
                    │ 静态或动态链接
                    ▼   system libuv.so.1（/usr/include/uv.h）
```

命名：移植后 C ABI 前缀从 `skiff_` 改为 `rt_`（chez-async runtime），避免与真
skiff 符号冲突、也标明这是 vendored fork。

---

## 3. 移植范围（要什么、砍什么）

**移入 `native/runtime/`（vendored，注明来源 skiff commit）：**
- `task.hpp`（Task / CompletionQueue / Counted，原样）
- `runtime.hpp` / `runtime.cpp`（Runtime 单例 + loop 线程 + Submit/Drain/Dispatch
  + 完成回调）
- `net.hpp`（Stream / Listener 结构 + 停泊队列）
- `rt_ffi.cpp`（**裁剪自 ffi.cpp**）：只保留 task 运行时子集的 extern-"C" 壳。

**砍掉（skiff 的协议/扩展层，I/O substrate 不需要）：**
- `http.cpp` / `http2.cpp` / `ws.cpp` / `tls.cpp`（llhttp/nghttp2/wslay/OpenSSL）
  —— chez-async 若要 HTTP 另立项目，不进 I/O 底座。
- pinned `_pinned` 变体 + `new_pinned_task`（v2 再议，见 §5）。
- 内嵌 Chez 的 shell/main（chez-async 宿主是 stock scheme）。

**C ABI 子集（对齐 skiff_runtime.h，前缀改 rt_）：**
生命周期 `rt_runtime_start/stop/exit_on_signal`；提交 `rt_timer`、`rt_fs_*`、
`rt_tcp_connect/listen/accept`、`rt_stream_read/write/close`、`rt_listener_close`、
`rt_dns_resolve`、`rt_spawn/proc_*`、`rt_fs_watch*`、`rt_stdio_open`；
阻塞 `rt_await`、`rt_cq_wait`、`rt_cq_try_pop`、`rt_cq_create/free`；
结果 `rt_task_result`、`rt_read_into`（v1 收 foreign void*）、`rt_stat_*`、
`rt_scandir_*`、`rt_str_result`、`rt_task_free`；错误 `rt_err_name/str`；
调试 `rt_debug_live_*`。

---

## 4. Scheme 绑定层（对齐 skiff/task.ss）

`internal/io-runtime.ss`（或 `low-level/io-runtime.ss`）照搬 skiff/task.ss 的形状：

- `(load-shared-object "libchez-async-rt.so")` 后 `foreign-procedure` 绑定。
- `%await` / `%cq-wait` 声明 `__collect_safe`（阻塞时线程 deactivate，别的线程
  GC 不被卡——正是 R1 验证过的机制，只是阻塞点从 uv_run 移到 C++ cv）。
- `task-run` / `task-run-void` / `task-run-str`：submit→await→free→raise 的单一
  owner（skiff 的 define-osi 思路）。错误对 `&io-error`（负 errno + 符号名）。
- **`await-hook` / `current-cq` thread-parameter**（关键集成缝）：
  - 默认（普通线程 / 阻塞上下文）：`await-hook` = 直接 `%await`，`current-cq` = 0。
  - 协程上下文（async/await）：`(chez-async ...)` 的调度器把 `await-hook` 重绑为
    「suspend 当前协程 + 把 task 挂到调度器的 cq」，`current-cq` 重绑为调度器的
    cq。调度器一个线程 `%cq-wait` 收割完成的 task，resume 对应协程。
  - **这直接对齐 skiff async 的做法**：同一套 task API，阻塞线程与协程调度共用。

---

## 5. 硬骨头与分期

### 5.1 协程调度器如何观察 task 完成

两条路，对应 await-hook 的两种绑定：
- **阻塞线程**：`%await`（__collect_safe）阻塞在 task 的 C++ cv 上。等同 skiff
  blocking await。简单，thread-per-await。
- **协程（fiber）**：调度器一个专用线程 `%cq-wait` 阻塞在共享 cq 上；某 task
  完成 → C++ loop 线程 `cq->Post` → 调度器线程醒 → 查出对应协程 → 塞回 runnable。
  协程的 `await` = 提交 task 到 `current-cq` + suspend，让出给调度器。
  **这是 skiff cq-as-scheduler-substrate 的照搬。** 我们现有 `internal/scheduler`
  的 suspend/resume 机制改成 keyed-on-task-handle 即可。

### 5.2 连续读 / 持久句柄（streams / listeners）

skiff `net.hpp` 已实现（`pending_accepts` / 停泊 read task / 常开 `uv_read_start`
+ 背压）——**直接移植 net.hpp，不用重写**。与 chez-async F5 高层 stream 的思路
一致，F5 逻辑退化为薄封装。

### 5.3 零拷贝（v2）

v1 走 foreign buffer 拷贝（ABI 收 void*）。v2 若要 skiff 的 pinned 零拷贝，需
stock `scheme` 导出 `Slock_object`/`Sunlock_object` 给 .so 解析——需确认
`--enable-...` 或用 `Sforeign_symbol` 反向，属独立优化项。

---

## 6. 落地顺序

**S0 原型闸门（先做，最高风险）**：最小 CMake 编一个只含 `rt_runtime_start/stop`
+ `rt_timer` + `rt_await` + `rt_cq_*` 的 .so（可先手写一个 50 行的 mini 运行时或
裁剪 skiff 的 timer 路径）；chez-async FFI 绑定；验证 ①任意线程 rt_timer→rt_await
端到端 ②`__collect_safe` await 阻塞时别的线程能 GC ③cq 批量收割。
**跑通 = 整条工具链（CMake/C++23 build + Chez 加载 C++ .so + __collect_safe await）
成立,才继续移植全量。**

**S1 构建骨架**：CMake/C++23 工程（`native/`），vendor skiff 的
task.hpp/runtime.*/net.hpp + 裁剪的 rt_ffi.cpp，链 system libuv，产
`libchez-async-rt.so`。bake recipe（可选，与 CMake 并存或替代）。

**S2 绑定层**：`internal/io-runtime.ss` 全量 C ABI 绑定 + task-run helpers +
await-hook/current-cq 缝 + &io-error。

**S3 op 迁移**：timer→fs→dns→tcp→stream→process→watch，逐个把 high-level API
重建在 io-task 上；旧路径与新路径并存 + 增量测试，27 套件保持绿。

**S4 协程集成**：scheduler 的 await-hook/current-cq 绑定，async/await 走 cq。

**S5 收敛**：删除弃用的纯 Scheme low-level uv 绑定与 promise-per-op；高层全部
落到 io-task。此步才真正「放弃现在的设计」。

**S6 零拷贝 / bake / 文档 / 可移植性**。

风险控制：S3/S4 新旧并存增量迁移，任何一步不许把 27 套件弄红；S5 才删旧路径。

---

## 7. 与真 skiff 的关系

- 代码 vendored（fork）自 skiff `src/runtime`，符号前缀 `rt_`，注明来源 commit。
- 不含 skiff 的协议层（http/http2/ws/tls）与内嵌 Chez shell。
- chez-async 宿主是 stock scheme + 加载 .so；skiff 是 C++ 内嵌 Chez。两者运行时
  内核（Task/CompletionQueue/loop 线程/Dispatch）一致,宿主/嵌入模型不同。
- 未来若 skiff 的运行时内核演进，可择机 re-sync（记录来源 commit 便于 diff）。
