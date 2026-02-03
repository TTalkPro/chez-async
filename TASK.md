# chez-async 未完成任务清单

## 📊 项目完成度

**当前阶段**: Phase 1-2 完成 (约 30%)

| 类别 | 完成度 | 状态 |
|------|--------|------|
| 核心基础设施 | 100% | ✅ 完成 |
| 事件循环 | 100% | ✅ 完成 |
| Timer | 100% | ✅ 完成 |
| 异步任务 | 100% | ✅ 完成 |
| TCP 套接字 | 0% | ⏳ 待实现 |
| UDP 套接字 | 0% | ⏳ 待实现 |
| 文件系统 | 0% | ⏳ 待实现 |
| DNS 解析 | 0% | ⏳ 待实现 |
| 其他句柄 | 0% | ⏳ 待实现 |
| 高层抽象 | 0% | ⏳ 待实现 |

---

## ✅ 已完成功能

### Phase 1: 核心基础设施

- [x] FFI 类型系统和绑定
- [x] 错误处理（`&uv-error` 条件类型）
- [x] 回调管理基础设施
- [x] 内存管理（lock-object/unlock-object）
- [x] 宏系统（define-ffi, with-uv-check, with-locked 等）
- [x] 句柄包装器基础（handle-base.ss）
- [x] 请求包装器基础（request-base.ss）
- [x] 缓冲区管理（buffer.ss）

### Phase 2: Timer & Threadpool

- [x] 事件循环完整实现
  - [x] `uv-loop-init` / `uv-loop-close`
  - [x] `uv-default-loop`
  - [x] `uv-run` (default/once/nowait)
  - [x] `uv-stop`
  - [x] `uv-loop-alive?`
- [x] Timer 完整实现
  - [x] `uv-timer-init`
  - [x] `uv-timer-start!` / `uv-timer-stop!`
  - [x] `uv-timer-again!`
  - [x] `uv-timer-set-repeat!` / `uv-timer-get-repeat`
  - [x] `uv-timer-get-due-in`
- [x] Async 句柄
  - [x] `uv-async-init` / `uv-async-send!`
- [x] Chez Scheme 线程池
  - [x] 任务队列（mutex + condition variables）
  - [x] 工作线程管理
  - [x] `async-work` / `async-work/error`
  - [x] 低层线程池 API
- [x] 简化 API 命名规范
- [x] 完整文档和示例

---

## ⏳ 待实现功能

### Phase 3: TCP 套接字 (最高优先级)

#### 3.1 Stream 基础

- [ ] **FFI 绑定** (`ffi/stream.ss`)
  - [ ] `%ffi-uv-stream-size`
  - [ ] `%ffi-uv-read-start`
  - [ ] `%ffi-uv-read-stop`
  - [ ] `%ffi-uv-write`
  - [ ] `%ffi-uv-shutdown`
  - [ ] `%ffi-uv-listen`
  - [ ] `%ffi-uv-accept`
  - [ ] `%ffi-uv-is-readable`
  - [ ] `%ffi-uv-is-writable`

- [ ] **回调支持** (`ffi/callbacks.ss`)
  - [ ] `make-alloc-callback` - 内存分配回调
  - [ ] `make-read-callback` - 读取回调
  - [ ] `make-write-callback` - 写入回调
  - [ ] `make-connection-callback` - 连接回调
  - [ ] `make-shutdown-callback` - 关闭回调

- [ ] **低层封装** (`low-level/stream.ss`)
  - [ ] Stream 句柄包装器
  - [ ] `uv-read-start!` / `uv-read-stop!`
  - [ ] `uv-write!`
  - [ ] `uv-shutdown!`
  - [ ] `uv-listen!`
  - [ ] `uv-accept!`

#### 3.2 TCP 套接字

- [ ] **FFI 绑定** (`ffi/tcp.ss`)
  - [ ] `%ffi-uv-tcp-size`
  - [ ] `%ffi-uv-tcp-init`
  - [ ] `%ffi-uv-tcp-open`
  - [ ] `%ffi-uv-tcp-nodelay`
  - [ ] `%ffi-uv-tcp-keepalive`
  - [ ] `%ffi-uv-tcp-simultaneous-accepts`
  - [ ] `%ffi-uv-tcp-bind`
  - [ ] `%ffi-uv-tcp-getsockname`
  - [ ] `%ffi-uv-tcp-getpeername`
  - [ ] `%ffi-uv-tcp-connect`
  - [ ] `%ffi-uv-tcp-close-reset`

