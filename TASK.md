# 缺陷修复任务清单

基线：HEAD 9ca907d，19/19 测试通过。审计日期 2026-07-20。
约定：**修复过程不自动 git 提交**，全部改动留在工作区由人工审查。

## A. Critical — 内存安全

- [x] A1. `low-level/stream.ss` read 回调 use-after-free：先 `foreign-free alloc-ptr` 再从
      `buf->base`（同一块内存）拷贝。改为先拷贝后释放。
- [x] A2. `low-level/udp.ss` recv 回调同样的先 free 后拷贝。改为先拷贝后释放。
- [x] A3. `low-level/udp.ss` `uv-udp-send!` 失败路径双重释放：错误分支 free 后 raise，
      又被外层 guard 再 free 一遍。重构错误处理避免重复清理。
- [x] A4. `low-level/tcp.ss` `uv-tcp-connect` 失败路径 sockaddr 双重释放（同上模式，
      参照同文件 bind 的正确写法）。
- [x] A5. `internal/callback-registry.ss` foreign-callable 实例创建后 `lock-object`，
      防止移动式 GC 搬移代码对象导致 C 侧函数指针悬空。
- [x] A6. `high-level/event-loop.ss` `uv-loop-close` 清理条件写反：成功路径泄漏 loop 结构体，
      失败路径 free 仍在使用的内存。改为成功时清理、失败时保留；`unregister-loop!` 移到
      close 成功之后。移除对整数地址的无效 `unlock-object`。
- [x] A7. `internal/foreign.ss` `with-c-string`/`with-uv-buf` 的 `dynamic-wind` 改为 `guard`
      （与同文件 `with-temp-buffer` 策略一致），消除协程挂起时提前释放 + 恢复后二次释放。

## B. High — 功能缺陷 / 泄漏

- [x] B1. `low-level/process.ss` `uv_process_options_t` 字段偏移错误（stdio_count 应为 44、
      stdio 48、uid 56、gid 60）；SETUID/SETGID 降权失效的安全问题。同步修正
      `ffi/process.ss` 中 96 字节的过量分配（实际 64）。
- [x] B2. `low-level/threadpool.ss` 任务完成路径不 `unlock-object`（submit 时锁了 task/
      callback/error-handler 三个对象），每个完成任务永久泄漏。完成时解锁。
- [x] B3. 请求类回调"先调用户回调、后清理"导致用户异常跳过清理。将清理动作移到用户回调
      之前（或对用户回调单独 guard）：
      - `low-level/stream.ss` write/shutdown 回调
      - `low-level/tcp.ss` connect 回调、`low-level/pipe.ss` connect 回调
      - `low-level/udp.ss` send 回调
      - `low-level/dns.ss` getaddrinfo（含 `uv_freeaddrinfo`）/getnameinfo 回调
      - `low-level/fs.ss` fs 回调（`uv_fs_req_cleanup`）
      - `low-level/process.ss` exit 回调（`uv-handle-close!`）
- [x] B4. `internal/promise-core.ss` then 回调 LIFO 逆序执行：settle 时 reverse 回调列表。
- [x] B5. `high-level/async-combinators.ss` `async-timeout`：操作先完成时取消超时 timer，
      避免 loop 被空 timer 拖住整个超时时长。
- [x] B6. `internal/macros.ss` `with-uv-request` body 抛异常时泄漏 req + wrapper
      （3 个 locked 对象）：加 guard 走 cleanup-fn。
- [x] B7. `low-level/udp.ss` `uv-udp-recv-start!` 重复调用不解锁旧 handle-data
      （参照 stream.ss `uv-read-start!` 的写法）。

## C. Medium — 正确性 / 边界

- [x] C1. c-string 解码统一为 UTF-8 并统一 NULL 处理（当前逐字节 Latin-1，中文路径乱码；
      `ffi/callbacks.ss` 版无 NULL 检查）：`internal/foreign.ss`、`ffi/fs.ss`、
      `ffi/callbacks.ss` `get-string-from-ptr`、`low-level/fs-event.ss`、`low-level/fs-poll.ss`、
      `low-level/process.ss`（重复定义处）。
