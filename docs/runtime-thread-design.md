# Runtime 线程与 Task 化设计（skiff 同构，纯 FFI）

状态：**已实现**（R1–R14，方案 A + B 全部落地；R8 断言机制具备但未全面插桩）
日期：2026-07-22
实现记录：27/27 全套件通过。R1 决定性验证 `__collect_safe`
（`tests/scratch/collect-safe-verify.ss`：反向对照证明去掉后 `(collect)` 直接
抛「cannot collect when multiple threads are active」）。核心模块
`high-level/runtime.ss` + `high-level/task.ss`，通用队列 `internal/thread-queue.ss`
（threadpool 一并复用）。测试 `tests/test-runtime.ss`（11）+ `tests/test-task.ss`（6）。
演示 `examples/runtime-demo.ss`。相对本草案的落地微调见 TASK.md R 组勾选说明。
关联：TASK.md R 组；参考 skiff `src/runtime/task.hpp`、`skiff_runtime.h`、
`~/workspace/skiff/chez-skiff-runtime-design.md`

## 0. 一句话

把事件循环从主线程搬到一个专属 **runtime 线程**（skiff 的
`skiff_runtime_start` 对应物），任意线程通过**提交队列 + uv_async 唤醒**投递工作
（`skiff_submit_task` 对应物），用 **mutex+condition 阻塞式 await** 取回结果
（`skiff_await` / `CompletionQueue` 对应物）——全程零 C 代码，依赖线程版 Chez 的
`__collect_safe` FFI 约定。

## 1. 目标与非目标

**目标**

- 主线程不再被 `uv-run` 占用：可以跑 REPL、计算、或另一套逻辑，I/O 在后台推进。
- Task 化的提交/等待/完成队列 API，与 skiff 的 C ABI 语义同构，未来若换成
  skiff 的 C++ runtime `.so`，高层代码可平移。
- 现有同线程用法**完全不受影响**：不调用 `runtime-start!` 时一切照旧。

**非目标**

- 不复刻 skiff「loop 线程永不碰 Scheme 堆」的性质。纯 FFI 下 loop 线程必须进
  Scheme 执行回调，GC stop-the-world 时完成分发会被暂停。这是「零 C 代码」的
  固有代价，本设计只把回调做薄来缓解，不试图消除。
- 不做 `uv_cancel` 真中止（沿用 F3 的 AbortController 式取消语义）。
- 不做多 runtime 多 loop 并存的完整支持（记录接口上预留，测试只覆盖单 runtime）。

## 2. 背景对照

### skiff 实际实现（非调研文档里的 quantum 步进）

- C++ 拥有独立 loop 线程；`Task` 结构承载参数与结果，loop 线程只读写 Task 字段，
  从不触碰 Scheme 堆。
- 提交：Scheme 线程（activated 状态）填参数、入队、`uv_async_send`。
- 等待：`skiff_await`/`skiff_cq_wait` 声明为 `__collect_safe`，Scheme 线程
  deactivate 后阻塞在 C 的 condvar 上，不阻碍其他线程 GC。
- `CompletionQueue`：多 task 汇入一个队列，单一等待者批量收割（调度器基座）。

### chez-async 现状

- `uv-run` 在调用方线程（通常主线程）驱动；所有 foreign-callable 回调在同线程
  重入 Scheme。协程 resume 严格在 Scheme 栈上（F1：`drive-loop` 包裹 `uv_run`，
  continuation 不跨 C 帧）。
- `low-level/threadpool.ss` 已经是半个本设计：线程安全 FIFO（mutex+cond 双列表）、
  `uv_async_t` 通知、结果在 loop 线程 dispatch——只是方向相反（CPU 任务发出去，
  而本设计要把 I/O 任务收进来）。
- 全库无 `__collect_safe` 用法。

## 3. 总体架构

分两层落地：