- [ ] **低层封装** (`low-level/tcp.ss`)
  - [ ] `uv-tcp-init`
  - [ ] `uv-tcp-open`
  - [ ] `uv-tcp-bind`
  - [ ] `uv-tcp-connect`
  - [ ] `uv-tcp-listen`
  - [ ] `uv-tcp-accept`
  - [ ] TCP 配置函数
    - [ ] `uv-tcp-nodelay!`
    - [ ] `uv-tcp-keepalive!`
    - [ ] `uv-tcp-simultaneous-accepts!`
  - [ ] 地址信息
    - [ ] `uv-tcp-getsockname`
    - [ ] `uv-tcp-getpeername`

- [ ] **地址处理** (`low-level/sockaddr.ss`)
  - [ ] `make-sockaddr-in` (IPv4)
  - [ ] `make-sockaddr-in6` (IPv6)
  - [ ] `sockaddr->string`
  - [ ] `string->sockaddr`

#### 3.3 测试和示例

- [ ] **测试** (`tests/test-tcp.ss`)
  - [ ] TCP 客户端连接测试
  - [ ] TCP 服务器监听测试
  - [ ] Echo 服务器测试
  - [ ] 多客户端并发测试
  - [ ] 错误处理测试

- [ ] **示例** (`examples/`)
  - [ ] `tcp-echo-server.ss` - Echo 服务器
  - [ ] `tcp-echo-client.ss` - Echo 客户端
  - [ ] `tcp-http-server.ss` - 简单 HTTP 服务器
  - [ ] `tcp-chat-server.ss` - 聊天服务器

- [ ] **文档** (`docs/api/tcp.md`)
  - [ ] TCP API 完整参考
  - [ ] 常用模式（echo server, HTTP server 等）
  - [ ] 最佳实践
  - [ ] 性能优化建议

**预计工作量**: 3-5 天

---

### Phase 4: 文件系统操作

#### 4.1 文件操作 FFI

- [ ] **FFI 绑定** (`ffi/fs.ss`)
  - [ ] `%ffi-uv-fs-open`
  - [ ] `%ffi-uv-fs-close`
  - [ ] `%ffi-uv-fs-read`
  - [ ] `%ffi-uv-fs-write`
  - [ ] `%ffi-uv-fs-unlink`
  - [ ] `%ffi-uv-fs-mkdir`
  - [ ] `%ffi-uv-fs-rmdir`
  - [ ] `%ffi-uv-fs-rename`
  - [ ] `%ffi-uv-fs-stat`
  - [ ] `%ffi-uv-fs-fstat`
  - [ ] `%ffi-uv-fs-lstat`
  - [ ] `%ffi-uv-fs-scandir`
  - [ ] `%ffi-uv-fs-readlink`
  - [ ] `%ffi-uv-fs-symlink`
  - [ ] `%ffi-uv-fs-chmod`
  - [ ] `%ffi-uv-fs-chown`
  - [ ] `%ffi-uv-fs-req-cleanup`

#### 4.2 低层封装

- [ ] **文件操作** (`low-level/fs.ss`)
  - [ ] `uv-fs-open`
  - [ ] `uv-fs-close`
  - [ ] `uv-fs-read`
  - [ ] `uv-fs-write`
  - [ ] `uv-fs-unlink`
  - [ ] `uv-fs-rename`
  - [ ] 文件元数据
    - [ ] `uv-fs-stat`
    - [ ] `uv-fs-fstat`
    - [ ] `uv-fs-lstat`
  - [ ] 目录操作
    - [ ] `uv-fs-mkdir`
    - [ ] `uv-fs-rmdir`
    - [ ] `uv-fs-readdir`
    - [ ] `uv-fs-scandir`
  - [ ] 权限和属性
    - [ ] `uv-fs-chmod`
    - [ ] `uv-fs-chown`

#### 4.3 高层 API

