# chez-async API 参考

本目录包含 chez-async 的完整 API 参考文档。

---

## 📚 API 文档索引

### 核心 API

| 文档 | 说明 |
|------|------|
| [async/await](../async-await-guide.md) | async/await 语法和 Promise API |
| [Combinators](../async-combinators-guide.md) | 组合器函数（all, race, any, timeout 等）|
| [Cancellation](../cancellation-guide.md) | 取消令牌 API |

### 网络 API

| 文档 | 说明 |
|------|------|
| [TCP API](tcp.md) | TCP 套接字完整参考 |
| UDP API | UDP 套接字（待补充） |
| Stream API | 流操作（待补充） |

### 文件系统 API

| 文档 | 说明 |
|------|------|
| FS API | 文件系统操作（待补充） |
| FS Watch API | 文件监控（待补充） |

### 系统 API

| 文档 | 说明 |
|------|------|
| [Timer API](timer.md) | 定时器完整参考 |
| DNS API | DNS 解析（待补充） |
| Process API | 进程管理（待补充） |
| Signal API | 信号处理（待补充） |

---

## 🚀 快速链接

### 按使用场景

**网络编程**
- [TCP 服务器](tcp.md#tcp-服务器)
- [TCP 客户端](tcp.md#tcp-客户端)
- [Stream 读写](tcp.md#数据传输)

**异步编程**
- [async/await 基础](../async-await-guide.md#基础用法)
- [Promise 链式调用](../async-await-guide.md#promise-链式调用)
- [错误处理](../async-await-guide.md#错误处理)

**并发控制**
- [并行等待（async-all）](../async-combinators-guide.md#async-all)
- [竞速（async-race）](../async-combinators-guide.md#async-race)
- [超时控制（async-timeout）](../async-combinators-guide.md#async-timeout)

**取消操作**
- [创建取消令牌](../cancellation-guide.md#基本用法)
- [注册取消回调](../cancellation-guide.md#取消回调)

---

## 📖 API 约定

### 命名规范

**修改操作** - `!` 后缀
```scheme
(uv-timer-start! timer ...)
(uv-handle-close! handle ...)
```

**谓词** - `?` 后缀
```scheme
(promise-fulfilled? p)
(handle-closed? handle)
(token-cancelled? token)
```

**构造函数** - `make-*` 前缀
```scheme
(make-promise loop executor)
(make-cancellation-token-source)
```

### 回调约定

**错误优先回调**
```scheme
(lambda (handle error-or-#f)
  (if error-or-#f
      (handle-error error-or-#f)
      (handle-success handle)))
```

**数据回调**
```scheme
(lambda (stream data-or-error)
  (cond
    [(bytevector? data-or-error) ...] ; 成功
    [(not data-or-error) ...]         ; EOF
    [else ...]))                      ; 错误
```

### 错误处理

所有 API 在出错时抛出 `&uv-error` 异常：

```scheme
(guard (e [(uv-error? e)
           (printf "Error: ~a (~a)~n"
                   (uv-error-name e)
                   (condition-message e))])
  ;; API 调用
  )
```

---

## 💡 使用建议

### 1. 选择合适的 API 层次

```
High-Level (async/await)   ← 推荐：简洁易用
    ↓
Low-Level (uv-*)          ← 需要更多控制时使用
    ↓
FFI (%ffi-uv-*)           ← 仅用于扩展库
```

### 2. 资源管理

始终关闭句柄：
```scheme
(uv-handle-close! handle
  (lambda (h)
    (printf "Handle closed~n")))
```

### 3. 错误处理

检查所有回调中的错误参数：
```scheme
(lambda (result err)
  (if err
      (handle-error err)
      (process-result result)))
```

### 4. 取消操作

为长时间运行的操作提供取消支持：
```scheme
(define cts (make-cancellation-token-source))
(define task (long-operation (cts 'token)))

;; 稍后取消
(cts 'cancel!)
```

---

## 📝 贡献

如果您发现 API 文档有误或希望补充内容，请：
1. 在 GitHub 上提交 Issue
2. 或直接提交 Pull Request

---

**文档版本**: 1.0.0
**最后更新**: 2026-02-05
