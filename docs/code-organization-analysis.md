# chez-async 代码组织分析与合并建议

**分析日期：** 2026-02-04

---

## 📊 当前目录结构分析

### 1. 主代码目录

```
chez-async/
├── ffi/              # FFI 绑定层（24 个文件）
├── low-level/        # libuv 底层封装（24 个文件）
├── internal/         # 内部工具和调度器（9 个文件）
├── high-level/       # 高级 API（6 个文件）
├── examples/         # 示例程序（16 个文件）
├── tests/            # 测试套件（35+ 个文件）
├── docs/             # 文档
└── chez-async/       # 符号链接目录（用于标准库路径）
```

### 2. chez-async/ 子目录分析

**类型：** 符号链接包装目录

**内容：**
```
chez-async/
├── ffi -> ../ffi
├── high-level -> ../high-level
├── internal -> ../internal
├── low-level -> ../low-level
└── tests/
    └── framework.ss -> ../../tests/test-framework.ss
```

**目的：** 支持标准库导入路径，例如：
```scheme
(import (chez-async high-level promise))
```

**状态：** ✅ **合理设计，无需修改**

这是一个标准的 Scheme 库组织方式，允许：
- 代码在顶层目录开发和管理
- 通过符号链接提供标准化的导入路径
- 避免实际的代码重复

---

## 🔍 发现的重复和相似内容

### 重复 1：async-await 的两个版本

#### 文件对比

| 特性 | async-await.ss（旧） | async-await-cc.ss（新） |
|------|---------------------|----------------------|
| **实现方式** | Promise 链宏展开 | call/cc 协程 |
| **await 实现** | 直接返回 Promise | 暂停协程等待 |
| **async 实现** | 宏展开为 Promise 链 | 创建协程返回 Promise |
| **行数** | 86 行 | 158 行 |
| **复杂度** | 简单 | 中等 |
| **功能** | 基础语法糖 | 真正的 async/await |
| **错误处理** | 基本 | 完整（guard 集成）|
| **性能** | 基准 | < 30% 开销 |

#### 使用情况

**async-await.ss（旧版）使用者：**
- `examples/async-await-demo.ss`
- `tests/test-async-await.ss`

**async-await-cc.ss（新版）使用者：**
- `examples/async-await-cc-demo.ss` ✅
- `examples/async-real-world-demo.ss` ✅
- `tests/test-async-await-cc.ss` ✅
- `tests/test-async-simple.ss` ✅
- `tests/test-phase3-integration.ss` ✅
- 所有 debug 文件 ✅

**结论：** 新版本是主要使用的版本，功能更完整。

---

## 💡 合并建议

### 方案 A：保留两个版本（推荐）✅

**理由：**
1. **向后兼容：** 旧版本可能被外部项目使用
2. **不同用途：**
   - 旧版：轻量级，适合简单场景
   - 新版：功能完整，适合复杂场景
3. **学习价值：** 展示两种实现方式的对比

**实施步骤：**

#### 1. 重命名和明确定位

```bash
# 保留旧版本，但重命名以明确其定位
mv high-level/async-await.ss high-level/async-await-simple.ss
```

**更新库名称：**
```scheme
(library (chez-async high-level async-await-simple)
  ...
  ;; 简化版 async/await，基于 Promise 宏展开
  ;; 适合轻量级使用场景
  )
```

#### 2. 设置新版本为默认

创建一个默认导出，指向新版本：

```scheme
;;; high-level/async-await.ss - async/await 默认实现
;;;
;;; 默认使用基于 call/cc 的完整实现

(library (chez-async high-level async-await)
  (export
    async
    await
    async*
    run-async
    run-async-loop
    async-value
    async-error)

  ;; 直接导出新版本的所有内容
  (import (chez-async high-level async-await-cc)))
```

#### 3. 更新文档

添加选择指南：

```markdown
# 选择 async/await 实现

## async-await（默认）
- 完整的 call/cc 实现
- 真正的协程暂停/恢复
- 推荐用于生产环境

## async-await-simple
- 轻量级 Promise 宏
- 适合简单场景
- 学习用途

## async-await-cc
- 与默认版本相同
- 显式导入 call/cc 版本
```

### 方案 B：移除旧版本（不推荐）

**步骤：**
1. 删除 `high-level/async-await.ss`
2. 更新所有引用文件
3. 保留 async-await-cc.ss 作为唯一实现

**风险：**
- 破坏向后兼容性
- 可能影响外部项目

---

## 📁 目录结构优化建议

### 当前结构评估

```
✅ ffi/              - FFI 绑定，清晰
✅ low-level/        - libuv 封装，清晰
✅ internal/         - 内部工具，清晰
✅ high-level/       - 高级 API，清晰
✅ examples/         - 示例，清晰
✅ tests/            - 测试，清晰
✅ docs/             - 文档，清晰
✅ chez-async/       - 符号链接，合理
```

**结论：** 目录结构已经很好，无需重大改动。

### 小优化建议

#### 1. 文档组织

```
docs/
├── api/                    # API 文档
├── guide/                  # 使用指南
├── implementation/         # 实现文档（新增）
│   ├── phase1-complete.md
│   ├── phase2-complete.md
│   └── phase3-complete.md
└── design/                 # 设计文档（新增）
    ├── implementation-plan.md
    └── chez-socket-design-analysis.md
```

#### 2. 测试组织