- [ ] **便利函数** (`high-level/fs.ss`)
  - [ ] `read-file-async` - 读取整个文件
  - [ ] `write-file-async` - 写入整个文件
  - [ ] `copy-file-async` - 复制文件
  - [ ] `list-directory-async` - 列出目录内容
  - [ ] `file-exists-async?` - 检查文件是否存在

#### 4.4 测试和文档

- [ ] **测试** (`tests/test-fs.ss`)
- [ ] **示例** (`examples/fs-demo.ss`)
- [ ] **文档** (`docs/api/fs.md`)

**预计工作量**: 2-3 天

---

### Phase 5: UDP 套接字

- [ ] **FFI 绑定** (`ffi/udp.ss`)
  - [ ] `%ffi-uv-udp-init`
  - [ ] `%ffi-uv-udp-bind`
  - [ ] `%ffi-uv-udp-send`
  - [ ] `%ffi-uv-udp-recv-start`
  - [ ] `%ffi-uv-udp-recv-stop`
  - [ ] `%ffi-uv-udp-set-membership`
  - [ ] `%ffi-uv-udp-set-multicast-loop`
  - [ ] `%ffi-uv-udp-set-multicast-ttl`
  - [ ] `%ffi-uv-udp-set-broadcast`
  - [ ] `%ffi-uv-udp-set-ttl`

- [ ] **低层封装** (`low-level/udp.ss`)
  - [ ] `uv-udp-init`
  - [ ] `uv-udp-bind`
  - [ ] `uv-udp-send`
  - [ ] `uv-udp-recv-start!` / `uv-udp-recv-stop!`
  - [ ] UDP 配置选项

- [ ] **测试和示例**
  - [ ] `tests/test-udp.ss`
  - [ ] `examples/udp-echo-server.ss`
  - [ ] `examples/udp-broadcast.ss`

- [ ] **文档** (`docs/api/udp.md`)

**预计工作量**: 2 天

---

### Phase 6: DNS 解析

- [ ] **FFI 绑定** (`ffi/dns.ss`)
  - [ ] `%ffi-uv-getaddrinfo`
  - [ ] `%ffi-uv-freeaddrinfo`
  - [ ] `%ffi-uv-getnameinfo`

- [ ] **低层封装** (`low-level/dns.ss`)
  - [ ] `uv-getaddrinfo` - 域名解析
  - [ ] `uv-getnameinfo` - 反向解析

- [ ] **高层 API** (`high-level/dns.ss`)
  - [ ] `resolve-hostname` - 简化的域名解析
  - [ ] 支持 IPv4/IPv6 选择

- [ ] **测试和文档**
  - [ ] `tests/test-dns.ss`
  - [ ] `examples/dns-lookup.ss`
  - [ ] `docs/api/dns.md`

**预计工作量**: 1 天

---

### Phase 7: Pipe (命名管道)

- [ ] **FFI 绑定** (`ffi/pipe.ss`)
  - [ ] `%ffi-uv-pipe-init`
  - [ ] `%ffi-uv-pipe-open`
  - [ ] `%ffi-uv-pipe-bind`
  - [ ] `%ffi-uv-pipe-connect`
  - [ ] `%ffi-uv-pipe-getsockname`
  - [ ] `%ffi-uv-pipe-getpeername`
  - [ ] `%ffi-uv-pipe-pending-instances`
  - [ ] `%ffi-uv-pipe-chmod`

- [ ] **低层封装** (`low-level/pipe.ss`)
- [ ] **测试和文档**

**预计工作量**: 1-2 天

---

### Phase 8: TTY (终端)

- [ ] **FFI 绑定** (`ffi/tty.ss`)
  - [ ] `%ffi-uv-tty-init`
  - [ ] `%ffi-uv-tty-set-mode`
  - [ ] `%ffi-uv-tty-reset-mode`
  - [ ] `%ffi-uv-tty-get-winsize`

- [ ] **低层封装** (`low-level/tty.ss`)
- [ ] **测试和文档**

**预计工作量**: 1 天

---

### Phase 9: Signal (信号处理)

- [ ] **FFI 绑定** (`ffi/signal.ss`)
  - [ ] `%ffi-uv-signal-init`
  - [ ] `%ffi-uv-signal-start`
  - [ ] `%ffi-uv-signal-stop`

