# chez-async 快速入门

## 安装

### 前置要求

1. **Chez Scheme**（推荐 10.0 或更高版本）
2. **libuv** 开发包（1.x 版本）

#### Debian/Ubuntu：

```bash
sudo apt-get install chezscheme libuv1-dev
```

#### macOS：

```bash
brew install chezscheme libuv
```

#### Fedora/RHEL：

```bash
sudo dnf install chezscheme libuv-devel
```

#### FreeBSD：

```bash
sudo pkg install chez-scheme libuv
```

### 验证安装

检查版本：

```bash
scheme --version
pkg-config --modversion libuv
```

## 第一个程序

创建文件 `hello-timer.ss`：

```scheme
#!/usr/bin/env scheme-script

(import (chezscheme)
        (chez-async))

;; 创建事件循环
(define loop (uv-loop-init))

;; 创建定时器
(define timer (uv-timer-init loop))

;; 查看句柄信息（使用简化 API）
(printf "Timer type: ~a~n" (handle-type timer))
(printf "Is closed?: ~a~n" (handle-closed? timer))

;; 启动定时器（1 秒后触发）
(uv-timer-start! timer 1000 0
  (lambda (t)
    (printf "Hello from chez-async!~n")
    (uv-handle-close! t)))

;; 运行事件循环
(uv-run loop 'default)

;; 清理
(uv-loop-close loop)
```

运行：

```bash
chmod +x hello-timer.ss
./hello-timer.ss
```

输出：
```
Timer type: timer
Is closed?: #f
Hello from chez-async!
```

## 核心概念

### 事件循环

事件循环是 libuv 的核心。它持续运行，处理 I/O 事件并执行回调。

```scheme
;; 创建新的事件循环
(define loop (uv-loop-init))

;; 运行事件循环（阻塞直到没有更多事件）
(uv-run loop 'default)

;; 清理
(uv-loop-close loop)
```

### 运行模式

- `'default` - 运行直到没有活跃的句柄
- `'once` - 处理一个事件（可能阻塞）
- `'nowait` - 处理事件但不阻塞

示例：
```scheme
;; 运行一次并返回
(uv-run loop 'once)

;; 不阻塞地轮询
(uv-run loop 'nowait)
```

### 句柄

句柄是执行 I/O 操作的长期存活对象：

- **Timer** - 定时回调 ✅
- **Async** - 线程安全唤醒 ✅
- **TCP** - TCP 套接字 ✅
- **UDP** - UDP 套接字 ✅
- **Pipe** - 命名管道 ✅
- **TTY** - 终端 ✅
- **Signal** - 信号处理 ✅
- **Process** - 进程管理 ✅

#### 简化句柄 API

chez-async 提供了简化的句柄访问器：

```scheme
(define timer (uv-timer-init loop))

;; 简化 API（推荐）
(handle-type timer)        ; 返回: 'timer
(handle? timer)            ; 返回: #t
(handle-closed? timer)     ; 返回: #f
(handle-data timer)        ; 获取关联数据
(handle-data-set! timer data)  ; 存储自定义数据

;; 完整名称也可用（向后兼容）
(uv-handle-wrapper-type timer)
(uv-handle-wrapper? timer)
;; 等等
```

所有句柄使用完毕必须关闭：

```scheme
(uv-handle-close! handle [optional-callback])
```

### 回调

事件发生时执行回调：

```scheme
(uv-timer-start! timer 1000 0
  (lambda (timer-handle)
    ;; 定时器触发时运行
    (printf "Timer fired!~n")

    ;; 访问句柄数据
    (let ([data (handle-data timer-handle)])
      (printf "Data: ~a~n" data))))
```

### 存储自定义数据

使用 `handle-data` 将自定义数据与句柄关联：

```scheme
(define timer (uv-timer-init loop))

;; 存储自定义数据
(handle-data-set! timer '(count 0 name "my-timer"))

;; 在回调中读取
(uv-timer-start! timer 1000 0
  (lambda (t)
    (let ([data (handle-data t)])
      (printf "Timer data: ~s~n" data))))
```

## 错误处理

所有错误抛出 `&uv-error` 条件：

```scheme
(guard (e [(uv-error? e)
           (printf "Error: ~a~n" (uv-error-name e))
           (printf "Message: ~a~n" (condition-message e))
           (printf "Operation: ~a~n" (uv-error-operation e))])
  (uv-timer-start! timer 1000 0 callback))
```

