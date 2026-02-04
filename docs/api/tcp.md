# TCP API 参考

本文档描述 chez-async 的 TCP 套接字 API。

## 概述

TCP（传输控制协议）是一种面向连接的可靠传输协议。chez-async 提供了基于 libuv 的 TCP 实现，支持：

- TCP 服务器（监听和接受连接）
- TCP 客户端（连接到远程服务器）
- 全双工数据传输
- IPv4 和 IPv6

## 快速开始

### Echo 服务器

```scheme
(import (chez-async))

(let ([loop (uv-loop-init)]
      [server (uv-tcp-init loop)])

  ;; 绑定到本地地址
  (uv-tcp-bind server "127.0.0.1" 8080)

  ;; 监听连接
  (uv-tcp-listen server 128
    (lambda (srv err)
      (unless err
        (let ([client (uv-tcp-accept srv)])
          ;; 处理客户端连接
          (uv-read-start! client
            (lambda (stream data)
              (when (bytevector? data)
                ;; 回显数据
                (uv-write! stream data
                  (lambda (err) (uv-handle-close! stream))))))))))

  ;; 运行事件循环
  (uv-run loop 'default)
  (uv-loop-close loop))
```

### Echo 客户端

```scheme
(import (chez-async))

(let ([loop (uv-loop-init)]
      [client (uv-tcp-init loop)])

  ;; 连接到服务器
  (uv-tcp-connect client "127.0.0.1" 8080
    (lambda (tcp err)
      (unless err
        ;; 发送数据
        (uv-write! tcp "Hello, Server!"
          (lambda (err) #f))
        ;; 读取响应
        (uv-read-start! tcp
          (lambda (stream data)
            (when (bytevector? data)
              (printf "Received: ~a~n" (utf8->string data)))
            (uv-handle-close! stream))))))

  (uv-run loop 'default)
  (uv-loop-close loop))
```

## API 参考

### TCP 句柄创建

#### `(uv-tcp-init loop)` -> tcp-handle

创建新的 TCP 句柄。

**参数：**
- `loop` - 事件循环

**返回：** TCP 句柄包装器

**示例：**
```scheme
(let ([tcp (uv-tcp-init loop)])
  ;; 使用 tcp...
  (uv-handle-close! tcp))
```

#### `(uv-tcp-init-ex loop flags)` -> tcp-handle

创建 TCP 句柄，指定地址族。

**参数：**
- `loop` - 事件循环
- `flags` - 地址族标志（`AF_INET` 或 `AF_INET6`）

**返回：** TCP 句柄包装器

#### `(uv-tcp-open tcp fd)` -> void

打开已存在的文件描述符作为 TCP 句柄。

**参数：**
- `tcp` - TCP 句柄
- `fd` - 文件描述符

### TCP 服务器

#### `(uv-tcp-bind tcp addr port)` -> void
#### `(uv-tcp-bind tcp addr port flags)` -> void

绑定 TCP 套接字到本地地址。

**参数：**
- `tcp` - TCP 句柄
- `addr` - IP 地址字符串（如 `"127.0.0.1"` 或 `"::1"`）
- `port` - 端口号（0 表示让系统选择）
- `flags` - 可选，绑定标志

**示例：**
```scheme
;; 绑定到所有 IPv4 接口
(uv-tcp-bind tcp "0.0.0.0" 8080)

;; 绑定到本地回环
(uv-tcp-bind tcp "127.0.0.1" 3000)

;; 让系统选择端口
(uv-tcp-bind tcp "127.0.0.1" 0)
```

#### `(uv-tcp-listen tcp backlog callback)` -> void

开始监听传入连接。

**参数：**
- `tcp` - TCP 句柄（需要先绑定）
- `backlog` - 等待队列长度（通常为 128）
- `callback` - 连接回调 `(lambda (server error-or-#f) ...)`

**示例：**
```scheme
(uv-tcp-listen server 128
  (lambda (srv err)
    (if err
        (printf "Listen error: ~a~n" err)
        (let ([client (uv-tcp-accept srv)])
          ;; 处理客户端
          ))))
```

#### `(uv-tcp-accept server)` -> tcp-handle

接受传入的连接，返回新的 TCP 句柄。

**参数：**
- `server` - 服务器 TCP 句柄

**返回：** 新的 TCP 句柄（代表客户端连接）

### TCP 客户端

#### `(uv-tcp-connect tcp addr port callback)` -> void

连接到远程服务器。

**参数：**
- `tcp` - TCP 句柄
- `addr` - 远程 IP 地址字符串
- `port` - 远程端口号
- `callback` - 连接回调 `(lambda (tcp error-or-#f) ...)`

**示例：**
```scheme
(uv-tcp-connect client "192.168.1.1" 80
  (lambda (tcp err)
    (if err
        (printf "Connect failed: ~a~n" err)
        (printf "Connected!~n"))))
```

### 数据传输

#### `(uv-read-start! stream callback)` -> void

开始从 stream 读取数据。

**参数：**
- `stream` - Stream 句柄（TCP/Pipe/TTY）
- `callback` - 读取回调 `(lambda (stream data-or-error) ...)`
  - `data-or-error` 可能是：
    - `bytevector` - 读取到的数据
    - `#f` - EOF（连接关闭）
    - `error` - 错误对象

