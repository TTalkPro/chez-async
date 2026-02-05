# chez-async API 参考

本目录包含 chez-async 的完整 API 参考文档。

---

## 核心 API

### async/await

| 函数 | 说明 |
|------|------|
| `(async body ...)` | 创建异步任务，返回 Promise |
| `(await promise)` | 等待 Promise 完成，返回结果（仅在 async 块内使用） |
| `(async* (params ...) body ...)` | 创建异步函数 |
| `(run-async promise)` | 运行 async 任务直到完成 |

详细用法见：[async/await 指南](../async-await-guide.md)

### Promise

| 函数 | 说明 |
|------|------|
| `(make-promise loop executor)` | 创建 Promise |
| `(promise-then p on-fulfilled [on-rejected])` | 链式调用 |
| `(promise-catch p on-rejected)` | 捕获错误 |
| `(promise-finally p on-finally)` | 清理资源 |
| `(promise-resolved loop value)` | 创建已完成的 Promise |
| `(promise-rejected loop reason)` | 创建已拒绝的 Promise |
| `(promise? p)` | 检查是否为 Promise |
| `(promise-fulfilled? p)` | 检查是否已完成 |
| `(promise-rejected? p)` | 检查是否已拒绝 |

### 组合器

| 函数 | 说明 | 类似于 |
|------|------|--------|
| `(async-all promises)` | 等待所有完成 | `Promise.all` |
| `(async-race promises)` | 返回最快的 | `Promise.race` |
| `(async-any promises)` | 返回首个成功的 | `Promise.any` |
| `(async-timeout promise ms)` | 添加超时 | — |
| `(async-sleep loop ms)` | 延迟 | `setTimeout` |
| `(async-delay loop ms thunk)` | 延迟执行 | — |
| `(async-catch promise handler)` | 错误处理 | `.catch()` |
| `(async-finally promise cleanup)` | 资源清理 | `.finally()` |

详细用法见：[组合器指南](../async-combinators-guide.md)

### 取消令牌

| 函数 | 说明 |
|------|------|
| `(make-cancellation-token-source)` | 创建取消令牌源 |
| `(cts-token cts)` | 获取关联的令牌 |
| `(cts-cancel! cts)` | 取消令牌 |
| `(cts-cancelled? cts)` | 检查是否已取消 |
| `(token-cancelled? token)` | 检查令牌是否已取消 |
| `(token-register! token callback)` | 注册取消回调 |
| `(async-with-cancellation token promise)` | 可取消的异步操作 |
| `(linked-token-source token ...)` | 链接多个令牌 |

详细用法见：[取消机制指南](../cancellation-guide.md)

---

## 网络 API

### TCP API

| 函数 | 说明 |
|------|------|
| `(uv-tcp-init loop)` | 创建 TCP 句柄 |
| `(uv-tcp-init-ex loop flags)` | 指定地址族创建 TCP 句柄 |
| `(uv-tcp-open tcp fd)` | 用已有文件描述符打开 TCP |
| `(uv-tcp-bind tcp addr port [flags])` | 绑定到本地地址 |
| `(uv-tcp-listen tcp backlog callback)` | 开始监听 |
| `(uv-tcp-accept server)` | 接受连接 |
| `(uv-tcp-connect tcp addr port callback)` | 连接远程服务器 |
| `(uv-tcp-nodelay! tcp enable?)` | 设置 TCP_NODELAY |
| `(uv-tcp-keepalive! tcp enable? [delay])` | 设置 TCP keepalive |
| `(uv-tcp-simultaneous-accepts! tcp enable?)` | 同时接受多个连接 |
| `(uv-tcp-getsockname tcp)` | 获取本地地址 |
| `(uv-tcp-getpeername tcp)` | 获取远程地址 |

详细参考见：[TCP API](tcp.md)

### UDP API

