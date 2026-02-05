# chez-async 文档索引

本目录包含 chez-async 项目的完整文档。

---

## 核心文档

### 快速开始

| 文档 | 说明 |
|------|------|
| [快速入门](guide/getting-started.md) | 安装和第一个程序 |
| [项目概述](../README.md) | 项目介绍和基本使用 |
| [项目状态](../PROJECT-STATUS.md) | 项目进度和指标 |

### 使用指南

| 文档 | 说明 |
|------|------|
| [async/await 指南](async-await-guide.md) | async/await 完整使用指南 |
| [组合器指南](async-combinators-guide.md) | 组合器使用指南（all、race、any、timeout 等）|
| [取消机制指南](cancellation-guide.md) | 取消令牌使用指南 |
| [TCP 编程指南](tcp-with-async-await.md) | 使用 async/await 进行 TCP 编程 |
| [异步任务指南](guide/async-work.md) | 线程池和后台任务指南 |

---

## 技术文档

### 实现原理

| 文档 | 说明 |
|------|------|
| [调度器架构](scheduler-architecture.md) | Loop、Scheduler 和 Pending 队列关联架构 |
| [async 宏实现详解](async-implementation-explained.md) | async/await 底层原理和 call/cc 机制 |
| [Promise 实现详解](promise-implementation-explained.md) | Promise 状态机和回调机制 |

---

## API 参考

| 文档 | 说明 |
|------|------|
| [API 完整索引](api/README.md) | 所有 API 函数的完整列表 |
| [Timer API](api/timer.md) | 定时器 API 完整参考 |
| [TCP API](api/tcp.md) | TCP 套接字 API 完整参考 |

---

## 推荐阅读路线

### 初学者路线

1. **[快速入门](guide/getting-started.md)** - 了解基础概念
2. **[async/await 指南](async-await-guide.md)** - 学习 async/await 基本用法
3. **[组合器指南](async-combinators-guide.md)** - 学习并发控制
4. **[TCP 编程指南](tcp-with-async-await.md)** - 实战 TCP 编程

### 进阶用户路线

1. **[取消机制指南](cancellation-guide.md)** - 学习取消机制
2. **[异步任务指南](guide/async-work.md)** - 理解线程池
3. **[调度器架构](scheduler-architecture.md)** - 理解调度器架构
4. **[async 宏实现详解](async-implementation-explained.md)** - 深入理解实现
5. **[Promise 实现详解](promise-implementation-explained.md)** - 深入理解 Promise

### API 参考

- **[API 完整索引](api/README.md)** - 所有 API 文档索引
- **[Timer API](api/timer.md)** - 定时器 API
- **[TCP API](api/tcp.md)** - TCP 套接字 API

---

## 快速查找

### 我想学习...

- **如何开始使用？** → [快速入门](guide/getting-started.md)
- **async/await 基础？** → [async/await 指南](async-await-guide.md)
- **并发控制？** → [组合器指南](async-combinators-guide.md)
- **取消操作？** → [取消机制指南](cancellation-guide.md)
- **TCP 编程？** → [TCP 编程指南](tcp-with-async-await.md)
- **后台任务？** → [异步任务指南](guide/async-work.md)

### 我想了解...

- **Loop、Scheduler 和队列的关系？** → [调度器架构](scheduler-architecture.md)
- **async 如何工作？** → [async 宏实现详解](async-implementation-explained.md)
- **Promise 如何实现？** → [Promise 实现详解](promise-implementation-explained.md)
- **项目状态和进展？** → [项目状态](../PROJECT-STATUS.md)

### 我想查阅...

- **完整 API 列表？** → [API 完整索引](api/README.md)
- **Timer API？** → [Timer API](api/timer.md)
- **TCP API？** → [TCP API](api/tcp.md)

---

## 贡献文档

如果您发现文档有误或希望补充内容，请：

1. 在 GitHub 上提交 Issue
2. 或直接提交 Pull Request

---

**文档创建：** 2026-02-05
**最后更新：** 2026-02-05
