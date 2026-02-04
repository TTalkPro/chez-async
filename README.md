# chez-async

**基于 call/cc 的现代异步编程库 - 为 Chez Scheme 打造**

完整的 async/await、Promise、协程调度器和 libuv 集成

[![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20FreeBSD-blue)](#快速开始)
[![Chez Scheme](https://img.shields.io/badge/Chez%20Scheme-10.0%2B-green)](#前置要求)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Status](https://img.shields.io/badge/status-production--ready-brightgreen)](#项目状态)

---

## 📢 最新更新 (2026-02-05)

### ✨ Phase 4 完成 - 高级特性

```scheme
;; async/await 语法
(async
  (let ([result (await (async-sleep loop 1000))])
    (printf "Waited 1 second~n")
    result))

;; 组合器
(async-all (list promise1 promise2 promise3))
(async-race (list fast-promise slow-promise))
(async-timeout promise 5000)

;; 取消令牌
(define cts (make-cancellation-token-source))
(define task (long-running-operation (cts 'token)))
(cts 'cancel!)  ; 取消操作
```

### 🎯 代码质量优化完成

- ✅ 缓冲区工具整合（减少 16 行样板代码）
- ✅ 错误回调标准化（4 个文件更新）
- ✅ 读写模式提取（2 个文件简化）
- ✅ 全部 39 个测试通过

详见：[Phase 4 报告](docs/phase4-complete.md) | [重构报告](docs/REFACTORING-COMPLETE.md)

---

## 目录

- [为什么选择 chez-async？](#为什么选择-chez-async)
- [核心特性](#核心特性)
- [项目状态](#项目状态)
- [快速开始](#快速开始)
- [示例代码](#示例代码)
- [API 文档](#api-文档)
- [架构设计](#架构设计)
- [项目结构](#项目结构)
- [开发路线图](#开发路线图)
- [文档](#-文档)

---

## 为什么选择 chez-async？

### 独特优势

**1. 真正的 async/await 语法**
```scheme
;; 像 JavaScript/C# 一样简洁
(async
  (let ([data (await (tcp-read-async client))])
    (await (tcp-write-async client data))))
```

**2. 基于 call/cc 的协程**
- 无需状态机
- 无需 CPS 变换
- 保持代码自然结构

**3. 工业级事件循环**
- 基于 libuv（Node.js 同款）
- 零 C/C++ 包装层
- 直接 FFI 绑定

**4. 完整的并发控制**
```scheme
;; 等待所有任务
(async-all promises)

;; 竞速
(async-race promises)

;; 超时控制
(async-timeout promise 5000)

;; 取消机制
(cancellable-operation token)
```

### 与其他方案对比

| 特性 | chez-async | Racket 异步 | 传统回调 |
|------|-----------|------------|---------|
| async/await | ✅ 原生支持 | ❌ 无 | ❌ 无 |
| 协程 | ✅ call/cc | ✅ delimited continuations | ❌ 无 |
| 取消 | ✅ CancellationToken | ✅ custodian | ❌ 手动 |
| 组合器 | ✅ 完整 | ✅ 完整 | ⚠️ 有限 |
| libuv 集成 | ✅ 直接 FFI | ❌ 无 | ✅ 可能有 |
| 学习曲线 | 低 | 中 | 高 |

---

## 核心特性

### 🚀 async/await 支持

```scheme
(define (fetch-user-data user-id)
  (async
    (let* ([user (await (db-query "SELECT * FROM users WHERE id = ?" user-id))]
           [posts (await (db-query "SELECT * FROM posts WHERE user_id = ?" user-id))])
      (list user posts))))
```

### 🔄 Promise/A+ 兼容

```scheme
(promise-then my-promise
  (lambda (value)
    (printf "Success: ~a~n" value))
  (lambda (error)
    (printf "Error: ~a~n" error)))
```

### ⚡ 高级组合器

- `async-all` - 并行等待所有任务
- `async-race` - 返回最快完成的任务
- `async-any` - 返回首个成功的任务
- `async-timeout` - 为任务添加超时
- `async-delay` - 延迟执行
- `async-catch` - 捕获错误
- `async-finally` - 清理资源

### 🎯 取消机制

```scheme
(define cts (make-cancellation-token-source))
(define task
  (async
    (when (token-cancelled? (cts 'token))
      (raise (make-operation-cancelled-error)))
    (await (long-operation))))

;; 在其他地方取消
(cts 'cancel!)
```

### 🧵 完整的 libuv 集成

- TCP/UDP 套接字
- 文件系统（异步）
- DNS 解析
- 进程管理
- 信号处理
- 定时器
- Pipe/TTY

---

## 项目状态

**当前版本**: Phase 4 完成 (2026-02-05)
**状态**: 生产就绪 ✅

### 已完成功能

#### Phase 1: 协程调度器 ✅
- ✅ 基于 call/cc 的协程实现
- ✅ 协程调度器和事件循环集成
- ✅ Suspend/Resume 机制

#### Phase 2: async/await 宏 ✅
- ✅ `async` 宏（创建异步函数）
- ✅ `await` 宏（等待 Promise）
- ✅ Promise/A+ 实现
- ✅ 错误传播和异常处理

#### Phase 3: libuv 深度集成 ✅
- ✅ TCP 套接字（客户端/服务器）
- ✅ UDP 套接字
- ✅ 文件系统（fs）
- ✅ DNS 解析
- ✅ Pipe 和 TTY
- ✅ 信号处理
- ✅ 进程管理
- ✅ 文件监控

#### Phase 4: 高级特性 ✅
- ✅ async/await 组合器（8个）
- ✅ 取消令牌（CancellationToken）
- ✅ 完整测试覆盖（39/39 通过）
- ✅ 代码质量优化重构

### 测试覆盖

```
✅ TCP:     8/8 通过
✅ UDP:     8/8 通过
✅ Pipe:    7/7 通过
✅ Promise: 13/13 通过
✅ Stream:  3/3 通过
───────────────────────
总计: 39/39 测试通过 ✅
```

---

## 快速开始

### 前置要求

- **Chez Scheme** 10.0+
- **libuv** 1.x

#### 安装

```bash
# Debian/Ubuntu
sudo apt-get install chezscheme libuv1-dev

# macOS
brew install chezscheme libuv

# FreeBSD
sudo pkg install chez-scheme libuv
```

### Hello World

```scheme
#!/usr/bin/env scheme-script

(import (chez-async))

;; 创建异步函数
(define (hello-async)
  (async
    (printf "Starting...~n")
    (await (async-sleep (uv-default-loop) 1000))
    (printf "Hello, async world!~n")))

;; 运行
(define loop (uv-default-loop))
(define p (hello-async))
(uv-run loop 'default)
```

---

## 示例代码

### 1. async/await 基础

```scheme
(import (chez-async))

(define (fetch-data url)
  (async
    (printf "Fetching ~a...~n" url)
    (await (async-sleep (uv-default-loop) 1000))
    (string-append "Data from " url)))

(define loop (uv-default-loop))
(define p (fetch-data "http://example.com"))

(promise-then p
  (lambda (data)
    (printf "Got: ~a~n" data)
    (uv-stop loop)))

(uv-run loop 'default)
```

### 2. 并行任务

```scheme
(define (parallel-fetch)
  (async
    (let ([urls '("url1" "url2" "url3")])
      (let ([promises (map fetch-data urls)])
        ;; 等待所有任务完成
        (await (async-all promises))))))
```

### 3. TCP Echo 服务器

```scheme
(import (chez-async))

(define (handle-client client)
  (async
    (let loop ()
      (let ([data (await (tcp-read-async client))])
        (when (bytevector? data)
          (await (tcp-write-async client data))
          (loop))))))

(define (start-server)
  (let* ([loop (uv-default-loop)]
         [server (uv-tcp-init loop)])
    (uv-tcp-bind server "0.0.0.0" 8080)
    (uv-tcp-listen server 128
      (lambda (srv err)
        (unless err
          (let ([client (uv-tcp-accept srv)])
            (handle-client client)))))
    (uv-run loop 'default)))
```

### 4. 超时和取消

```scheme
(define (with-timeout)
  (async
    (guard (e [(timeout-error? e)
               (printf "Operation timed out!~n")])
      (await (async-timeout
               (long-running-operation)
               5000)))))

(define (cancellable-task)
  (let ([cts (make-cancellation-token-source)])
    ;; 5秒后自动取消
    (async-sleep loop 5000)
    (cts 'cancel!)

    ;; 运行可取消任务
    (async
      (let ([token (cts 'token)])
        (await (long-operation-with-cancellation token))))))
```

---

## API 文档

### 核心 API

#### async/await

```scheme
(async body ...)              ; 创建异步函数，返回 Promise
(await promise)               ; 等待 Promise 完成
```

#### Promise

```scheme
(make-promise loop executor)  ; 创建 Promise
(promise-then p on-fulfilled [on-rejected])  ; 链式调用
(promise-catch p on-rejected)                ; 捕获错误
(promise-finally p on-finally)               ; 清理资源
(promise-resolved loop value)                ; 创建已完成的 Promise
(promise-rejected loop reason)               ; 创建已拒绝的 Promise
```

#### 组合器

```scheme
(async-all promises)          ; 等待全部完成
(async-race promises)         ; 返回最快的
(async-any promises)          ; 返回首个成功
(async-timeout promise ms)    ; 添加超时
(async-sleep loop ms)         ; 延迟
(async-delay loop ms thunk)   ; 延迟执行
(async-catch thunk)           ; 错误处理
(async-finally promise cleanup) ; 资源清理
```

#### 取消

```scheme
(make-cancellation-token-source)  ; 创建取消源
(cts 'token)                      ; 获取令牌
(cts 'cancel!)                    ; 请求取消
(token-cancelled? token)          ; 检查是否已取消
(token-register! token callback)  ; 注册取消回调
```

### 网络 API

```scheme
;; TCP
(uv-tcp-init loop)
(uv-tcp-bind tcp addr port)
(uv-tcp-listen tcp backlog callback)
(uv-tcp-connect tcp addr port callback)

;; UDP
(uv-udp-init loop)
(uv-udp-bind udp addr port)
(uv-udp-send! udp data addr port callback)
(uv-udp-recv-start! udp callback)

;; Stream
(uv-read-start! stream callback)
(uv-write! stream data callback)
```

### 文件系统 API

```scheme
(uv-fs-open path flags mode callback)
(uv-fs-read fd buffer offset callback)
(uv-fs-write fd buffer offset callback)
(uv-fs-close fd callback)
(uv-fs-stat path callback)
(uv-fs-unlink path callback)
```

完整 API 文档见：[docs/](docs/)

---

## 架构设计

### 分层架构

```
┌─────────────────────────────────────┐
│  High-Level API (async/await)       │  ← 用户代码
│  - async macro                      │
│  - await macro                      │
│  - Promise/A+                       │
│  - Combinators                      │
│  - CancellationToken                │
└─────────────────────────────────────┘
              ↓
┌─────────────────────────────────────┐
│  Internal (调度器)                   │
│  - Coroutine Scheduler              │
│  - call/cc integration              │
│  - Event Loop per-loop storage      │
│  - Callback Registry                │
└─────────────────────────────────────┘
              ↓
┌─────────────────────────────────────┐
│  Low-Level API (libuv 绑定)        │
│  - uv-tcp-*, uv-udp-*              │
│  - uv-fs-*                         │
│  - uv-handle-*, uv-request-*       │
└─────────────────────────────────────┘
              ↓
┌─────────────────────────────────────┐
│  FFI Layer (直接 C 绑定)           │
│  - %ffi-uv-* functions             │
│  - ftype definitions               │
└─────────────────────────────────────┘
              ↓
       [ libuv C Library ]
```

### 协程调度机制

```
用户代码: (await promise)
    ↓
协程挂起 (call/cc 保存 continuation)
    ↓
注册回调到 Promise
    ↓
返回事件循环
    ↓
... 事件发生 ...
    ↓
Promise 完成，回调触发
    ↓
协程恢复 (continuation 调用)
    ↓
用户代码继续执行
```

---

## 项目结构

```
chez-async/
├── high-level/               # 用户 API
│   ├── promise.ss            # Promise 实现
│   ├── async-await.ss        # async/await 宏
│   ├── async-combinators.ss  # 组合器
│   └── cancellation.ss       # 取消令牌
│
├── internal/                 # 内部实现
│   ├── scheduler.ss          # 协程调度器
│   ├── macros.ss             # 宏工具
│   ├── buffer-utils.ss       # 缓冲区工具
│   └── macro-enhancements.ss # 增强宏
│
├── low-level/                # libuv 封装
│   ├── tcp.ss                # TCP 套接字
│   ├── udp.ss                # UDP 套接字
│   ├── stream.ss             # Stream 操作
│   ├── fs.ss                 # 文件系统
│   ├── dns.ss                # DNS 解析
│   └── timer.ss              # 定时器
│
├── ffi/                      # FFI 绑定
│   ├── types.ss              # C 类型
│   ├── core.ss               # 核心函数
│   ├── tcp.ss                # TCP FFI
│   └── fs.ss                 # FS FFI
│
├── tests/                    # 测试套件
│   ├── test-tcp.ss
│   ├── test-async.ss
│   └── test-cancellation.ss
│
├── examples/                 # 示例代码
│   ├── tcp-echo-server.ss
│   └── async-parallel.ss
│
└── docs/                     # 文档
    ├── async-await-guide.md
    ├── async-combinators-guide.md
    ├── cancellation-guide.md
    └── api/
        ├── tcp.md
        └── timer.md
```

---

## 开发路线图

### ✅ Phase 1: 协程调度器（已完成）
- call/cc 协程实现
- 调度器和事件循环集成
- Suspend/Resume 机制

### ✅ Phase 2: async/await（已完成）
- async/await 宏
- Promise/A+ 实现
- 错误处理

### ✅ Phase 3: libuv 集成（已完成）
- TCP/UDP/Pipe/TTY
- 文件系统
- DNS/信号/进程

### ✅ Phase 4: 高级特性（已完成）
- 8个组合器函数
- 取消令牌机制
- 代码质量优化

### 🚀 未来计划
- Stream/Iterator 支持
- 更多性能优化
- 生态系统集成（数据库、HTTP等）

---

## 📚 文档

### 使用指南

- **[Getting Started](docs/guide/getting-started.md)** - 快速入门
- **[async/await Guide](docs/async-await-guide.md)** - async/await 完整指南
- **[Async Combinators Guide](docs/async-combinators-guide.md)** - 组合器使用
- **[Cancellation Guide](docs/cancellation-guide.md)** - 取消机制
- **[TCP with async/await](docs/tcp-with-async-await.md)** - TCP 编程指南

### 实现原理

- **[async Implementation](docs/async-implementation-explained.md)** - async 宏实现详解
- **[Promise Implementation](docs/promise-implementation-explained.md)** - Promise 实现详解

### API 参考

- **[Timer API](docs/api/timer.md)** - 定时器 API
- **[TCP API](docs/api/tcp.md)** - TCP 套接字 API

完整文档索引：[docs/README.md](docs/README.md)

项目状态：[PROJECT-STATUS.md](PROJECT-STATUS.md)

---

## 运行测试

```bash
cd chez-async

# 运行单个测试
scheme --libdirs .:.:. --program tests/test-tcp.ss
scheme --libdirs .:.:. --program tests/test-async.ss

# 运行所有测试
./run-tests.sh
```

---

## 参考资料

- **[libuv 文档](https://docs.libuv.org/)** - libuv 官方文档
- **[Promise/A+](https://promisesaplus.com/)** - Promise 规范
- **[async/await 模式](https://en.wikipedia.org/wiki/Async/await)** - 异步编程模式
- **[call/cc](https://en.wikipedia.org/wiki/Call-with-current-continuation)** - Continuation 机制

---

## 许可证

MIT License

---

## 贡献

欢迎贡献！请查看贡献指南并提交 Pull Request。

---

## 致谢

- **[libuv](https://libuv.org/)** - 提供高性能异步 I/O
- **[chez-socket](https://github.com/arcfide/chez-socket)** - FFI 绑定设计参考
- **Chez Scheme 社区** - 提供优秀的 Scheme 实现

---

**Star ⭐ 本项目** 如果它对你有帮助！
