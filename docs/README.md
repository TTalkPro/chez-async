# chez-async 文档索引

本目录包含 chez-async 项目的完整文档。

---

## 📚 核心文档

### 快速开始

| 文档 | 说明 |
|------|------|
| [Getting Started](guide/getting-started.md) | 快速入门指南 |
| [../README.md](../README.md) | 项目概述和基本使用 |
| [../PROJECT-STATUS.md](../PROJECT-STATUS.md) | 项目状态和进度 |

### 使用指南

| 文档 | 说明 |
|------|------|
| [async/await Guide](async-await-guide.md) | async/await 完整使用指南 |
| [Async Combinators Guide](async-combinators-guide.md) | 组合器使用指南（all, race, any, timeout 等）|
| [Cancellation Guide](cancellation-guide.md) | 取消令牌使用指南 |
| [TCP with async/await](tcp-with-async-await.md) | TCP 编程指南 |
| [Async Work Guide](guide/async-work.md) | 异步任务和线程池指南 |

---

## 🔧 技术文档

### 实现原理

| 文档 | 说明 |
|------|------|
| [async Implementation](async-implementation-explained.md) | async 宏实现详解 |
| [Promise Implementation](promise-implementation-explained.md) | Promise 实现详解 |

---

## 📖 API 参考

| 文档 | 说明 |
|------|------|
| [Timer API](api/timer.md) | Timer API 完整参考 |
| [TCP API](api/tcp.md) | TCP API 完整参考 |

---

## 📋 Phase 完成报告

| 文档 | 说明 |
|------|------|
| [Phase 1 Complete](phase1-complete.md) | 协程调度器实现完成 |
| [Phase 2 Complete](phase2-complete.md) | async/await 宏实现完成 |
| [Phase 3 Complete](phase3-complete.md) | libuv 深度集成完成 |
| [Phase 4 Complete](phase4-complete.md) | 高级特性实现完成 |

---

## 🎯 推荐阅读路线

### 初学者路线

1. **[Getting Started](guide/getting-started.md)** - 了解基础概念
2. **[async/await Guide](async-await-guide.md)** - 学习 async/await 基本用法
3. **[Async Combinators Guide](async-combinators-guide.md)** - 学习并发控制
4. **[TCP with async/await](tcp-with-async-await.md)** - 实战 TCP 编程

### 进阶用户路线

1. **[Cancellation Guide](cancellation-guide.md)** - 学习取消机制
2. **[Async Work Guide](guide/async-work.md)** - 理解线程池
3. **[async Implementation](async-implementation-explained.md)** - 深入理解实现
4. **[Promise Implementation](promise-implementation-explained.md)** - 深入理解 Promise

### API 参考

- **[Timer API](api/timer.md)** - 定时器 API
- **[TCP API](api/tcp.md)** - TCP 套接字 API

---

## 📊 文档统计

| 类型 | 数量 | 总行数 |
|------|------|--------|
| 使用指南 | 5 | ~2,500 |
| 技术文档 | 2 | ~1,400 |
| API 参考 | 2 | ~500 |
| 完成报告 | 4 | ~1,200 |
| **总计** | **13** | **~5,600** |

---

## 🔍 快速查找

### 我想学习...

- **如何开始使用？** → [Getting Started](guide/getting-started.md)
- **async/await 基础？** → [async/await Guide](async-await-guide.md)
- **并发控制？** → [Async Combinators Guide](async-combinators-guide.md)
- **取消操作？** → [Cancellation Guide](cancellation-guide.md)
- **TCP 编程？** → [TCP with async/await](tcp-with-async-await.md)
- **后台任务？** → [Async Work Guide](guide/async-work.md)

### 我想了解...

- **async 如何工作？** → [async Implementation](async-implementation-explained.md)
- **Promise 如何实现？** → [Promise Implementation](promise-implementation-explained.md)
- **项目的发展历程？** → [Phase 1-4 Complete Reports](phase1-complete.md)

### 我想查阅...

- **Timer API？** → [Timer API](api/timer.md)
- **TCP API？** → [TCP API](api/tcp.md)

---

## 💡 贡献文档

如果您发现文档有误或希望补充内容，请：

1. 在 GitHub 上提交 Issue
2. 或直接提交 Pull Request

---

**文档创建：** 2026-02-05
**最后更新：** 2026-02-05
**文档完整度：** ⭐⭐⭐⭐⭐ (5/5)