- **方案 A（runtime 线程）**：`fork-thread` 一个线程跑现有 `drive-loop`/`uv-run`，
  现有 FFI 绑定、handle 包装、promise/协程层一行不改——它们本来就只会在这个
  线程上执行。对外暴露线程安全的 `runtime-submit!` / `runtime-await`。
- **方案 B（Task 层）**：在 A 之上把提交/等待固化成 task 记录 + completion-queue
  记录，与 skiff 的 `Task`/`CompletionQueue` 字段级对应。B 是 A 的 API 皮，
  不引入新的并发机制。

```
主线程 / 任意线程                    runtime 线程（fork-thread）
─────────────────                   ──────────────────────────
task-submit! ──┐                    外层循环:
runtime-submit!├─→ [提交队列 FIFO]──→  1. drain 提交队列 → spawn 协程
               └─→ uv_async_send ──→  2. drive-loop（uv_run + 协程调度）
                                       3. 静止后 condvar 等待新提交
task-await ←── [task 记录 cond] ←──  完成回调填结果 + signal
cq-wait-one ←─ [completion queue] ←─ （或 Post 到 cq）
```

## 4. 关键机制

### 4.1 `__collect_safe`：为什么是必须项，以及顺带修掉一个潜伏问题

线程版 Chez 里，一个 **activated** 线程阻塞在普通 foreign call（如 `uv_run`
睡在 epoll）期间，其他线程发起的 GC 必须等它回到安全点。因此：

- runtime 线程的 `uv_run` 绑定必须声明 `__collect_safe`（进入时 deactivate、
  返回时 activate），否则主线程一分配触发 GC 就会挂到下一个 I/O 事件才醒。
- 相应地，`uv_run` 期间线程是 deactivated 状态，libuv 触发的每个
  foreign-callable 回调入口必须声明 `__collect_safe`（入口 activate、退出
  deactivate），否则回调在 deactivated 线程上进 Scheme 是未定义行为。

**顺带收益**：现架构下这其实已是潜伏问题——threadpool 工作线程会分配
（task-result、闭包），若它们触发 GC 而主线程正 activated 地睡在
`uv_run`/epoll 里，GC 要一直等到下一个事件唤醒主线程。把 `uv_run` 与全部回调
统一 `__collect_safe` 化后，同线程模式也受益。因此 R1/R2 **不区分模式，全局改**。

约定与版本：`__collect_safe` 需要 Chez ≥ 9.5.2 线程版。`runtime-start!` 入口
检查 `(threaded?)`，非线程版给出明确错误（同线程模式不受影响）。

实现落点：

- `internal/macros.ss` 的 `define-ffi` 加可选 `collect-safe` 标志
  （展开为 `(foreign-procedure __collect_safe name ...)`）；`ffi/core.ss`
  的 `%ffi-uv-run` 改用之。
- `internal/callback-registry.ss` 创建 foreign-callable 的位置统一加
  `__collect_safe`。Chez 的 activate 状态按嵌套计数维护，activated 线程进入
  `__collect_safe` callable 是安全的幂等包裹，同线程模式无需分叉两套回调。

### 4.2 提交通道与唤醒协议

**提交队列**：从 `threadpool.ss` 提炼通用线程安全 FIFO 到
`internal/thread-queue.ss`（双列表 + mutex + condition，push/pop-all/
blocking-pop 原语），threadpool 与 runtime 共用。

**唤醒双通道**（对应 runtime 外层循环的两种阻塞位置）：

1. runtime 线程阻塞在 `uv_run`（还有 ref'd 句柄）：`runtime-submit!` 入队后
   `uv_async_send` 一个**常驻、unref 的**提交 async 句柄，其回调 drain 队列。
2. runtime 线程静止（loop 无 ref'd 句柄、无 runnable 协程）：外层循环阻塞在
   提交队列的 condition 上，`queue-push!` 的 `condition-signal` 直接唤醒。