```
tests/
├── unit/                   # 单元测试（新增）
│   ├── test-coroutine.ss
│   ├── test-promise.ss
│   └── test-timer.ss
├── integration/            # 集成测试（新增）
│   ├── test-async-await-cc.ss
│   └── test-phase3-integration.ss
└── debug/                  # 调试工具（新增）
    ├── debug-await-twice.ss
    └── debug-detailed-await.ss
```

---

## 🔄 具体合并步骤

### 步骤 1：备份当前状态

```bash
# 创建备份分支
git checkout -b backup-before-merge
git push origin backup-before-merge

# 回到主分支
git checkout main
```

### 步骤 2：重命名旧版本

```bash
# 重命名旧版本
git mv high-level/async-await.ss high-level/async-await-simple.ss

# 更新库名称
sed -i 's/chez-async high-level async-await)/chez-async high-level async-await-simple)/' high-level/async-await-simple.ss
```

### 步骤 3：创建默认导出

创建 `high-level/async-await.ss`:

```scheme
(library (chez-async high-level async-await)
  (export
    async await async*
    run-async run-async-loop
    async-value async-error)
  (import (chez-async high-level async-await-cc)))
```

### 步骤 4：更新使用旧版本的文件

```bash
# 更新 examples/async-await-demo.ss
sed -i 's/high-level async-await)/high-level async-await-simple)/' examples/async-await-demo.ss

# 更新 tests/test-async-await.ss
sed -i 's/high-level async-await)/high-level async-await-simple)/' tests/test-async-await.ss
```

### 步骤 5：组织测试目录（可选）

```bash
# 创建子目录
mkdir -p tests/unit tests/integration tests/debug

# 移动文件
mv tests/test-coroutine.ss tests/unit/
mv tests/test-promise.ss tests/unit/
mv tests/test-async-await-cc.ss tests/integration/
mv tests/debug-*.ss tests/debug/
```

### 步骤 6：更新文档

```bash
# 创建实现文档目录
mkdir -p docs/implementation docs/design

# 移动文档
mv docs/phase*.md docs/implementation/
mv docs/implementation-plan.md docs/design/
mv docs/chez-socket-*.md docs/design/
```

### 步骤 7：更新 README

添加关于两个版本的说明。

### 步骤 8：提交更改

```bash
git add -A
git commit -m "Reorganize async/await implementations

- Rename old async-await.ss to async-await-simple.ss
- Create new async-await.ss that exports async-await-cc
- Update documentation
- Organize test directory structure
- Maintain backward compatibility

Changes:
- high-level/async-await.ss: Now exports async-await-cc (default)
- high-level/async-await-simple.ss: Renamed from async-await.ss
- high-level/async-await-cc.ss: No changes (remains explicit import)

Migration guide:
- Default users: No changes needed
- Simple version users: Change import to async-await-simple
- Explicit cc users: No changes needed

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>"
```

---

## 📋 合并检查清单

### 准备阶段
- [ ] 创建备份分支
- [ ] 确认所有测试通过
- [ ] 审查所有使用 async-await 的文件

### 实施阶段
- [ ] 重命名 async-await.ss → async-await-simple.ss
- [ ] 创建新的 async-await.ss（导出 async-await-cc）
- [ ] 更新使用旧版本的文件
- [ ] 更新文档引用
- [ ] 组织测试目录（可选）

### 验证阶段
- [ ] 运行所有测试
- [ ] 验证示例程序
- [ ] 检查导入路径
- [ ] 更新文档

### 完成阶段
- [ ] 提交更改
- [ ] 更新 README
- [ ] 创建迁移指南
- [ ] 发布说明

---

## 📝 迁移指南

### 对于现有用户

#### 如果使用默认导入

```scheme
;; 之前
(import (chez-async high-level async-await))

;; 之后 - 无需更改！
;; 现在自动使用 async-await-cc（完整实现）
(import (chez-async high-level async-await))
```

#### 如果需要轻量级版本

```scheme
;; 使用简化版本
(import (chez-async high-level async-await-simple))
```

#### 如果显式使用 call/cc 版本

```scheme
;; 无需更改
(import (chez-async high-level async-await-cc))
```

---

## 🎯 推荐方案总结

### 最终结构

```
high-level/
├── async-await.ss          # 默认（导出 async-await-cc）
├── async-await-cc.ss       # 完整实现（call/cc）
├── async-await-simple.ss   # 简化实现（Promise 宏）
├── promise.ss              # Promise API
├── event-loop.ss           # 事件循环
└── ...
```

### 优势

1. **向后兼容：** 所有现有代码继续工作
2. **清晰定位：** 每个版本有明确的用途
3. **默认最佳：** 新用户自动获得最好的实现
4. **灵活选择：** 用户可以根据需求选择版本
5. **文档清晰：** 明确说明各版本的差异

### 风险

**最小：**
- 只是重命名和创建导出
- 不破坏任何现有功能
- 易于回滚

---

## 🚀 下一步行动

### 立即执行（高优先级）

1. ✅ 创建备份分支
2. ✅ 实施方案 A
3. ✅ 运行所有测试
4. ✅ 更新文档

### 短期（可选）

1. 组织测试目录
2. 组织文档目录
3. 添加迁移指南

### 长期（未来）

1. 考虑废弃 async-await-simple
2. 监控两个版本的使用情况
3. 收集用户反馈

---

**分析完成时间：** 2026-02-04
**推荐方案：** 方案 A - 保留两个版本，设置新版为默认
**下一步：** 开始实施合并步骤
