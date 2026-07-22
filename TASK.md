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

- [x] E1. **为本轮修复补回归测试**。19/19 通过只说明没改坏现有行为；本轮修的 UAF、
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

- [x] F1. **协程只在 `run-scheduler` 内运行** —— 已修复（方案 A，见
      `docs/f1-scheduler-integration-design.md`）。抽出统一驱动器 `drive-loop`
      （`internal/scheduler.ss`），`uv-run 'default` 在存在调度器时经注入的
      `scheduler-driver`（`internal/loop-registry`）委托它，使 `(async ...)` +
      `(uv-run loop 'default)` 可直接混用。用注入而非 event-loop import scheduler，
      规避了「coroutine 进入 event-loop 依赖图 → 与 threadpool fork-thread 死锁」的
      初始化顺序坑。新增 `tests/test-scheduler-integration.ss`（6 例）。22/22 通过。
      注：协程逃逸仍严格在 Scheme 栈上（drive-loop 包裹 uv_run，不进 uv 回调），
      保持 C 边界安全。
- [x] F2. **忙等自旋** —— 已修复（死锁检测策略）。
      关键洞察：微任务待处理时 idle handle 处于 ref 状态、定时器/线程池 async 也都 ref，
      因此 `uv_run 'once` 返回 0（无活跃 ref 句柄）**即可断定**再无东西能推进 —— 不是模糊信号。
      - `promise-wait`（`high-level/promise.ss`）：`uv_run 'once` 返回 0 且仍 pending → 报死锁。
      - `drive-loop` Case 2（`internal/scheduler.ss`）：`uv_run` 返回 0 且无协程被唤醒进 runnable
        且仍有 pending 协程 → 报死锁。
      - `define-sync-wrapper` 那处已随 H1 删除。
      新增 `tests/test-promise-semantics.ss` 覆盖（promise-wait 死锁、调度器协程死锁、
      正常仍能 resolve）。25/25 通过。
- [x] F3. **cancellation 重新设计**（`high-level/cancellation.ss`）—— 已完成：
      - token callbacks 改用 id→callback 哈希表（O(1) 增删，替代 append 的 O(n²)）；
        `cancel-token-register!` 返回注销器 thunk；取消时按 id 升序 FIFO 调用。
      - `async-cancellable` 在被包装 promise settle 后调用注销器，从 token 移除取消回调
        → 长命 token 不再无界累积；并改用 promise 所属 loop（修 M6，新增 `promise-loop` 访问器）。
      - `link-tokens` 子取消时从所有父 token 注销 → 父不再永久持有子 source。
      - 取消语义（只 reject 包装、不中止底层 libuv 操作，AbortController 式）在模块头写明；
        真正的 `uv_cancel` 中止留作独立工作项（未做）。
      新增 `tests/test-cancellation-redesign.ss`（7 例）。23/23 通过。
- [x] F4. **unhandled rejection 检测** —— 已完成（延迟一拍复查 + 可配置钩子）：
      - promise-record 新增 `rejection-handled?` 字段；`promise-then` 总会把 rejection
        传播给派生 promise，故 then 过即标记父为已负责（责任转移到链尾）；
        `promise-wait` 消费 rejection 时也标记。
      - `reject-promise!` 在 reject 时若无人负责，调度微任务延迟一拍复查——
        同一轮同步挂 catch 来得及抑制；复查仍无人负责则调用
        `unhandled-rejection-handler`（make-parameter，默认打印 stderr，可
        parameterize 覆盖；已从 promise.ss 与 chez-async.ss 导出）。
      - 覆盖动态 reject 路径：make-promise 的 reject、async 块异常、then 链传播。
        **显式构造的 `promise-rejected` 豁免**：它是「值」而非「事件」，且构造器
        不应有 loop 副作用（经检测微任务会创建 idle handle，令未运行的 loop 无法 close）。
      - 上线即抓到一个潜伏 bug：test-async-combinators 的 then 回调 `assert-equal`
        少传参抛异常被静默吞掉，现已修复。
      测试见 `tests/test-promise-semantics.ss` 新增 4 例（报告/同步 catch 抑制/
      async 块未捕获/promise-wait 抑制）。25/25 通过、全套件零误报。