| 函数 | 说明 |
|------|------|
| `(uv-udp-init loop)` | 创建 UDP 句柄 |
| `(uv-udp-init-ex loop flags)` | 指定标志创建 UDP 句柄 |
| `(uv-udp-open udp fd)` | 用已有文件描述符打开 UDP |
| `(uv-udp-bind udp addr port [flags])` | 绑定到本地地址 |
| `(uv-udp-connect udp addr port)` | 连接到远程地址 |
| `(uv-udp-disconnect udp)` | 断开连接 |
| `(uv-udp-send! udp data addr port callback)` | 发送数据 |
| `(uv-udp-try-send udp data addr port)` | 尝试同步发送 |
| `(uv-udp-recv-start! udp callback)` | 开始接收数据 |
| `(uv-udp-recv-stop! udp)` | 停止接收 |
| `(uv-udp-getsockname udp)` | 获取本地地址 |
| `(uv-udp-getpeername udp)` | 获取远程地址 |
| `(uv-udp-set-broadcast! udp enable?)` | 设置广播 |
| `(uv-udp-set-ttl! udp ttl)` | 设置 TTL |
| `(uv-udp-join-multicast-group! udp addr iface)` | 加入组播 |
| `(uv-udp-leave-multicast-group! udp addr iface)` | 离开组播 |

### Stream API

所有 TCP、Pipe、TTY 句柄都是 Stream，支持以下通用操作：

| 函数 | 说明 |
|------|------|
| `(uv-read-start! stream callback)` | 开始读取数据 |
| `(uv-read-stop! stream)` | 停止读取 |
| `(uv-write! stream data callback)` | 写入数据 |
| `(uv-try-write stream data)` | 尝试同步写入 |
| `(uv-shutdown! stream callback)` | 关闭写端（half-close） |
| `(uv-stream-readable? stream)` | 检查是否可读 |
| `(uv-stream-writable? stream)` | 检查是否可写 |

高级 Stream API（Promise 封装）：

| 函数 | 说明 |
|------|------|
| `(stream-read stream)` | 读取数据，返回 Promise |
| `(stream-write stream data)` | 写入数据，返回 Promise |
| `(stream-shutdown stream)` | 关闭写端，返回 Promise |
| `(stream-end stream)` | 结束 stream |
| `(stream-pipe source dest)` | 管道连接 |
| `(make-stream-reader stream)` | 创建流读取器 |

### Pipe API

| 函数 | 说明 |
|------|------|
| `(uv-pipe-init loop ipc?)` | 创建 Pipe 句柄 |
| `(uv-pipe-open pipe fd)` | 用已有文件描述符打开 |
| `(uv-pipe-bind pipe name)` | 绑定到路径 |
| `(uv-pipe-listen pipe backlog callback)` | 监听连接 |
| `(uv-pipe-accept server)` | 接受连接 |
| `(uv-pipe-connect pipe name callback)` | 连接到路径 |
| `(uv-pipe-getsockname pipe)` | 获取本地路径 |
| `(uv-pipe-getpeername pipe)` | 获取远程路径 |
| `(uv-pipe-pending-count pipe)` | 待处理句柄数量 |
| `(uv-pipe-pending-type pipe)` | 待处理句柄类型 |

---

## 文件系统 API

### 异步文件操作

