# chez-async 内部架构

本文档描述 chez-async 的内部设计，帮助开发者理解代码结构。

## 模块分层

```
┌─────────────────────────────────────────────────────────┐
│                    用户代码                              │
└─────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────┐
│                 high-level/                              │
│   event-loop.ss  - 事件循环封装                          │
│   promise.ss     - Promise 抽象                          │
│   stream.ss      - 流操作封装                            │
└─────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────┐
│                  low-level/                              │
│   timer.ss, tcp.ss, udp.ss, pipe.ss, ...                │
│   handle-base.ss - 句柄基础操作                          │
└─────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────┐
│                    ffi/                                  │
│   core.ss      - libuv 核心 FFI                          │
│   handles.ss   - 句柄 FFI                                │
│   callbacks.ss - 回调桥接                                │
│   types.ss     - 类型定义                                │
│   errors.ss    - 错误处理                                │
└─────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────┐
│                 internal/                                │
│   loop-registry.ss    - 循环注册表                       │
│   callback-registry.ss - 回调注册表                      │
│   macros.ss           - 公共宏                           │
│   utils.ss            - 工具函数                         │
└─────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────┐
│                    libuv (C)                             │
└─────────────────────────────────────────────────────────┘
```

## 全局状态

chez-async 仅使用 2 个必要的全局变量，都是为了支持 C 回调查找 Scheme 对象：

| 变量 | 位置 | 用途 |
|------|------|------|
| `*callback-registry*` | internal/callback-registry.ss | 回调工厂注册 + GC 保护 |
| `*loop-registry*` | internal/loop-registry.ss | C 指针 -> loop 对象映射 |

**设计说明：** `*callback-registry*` 同时承担两个职责：
1. 延迟初始化回调工厂
2. 保持对 foreign-callable 的引用，防止 GC 回收

这样设计避免了冗余的全局状态。

## 回调系统架构

### 问题背景

libuv 回调是 C 函数指针，只传递 C 指针参数。我们需要：
1. 把 Scheme 函数包装成 C 可调用的形式
2. 在回调中找到对应的 Scheme 对象
3. 调用用户提供的 Scheme 回调

### 三层回调架构

```
┌─────────────────────────────────────────────────────────────┐
│ libuv C 层                                                   │
│   回调签名: void (*uv_timer_cb)(uv_timer_t* handle)         │
│   需要: C 函数指针                                           │
└──────────────────────────┬──────────────────────────────────┘
                           │ foreign-callable-entry-point
                           ▼
┌─────────────────────────────────────────────────────────────┐
│ *callback-registry* 桥接层                                   │
│   存储: foreign-callable (Scheme函数包装成C可调用)           │
│   作用: 查找 handle wrapper，调用用户回调                    │
└──────────────────────────┬──────────────────────────────────┘
                           │ (handle-data wrapper)
                           ▼
┌─────────────────────────────────────────────────────────────┐
│ 用户回调                                                     │
│   存储在: handle-data 字段                                   │
│   内容: (lambda (timer) (display "定时器触发"))              │
└─────────────────────────────────────────────────────────────┘
```

### `*callback-registry*` 详解

#### 数据结构

```scheme
*callback-registry* = eq-hashtable {
  回调类型键 -> (factory . instance)
}

;; 例如：
{
  'timer        -> (factory-thunk . foreign-callable或#f)
  'read         -> (factory-thunk . foreign-callable或#f)
  'write        -> (factory-thunk . foreign-callable或#f)
  'process-exit -> (factory-thunk . foreign-callable或#f)
  ...
}
```

- **factory**: 创建 foreign-callable 的 thunk（无参函数）
- **instance**: 已创建的 foreign-callable，或 `#f` 表示尚未创建

#### 回调类型常量

```scheme
;; 句柄回调
CALLBACK-CLOSE              ; 关闭回调
CALLBACK-TIMER              ; 定时器回调
CALLBACK-ASYNC              ; 异步唤醒回调

;; 流回调
CALLBACK-ALLOC              ; 内存分配回调
CALLBACK-READ               ; 读取回调
CALLBACK-WRITE              ; 写入回调
CALLBACK-SHUTDOWN           ; 关闭流回调
CALLBACK-CONNECTION         ; 连接监听回调

;; TCP 回调
CALLBACK-CONNECT            ; TCP 连接回调

;; DNS 回调
CALLBACK-GETADDRINFO        ; DNS 解析回调
CALLBACK-GETNAMEINFO        ; 反向 DNS 回调

;; 文件系统回调
CALLBACK-FS                 ; 通用 FS 回调
CALLBACK-FS-STAT            ; FS stat 回调
CALLBACK-FS-SCANDIR         ; FS scandir 回调
CALLBACK-FS-READLINK        ; FS readlink 回调

;; UDP 回调
CALLBACK-UDP-SEND           ; UDP 发送回调
CALLBACK-UDP-RECV           ; UDP 接收回调

;; 其他回调
CALLBACK-SIGNAL             ; 信号处理回调
CALLBACK-POLL               ; 文件描述符轮询回调
CALLBACK-PREPARE            ; Prepare 回调
CALLBACK-CHECK              ; Check 回调
CALLBACK-IDLE               ; Idle 回调
CALLBACK-FS-EVENT           ; FS Event 回调
CALLBACK-FS-POLL            ; FS Poll 回调
CALLBACK-PROCESS-EXIT       ; 进程退出回调
```

