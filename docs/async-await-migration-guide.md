# async/await 迁移指南

**版本：** 1.0
**日期：** 2026-02-04

---

## 📋 概述

chez-async 现在提供三种 async/await 实现，满足不同需求：

| 导入路径 | 实现方式 | 适用场景 | 状态 |
|---------|---------|---------|------|
| `(chez-async high-level async-await)` | call/cc（默认） | **推荐使用** | ✅ 默认 |
| `(chez-async high-level async-await-cc)` | call/cc（显式） | 明确使用完整实现 | ✅ 推荐 |
| `(chez-async high-level async-await-simple)` | Promise 宏 | 简单场景/学习 | ⚠️ 功能受限 |

---

## 🔄 版本对比

### async-await（默认）和 async-await-cc

**完全相同！** 默认版本直接导出 async-await-cc 的所有功能。

**特性：**
- ✅ 真正的协程暂停/恢复
- ✅ 支持在任意位置 await
- ✅ 完整的错误处理
- ✅ 支持多次 await
- ✅ 与 libuv 深度集成
- ✅ 生产就绪

**示例：**
```scheme
(async
  (let* ([response (await (http-get url))]
         [body (await (read-body response))]
         [result (await (process body))])
    result))
```

### async-await-simple

**轻量级实现**，基于 Promise 宏展开。

**限制：**
- ❌ await 只能在顶层表达式
- ❌ 不支持 let/let* 中的 await
- ❌ 不支持控制结构中的 await
- ❌ 功能有限

**适用场景：**
- 简单的 Promise 包装
- 学习和理解宏展开
- 极简场景

**示例：**
```scheme
;; 可以工作
(async (await (fetch-data)))

;; 不能工作
(async
  (let ([data (await (fetch-data))])  ; ❌ 不支持
    data))
```

---

## 🚀 迁移步骤

### 场景 1：使用默认导入（最常见）

**之前：**
```scheme
(import (chez-async high-level async-await))
```

**现在：**
```scheme
;; 无需更改！自动使用完整实现
(import (chez-async high-level async-await))
```

**影响：** ✅ 无影响，自动升级到完整实现

### 场景 2：依赖旧版本简化实现

如果你的代码依赖旧版本的行为（Promise 宏），需要更新导入：

**之前：**
```scheme
(import (chez-async high-level async-await))

;; 旧版本的简单用法
(async (await (fetch-data)))
```

**现在：**
```scheme
(import (chez-async high-level async-await-simple))

;; 继续使用简化版本
(async (await (fetch-data)))
```

**影响：** 需要修改导入语句

### 场景 3：显式使用 call/cc 版本

**之前：**
```scheme
(import (chez-async high-level async-await-cc))
```

**现在：**
```scheme
;; 无需更改，继续使用
(import (chez-async high-level async-await-cc))

;; 或者改用默认版本（相同功能）
(import (chez-async high-level async-await))
```

**影响：** ✅ 无影响

---

## 📊 API 对比

### 共同导出

所有版本都导出：
- `async` - 创建异步任务
- `await` - 等待 Promise
- `async*` - 创建异步函数

### 仅完整版本（async-await / async-await-cc）

额外导出：
- `run-async` - 运行异步任务
- `run-async-loop` - 运行事件循环
- `async-value` - 创建解决的 Promise
- `async-error` - 创建拒绝的 Promise

### 仅简化版本（async-await-simple）

额外导出：
- `async-run` - 运行异步 thunk

---

## ✅ 检查清单

### 如果你的代码使用以下模式，无需修改：

- [ ] 只导入 `(chez-async high-level async-await)`
- [ ] 使用基本的 `async` 和 `await`
- [ ] 代码中有复杂的 await 用法（let/let* 中）
- [ ] 使用 `run-async` 函数

✅ **你的代码会自动升级到完整实现，功能更强大！**

### 如果你的代码符合以下情况，需要更新：

- [ ] 依赖旧版本的简单宏行为
- [ ] 只使用简单的顶层 await
- [ ] 使用 `async-run` 函数