- [x] C2. `ffi/callbacks.ss` alloc 回调失败路径显式置 `base=NULL/len=0`，避免 libuv
      读到未初始化的 uv_buf_t。
- [x] C3. `internal/foreign.ss` `make-uv-buf` 空数据时 `(foreign-alloc 0)` 报错；处理 0 长度。
- [x] C4. `ffi/fs.ss` `uv-stat-size` 128 → 160（与自身偏移表一致）。
- [x] C5. `chez-async.ss` 导出缺口：`&uv-error` 家族（`uv-error?`/`uv-error-code`/
      `uv-error-name` 等）、cancellation 模块整体转发、`timeout-error-timeout-ms`
      （先补进 async-combinators.ss 自己的 export 表）。

## D. 工程卫生

- [x] D1. 修复坏示例：`examples/timer-demo.ss`（unbound `handle-type`）、
      `examples/callcc-poc.ss`（括号不配）、`examples/callcc-simple.ss`（重复定义）。
- [x] D2. `examples/dns-cache-proxy.ss` 监听端口 53 与文件头文档 15353 矛盾，改回 15353。
- [x] D3. 消除 `tests/test-framework.ss` 双名文件。实际情况：`framework.ss` 原是指向
      `test-framework.ss` 的符号链接；现已把真实内容放入 `framework.ss` 并删除
      `test-framework.ss`，只保留与库名 `(chez-async tests framework)` 匹配的文件。

## 验证

- [x] 每组修复后运行 `./run-tests.sh`，保持 19/19 通过。
- [x] 修复完成后对示例做编译冒烟（`scheme --libdirs .:.. --program`）。

---

# 剩余问题清单（2026-07-20 修复轮之后）

以下是本轮**未修复**的问题全集，按优先级排序。E 组是本轮修复的直接后续
（低成本、应尽快做）；F 组是设计级缺陷（动手前需要先定方案）；G/H 为低优先级。

## E. 后续补强 — 回归测试与提交（建议下一轮优先做）

- [ ] E1. **为本轮修复补回归测试**。19/19 通过只说明没改坏现有行为；本轮修的 UAF、
      双重释放、GC 锁定只在错误路径 / GC 压力 / 堆碎片化下触发，现有测试覆盖不到。
      最有价值的用例：
      - UDP send 到不可达地址 / EBADF（走同步失败清理路径，验证无 double-free）
      - TCP connect 同步失败路径（EINVAL / EADDRNOTAVAIL）
      - 用户回调抛异常后：请求资源已清理、process 句柄已关闭、loop 可正常退出
      - `async-timeout`：操作先完成时 loop 立即退出（不等 timeout-ms）
      - then 回调按注册顺序（FIFO）触发
      - 中文路径/文件名经 fs / fs-event 往返不乱码
      → 已完成：新增 `tests/test-regression.ss`（6 个用例，全部覆盖上述场景），
        已登记进 run-tests.sh。
- [x] E2. internal/ 全部 8 个模块无直接单元测试。已给 `internal/foreign.ss` 补
      `tests/test-internal-foreign.ss`（12 个用例：UTF-8 往返、NULL 处理、空数据、
      buf 读写、allocate-zeroed 清零、拷贝辅助），已登记进 run-tests.sh。
      其余 internal 模块仍无直接测试（后续可补）。
- [ ] E3. 审查 `git diff` 后分组提交本轮改动（当前未提交）。

## F. 设计级缺陷（动手前需先定方案，按影响排序）

- [ ] F1. **协程只在 `run-scheduler` 内运行**（`internal/scheduler.ss`）。
      runnable 队列没有挂到任何 uv handle：普通 `uv-run` 驱动下 `(async ...)` 永不执行；
      `run-scheduler` 退出后才 settle 的 promise 会 resume 协程入队但无人消费，
      协程连同 continuation 悬挂泄漏。方向：给调度器挂 per-loop idle/prepare handle，
      涉及调度器架构调整。当前功能可用性影响最大的一项。