- [ ] **低层封装** (`low-level/signal.ss`)
  - [ ] `uv-signal-init`
  - [ ] `uv-signal-start!` / `uv-signal-stop!`
  - [ ] 常见信号常量 (SIGINT, SIGTERM 等)

- [ ] **测试和文档**

**预计工作量**: 1 天

---

### Phase 10: Process (进程管理)

- [ ] **FFI 绑定** (`ffi/process.ss`)
  - [ ] `%ffi-uv-spawn`
  - [ ] `%ffi-uv-process-kill`
  - [ ] `%ffi-uv-kill`
  - [ ] `%ffi-uv-process-get-pid`

- [ ] **进程选项结构**
  - [ ] `uv_process_options_t` 封装
  - [ ] stdio 重定向配置
  - [ ] 环境变量设置

- [ ] **低层封装** (`low-level/process.ss`)
  - [ ] `uv-spawn`
  - [ ] `uv-process-kill!`
  - [ ] 进程退出回调

- [ ] **测试和文档**

**预计工作量**: 2-3 天

---

### Phase 11: Poll (文件描述符轮询)

- [ ] **FFI 绑定** (`ffi/poll.ss`)
  - [ ] `%ffi-uv-poll-init`
  - [ ] `%ffi-uv-poll-start`
  - [ ] `%ffi-uv-poll-stop`

- [ ] **低层封装** (`low-level/poll.ss`)
- [ ] **测试和文档**

**预计工作量**: 1 天

---

### Phase 12: 其他句柄类型

#### 12.1 Prepare / Check / Idle

- [ ] **FFI 绑定**
  - [ ] `ffi/prepare.ss`
  - [ ] `ffi/check.ss`
  - [ ] `ffi/idle.ss`

- [ ] **低层封装**
  - [ ] `low-level/prepare.ss`
  - [ ] `low-level/check.ss`
  - [ ] `low-level/idle.ss`

**用途**: 事件循环钩子，用于在事件循环的不同阶段执行回调

**预计工作量**: 1 天

#### 12.2 FS Event (文件系统监视)

- [ ] **FFI 绑定** (`ffi/fs-event.ss`)
  - [ ] `%ffi-uv-fs-event-init`
  - [ ] `%ffi-uv-fs-event-start`
  - [ ] `%ffi-uv-fs-event-stop`

- [ ] **低层封装** (`low-level/fs-event.ss`)
  - [ ] `uv-fs-event-init`
  - [ ] `uv-fs-event-start!` / `uv-fs-event-stop!`
  - [ ] 事件类型（rename, change）

- [ ] **测试和文档**

**预计工作量**: 1-2 天

#### 12.3 FS Poll (定期文件状态检查)

- [ ] **FFI 绑定** (`ffi/fs-poll.ss`)
- [ ] **低层封装** (`low-level/fs-poll.ss`)

**预计工作量**: 1 天

---

### Phase 13: 高层抽象

#### 13.1 Promise/Future 风格 API

- [ ] **核心实现** (`high-level/promise.ss`)
  - [ ] Promise 记录类型
  - [ ] `make-promise` / `promise-resolve` / `promise-reject`
  - [ ] `promise-then` / `promise-catch` / `promise-finally`
  - [ ] `promise-all` / `promise-race`
  - [ ] `promise->async-work` 转换

- [ ] **async/await 语法糖** (`high-level/async.ss`)
  - [ ] `async` 宏 - 定义异步函数
  - [ ] `await` 宏 - 等待 Promise
  - [ ] 基于 continuation 的实现

- [ ] **示例**
  - [ ] `examples/promise-demo.ss`
  - [ ] `examples/async-await-demo.ss`

**预计工作量**: 3-5 天

#### 13.2 Stream 抽象

- [ ] **Stream 协议** (`high-level/stream.ss`)
  - [ ] 统一的 stream 接口
  - [ ] `stream-read` / `stream-write`
  - [ ] `stream-pipe` - 管道连接
  - [ ] Backpressure 处理

- [ ] **Stream 组合器**
  - [ ] `map-stream`
  - [ ] `filter-stream`
  - [ ] `reduce-stream`

**预计工作量**: 2-3 天

#### 13.3 HTTP 实现

- [ ] **HTTP 解析器** (`high-level/http-parser.ss`)
  - [ ] HTTP 请求/响应解析
  - [ ] Header 解析
  - [ ] Chunked encoding 支持