提交 async 句柄必须 `uv_unref`：否则它永久把 loop 顶成「有活跃句柄」，
`uv_run` 永不返回 0，**F2 的死锁检测（返回 0 ⇒ 无法推进）会全面失效**。
unref 后该句柄不计入活跃数，F2 语义原样保留。

**提交物执行位置（F1 硬约束）**：提交 async 回调运行在 `uv_run` 的 C 栈上，
提交的闭包若直接在此执行则不能 `await`（continuation 逃逸跨 C 帧 = UB）。
因此回调**只做 spawn**：把闭包包成协程压入调度器 runnable 队列；`uv_run 'once`
返回后由 `drive-loop` 在 Scheme 栈上执行。提交闭包因此天然可以 `await`。

### 4.3 跨线程等待与结果桥

`runtime-submit!` 返回一个**结果单元**（方案 B 里升格为 task 记录）：

```scheme
(define-record-type result-cell
  (fields (immutable mutex) (immutable cond)
          (mutable done?) (mutable success?) (mutable value)))
```

- 完成侧（runtime 线程，协程正常结束或抛异常）：填 `value`/`success?`、
  置 `done?`、`condition-signal`。
- 等待侧（任意线程）`runtime-await`：`with-mutex` + `condition-wait` 循环。
  Chez 原生 condition-wait 阻塞时线程处于可收集状态，不需要额外处理。
- 异常传播：`success? = #f` 时 `runtime-await` 在等待方线程 re-raise
  （包一层 `&runtime-task-error` 保留原 condition）。

**线程归属规则**：runtime 模式下，promise、handle、协程等一切 chez-async
对象只能在 runtime 线程上触碰；跨线程只允许 `runtime-submit!`、
`runtime-await`、task/cq API。提供 debug 断言（`runtime-owned?` 检查
当前线程），默认关闭，`debug-enabled?` 开启时在高层 API 入口生效。

### 4.4 生命周期

- `runtime-start!`：创建 loop（或收编 `uv-default-loop`？——**决定：新建专属
  loop**，不与主线程既有 loop 混用，避免所有权二义）→ 建提交队列与 unref'd
  async 句柄 → `fork-thread` 外层循环。
- `runtime-stop!`：置 stop 标志 + 唤醒（async send + condition signal）→
  runtime 线程退出外层循环后：close 提交 async 句柄 → `uv_run` 一轮处理
  close 回调 → `uv-loop-close`（沿用 A6 的清理次序）→ signal 已退出 cond。
  `runtime-stop!` 阻塞等待该 cond（join 语义）。
- 停机时在途 task：置为 failed（`&runtime-stopped`），await 侧收到异常。
  是否等待在途 task 排干由 `#:drain?` 参数控制（默认 #t：先排干再退）。
- 与 threadpool 的关系：threadpool 的 async 句柄挂在 runtime 的 loop 上时，
  `threadpool-shutdown!` 必须先于 `runtime-stop!`；threadpool-submit! 的
  「只能主线程调用」约束（H6）在 runtime 模式下改述为「只能 runtime 线程调用」。

### 4.5 方案 B：Task / CompletionQueue 层

与 skiff 字段级对应（`task.hpp`）：

| skiff | chez-async |
|---|---|
| `Task{op, params..., result, done_, m_, cv_}` | `task` 记录：id、描述用 op 符号、result-cell 内嵌、所属 runtime、可选 cq |
| `Task::Complete` → 填结果、signal、`cq->Post` | 协程结束钩子：settle cell + signal + `cq-post!` |
| `Task::Wait`（`__collect_safe` 阻塞） | `task-await`（condition-wait） |
| `CompletionQueue::Post/WaitOne/TryPop` | `completion-queue` 记录（thread-queue 复用）：`cq-post!`/`cq-wait-one`/`cq-try-pop` |
| cq 引用计数保生命周期 | 不需要——GC 管生命周期，task 持有 cq 引用即可 |
| `skiff_task_free` / pinned buffer | 不需要——bytevector 结果在 Scheme 堆上，无手工释放 |