| 函数 | 说明 |
|------|------|
| `(uv-fs-open loop path flags mode callback)` | 打开文件 |
| `(uv-fs-close loop fd callback)` | 关闭文件 |
| `(uv-fs-read loop fd buffer offset callback)` | 读取文件 |
| `(uv-fs-write loop fd buffer offset callback)` | 写入文件 |
| `(uv-fs-unlink loop path callback)` | 删除文件 |
| `(uv-fs-rename loop old-path new-path callback)` | 重命名文件 |
| `(uv-fs-copyfile loop src dst flags callback)` | 复制文件 |
| `(uv-fs-stat loop path callback)` | 获取文件信息 |
| `(uv-fs-fstat loop fd callback)` | 获取文件描述符信息 |
| `(uv-fs-lstat loop path callback)` | 获取符号链接信息 |
| `(uv-fs-mkdir loop path mode callback)` | 创建目录 |
| `(uv-fs-rmdir loop path callback)` | 删除目录 |
| `(uv-fs-scandir loop path callback)` | 扫描目录 |
| `(uv-fs-readlink loop path callback)` | 读取符号链接 |
| `(uv-fs-symlink loop path new-path callback)` | 创建符号链接 |
| `(uv-fs-link loop path new-path callback)` | 创建硬链接 |
| `(uv-fs-chmod loop path mode callback)` | 修改权限 |
| `(uv-fs-fchmod loop fd mode callback)` | 修改文件描述符权限 |
| `(uv-fs-chown loop path uid gid callback)` | 修改所有者 |
| `(uv-fs-ftruncate loop fd offset callback)` | 截断文件 |
| `(uv-fs-fsync loop fd callback)` | 同步到磁盘 |
| `(uv-fs-fdatasync loop fd callback)` | 同步数据到磁盘 |

### 同步文件操作

| 函数 | 说明 |
|------|------|
| `(uv-fs-open-sync loop path flags mode)` | 同步打开文件 |
| `(uv-fs-close-sync loop fd)` | 同步关闭文件 |
| `(uv-fs-read-sync loop fd buffer offset)` | 同步读取 |
| `(uv-fs-write-sync loop fd buffer offset)` | 同步写入 |
| `(uv-fs-stat-sync loop path)` | 同步获取文件信息 |
| `(uv-fs-mkdir-sync loop path mode)` | 同步创建目录 |
| `(uv-fs-rmdir-sync loop path)` | 同步删除目录 |
| `(uv-fs-unlink-sync loop path)` | 同步删除文件 |
| `(uv-fs-rename-sync loop old-path new-path)` | 同步重命名 |
| `(uv-fs-scandir-sync loop path)` | 同步扫描目录 |

### 文件监控

| 函数 | 说明 |
|------|------|
| `(uv-fs-event-init loop)` | 创建文件事件句柄 |
| `(uv-fs-event-start! handle path flags callback)` | 开始监控文件变化 |
| `(uv-fs-event-stop! handle)` | 停止监控 |
| `(uv-fs-event-getpath handle)` | 获取监控路径 |
| `(uv-fs-poll-init loop)` | 创建文件轮询句柄 |
| `(uv-fs-poll-start! handle path interval callback)` | 开始轮询文件变化 |
| `(uv-fs-poll-stop! handle)` | 停止轮询 |
| `(uv-fs-poll-getpath handle)` | 获取轮询路径 |

---

## 系统 API

### Timer API

| 函数 | 说明 |
|------|------|
| `(uv-timer-init loop)` | 创建定时器 |
| `(uv-timer-start! timer timeout repeat callback)` | 启动定时器 |
| `(uv-timer-stop! timer)` | 停止定时器 |
| `(uv-timer-again! timer)` | 重启定时器 |
| `(uv-timer-set-repeat! timer repeat)` | 设置重复间隔 |
| `(uv-timer-get-repeat timer)` | 获取重复间隔 |
| `(uv-timer-get-due-in timer)` | 获取剩余时间 |

详细参考见：[Timer API](timer.md)

### DNS API

| 函数 | 说明 |
|------|------|
| `(uv-getaddrinfo loop host service hints callback)` | 异步 DNS 解析 |
| `(uv-getnameinfo loop addr flags callback)` | 反向 DNS 解析 |
| `(resolve-hostname loop host callback)` | 简化的主机名解析 |
| `(resolve-hostname-sync loop host)` | 同步主机名解析 |

### Process API