#### 工作流程

以 Timer 为例：

```scheme
;; 1. 模块加载时注册工厂（延迟初始化）
(define-registered-callback get-timer-callback CALLBACK-TIMER
  (lambda ()
    ;; factory: 创建 foreign-callable
    (make-timer-callback
      (lambda (wrapper)
        ;; 桥接逻辑
        (let ([user-callback (handle-data wrapper)])
          (when user-callback
            (user-callback wrapper)))))))

;; 2. 启动定时器时获取回调入口点
(define (uv-timer-start! timer timeout repeat callback)
  ;; 保存用户回调到 handle-data
  (handle-data-set! timer callback)
  ;; 获取通用回调的 C 入口点
  (%ffi-uv-timer-start (handle-ptr timer)
                       (get-timer-callback)  ; <- 这里
                       timeout repeat))

;; 3. 定时器触发时的调用链
libuv 调用 C 函数指针
  -> foreign-callable 执行
    -> 从 C 指针找到 wrapper: (ptr->wrapper handle-ptr)
      -> 从 wrapper 取用户回调: (handle-data wrapper)
        -> 调用用户回调: (user-callback wrapper)
```

#### 设计优点

1. **每种类型只需一个 foreign-callable** - 而不是每个 handle 都创建一个
2. **延迟初始化** - 只有实际使用某类型回调时才创建 foreign-callable
3. **内存效率** - foreign-callable 有开销，这样可以最小化数量
4. **统一管理** - 所有回调集中在一个注册表，便于调试和维护

## 循环注册系统

### `*loop-registry*` 详解

```scheme
*loop-registry* = eqv-hashtable {
  C指针(整数) -> loop对象
}
```

#### 用途

libuv 回调只提供 C 指针，我们需要找到对应的 Scheme 对象：

```scheme
;; 在回调中
(define (some-callback handle-ptr ...)
  ;; 1. 从 handle 获取 loop 指针
  (let* ([loop-ptr (uv-handle-get-loop handle-ptr)]
         ;; 2. 从全局注册表找到 loop 对象
         [loop (get-loop-by-ptr loop-ptr)]
         ;; 3. 从 loop 的 per-loop 注册表找到 handle wrapper
         [wrapper (loop-get-wrapper loop handle-ptr)])
    ...))
```

#### Per-loop 注册表

每个 loop 对象内部维护自己的句柄注册表：

```scheme
(define-record-type uv-loop
  (fields
    (immutable ptr)            ; uv_loop_t* C 指针
    (immutable ptr-registry)   ; hashtable: C 指针 -> handle wrapper
    (mutable threadpool)       ; 关联的线程池
    (immutable temp-buffers))) ; hashtable: 临时缓冲区
```

这种设计的优点：
- 多个 loop 互不影响
- 易于测试（可创建独立的测试 loop）
- 符合 libuv 的 per-loop 架构

## 句柄生命周期

```
创建 (uv-*-init)
  │
  ├── 分配 C 内存
  ├── 调用 libuv 初始化
  ├── 创建 Scheme wrapper
  └── 注册到 loop 的 ptr-registry
  │
  ▼
使用 (uv-*-start!, uv-*-stop!, ...)
  │
  ├── 保存用户回调到 handle-data
  ├── lock-object 防止 GC
  └── 调用 libuv 操作
  │
  ▼
关闭 (uv-handle-close!)
  │
  ├── 调用 libuv uv_close
  ├── 设置关闭标志
  └── (异步) close 回调执行时：
      ├── 从 ptr-registry 注销
      ├── unlock-object 用户回调
      └── 释放 C 内存
```

## 命名规范

### 函数命名

| 前缀 | 用途 | 示例 |
|------|------|------|
| `%ffi-uv-*` | 原始 FFI 绑定（私有） | `%ffi-uv-timer-init` |
| `uv-*` | 公开 API | `uv-timer-init` |
| `make-*` | 构造函数 | `make-handle` |
| `*-?` | 谓词 | `handle-closed?` |
| `*-!` | 修改操作 | `uv-timer-start!` |
| `*-set!` | setter | `handle-data-set!` |

### 常量命名

| 前缀 | 用途 | 示例 |
|------|------|------|
| `CALLBACK-*` | 回调类型 | `CALLBACK-TIMER` |
| `UV-*` | libuv 常量 | `UV-RUN-DEFAULT` |

### 全局变量

- 使用 `*name*` 格式（星号括起）
- 仅在必要时使用（C 互操作）