- [x] F5. **stream 高层重写**（`high-level/stream.ss`）—— 已完成：
      - stream-reader 改为「单一持续读 + 缓冲队列 + 等待者队列」解复用模型：
        多个并发 stream-reader-read 按 FIFO 依次拿到数据块（不再互相覆盖回调、
        第一个 promise 不再永不 settle）；缓冲队列真正启用（替代旧死字段）。
      - reader 背压：缓冲超过高水位（64 块）暂停底层读取，消费降到低水位（16 块）恢复。
      - stream-pipe 背压：以在途写入字节数计量，超过 256KB 暂停读源、排空后恢复；
        源 EOF 后等所有在途写入完成才 resolve；读/写错误 reject。
      - stream-read 保持一次性语义，补文档提示并发/连续读用 stream-reader。
      新增 `tests/test-stream-reader.ss`（3 例：连续读到 EOF、并发读 FIFO、
      300KB 背压 pipe 完整性）。24/24 通过。
      注：旧的 on-data/on-end/on-error 死字段已随重写移除（reader 记录类型换新字段集）。
- [ ] F6. **可移植性：FFI 层仅 Linux x86-64 正确**。addrinfo 偏移硬编码 glibc 布局
      （`ffi/dns.ss:69-79`，macOS 上 ai_addr/ai_canonname 互换）；信号常量
      （`ffi/signal.ss`）与 UV_E* 错误码（`ffi/errors.ss`）是 Linux 值；
      手写 ntohs 假设小端（`low-level/sockaddr.ss`）；`dirent-size=16` 手写常量
      （`ffi/fs.ss`）；int64 偏移用 `long`（LLP64 截断，`ffi/fs.ss:293,299,402,422`）。
      短期建议：README 明确声明仅支持 Linux x86-64；跨平台留作长期项。

## G. 性能优化（不影响正确性，单独一轮）

- [x] G1. foreign 内存拷贝改为 8 字节一组批量复制 —— 已完成。
      `copy-bytevector-to-foreign!` / `copy-foreign-to-bytevector!`（`internal/foreign.ss`）
      用 `unsigned-64` + `bytevector-u64-native-ref/set!` 每次搬 8 字节（原生字节序两端
      一致、字节完全保真），尾部逐字节，约 8× 提速。`string->c-string` / `c-string->string`
      及 stream/udp 写路径的逐字节循环统一改用这两个辅助。
      （未用真 memcpy foreign-procedure：Chez 无稳定的「bytevector→地址」公有 API，
      8 字节分块是用文档化原语实现的安全等效方案。）
      新增边界长度测试（0/1/7/8/9/15/16/17/63/64/65/1003/4096 精确往返）。24/24 通过。
- [ ] G2. 每次写分配两块 foreign 内存（uv_buf_t + data），可池化。
      —— **推迟**：缓冲池的生命周期正确性（何时归还、跨异步操作的所有权）风险高，
      收益需实测支撑，单独一轮谨慎处理。
- [ ] G3. 微任务 idle handle 每轮 drain 完销毁、下次重建（`high-level/promise.ss`）。
      —— **推迟**：与 `uv_loop_close` 生命周期纠缠。stop-但-不-close 的 idle handle 仍是
      「未关闭句柄」，会让 `uv_loop_close` 返回 EBUSY；要复用须在 loop 关闭时先 close 该
      handle 并再跑一次 uv_run 处理 close 回调，而 event-loop 不能 import promise（成环），
      需再加一个注入钩子。当前「drain 完即 close」已把开销限制在每「批」一次（一次 drain
      处理该批全部微任务），代价可控。留待需要时配合 loop-close 钩子一并做。
- [ ] G4. 调度器 runnable 严格优先于 `uv_run`（`internal/scheduler.ss`）。
      —— **推迟/基本非问题**：协程 resume 都经微任务 idle handle 在 `uv_run` 内触发
      （`suspend-for-promise!` 的 promise-then → schedule-microtask），因此「互相唤醒」
      本身就依赖 uv_run，runnable 会自然抽干后才进 Case 2。真正能持续占满 runnable 的
      只有「协程在紧循环里不断 spawn 子协程」这类病态场景（对单线程而言本就饿死一切）。
      插入 nowait poll 的收益边际、且引入时序微妙性，暂不做。

## H. 低优先级 / 小项

- [x] H1. `define-sync-wrapper` 死宏已删除（`internal/macros.ss` 定义 + export 一并移除；
      引用未绑定 `uv-run`，全库无使用点）。
- [x] H2. promise 组合器（all/race/any/all-settled）已加 `combinator-loop` 校验：
      非 promise 或跨 loop 输入时报清晰错误，不再静默取第一个 loop。
      （取消侧固定 `uv-default-loop` 已随 F3 修复为用 promise 所属 loop；
      `async-combinators` 的 sleep/timeout/delay 仍固定 `uv-default-loop`，待多 loop 支持时处理。）
