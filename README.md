# chez-async

Chez Scheme async programming library with libuv integration and native threadpool

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

- Chez Scheme 9.5 或更高版本
- libuv 1.x（开发包）

在 Debian/Ubuntu 上安装：

```bash
sudo apt-get install chezscheme libuv1-dev
```

### 示例：简单定时器

```scheme
#!/usr/bin/env scheme-script

(import (chezscheme)
        (chez-async high-level event-loop)
        (chez-async low-level timer)
        (chez-async low-level handle-base))

;; 创建事件循环
(define loop (uv-loop-init))

;; 创建定时器
(define timer (uv-timer-init loop))

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
(uv-handle-close! handle [callback]) → void
(uv-handle-ref! handle) → void
(uv-handle-unref! handle) → void
(uv-handle-has-ref? handle) → boolean
(uv-handle-active? handle) → boolean
(uv-handle-closing? handle) → boolean
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
├── ffi/                    # FFI 底层绑定
│   ├── types.ss            # C 类型定义
│   ├── errors.ss           # 错误处理
│   ├── core.ss             # 核心 API
│   ├── handles.ss          # 句柄操作
│   ├── requests.ss         # 请求操作
│   ├── callbacks.ss        # 回调管理
│   └── timer.ss            # Timer FFI
│
├── low-level/              # 低层 Scheme 封装
│   ├── handle-base.ss      # 句柄包装器基础
│   ├── request-base.ss     # 请求包装器基础
│   ├── buffer.ss           # 缓冲区管理
│   └── timer.ss            # Timer 高层封装
│
├── high-level/             # 高层 Scheme 风格接口
│   └── event-loop.ss       # 事件循环封装
│
├── tests/                  # 测试
│   ├── test-framework.ss   # 测试框架
│   └── test-timer.ss       # Timer 测试
│
├── examples/               # 示例代码
│   └── timer-demo.ss       # Timer 示例
│
└── README.md
```

## 内存管理

本库使用以下策略确保内存安全：

1. **句柄生命周期**：必须调用 `uv-handle-close!` 才能释放
2. **GC 保护**：使用 `lock-object` 防止 Scheme 对象被 GC
3. **资源清理**：在关闭回调中自动解锁所有对象
4. **回调注册**：防止 `foreign-callable` 被 GC

## 开发路线图

### Phase 1: 基础设施 ✅

- FFI 类型系统
- 错误处理
- 回调管理
- 句柄/请求包装器

### Phase 2: Timer ✅

- Timer API 实现
- 测试和示例

### Phase 3: TCP（进行中）

- Stream 基础
- TCP 客户端和服务器
- Echo 服务器示例

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

## 参考项目

- [libuv](https://libuv.org/) - 官方文档
- [chez-socket](https://github.com/arcfide/chez-socket) - 架构参考
- [chez-async](https://github.com/ufo5260987423/chez-async) - libuv 绑定参考

## 许可证

MIT License

## 贡献

欢迎贡献！请提交 Issue 或 Pull Request。

## 作者

基于计划文档实现
