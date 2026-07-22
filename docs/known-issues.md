# 已知限制与设计约定

对应 C++ 运行时栈（2026-07-22 收敛后）。

## 运行前提

- **线程版 Chez Scheme 10.4+**：`__collect_safe` FFI 约定与 `fork-thread` 都需要。
- **C++ 构建**：CMake + C++23 编译器 + libuv。运行时是 native/ 的
  `chez-async-rt.so`，不是纯 Scheme 库——`(import (chez-async))` 即触发
  `load-shared-object`，故 `.so` 必须在动态链接器路径上（`LD_LIBRARY_PATH=
  native/<mt>`，或 `bake install` 后在 Chez lib dir 的 native 子树）。
- **单一全局运行时**：`io-runtime-start!` / `io-runtime-stop!` 是进程级单例，
  启一次即可；不是每 `run-async` 起停。`run-async` 不可嵌套。

## 平台

- **Linux x86-64 优先**（machine-type `ta6le`）。构建脚本按 `(machine-type)` 推导
  落点/soext，但只在 Linux 实测过。
- **`O_*` 打开标志硬编码 Linux 值**（`high-level/io-fs.ss`：O_CREAT=#o100 等）。
  macOS/BSD 的 O_CREAT/O_TRUNC/O_APPEND 值不同——跨平台需改为从 C 运行时查询。
- **soname 无 lib 前缀**（`chez-async-rt.so`）。macOS `.dylib` / Windows `.dll`
  的加载名与扩展名未处理。

## pinned 零拷贝（Model B）

- `io-read!` / `io-write!` / `io-stream-read!` / `io-stream-write!` 直接读写调用方
  bytevector（`Slock_object` 锁定至 `task-free`，零拷贝）。
- 代价：`.so` 用了 Chez C API（scheme.h 的 `Slock_object` 等），这些内核符号在
  `.so` 里**留未定义**，dlopen 进宿主 `scheme` 时从其动态符号表解析（stock
  scheme 已导出）。故 **`.so` 只能加载进 Chez 宿主**，不能独立运行/被非 Chez
  程序加载。构建需 `CHEZ_INCLUDE`（bake `(chez-api #t)` 自动注入；build.sh 自算）。
- pinned I/O 期间 bytevector 被锁（GC 不会移动/回收它），但调用方仍须持有引用
  至操作完成（`task-free` 前勿丢弃）。非 pinned 的 `io-read`/`io-write` 走 foreign
  中转 buffer，无此约束。

## 与旧设计相比（已消除的问题）

C++ loop 线程从不触碰 Scheme 堆、不参与 Chez GC rendezvous，因此：
- **I/O 完成分发与 GC 完全解耦**（旧纯 Scheme 方案里 stop-the-world 会暂停完成
  分发，已消除）。
- 完成回调是纯 C++，无每次进 Scheme 的开销。

## 尚未移植的 skiff 能力

运行时内核只 vendored 了 task substrate（fs/net/proc/timer/watch）。skiff 的协议层
**http/http2/ws/tls** 未移植（它们是 skiff 的 llhttp/nghttp2/wslay/OpenSSL 绑定）。
如需 HTTP，另立项目或从 skiff 再 vendored。