- [x] H3. 语义向 JS Promise 对齐 —— 已完成（经用户确认的行为变更）：
      - `promise-resolved`：value 为 promise 时跟随它（采用其最终状态），
        与 `make-promise` 的 resolve、JS `Promise.resolve` 一致。
      - `promise-finally`：on-finally 返回 promise 时先等待它再传递原值/原因；
        该 promise reject 或 on-finally 抛异常则以该错误取代原结果（JS finally 语义）。
      测试见 `tests/test-promise-semantics.ss`（H3.1 跟随/普通值、H3.2 等待/reject 覆盖）。
- [ ] H4. `tests/scratch/` 12 个调试草稿不被运行，考虑删除或转正为测试。
- [x] H5. `ffi/tcp.ss` 冗余的 `%ffi-uv-tcp-listen` 已删除（定义 + export；
      监听统一用 stream.ss 的 `%ffi-uv-listen`）。
- [x] H6. `threadpool-submit!` 已补线程安全约束文档（只能主线程调用）。

---

# Runtime 线程与 Task 化（2026-07-22 设计轮）

设计文档：`docs/runtime-thread-design.md`（skiff 同构：runtime 线程 +
提交队列 + Task/CompletionQueue，纯 FFI，零 C 代码）。
前置条件：线程版 Chez ≥ 9.5.2（`__collect_safe`）；`runtime-start!` 入口用
`(threaded?)` 检查并给出明确报错。
约定沿用：改动不自动 git 提交；每步跑 `./run-tests.sh` 保持全绿。

## R-0. 前置验证（先做，风险最高的假设先证伪）

- [x] R1. `__collect_safe` 最小验证程序 —— 已完成，决定性通过
      （`tests/scratch/collect-safe-verify.ss`，Chez 10.4.1 线程版）。四场景：
      - **A** 正向功能：fork-thread 经 `__collect_safe` uv_run 深睡 epoll，
        `__collect_safe` 定时器回调分配 Scheme 堆对象并计算，主线程并发 GC
        压力（2000×分配 + 显式 collect）→ 回调 20 次值全对、uv_run 干净返回。
      - **A2** 计时证明：runtime 线程单挂 300ms 定时器深睡，主线程重 GC 仅
        **2ms** 完成（远小于 300ms）→ GC 未被 epoll 阻塞。
      - **A3** 反向对照（决定性）：去掉 `__collect_safe`，主线程 `(collect)`
        直接抛 **“cannot collect when multiple threads are active”** —— 证明
        activated 的 epoll 深睡下 GC 根本无法运行，`__collect_safe` 是必要而
        非可选。
      - **B** 同线程路径：主线程 activated 状态经 uv_run 'nowait 反复进入同一
        collect-safe 回调，嵌套 activate 幂等、值全对。
      结论：R2/R3 全局 collect-safe 化的两个前提（deactivated 线程回调安全、
      activated 线程嵌套安全）均成立，方案 A 可继续。

## R-A. 方案 A：runtime 线程（现有 API 全部不动）

- [x] R2. `internal/macros.ss` `define-ffi` 加可选首标志 `collect-safe`
      （展开为 `foreign-procedure __collect_safe`）；`ffi/core.ss` `%ffi-uv-run`
      改用。全局生效不分模式。25/25 通过。
- [x] R3. 所有 foreign-callable 站点统一 `__collect_safe`：`ffi/callbacks.ss`
      10 处、`low-level/{fs,dns,process}.ss` 7 处、`internal/macros.ss`
      `define-c-callback`。回调实例由 callbacks/low-level 工厂创建（registry
      只缓存），故改在工厂站点。25/25 通过，同线程模式零行为变化。
- [x] R4. 提炼 `internal/thread-queue.ss`：双列表 FIFO + mutex + condition
      （`tq-push!` / `tq-pop-all!` / `tq-blocking-pop!` / `tq-try-pop!` +
      `tq-mutex`/`tq-condition` 供外部 broadcast）。threadpool 的
      task-queue/result-queue 改为复用（薄 alias），删掉自带的 task-queue
      记录类型与 5 个队列函数。25/25 通过，行为不变。