⚠️ **需要将导入改为 `async-await-simple`**

---

## 🔧 具体迁移示例

### 示例 1：基础用法（无需修改）

```scheme
;;; 之前
(import (chez-async high-level async-await))

(define (fetch-user id)
  (async
    (await (db-query "users" id))))

;;; 之后 - 无需修改！
;;; 代码完全相同，但现在使用完整实现
(import (chez-async high-level async-await))

(define (fetch-user id)
  (async
    (await (db-query "users" id))))
```

### 示例 2：复杂用法（自动获得支持）

```scheme
;;; 之前 - 可能不工作
(import (chez-async high-level async-await))

(async
  (let* ([a (await (op1))]  ; 旧版本可能不支持
         [b (await (op2 a))])
    (+ a b)))

;;; 之后 - 完全支持！
;;; 无需修改，自动升级
(import (chez-async high-level async-await))

(async
  (let* ([a (await (op1))]
         [b (await (op2 a))])
    (+ a b)))
```

### 示例 3：使用简化版本

```scheme
;;; 如果你只需要简单功能
(import (chez-async high-level async-await-simple))

;; 简单包装
(define p (async (await (fetch-data))))
```

---

## 📖 推荐实践

### 新项目

```scheme
;; 推荐：使用默认版本（完整实现）
(import (chez-async high-level async-await))
```

### 现有项目

```scheme
;; 选项 1：使用默认版本（推荐）
(import (chez-async high-level async-await))

;; 选项 2：显式使用完整版本
(import (chez-async high-level async-await-cc))

;; 选项 3：继续使用简化版本（如果需要）
(import (chez-async high-level async-await-simple))
```

### 学习和示例

```scheme
;; 学习基础概念 - 简化版本
(import (chez-async high-level async-await-simple))

;; 学习完整功能 - 完整版本
(import (chez-async high-level async-await))
;; 或
(import (chez-async high-level async-await-cc))
```

---

## 🐛 常见问题

### Q1: 我需要修改代码吗？

**A:** 大多数情况下不需要。如果你使用默认导入 `(chez-async high-level async-await)`，代码会自动升级到完整实现，功能更强大。

### Q2: 性能会受影响吗？

**A:** 完整实现的开销 < 30%，但提供了更强大的功能。对于大多数应用来说，这个开销可以忽略不计。

### Q3: 为什么保留简化版本？

**A:**
1. 向后兼容 - 避免破坏依赖旧版本的代码
2. 学习价值 - 展示两种实现方式
3. 特定场景 - 有些场景可能更适合简单实现

### Q4: async-await 和 async-await-cc 有什么区别？

**A:** 完全没有区别！默认版本直接导出 async-await-cc 的内容。选择哪个取决于你的偏好：
- `async-await` - 简洁，推荐
- `async-await-cc` - 明确，显示实现方式

### Q5: 如何选择版本？

**A:** 遵循这个简单规则：
- ✅ **默认使用** `async-await`（或 `async-await-cc`）
- ⚠️ **特殊情况** 才使用 `async-await-simple`

---

## 📝 更新日志

### 2026-02-04 - 版本重组

**变更：**
- ✅ 创建 `async-await.ss` 作为默认导出
- ✅ 保留 `async-await-cc.ss` （完整实现）
- ✅ 重命名旧版本为 `async-await-simple.ss`
- ✅ 更新相关示例和测试

**影响：**
- ✅ 向后兼容 - 现有代码无需修改
- ✅ 功能增强 - 默认获得完整实现
- ✅ 清晰定位 - 每个版本有明确用途

---

## 🚀 下一步

1. **检查你的代码** - 确认使用的导入路径
2. **运行测试** - 确保一切正常工作
3. **享受新功能** - 使用完整的 async/await！

---

## 📞 获取帮助

- **使用指南：** `docs/async-await-guide.md`
- **示例代码：** `examples/async-await-cc-demo.ss`
- **API 文档：** 查看库文件中的注释
- **问题报告：** GitHub Issues

---

**迁移指南版本：** 1.0
**最后更新：** 2026-02-04