API 草案：

```scheme
(task-submit! runtime thunk)            ; → task（thunk 在 runtime 线程协程中执行，可 await）
(task-submit! runtime thunk #:cq cq)    ; 完成后额外 post 到 cq
(task-await task)                       ; 阻塞至完成，返回值或 re-raise
(task-poll task)                        ; 非阻塞：pending / (done . value) / (failed . e)
(task-op task) (task-id task)
(make-completion-queue)
(cq-wait-one cq)                        ; 阻塞取一个完成 task
(cq-try-pop cq)                         ; 非阻塞，无则 #f
```

promise 桥接：runtime 线程内部照常用 promise/async-await；task 只是**跨线程
边界**的表示。`task-submit!` 的 thunk 里 `(await (fs-read ...))` 即已打通。
不提供「主线程拿 promise」——promise 不跨线程。

取消：`(task-cancel! task)` 挂 F3 的 cancel-token 到 thunk 的执行上下文
（`task-submit!` 内部为每个 task 配一个 token，thunk 通过参数拿到）；
语义与 F3 一致（reject 包装、不中止底层 libuv 操作）。

## 5. 与 skiff 的剩余差距（明确接受）

1. **GC 耦合**：runtime 线程每个完成回调都要 activate + 进 Scheme，
   stop-the-world 期间 I/O 完成分发暂停。skiff 的 C++ loop 线程无此耦合。
2. **回调进出开销**：每次回调 activate/deactivate 一对状态切换。libuv 场景
   回调频率 = I/O 事件频率，可接受；若实测成为热点，出路才是 C shim。
3. **无 pinned 零拷贝路径**：读写仍经 foreign 内存 + 8 字节分块拷贝（G1）。

## 6. 落地顺序

1. R1/R2（`__collect_safe` 化）——独立收益，先行合入并全量回归。
2. R3（thread-queue 提炼）+ R4（runtime 核心）+ R5（await 桥）。
3. R6（生命周期/停机）+ R7（线程归属断言）。
4. R8（测试）+ R9（demo）→ 方案 A 完成。
5. R10–R12（Task/cq 层）→ R13（取消）→ R14（文档）。

## 7. 测试计划（对应 R8/R12）

- 主线程自由：runtime 跑 100ms timer 期间主线程完成一段计算并先行返回。
- 提交并发：4 个 fork-thread 各 submit 200 个 task，结果计数与值全对。
- await 语义：值返回、异常 re-raise、`task-poll` 三态。
- cq 批量：N 个 task 汇入一个 cq，`cq-wait-one` 收割 N 次不重不漏。
- 停机：drain 模式在途 task 全完成；非 drain 模式在途 task 收到
  `&runtime-stopped`；停机后 handle 零泄漏（loop close 成功）。
- F2 保持：runtime 模式下 promise-wait 死锁检测仍然有效（提交 async
  已 unref，验证 uv_run 返回 0 路径可达）。
- 回归：全部现有套件在「不启用 runtime」下 100% 通过（同线程模式零影响）。

## 8. 风险与对策

| 风险 | 对策 |
|---|---|
| F1 记录过的 import-graph fork-thread 死锁（coroutine 顶层 init 与 fork-thread 的初始化顺序）| `runtime.ss` 的导入布局照抄 F1 的注入模式；合入前用 test-async.ss 的死锁复现方法验证 |
| `__collect_safe` callable 在 activated 线程上的嵌套语义与预期不符 | R2 先写一个最小验证程序（主线程 activated 进回调、runtime 线程 deactivated 进回调各跑 GC 压力）再全量铺开 |
| 提交 async unref 后、loop 静止窗口丢唤醒 | 双通道设计（4.2）：condvar 是兜底通道，push 总是 signal；外层循环 re-check 队列后才 wait |
| 停机竞态（stop 与 submit 并发） | stop 标志与提交队列同一 mutex 保护；stop 后 submit 抛 `&runtime-stopped` |