| 函数 | 说明 |
|------|------|
| `(uv-spawn loop options callback)` | 创建子进程 |
| `(uv-process-kill! process signum)` | 向进程发送信号 |
| `(uv-process-get-pid process)` | 获取进程 PID |
| `(uv-kill pid signum)` | 向指定 PID 发送信号 |
| `(make-process-options ...)` | 创建进程选项 |

### Signal API

| 函数 | 说明 |
|------|------|
| `(uv-signal-init loop)` | 创建信号句柄 |
| `(uv-signal-start! signal signum callback)` | 开始监听信号 |
| `(uv-signal-start-oneshot! signal signum callback)` | 监听一次信号 |
| `(uv-signal-stop! signal)` | 停止监听 |
| `(signum->name signum)` | 信号编号转名称 |

支持的信号常量：`SIGINT`、`SIGTERM`、`SIGHUP`、`SIGQUIT`、`SIGUSR1`、`SIGUSR2`、`SIGCHLD` 等。

### Poll API

| 函数 | 说明 |
|------|------|
| `(uv-poll-init loop fd)` | 创建 Poll 句柄 |
| `(uv-poll-init-socket loop socket)` | 用套接字创建 Poll |
| `(uv-poll-start! poll events callback)` | 开始轮询 |
| `(uv-poll-stop! poll)` | 停止轮询 |

事件常量：`UV_READABLE`、`UV_WRITABLE`、`UV_DISCONNECT`

### 异步任务 API

| 函数 | 说明 |
|------|------|
| `(async-work loop work-fn callback)` | 提交后台任务 |
| `(async-work/error loop work-fn success-cb error-cb)` | 带错误处理的后台任务 |
| `(make-threadpool loop size)` | 创建线程池 |
| `(threadpool-start! pool)` | 启动线程池 |
| `(threadpool-submit! pool work callback error-handler)` | 直接提交任务 |
| `(threadpool-shutdown! pool)` | 关闭线程池 |

详细参考见：[异步任务指南](../guide/async-work.md)

---

## 通用句柄 API

所有句柄（Timer、TCP、UDP、Pipe、TTY、Signal、Process 等）都支持以下通用操作：

| 函数 | 说明 |
|------|------|
| `(handle? h)` | 检查是否为句柄 |
| `(handle-type h)` | 获取句柄类型 |
| `(handle-closed? h)` | 检查是否已关闭 |
| `(handle-ptr h)` | 获取 C 指针 |
| `(handle-data h)` | 获取关联数据 |
| `(handle-data-set! h data)` | 设置关联数据 |
| `(uv-handle-close! h [callback])` | 关闭句柄 |
| `(uv-handle-ref! h)` | 增加引用计数 |
| `(uv-handle-unref! h)` | 减少引用计数 |
| `(uv-handle-has-ref? h)` | 检查引用状态 |
| `(uv-handle-active? h)` | 检查是否活跃 |
| `(uv-handle-closing? h)` | 检查是否正在关闭 |

---

## 地址处理

| 函数 | 说明 |
|------|------|
| `(make-sockaddr-in ip port)` | 创建 IPv4 地址结构 |
| `(make-sockaddr-in6 ip port)` | 创建 IPv6 地址结构 |
| `(parse-address addr-string port)` | 自动检测 IPv4/IPv6 |
| `(sockaddr->string addr-ptr)` | 地址转字符串 |
| `(free-sockaddr addr-ptr)` | 释放地址内存 |

---

## API 约定

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

## 使用建议

### 1. 选择合适的 API 层次

```
High-Level (async/await)   <- 推荐：简洁易用
    |
Low-Level (uv-*)          <- 需要更多控制时使用
    |
FFI (%ffi-uv-*)           <- 仅用于扩展库
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

## 贡献

如果您发现 API 文档有误或希望补充内容，请：
1. 在 GitHub 上提交 Issue
2. 或直接提交 Pull Request

---

**文档版本**: 2.0.0
**最后更新**: 2026-02-05
