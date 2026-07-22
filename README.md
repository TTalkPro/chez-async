# chez-async

Chez Scheme 的 Node.js 式异步 I/O 运行时——**同步写法，异步执行**。

async/await 协程、文件系统、TCP/网络、子进程、DNS、定时器，全部建在一个移植自
[skiff](../skiff) 的 **C++ task 运行时**（libuv）之上。事件循环跑在专属的 C++
线程上，从不触碰 Scheme 堆，因此 I/O 与 Chez 的 GC 完全解耦。

```scheme
(import (chez-async))

(io-runtime-start!)

(run-async
  (lambda ()
    ;; 两个文件并发读——await-all 让它们真正并行
    (let ([contents (await-all
                      (list (async (lambda () (io-read-file "a.txt")))
                            (async (lambda () (io-read-file "b.txt")))))])
      (for-each (lambda (bv) (display (utf8->string bv)) (newline)) contents))))

(io-runtime-stop!)
```

## 架构

```
用户代码（同步写法 + async/await/await-all）
        │
Scheme 高层：io-fs / io-net / io-proc / io-async（协程调度器）
        │
Scheme 绑定层：internal/io-runtime（foreign-procedure 绑 C ABI，
        │                          await/cq-wait 声明 __collect_safe）
        │  C ABI（uintptr_t 句柄 + foreign void* buffer）
        ▼
libchez-async-rt.so（native/，移植自 skiff src/runtime，纯 C++/libuv）
   ├─ 专属 loop 线程：uv_run，从不碰 Scheme 堆
   ├─ 任意 Scheme 线程提交 Task → uv_async 唤醒 loop → Dispatch 发 uv 调用
   └─ 完成回调只写 Task 结果 + 投递 CompletionQueue（无 Scheme 交互）
```

**双模式一套 API**：`io-fs`/`io-net`/`io-proc` 的操作默认**阻塞**调用线程
（`__collect_safe`，不卡别的线程 GC）；放进 `run-async` 里，同一套调用**自动变
协程挂起**——靠 `await-hook`/`current-cq` 两个 thread-parameter 切换。阻塞线程与
协程调度共用同一套 task 提交/完成机制。

## 构建

需要：线程版 Chez Scheme 10.4+、C++23 编译器、CMake、libuv、[bake](../bake)。

```sh
bake              # 编 native 运行时 + (chez-async) 库闭包
bake runtime      # 只编 native → native/<machine-type>/chez-async-rt.so
bake test         # 跑测试套件
bake install      # 装库树 + native .so → ~/.local/share/chez/lib
```

无 bake 时用 `native/build.sh` 直接 cmake 构建 native。

运行未安装的代码需让动态链接器找到 `.so`：

```sh
LD_LIBRARY_PATH=native/ta6le scheme --libdirs . --program examples/demo.ss
```

`bake install` 后 native `.so` 落 `~/.local/share/chez/lib/native/<mt>/`，
`(import (chez-async))` 全局可解析。

## API 速览

**生命周期**：`io-runtime-start!` / `io-runtime-stop!`

**async/await**（在 `run-async` 内）：
- `(run-async thunk)` — 起根协程，返回其值（异常传播）
- `(async thunk)` → future；`(await x)` — await future 或裸 task 句柄
- `(await-all fs)` — 并发 await 一组 future；`(in-async?)`

**定时器**：`(io-sleep ms)`

**文件系统**：`io-open`/`io-read`/`io-write`/`io-close`、`io-read-file`/
`io-write-file`、`io-mkdir`/`io-rmdir`/`io-unlink`/`io-rename`/`io-realpath`/
`io-scandir`、`io-stat`（`stat-info-size`/`-mtime`/`-mode`/`-dir?`/`-file?`）、
`io-exists?`、`io-watch`/`io-watch-next`/`io-watch-close`

**网络**：`io-dns-resolve`/`io-dns-resolve-all`、`io-tcp-connect`/`io-tcp-listen`/
`io-tcp-accept`、`io-stream-read`/`io-stream-write`/`io-stream-close`/
`io-stream-pipe`、`io-listener-close`

**子进程**：`io-spawn`（inherit/capture stdio）、`io-proc-wait`/`-kill`/`-close`、
`io-proc-stdin`/`-stdout`/`-stderr`、`io-run`、`io-run/output`

**错误**：I/O 失败抛 `&io-error`（`io-error?` / `io-error-errno` / `io-error-name`）。

## 示例

- [`examples/demo.ss`](examples/demo.ss) — async/await 并发 fs、并发 sleep、子进程、DNS
- [`examples/tcp-echo-server.ss`](examples/tcp-echo-server.ss) — TCP echo（每连接一协程）

## 设计文档

- [`docs/skiff-aligned-io-design.md`](docs/skiff-aligned-io-design.md) — 移植 skiff 运行时的架构
- [`docs/runtime-thread-design.md`](docs/runtime-thread-design.md) — 早期纯 FFI runtime 线程方案（已被 C++ 运行时取代）

## 与 skiff 的关系

`native/runtime/` vendored 自 skiff 的 `src/runtime`（Task/CompletionQueue + C++
loop 线程），符号前缀 `skiff_` → `rt_`、命名空间 `skiff` → `cart`，砍掉协议层
（http/http2/ws/tls）与内嵌 Chez shell。chez-async 是 Chez 当宿主 + 加载 `.so`；
skiff 是 C++ 内嵌 Chez。运行时内核一致，宿主模型不同。