- [x] R5. `high-level/runtime.ss` 核心：runtime 记录（专属 loop、线程、
      提交队列、unref'd 提交 async 句柄、submit-mutex/stopped?/drain?、
      done-cond）；`runtime-start!`（`(threaded?)` 检查 + fork 线程并等其
      记录 thread-id）；外层循环 = `drain-submit-queue!` → `drive-loop 'default`
      → 停机收尾 / 静止 `tq-blocking-pop!` 等待。导入布局无 F1 式 fork-thread
      初始化死锁（冒烟 + 全套件验证通过）。
- [x] R6. `runtime-submit!` / `runtime-submit-cell!`（submit-mutex 内检查
      stopped? 再 push，杜绝孤儿 cell；tq-push! signal condition 通道 +
      `uv-async-send!` uv_run 通道，双通道唤醒）与 `runtime-await`
      （result-cell：mutex+cond+done?/ok?/value；失败 re-raise 原异常对象）。
      提交 async 回调只 `drain-submit-queue!`→spawn，不执行闭包（F1 硬约束）；
      协程内 await 因此合法。`runtime-poll` 三态。冒烟见
      `tests/scratch/runtime-{smoke,await-io}.ss`（await-io 证实后台线程上
      同步写法异步 I/O + 主线程自由 + 异常跨线程传播）。
- [x] R7. 生命周期：`runtime-stop!`（`'drain? #t` 默认排干未启动提交；
      `'drain? #f` 未启动项以 `&runtime-stopped` 失败；两者都等已 spawn 协程
      跑完，不中途丢在途 libuv 操作）→ `finish-shutdown!`：close 提交句柄 →
      nowait flush close 回调 → `uv-loop-close`（A6 次序）→ signal join。
      stopped? 与提交 push 同 submit-mutex 串行化，stop 后 submit 抛
      `&runtime-stopped`。
- [~] R8. 线程归属断言：机制已具备（`runtime-on-thread?` 谓词 +
      记录 thread-id）。**全面插桩每个高层 API 入口暂缓**——跨 low-level/
      high-level 铺断言与收益不成比例，留作后续按需添加。
- [x] R9. `tests/test-runtime.ss`（11 例）：start/stop、await 值、主线程
      自由（timer 期间算 fib 不阻塞）、异常跨线程、poll 三态、串行 await I/O、
      4 线程并发 submit、drain 停机全完成、非 drain 停机无 cell 悬挂、停机后
      submit 被拒、无句柄泄漏（停机后可再起新 runtime）。登记 run-tests.sh。
- [x] R10. `examples/runtime-demo.ss`：主线程算 fib 与后台 I/O 并行、并发提交
      收集结果、异常跨线程传播、drain 停机。

## R-B. 方案 B：Task / CompletionQueue 层（A 之上的 API 皮）

- [x] R11. `high-level/task.ss`：task 记录（id、op 符号、内嵌 result-cell、
      所属 runtime、可选 cq、cancel-source）+ completion-queue（复用
      thread-queue）：`task-submit!`（关键字 `'op` / `'cq`）/ `task-await` /
      `task-poll` / `make-completion-queue` / `cq-wait-one` / `cq-try-pop`。
      完成钩子经 runtime 新增的 `runtime-submit-cell!` on-complete 参数
      （settle 后在 runtime 线程 `cq-post!`，对应 skiff `Task::Complete`）。
- [x] R12. `tests/test-task.ss`（6 例）：task-await 值、op 标签、poll 三态、
      **N=20 task 汇入单 cq 收割不重不漏**、task-cancel!、cq-try-pop 非阻塞。
- [x] R13. `task-cancel!`：每 task 内置 F3 cancel-source；token 经
      `task-current-token` 参数在 thunk 内可取（thunk 保持零参），
      thunk 用 `(await (async-cancellable (task-current-token) p))` 包装
      即可被取消。语义与 F3 一致（reject 包装，不做 uv_cancel 真中止）。
- [x] R14. `chez-async.ss` 导出 runtime + task 全部 API；README 增 runtime
      章节；known-issues.md 记录三条已接受差距（GC 耦合 / 回调 activate 开销
      / 无零拷贝，设计文档 §5）。27/27 全套件通过。

---

# 移植 skiff C++ 运行时 —— Task-based I/O substrate（2026-07-22，已定架构）

