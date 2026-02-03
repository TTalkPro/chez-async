# chez-async

**High-performance async programming library for Chez Scheme**

Chez Scheme async programming library with libuv integration and native threadpool

[![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20FreeBSD-blue)](#快速开始)
[![Chez Scheme](https://img.shields.io/badge/Chez%20Scheme-10.0%2B-green)](#前置要求)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

---

## 目录

- [📢 重构更新](#-重构更新-2026-02-03)
- [为什么选择 chez-async？](#为什么选择-chez-async)
- [核心特性](#核心特性)
- [项目状态](#项目状态)
- [架构设计](#架构设计)
- [快速开始](#快速开始)
- [运行示例](#运行示例)
- [API 文档](#api-文档)
- [📚 文档](#-文档)
- [项目结构](#项目结构)
- [内存管理](#内存管理)
- [开发路线图](#开发路线图)
- [参考项目](#参考项目)
- [获取帮助](#获取帮助)
- [贡献](#贡献)

---

## 📢 重构更新 (2026-02-03)

✨ **新特性**：简化的 API 命名，更符合 Scheme 惯例！

```scheme
;; 旧方式（仍然支持）
(uv-handle-wrapper-scheme-data-set! timer callback)
(define ptr (uv-handle-wrapper-ptr timer))

;; 新方式（推荐）- 名称缩短 56%
(handle-data-set! timer callback)
(define ptr (handle-ptr timer))
```

**改进**：
- ✅ FFI 绑定代码减少 38%
- ✅ 函数名称缩短 56%
- ✅ 100% 向后兼容
- ✅ 零性能损失

详见：[重构报告](REFACTORING-REPORT.md) | [命名规范](docs/naming-convention.md)

---

## 为什么选择 chez-async？

### 设计理念

chez-async 遵循 **直接 FFI 绑定** 的设计原则，参考 chez-socket 的成功模式：

- **零 C/C++ 包装层**: 直接使用 Chez Scheme 的 FFI 调用 libuv，避免额外的 C 代码维护
- **类型安全**: 完整的类型系统和错误处理机制
- **内存安全**: lock-object/unlock-object 配合 GC，自动管理对象生命周期
- **性能优先**: 编译时宏展开，运行时零开销

### 与其他方案的区别

| 特性 | chez-async | 传统 C 包装 | 纯 Scheme 实现 |
|------|-----------|------------|---------------|
| 性能 | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐ |
| 维护成本 | 低 | 高 | 中 |
| 跨平台 | 优秀 | 需编译 | 优秀 |
| 线程安全 | 原生支持 | 依赖实现 | 有限 |
| 事件循环 | libuv (工业级) | 自定义 | select/poll |

### 核心优势

1. **工业级事件循环**: 基于 libuv，被 Node.js、Julia 等项目验证
2. **原生线程池**: 自主实现 Chez Scheme 线程池，避免与 libuv 的 `uv_queue_work` 冲突
3. **简洁易用**: 简化的 API 命名，符合 Scheme 习惯
4. **完整文档**: 详细的指南、API 参考和示例代码
5. **测试覆盖**: 完整的测试套件，跨平台验证（Linux、FreeBSD）

---

## 核心特性

- **🚀 高性能**: 直接 FFI 绑定 libuv，零 C/C++ 包装层开销
- **🧵 原生线程池**: 自主实现 Chez Scheme 线程池，完全控制任务调度
- **🔒 线程安全**: 使用 `uv_async_t` 进行线程间通信，mutex 保护共享数据
- **💾 内存安全**: 自动 GC 管理，lock-object 防止对象被回收
- **📝 简洁 API**: 简化的命名规范（名称缩短 56%），更符合 Scheme 惯例
- **🔄 100% 向后兼容**: 旧 API 完全保留，平滑迁移
- **🎯 事件驱动**: libuv 事件循环，非阻塞 I/O
- **⚡ 异步任务**: 支持 CPU 密集型和阻塞型后台任务

---

## 项目状态

**当前阶段**: Phase 1-2 完成（基础设施 + Timer + Threadpool）

### 已实现功能

- ✅ 事件循环（Event Loop）
- ✅ 句柄基础操作（关闭、引用计数）
- ✅ 定时器（Timer）- 单次和重复
- ✅ 错误处理和条件类型
- ✅ 回调管理基础设施
- ✅ 内存管理和 GC 安全
- ✅ Chez Scheme 线程池系统
- ✅ 异步任务队列（async-work API）

### 计划实现

- ⏳ TCP 套接字
- ⏳ 文件系统操作
- ⏳ UDP 套接字
- ⏳ 其他句柄类型（Pipe, TTY, Signal, Process 等）
- ⏳ DNS 解析
- ⏳ 高层 Promise/Future 风格 API

## 架构设计

本项目采用直接 FFI 绑定方式，参考 chez-socket 的设计模式，避免 C/C++ 包装层：

```
High-Level API (high-level/)  ← Promise/Future 风格（计划中）
    ↓
Low-Level API (low-level/)    ← 主要用户接口
    ↓
FFI Layer (ffi/)              ← 直接 C 绑定
    ↓
libuv C Library
```

### 线程管理策略

**核心特性**：本库实现了自己的 Chez Scheme 线程池，不使用 libuv 的 `uv_queue_work` API。

**架构**：
```
用户任务 → Chez 线程池 → 工作线程执行 → uv_async_t 通知 → 主线程回调
```

**优势**：
- 完全控制线程生命周期和任务调度
- 避免 Chez 线程锁定机制与 libuv 冲突
- 使用 `uv_async_t` 安全地跨线程通信
- 支持用户自定义的 CPU 密集型任务

**实施**：
- 异步任务队列使用 mutex 和 condition variables
- 工作线程使用 Chez Scheme 的线程系统
- 结果通过 `uv_async_send` 通知主线程
- 文件系统等内置异步 API 仍使用 libuv 内部线程池

## 快速开始

### 前置要求

- **Chez Scheme** (version 10.0 or higher recommended)
- **libuv** development package (version 1.x)

#### 在 Debian/Ubuntu 上安装：

```bash
sudo apt-get install chezscheme libuv1-dev
```

#### 在 macOS 上安装：

```bash
brew install chezscheme libuv
```

#### 在 Fedora/RHEL 上安装：

```bash
sudo dnf install chezscheme libuv-devel
```

#### 在 FreeBSD 上安装：

```bash
sudo pkg install chez-scheme libuv
```

#### 验证安装：

```bash
scheme --version
pkg-config --modversion libuv
```

### 示例：简单定时器

```scheme
#!/usr/bin/env scheme-script

(import (chezscheme)
        (chez-async))  ; 统一导入

;; 创建事件循环
(define loop (uv-loop-init))

;; 创建定时器
(define timer (uv-timer-init loop))

;; 使用简化 API 检查句柄
(printf "Timer type: ~a~n" (handle-type timer))
(printf "Is closed?: ~a~n" (handle-closed? timer))

;; 启动 1 秒后触发的单次定时器
(uv-timer-start! timer 1000 0
  (lambda (t)
    (printf "Timer fired!~n")
    (uv-handle-close! t)))

;; 运行事件循环
(uv-run loop 'default)

;; 清理
(uv-loop-close loop)
```

### 示例：重复定时器

```scheme
(import (chezscheme) (chez-async))

(define loop (uv-loop-init))
(define timer (uv-timer-init loop))
(define count 0)

;; 每 500ms 触发一次
(uv-timer-start! timer 500 500
  (lambda (t)
    (set! count (+ count 1))
    (printf "Tick ~a~n" count)
    (when (= count 5)
      (uv-timer-stop! t)
      (uv-handle-close! t))))

(uv-run loop 'default)
(uv-loop-close loop)
```

### 示例：后台任务（Async Work）

```scheme
#!/usr/bin/env scheme-script

(import (chezscheme) (chez-async))

;; CPU 密集型任务
(define (fib n)
  (if (<= n 1) n
      (+ (fib (- n 1)) (fib (- n 2)))))

(define loop (uv-loop-init))

;; 在后台线程执行计算
(async-work loop
  (lambda ()
    (printf "[Worker] Computing fib(40)...~n")
    (fib 40))
  (lambda (result)
    (printf "[Main] Result: ~a~n" result)
    (uv-stop loop)))

(printf "Event loop running (non-blocking)...~n")
(uv-run loop 'default)
(uv-loop-close loop)
```

## 运行示例

```bash
cd chez-async

# 运行 timer 示例
chmod +x examples/timer-demo.ss
./examples/timer-demo.ss

# 运行 async work 示例
chmod +x examples/async-work-demo.ss
./examples/async-work-demo.ss

# 运行测试
chmod +x tests/test-timer.ss
./tests/test-timer.ss
```

## API 文档

### 事件循环 API

```scheme
;; 创建和销毁
(uv-loop-init) → uv-loop
(uv-loop-close loop) → void
(uv-default-loop) → uv-loop

;; 运行
(uv-run loop mode) → int
  ;; mode: 'default | 'once | 'nowait

(uv-stop loop) → void

;; 状态查询
(uv-loop-alive? loop) → boolean
```

### Timer API

```scheme
;; 创建
(uv-timer-init loop) → uv-timer

;; 操作
(uv-timer-start! timer timeout repeat callback) → void
  ;; timeout: 首次触发延迟（毫秒）
  ;; repeat: 重复间隔（毫秒，0 表示单次）
  ;; callback: (lambda (timer) ...)

(uv-timer-stop! timer) → void
(uv-timer-again! timer) → void
(uv-timer-set-repeat! timer repeat) → void
(uv-timer-get-repeat timer) → uint64
(uv-timer-get-due-in timer) → uint64
```

### 句柄通用 API

```scheme
;; 句柄操作
(uv-handle-close! handle [callback]) → void
(uv-handle-ref! handle) → void
(uv-handle-unref! handle) → void
(uv-handle-has-ref? handle) → boolean
(uv-handle-active? handle) → boolean
(uv-handle-closing? handle) → boolean

;; 句柄包装器访问器（简化名称，推荐使用）
(handle? obj) → boolean
(handle-ptr handle) → pointer
(handle-type handle) → symbol
(handle-loop handle) → uv-loop
(handle-data handle) → any
(handle-data-set! handle data) → void
(handle-closed? handle) → boolean
(handle-close-callback handle) → procedure

;; 完整名称（向后兼容）
(make-uv-handle-wrapper ptr type loop) → handle
(uv-handle-wrapper? obj) → boolean
(uv-handle-wrapper-ptr handle) → pointer
(uv-handle-wrapper-scheme-data handle) → any
(uv-handle-wrapper-scheme-data-set! handle data) → void
;; ... 等等（旧名称仍然可用）
```

### 异步任务 API

```scheme
;; 提交后台任务
(async-work loop work-fn callback) → task-id
  ;; work-fn: (lambda () ...) - 在工作线程执行
  ;; callback: (lambda (result) ...) - 在主线程执行

;; 带错误处理的异步任务
(async-work/error loop work-fn success-cb error-cb) → task-id

;; 低层 API
(make-threadpool loop size) → threadpool
(threadpool-start! pool) → void
(threadpool-submit! pool work callback error-handler) → task-id
(threadpool-shutdown! pool) → void
```

### 错误处理

所有 API 在出错时会抛出 `&uv-error` 异常：

```scheme
(guard (e [(uv-error? e)
           (printf "UV Error: ~a (~a)~n"
                   (uv-error-name e)
                   (condition-message e))])
  (uv-timer-start! timer 1000 0 callback))
```

## 项目结构

```
chez-async/
├── internal/               # 内部工具和宏
│   ├── macros.ss           # FFI 和错误处理宏
│   └── utils.ss            # 通用工具函数
│
├── ffi/                    # FFI 底层绑定
│   ├── types.ss            # C 类型定义
│   ├── errors.ss           # 错误处理
│   ├── core.ss             # 核心 API
│   ├── handles.ss          # 句柄操作
│   ├── callbacks.ss        # 回调管理
│   ├── timer.ss            # Timer FFI
│   └── async.ss            # Async 句柄 FFI
│
├── low-level/              # 低层 Scheme 封装
│   ├── handle-base.ss      # 句柄包装器基础（简化 API）
│   ├── request-base.ss     # 请求包装器基础
│   ├── buffer.ss           # 缓冲区管理
│   ├── timer.ss            # Timer 高层封装
│   ├── async.ss            # Async 句柄封装
│   └── threadpool.ss       # 线程池核心实现
│
├── high-level/             # 高层 Scheme 风格接口
│   ├── event-loop.ss       # 事件循环封装
│   └── async-work.ss       # 异步任务 API
│
├── tests/                  # 测试套件
│   ├── test-framework.ss   # 测试框架
│   ├── test-timer.ss       # Timer 测试
│   └── test-async.ss       # Async work 测试
│
├── examples/               # 示例代码
│   ├── timer-demo.ss       # Timer 示例
│   └── async-work-demo.ss  # 后台任务示例
│
├── docs/                   # 完整文档
│   ├── guide/              # 用户指南
│   │   ├── getting-started.md
│   │   └── async-work.md
│   └── api/                # API 参考
│       └── timer.md
│
└── chez-async.ss           # 主库文件（统一导出）
```

## 内存管理

本库使用以下策略确保内存安全：

1. **句柄生命周期**：必须调用 `uv-handle-close!` 才能释放
2. **GC 保护**：使用 `lock-object` 防止 Scheme 对象被 GC
3. **资源清理**：在关闭回调中自动解锁所有对象
4. **回调注册**：防止 `foreign-callable` 被 GC

## 开发路线图

### Phase 1: 基础设施 ✅

- ✅ FFI 类型系统
- ✅ 错误处理和条件类型
- ✅ 回调管理基础设施
- ✅ 句柄/请求包装器
- ✅ 内存管理和 GC 安全
- ✅ 宏系统（代码生成）

### Phase 2: Timer & Threadpool ✅

- ✅ Timer API 实现
- ✅ Chez Scheme 线程池系统
- ✅ 异步任务队列（async-work API）
- ✅ uv_async_t 跨线程通信
- ✅ 测试和示例
- ✅ 简化 API 命名规范

### Phase 3: TCP（计划中）

- ⏳ Stream 基础
- ⏳ TCP 客户端和服务器
- ⏳ Echo 服务器示例

### Phase 4: 文件系统

- 异步文件操作
- 目录操作
- 文件元数据

### Phase 5: 其他功能

- UDP
- Pipe, TTY, Signal, Process
- DNS 解析

### Phase 6: 高层接口

- Promise/Future 风格 API
- 完整文档

## 📚 文档

### 指南

- **[Getting Started](docs/guide/getting-started.md)** - 快速入门教程
  - 安装和配置
  - 核心概念（事件循环、句柄、回调）
  - 简化 Handle API
  - 错误处理
  - 最佳实践

- **[Async Work Guide](docs/guide/async-work.md)** - 异步任务完整指南
  - 架构和线程安全
  - CPU 密集型和 I/O 密集型任务
  - 错误处理和调试
  - 性能优化
  - 常见问题

### API 参考

- **[Timer API](docs/api/timer.md)** - 定时器 API 完整参考
  - 单次和重复定时器
  - 8 种常用模式（Countdown, Debounce, Throttle, Rate Limiter 等）
  - 最佳实践
  - 完整示例代码

### 示例代码

- `examples/timer-demo.ss` - Timer 使用示例
- `examples/async-work-demo.ss` - 后台任务示例
- `tests/test-timer.ss` - Timer 测试套件

---

## 参考项目

- [libuv](https://libuv.org/) - 官方文档
- [chez-socket](https://github.com/arcfide/chez-socket) - 架构参考
- [chez-async](https://github.com/ufo5260987423/chez-async) - libuv 绑定参考

---

## 获取帮助

- **文档**: 查看 [Getting Started Guide](docs/guide/getting-started.md) 和 [API Reference](docs/api/timer.md)
- **示例**: 浏览 `examples/` 目录获取完整示例代码
- **问题**: 提交 GitHub Issue 报告 bug 或提问
- **讨论**: 通过 Pull Request 参与代码贡献

## 许可证

MIT License

## 贡献

欢迎贡献！请提交 Issue 或 Pull Request。

贡献指南：
1. Fork 本仓库
2. 创建特性分支 (`git checkout -b feature/amazing-feature`)
3. 提交更改 (`git commit -m 'Add amazing feature'`)
4. 推送到分支 (`git push origin feature/amazing-feature`)
5. 创建 Pull Request

## 致谢

- [libuv](https://libuv.org/) - 提供高性能跨平台异步 I/O
- [chez-socket](https://github.com/arcfide/chez-socket) - FFI 绑定设计参考
- Chez Scheme 社区 - 提供优秀的 Scheme 实现