**示例：**
```scheme
(uv-read-start! tcp
  (lambda (stream data)
    (cond
      [(bytevector? data)
       (printf "Received ~a bytes~n" (bytevector-length data))]
      [(not data)
       (printf "Connection closed~n")
       (uv-handle-close! stream)]
      [else
       (printf "Error: ~a~n" data)
       (uv-handle-close! stream)])))
```

#### `(uv-read-stop! stream)` -> void

停止读取数据。

#### `(uv-write! stream data callback)` -> void

写入数据到 stream。

**参数：**
- `stream` - Stream 句柄
- `data` - `bytevector` 或 `string`
- `callback` - 写入完成回调 `(lambda (error-or-#f) ...)`

**示例：**
```scheme
(uv-write! tcp "Hello, World!"
  (lambda (err)
    (when err
      (printf "Write error: ~a~n" err))))
```

#### `(uv-try-write stream data)` -> integer

尝试同步写入数据（非阻塞）。

**参数：**
- `stream` - Stream 句柄
- `data` - `bytevector` 或 `string`

**返回：**
- 正数：成功写入的字节数
- 负数：错误码（`UV_EAGAIN` 表示需要等待）

#### `(uv-shutdown! stream callback)` -> void

关闭 stream 的写端（half-close）。

**参数：**
- `stream` - Stream 句柄
- `callback` - 完成回调 `(lambda (error-or-#f) ...)`

### TCP 选项

#### `(uv-tcp-nodelay! tcp enable?)` -> void

启用/禁用 TCP_NODELAY（禁用 Nagle 算法）。

对于低延迟应用（如游戏、实时通信），建议启用。

**参数：**
- `tcp` - TCP 句柄
- `enable?` - 布尔值

#### `(uv-tcp-keepalive! tcp enable?)` -> void
#### `(uv-tcp-keepalive! tcp enable? delay)` -> void

启用/禁用 TCP keepalive。

**参数：**
- `tcp` - TCP 句柄
- `enable?` - 布尔值
- `delay` - 发送第一个 keepalive 探测前的空闲时间（秒）

#### `(uv-tcp-simultaneous-accepts! tcp enable?)` -> void

启用/禁用同时接受多个连接（主要用于 Windows）。

### 地址信息

#### `(uv-tcp-getsockname tcp)` -> (ip . port)

获取本地地址。

**返回：** 点对 `(ip-string . port-number)`

**示例：**
```scheme
(let ([addr (uv-tcp-getsockname tcp)])
  (printf "Bound to ~a:~a~n" (car addr) (cdr addr)))
```

#### `(uv-tcp-getpeername tcp)` -> (ip . port)

获取远程地址。

**返回：** 点对 `(ip-string . port-number)`

### 地址处理

#### `(make-sockaddr-in ip port)` -> sockaddr-ptr

创建 IPv4 地址结构。

#### `(make-sockaddr-in6 ip port)` -> sockaddr-ptr

创建 IPv6 地址结构。

#### `(parse-address addr-string port)` -> sockaddr-ptr

解析地址字符串，自动检测 IPv4 或 IPv6。

#### `(sockaddr->string addr-ptr)` -> string

将 sockaddr 转换为 `"ip:port"` 格式的字符串。

#### `(free-sockaddr addr-ptr)` -> void

释放 sockaddr 结构的内存。

## 错误处理

TCP 操作可能抛出 `&uv-error` 条件。常见错误：

- `ECONNREFUSED` - 连接被拒绝
- `ETIMEDOUT` - 连接超时
- `EADDRINUSE` - 地址已被使用
- `EADDRNOTAVAIL` - 地址不可用
- `EPIPE` - 管道破裂（对端已关闭）

**示例：**
```scheme
(guard (e [(uv-error? e)
           (printf "Error ~a: ~a~n"
                   (uv-error-name e)
                   (condition-message e))])
  (uv-tcp-connect tcp "invalid" 80
    (lambda (tcp err) #f)))
```

## 最佳实践

### 1. 资源清理

始终在完成后关闭句柄：

```scheme
(uv-handle-close! tcp
  (lambda (handle)
    (printf "TCP handle closed~n")))
```

### 2. 错误处理

检查所有回调中的错误参数：

```scheme
(uv-tcp-connect tcp host port
  (lambda (tcp err)
    (if err
        (begin
          (printf "Connect failed: ~a~n" err)
          (uv-handle-close! tcp))
        (begin
          ;; 连接成功
          ))))
```

### 3. 缓冲区管理

对于大量数据传输，使用 `uv-try-write` 避免内存累积：

```scheme
(let ([written (uv-try-write tcp data)])
  (when (< written 0)
    ;; 需要等待，使用异步写入
    (uv-write! tcp data callback)))
```

### 4. 服务器性能

- 设置合适的 backlog（通常 128-1024）
- 使用 `uv-tcp-nodelay!` 降低延迟
- 考虑使用多进程处理高并发

## 完整示例

参见：
- `examples/tcp-echo-server.ss` - Echo 服务器
- `examples/tcp-echo-client.ss` - Echo 客户端