设计文档：`docs/skiff-aligned-io-design.md`。
**架构决策（经用户确认）**：移植 skiff 的 C++ task 运行时——把
`skiff/src/runtime/{task.hpp,runtime.hpp,runtime.cpp,net.hpp}` + 裁剪的
`ffi.cpp` adapt 进 chez-async（`native/runtime/`，符号前缀改 `rt_`），CMake/C++23
构建为 `libchez-async-rt.so`，chez-async 的 I/O 经 FFI 重绑到其 C ABI。放弃纯 FFI
方案（`runtime-thread-design.md` 的纯 Scheme 版将被取代）。
**关键事实**：skiff 运行时内核（task.hpp/runtime.*/net.hpp）不 include scheme.h、
只依赖 uv.h——纯 C++ 可干净抽成 .so。v1 丢 pinned 零拷贝、buffer ABI 收 foreign
void*，runtime .so 零 Chez 头依赖。收益：消除纯 FFI 版三条差距（GC 耦合 / 回调进
Scheme 开销 / 无零拷贝）。代价：从零构建变成带 CMake/C++23 产物（用户已接受）。
工具链已确认齐备：g++14 -std=c++23、cmake 3.31、system libuv、Chez 10.4.1 scheme.h。
约定沿用：不自动提交；Scheme 侧每步 `./run-tests.sh` 保持全绿。

## S-0. 原型闸门（先做，最高风险的整条工具链先证）

- [x] S0. **已通过。** 最小 task 运行时 `native/runtime/rt_mini.cpp`（忠实模仿
      skiff task.hpp/runtime.cpp 的 Task/CompletionQueue/loop 线程/Submit/Drain/
      Dispatch timer 路径,纯 C++/libuv,零 Chez 头）+ `native/CMakeLists.txt`
      （C++23,pkg-config 找 system libuv,产 `libchez-async-rt.so`）+ 绑定验证
      `tests/scratch/rt-timer-gate.ss`。三项全过：①Chez 加载 C++ .so,rt_timer→
      rt_await 端到端(60ms 定时器 await 到 0)；②`__collect_safe` rt_await:一线程
      阻塞 300ms await 时主线程重 GC 仅 2ms 完成(阻塞点从 uv_run 移到 C++ cv,
      collect_safe 语义照样成立)；③CompletionQueue 收割 15 个 timer 不重不漏。
      **整条工具链(g++14 -std=c++23 编 .so + Chez load-shared-object + collect_safe
      await + cq)成立,S1 可继续。**

## S-1. 构建骨架 + vendor

- [x] S1. **已完成。** `native/` CMake/C++23 工程 vendor 自 skiff @ 93e0fd6：
      `runtime/{task.hpp,net.hpp,runtime.hpp,runtime.cpp}`（namespace skiff→
      **cart**，来源头注释）+ `rt_runtime.h`（C ABI，rt_ 前缀，砍 pinned/
      http/http2/ws/tls）+ `rt_ffi.cpp`（裁剪自 ffi.cpp：去 scheme.h、buffer
      参数改裸 foreign void*、rt_ 前缀）。`native/CMakeLists.txt`（C++23，
      pkg-config 链 system libuv）+ `native/build.sh`。产物
      `libchez-async-rt.so`：61 个 rt_ 符号、**零 Chez 依赖**（只链
      libuv/libstdc++/libc）。gate `tests/scratch/rt-runtime-gate.ss` 全过：
      timer、fs 往返（open+write+read+close+stat，UTF-8 内容一致）、dns
      resolve localhost、task 泄漏计数=0。Scheme 27/27 仍绿（.so 尚未被
      Scheme 引用）。
      注：符号命名用户定 `rt_` 前缀；vendor 方式用户定直接 copy。运行时加载需
      `LD_LIBRARY_PATH=native/build`（S6 再定安装路径）。

## S-1.5. bake 构建集成（用户要求：S2 前先立起来）