常见错误码：
- `EINVAL` - 无效参数
- `ENOMEM` - 内存不足
- `EBADF` - 无效的文件描述符

## 内存管理

chez-async 自动管理内存：

1. 使用中的对象会被锁定防止 GC 回收
2. 句柄关闭时对象会被解锁
3. 使用完毕后始终关闭句柄

```scheme
;; 良好实践
(define timer (uv-timer-init loop))
(uv-timer-start! timer 1000 0
  (lambda (t)
    ;; 做一些工作...
    (uv-handle-close! t)))  ;; 始终关闭！

;; 带清理回调
(uv-handle-close! timer
  (lambda (h)
    (printf "Timer closed~n")))
```

## 异步任务（后台任务）

在后台线程中处理 CPU 密集型任务：

```scheme
(define loop (uv-loop-init))

;; 提交后台任务
(async-work loop
  (lambda ()
    ;; 在工作线程中运行
    (expensive-computation))
  (lambda (result)
    ;; 在主线程中运行
    (printf "Result: ~a~n" result)
    (uv-stop loop)))

(uv-run loop 'default)
(uv-loop-close loop)
```

详见 [异步任务指南](async-work.md)。

## API 风格

### 命名约定

chez-async 提供两种命名风格：

**简化版（推荐）**：
- 更短、更 Scheme 风格
- 示例：`handle-type`、`handle-data-set!`

**完整名称（向后兼容）**：
- 原始详细名称
- 示例：`uv-handle-wrapper-type`、`uv-handle-wrapper-scheme-data-set!`

两种风格功能完全相同，根据偏好选择。

### 函数命名模式

- `foo?` - 谓词（返回布尔值）
- `foo!` - 修改操作（有副作用）
- `foo-set!` - 设置函数
- `make-foo` - 构造函数

## 最佳实践

### 1. 始终关闭句柄

```scheme
;; 错误
(define timer (uv-timer-init loop))
(uv-timer-start! timer 1000 0 callback)
;; 忘记关闭！

;; 正确
(uv-timer-start! timer 1000 0
  (lambda (t)
    (do-work)
    (uv-handle-close! t)))  ;; 完成后关闭
```

### 2. 使用错误处理

```scheme
;; 良好实践
(guard (e [else
           (fprintf (current-error-port)
                   "Error: ~a~n" e)])
  (uv-run loop 'default))
```

### 3. 正确清理

```scheme
;; 始终清理事件循环
(define loop (uv-loop-init))
(guard (e [else
           (uv-loop-close loop)
           (raise e)])
  (do-work loop))
(uv-loop-close loop)
```

## 常见模式

### 重复定时器

```scheme
(define count 0)
(uv-timer-start! timer 0 1000  ; 立即开始，每秒重复
  (lambda (t)
    (set! count (+ count 1))
    (printf "Tick ~a~n" count)
    (when (>= count 5)
      (uv-timer-stop! t)
      (uv-handle-close! t))))
```

### 多个定时器

```scheme
(define timer1 (uv-timer-init loop))
(define timer2 (uv-timer-init loop))

(uv-timer-start! timer1 1000 0 callback1)
(uv-timer-start! timer2 2000 0 callback2)

(uv-run loop 'default)
```

### 后台计算

```scheme
(async-work loop
  (lambda ()
    ;; 在工作线程中进行繁重计算
    (compute-fibonacci 40))
  (lambda (result)
    ;; 在主线程中处理结果
    (printf "Fibonacci: ~a~n" result)))
```

## 调试技巧

### 启用调试日志

```scheme
(import (chez-async internal utils))

;; 启用调试输出
(debug-enabled? #t)

;; 使用调试日志
(debug-log "Timer created: ~a~n" timer)
```

### 检查句柄状态

```scheme
(printf "Active?: ~a~n" (uv-handle-active? timer))
(printf "Closing?: ~a~n" (uv-handle-closing? timer))
(printf "Has ref?: ~a~n" (uv-handle-has-ref? timer))
```

## 下一步

- 阅读 [异步任务指南](async-work.md)
- 查看 [Timer API 参考](../api/timer.md)
- 探索 [示例代码](../../examples/)
- 浏览源代码了解高级用法

## 获取帮助

- GitHub Issues：报告 bug 或提问
- examples 目录：可运行的代码示例
- API 文档：详细参考