- [ ] F2. **忙等自旋**：`high-level/promise.ss` `promise-wait`（:285-288）、
      `internal/scheduler.ss` scheduler-loop（:341-344）、`internal/macros.ss`
      `define-sync-wrapper` —— pending 但 loop 无活跃 handle 时 `uv_run` 立即返回，
      100% CPU 死循环。需定策略：检测到该状态时报"死锁"错误还是阻塞等待。
- [ ] F3. **cancellation 重新设计**（`high-level/cancellation.ss`）：
      token 注册只增不删（长命 token 上每次 `async-cancellable` 追加闭包，无界泄漏），
      `append` 注册 O(n²)；cancel 只 reject 包装 promise，底层 libuv 操作照跑。
      需决策是否支持真正的操作取消（`uv_cancel`）。
- [ ] F4. **unhandled rejection 完全静默**（`internal/promise-core.ss` reject 无钩子/日志）。
      需定语义：何时判定"未处理"（GC 时？loop 退出时？），是否提供可配置钩子。
      与裸 `spawn-coroutine!` 失败会打印 stderr 的行为也不一致。
- [ ] F5. **stream 高层基本需要重写**（`high-level/stream.ss`）：
      stream-reader 注释描述的缓冲机制未实现（buffer/on-data/on-end/on-error 全是死字段）；
      `reading?` 置位但从不检查，并发读会覆盖回调致第一个 promise 永不 settle；
      stream-pipe 无背压，慢消费者内存无界增长。
- [ ] F6. **可移植性：FFI 层仅 Linux x86-64 正确**。addrinfo 偏移硬编码 glibc 布局
      （`ffi/dns.ss:69-79`，macOS 上 ai_addr/ai_canonname 互换）；信号常量
      （`ffi/signal.ss`）与 UV_E* 错误码（`ffi/errors.ss`）是 Linux 值；
      手写 ntohs 假设小端（`low-level/sockaddr.ss`）；`dirent-size=16` 手写常量
      （`ffi/fs.ss`）；int64 偏移用 `long`（LLP64 截断，`ffi/fs.ss:293,299,402,422`）。
      短期建议：README 明确声明仅支持 Linux x86-64；跨平台留作长期项。

## G. 性能优化（不影响正确性，单独一轮）

- [ ] G1. foreign 内存拷贝逐字节循环（`internal/foreign.ss:233-248, 105-113`；
      stream/udp 写路径同样）→ 改 memcpy（foreign-procedure）。
- [ ] G2. 每次写分配两块 foreign 内存（uv_buf_t + data），可池化。
- [ ] G3. 微任务 idle handle 每轮 drain 完销毁、下次重建（`high-level/promise.ss:387-391`）
      → 改为 stop 保留（unref 状态）。
- [ ] G4. 调度器 runnable 严格优先于 `uv_run`（`internal/scheduler.ss:327-344`），
      互相唤醒的协程链可饿死 I/O → 每轮至少 poll 一次 nowait。

## H. 低优先级 / 小项

- [x] H1. `define-sync-wrapper` 死宏已删除（`internal/macros.ss` 定义 + export 一并移除；
      引用未绑定 `uv-run`，全库无使用点）。
- [x] H2. promise 组合器（all/race/any/all-settled）已加 `combinator-loop` 校验：
      非 promise 或跨 loop 输入时报清晰错误，不再静默取第一个 loop。
      （注：组合器/取消固定用 `uv-default-loop` 的问题属 F 组多 loop 支持，未在此处理。）
- [ ] H3. 语义偏差（相对 JS Promise 基线）：`promise-resolved` 不解包 promise 值
      （与 `make-promise` 的 resolve 不一致，promise.ss:105-116）；
      `promise-finally` 的回调返回 promise 时不等待（promise.ss:155-164）。
      —— 属行为变更，留待确认是否要向 JS 语义对齐。
- [ ] H4. `tests/scratch/` 12 个调试草稿不被运行，考虑删除或转正为测试。
- [x] H5. `ffi/tcp.ss` 冗余的 `%ffi-uv-tcp-listen` 已删除（定义 + export；
      监听统一用 stream.ss 的 `%ffi-uv-listen`）。
- [x] H6. `threadpool-submit!` 已补线程安全约束文档（只能主线程调用）。