- [x] S1.5. **已完成。** `recipe.ss`（bake 构建/安装描述）：
      - `(native-task 'runtime (dir ".") (build (cmake (targets "chez-async-rt")))
        (produces "chez-async-rt"))` —— cmake 后端 Model A（纯 C ABI，不注入
        Chez 头）。**dir "."** 是项目自有 native 的惯用法：landing 落
        **`native/<mt>/chez-async-rt.so`**（=`native/ta6le/…`），正是 install-task
        随库树扫描并安装的 native 子树位置。构建入口是**仓库根 `CMakeLists.txt`**
        （编 native/runtime/*.cpp；`PREFIX ""` 去 lib 前缀 + `install(TARGETS)`）。
      - `(library-task 'libs '(chez-async))` —— 编 umbrella + 全 import 闭包为
        .so（→ `_build/ta6le/`，零错误）。
      - `(task 'build '(runtime libs))` 默认；`(task 'test '(runtime))`。
      - **`(install-task 'install (lib chez-async) (from ".") (target user))`**
        + uninstall + install-global/uninstall-global。install 把库树**和**
        `native/<mt>/*.so` 一起装到 `~/.local/share/chez/lib`（native 供统一加载，
        designs/20-21）。
      验证：`bake`/`bake runtime`（落 `native/ta6le/`，bake 校验通过）/`bake libs`/
      `bake test`（27/27）全过；`bake install` 装 69 文件含
      `native/ta6le/chez-async-rt.so`，从任意目录 `CHEZSCHEMELIBDIRS` 下
      `(import (chez-async))` + 加载装好的 native、timer-await=0；`bake uninstall`
      干净卸载（含 native，无残留）。
      注：soname 无 lib 前缀→`(load-shared-object "chez-async-rt.so")`。
      `native/build.sh` 为无 bake 时的等价 cmake 后备（源=仓库根 CMakeLists）。
      gitignore：`/build/`、`_build/`、`/native/*/` + `!/native/runtime/`。

## S-2. Scheme 绑定层

- [x] S2. **已完成。** `chez-async/internal/io-runtime.ss`（对齐 skiff/task.ss）：
      - 加载：`load-shared-object`——env `CHEZ_ASYNC_RT` 覆盖，否则裸名
        `"chez-async-rt.so"`（靠 LD_LIBRARY_PATH/已安装）。
      - 全量 rt_ C ABI `foreign-procedure` 绑定（lifecycle/timer/fs/tcp/stream/
        dns/proc/watch/stat/scandir/cq/debug/err）；`%await`/`%cq-wait` 声明
        `__collect_safe`；buffer 参数用 `void*`（裸 foreign 指针）。
      - `task-run`/`task-run-void`/`task-run-str`（submit→await→free→raise 单一
        owner）；`&io-error`（负 errno + 符号名 + who + message）。
      - `await-hook`/`current-cq` thread-parameter 集成缝（默认阻塞 %await /
        cq=0；S4 协程调度器重绑）。`submit-*` 各 op（cq 默认 (current-cq)）、
        stat/scandir 访问器、`io-sleep`、cq 包装、`io-live-*` 泄漏计数。
      验证 `tests/scratch/io-runtime-gate.ss`（经绑定层非裸 foreign）：io-sleep、
      fs 往返（open/write/read/close/stat，UTF-8 一致）、dns→::1、错误路径
      （task-run 抛 &io-error ENOENT errno -2）、cq 收割 12 timer、泄漏=0。
      运行需 `LD_LIBRARY_PATH=native/ta6le`。
      注：暂不进 (chez-async) umbrella 导出——import 即触发 load-shared-object，
      会让无 .so 路径的现有 27 套件加载失败；S5 收敛时并入。

## S-3. op 迁移（high-level 重建在 io-task 上，新旧并存）

- [ ] S3. timer → fs-*（open/read/write/close/stat/mkdir/...）→ dns → tcp →
      stream → process → watch，逐个把 high-level API 重建在 rt_ task 上。
      buffer 走 foreign void* + 现有 bytevector↔foreign 拷贝。每迁一个增量测试，
      旧路径与旧测试保持绿。stream/listener 直接移植 skiff net.hpp（含停泊队列/
      背压），F5 高层逻辑退化为薄封装。

## S-4. 协程调度器集成

- [ ] S4. `internal/scheduler` 的 suspend/resume 改 keyed-on-task-handle；
      async 上下文把 `await-hook` 重绑为 suspend 协程 + 挂 task 到调度器 cq、
      `current-cq` 重绑为调度器 cq；一个调度器线程 `%cq-wait` 收割 resume。
      对齐 skiff async 的 cq-as-scheduler-substrate。

## S-5. 收敛（此步才真正「放弃现在的设计」）

- [ ] S5. async/await、async-combinators、high-level stream 全部落到 io-task；
      删除弃用的纯 Scheme low-level uv 绑定层与 promise-per-op 路径；更新全部
      测试。`make-promise` 保留给纯计算/组合器。

## S-6. 零拷贝 / bake / 文档

- [ ] S6. v2 pinned 零拷贝（需 stock scheme 导出 Slock_object 给 .so，或
      Sforeign_symbol 反向）；bake recipe（可选，与 CMake 并存）；README/
      known-issues 更新；迁移说明（旧 low-level API → io-task）；可移植性
      （runtime .so 跨平台 libuv 链接）。
