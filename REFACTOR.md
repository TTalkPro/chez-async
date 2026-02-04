# chez-async 重构计划

## 问题分析

### 1. 重复代码模式
- `load-shared-object` 在每个 FFI 文件中重复调用
- 回调工厂模式重复 10+ 次
- 请求分配/清理模式重复 20+ 次
- `c-string->string` 在 3 个文件中重复定义
- 同步操作包装器重复 11+ 次

### 2. 全局变量问题
- `*callback*` 类全局变量分散在各模块
- 没有统一的管理机制

### 3. 命名不一致
- 部分别名（`make-handle` / `make-uv-handle-wrapper`）
- 注释中英混杂

## 重构方案

### Phase 1: 集中库加载
创建 `ffi/lib.ss` 统一管理 libuv 库加载

### Phase 2: 增强宏系统
在 `internal/macros.ss` 添加：
- `define-lazy-callback` - 延迟初始化回调
- `with-uv-request` - 请求分配/执行/清理
- `define-sync-wrapper` - 生成同步版本

### Phase 3: 通用工具函数
创建 `internal/foreign-utils.ss`:
- `c-string->string` 统一实现
- 缓冲区操作工具
- 内存管理工具

### Phase 4: 应用重构
使用新宏重构 DNS 和 FS 模块

---
*创建日期: 2026-02-04*