- [ ] **HTTP 服务器** (`high-level/http-server.ss`)
  - [ ] 基于 TCP 的 HTTP 服务器
  - [ ] 中间件系统
  - [ ] 路由支持
  - [ ] 静态文件服务

- [ ] **HTTP 客户端** (`high-level/http-client.ss`)
  - [ ] GET/POST/PUT/DELETE 等方法
  - [ ] Header 管理
  - [ ] 连接池

- [ ] **示例**
  - [ ] `examples/http-hello-world.ss`
  - [ ] `examples/http-static-server.ss`
  - [ ] `examples/http-client-demo.ss`

**预计工作量**: 5-7 天

#### 13.4 WebSocket 实现

- [ ] **WebSocket 协议** (`high-level/websocket.ss`)
  - [ ] 握手处理
  - [ ] Frame 解析
  - [ ] Ping/Pong
  - [ ] 消息分片

- [ ] **WebSocket 服务器**
- [ ] **WebSocket 客户端**

**预计工作量**: 3-5 天

---

## 🎯 推荐实施顺序

根据依赖关系和实用性，推荐按以下顺序实施：

### 第一阶段：核心网络功能 (2-3 周)
1. **TCP 套接字** (Phase 3) - 最高优先级
   - Stream 基础
   - TCP 客户端和服务器
   - Echo 服务器示例

2. **DNS 解析** (Phase 6)
   - 使 TCP 客户端功能完整

3. **文件系统** (Phase 4)
   - 与 TCP 结合可构建完整 Web 服务器

### 第二阶段：扩展功能 (1-2 周)
4. **UDP 套接字** (Phase 5)
5. **Signal 处理** (Phase 9)
6. **Process 管理** (Phase 10)

### 第三阶段：系统集成 (1 周)
7. **Pipe** (Phase 7)
8. **TTY** (Phase 8)
9. **Poll** (Phase 11)
10. **其他句柄** (Phase 12)

### 第四阶段：高层抽象 (2-3 周)
11. **Promise/Future** (Phase 13.1)
12. **Stream 抽象** (Phase 13.2)
13. **HTTP** (Phase 13.3)
14. **WebSocket** (Phase 13.4)

---

## 📝 注意事项

### 技术债务
- [ ] 需要重构 buffer.ss 以支持 TCP 读写
- [ ] 需要实现更完善的错误码映射
- [ ] 需要添加性能测试套件

### 文档
- [ ] 每个新功能都需要配套文档
- [ ] 需要更新 Getting Started Guide
- [ ] 需要添加性能优化指南
- [ ] 需要添加故障排除指南

### 测试
- [ ] 需要增加集成测试
- [ ] 需要添加性能基准测试
- [ ] 需要测试多平台兼容性（Linux, macOS, FreeBSD, Windows）

### 社区
- [ ] 收集用户反馈
- [ ] 建立示例项目库
- [ ] 编写迁移指南（从其他 Scheme async 库）

---

## 📅 时间估算

| 阶段 | 内容 | 预计时间 |
|------|------|----------|
| Phase 3 | TCP 套接字 | 3-5 天 |
| Phase 4 | 文件系统 | 2-3 天 |
| Phase 5 | UDP 套接字 | 2 天 |
| Phase 6 | DNS 解析 | 1 天 |
| Phase 7-12 | 其他句柄 | 1-2 周 |
| Phase 13 | 高层抽象 | 2-3 周 |

**总计**: 约 **6-10 周** (按每天 4-6 小时工作量)

---

## 🚀 快速开始下一步

要开始实现 TCP 套接字（最高优先级），可以：

1. 创建 `ffi/stream.ss` - Stream FFI 绑定
2. 创建 `ffi/tcp.ss` - TCP FFI 绑定
3. 更新 `ffi/callbacks.ss` - 添加网络回调
4. 创建 `low-level/stream.ss` - Stream 封装
5. 创建 `low-level/tcp.ss` - TCP 封装
6. 创建 `tests/test-tcp.ss` - TCP 测试
7. 创建 `examples/tcp-echo-server.ss` - Echo 服务器示例
8. 编写 `docs/api/tcp.md` - TCP API 文档

---

*最后更新: 2026-02-03*
*基于 chez-async v0.2.0*
