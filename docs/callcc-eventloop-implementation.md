# 基于 call/cc 的 Event Loop 与 async/await 实现方案

## 基于 chez-socket 的深度分析与设计

### 1. chez-socket 核心设计精髓

#### 1.1 关键技术点

从 chez-socket 的 `coroutine-scheduler.ss` 分析得出的核心机制：

**三层队列模型：**
```scheme
coroutine-scheduler:
  - runnable:    ; 可立即执行的任务队列
  - pending:     ; 等待 I/O 的任务
  - timers:      ; 定时器队列（按 deadline 排序）
```

**核心原语 - yield-for-io!:**
```scheme
(define (yield-for-io! sched type fd)
  ;; 让出控制权等待 fd 就绪
  (call/cc
    (lambda (k)
      (register-wait! sched type fd k)  ; 保存 continuation
      (run-loop sched))))               ; 回到调度循环
```

**调度循环模式：**
```scheme
(define (run-loop sched)
  (process-expired-timers! sched)
  (cond
    [(stopped?) (exit)]
    [(has-runnable?) (execute-task) (loop)]
    [else (wait-for-io timeout) (loop)]))
```

#### 1.2 I/O 多路复用抽象

chez-socket 使用 `io-backend` 抽象层：
- **Linux**: epoll (O(1) 性能)
- **macOS/BSD**: kqueue (O(1) 性能)
- **其他**: poll (POSIX 标准)

### 2. chez-async 的适配方案

#### 2.1 架构对比

| 特性 | chez-socket | chez-async |
|------|-------------|------------|
| I/O 后端 | epoll/kqueue/poll | libuv |
| 任务调度 | call/cc 协程 | Promise 回调 |
| 事件循环 | 自实现调度循环 | libuv event loop |
| 跨平台 | Unix-like | 跨平台（含 Windows）|

#### 2.2 混合架构设计

**目标：** 在 libuv 事件循环之上添加 call/co 协程层

```
┌─────────────────────────────────────────────┐
│           async/await 语法层                 │
│  (async (await (http-get url)))             │
└──────────────────┬──────────────────────────┘
                   │
┌──────────────────▼──────────────────────────┐
│      call/cc 协程调度器                      │
│  - suspend: 保存 continuation               │
│  - resume: 恢复执行                         │
│  - 任务队列管理                             │
└──────────────────┬──────────────────────────┘
                   │
┌──────────────────▼──────────────────────────┐
│         Promise 层（现有）                    │
│  - make-promise                             │
│  - promise-then/catch                       │
└──────────────────┬──────────────────────────┘
                   │
┌──────────────────▼──────────────────────────┐
│         libuv 事件循环                       │
│  - uv_tcp, uv_timer, uv_fs 等               │
└─────────────────────────────────────────────┘
```

### 3. 核心实现

#### 3.1 协程任务定义

```scheme
;; internal/continuation.ss

(library (internal continuation)
  (export
    make-coroutine
    coroutine?
    coroutine-id
    coroutine-state
    coroutine-continuation
    coroutine-result
    coroutine-loop
    set-coroutine-state!
    set-coroutine-continuation!
    set-coroutine-result!
    current-coroutine)
  
  (import (chezscheme))
  
  ;; 协程状态
  (define-record-type coroutine
    (fields
      id                  ; 唯一标识符
      (mutable state)     ; 'created | 'running | 'suspended | 'completed
      (mutable continuation)  ; 保存的 call/cc continuation
      (mutable result)    ; 结果或错误
      (mutable loop))     ; 关联的 libuv loop
    
    (nongenerative
      (lambda (id)
        (format #t "Creating coroutine ~a~%" id)))
    
    (opaque #t))  ; 不透明类型，封装实现
  
  ;; 线程局部变量：当前协程
  (define current-coroutine
    (make-thread-parameter #f))
  
  ;; 生成唯一 ID
  (define coroutine-counter 0)
  (define (generate-id)
    (set! coroutine-counter (+ coroutine-counter 1))
    coroutine-counter))
```

#### 3.2 暂停和恢复原语

```scheme
;; internal/suspend-resume.ss

(library (internal suspend-resume)
  (export
    suspend-current!
    resume-coroutine!
    with-suspended)
  
  (import 
    (chezscheme)
    (internal continuation)
    (only (libuv loop) uv-default-loop))
  
  ;; 暂停当前协程
  (define (suspend-current! callback)
    "暂停当前协程，注册回调函数"
    (call/cc
      (lambda (k)
        (let ([coro (current-coroutine)])
          (unless coro
            (error 'suspend-current! "No current coroutine"))
          
          ;; 保存 continuation
          (set-coroutine-continuation! coro k)
          (set-coroutine-state! coro 'suspended)
          
          ;; 注册回调
          (callback
            (lambda (result)
              (resume-coroutine! coro result)))))))
  
  ;; 恢复协程
  (define (resume-coroutine! coro result)
    "将协程加入任务队列，准备恢复执行"
    (when (eq? (coroutine-state coro) 'suspended)
      (set-coroutine-result! coro result)
      (set-coroutine-state! coro 'running)
      
      ;; 将协程加入任务队列
      (let ([loop (coroutine-loop coro)])
        (uv-loop-enqueue! loop coro))))
  
  ;; 执行协程（从队列取出后调用）
  (define (execute-coroutine coro)
    (if (coroutine-continuation coro)
        ;; 恢复保存的 continuation
        ((coroutine-continuation coro) 
         (coroutine-result coro))
        ;; 首次执行
        (values)))
  
  ;; 辅助宏：with-suspended
  (define-syntax with-suspended
    (syntax-rules ()
      [(with-suspended (var) body ...)
       (suspend-current!
         (lambda (resume)
           (lambda (var)
             (resume var) ...))))]))
```

#### 3.3 async/await 宏实现

```scheme
;; high-level/async-await-cc.ss

(library (async-await-cc)
  (export
    async
    await
    spawn
    run-coroutines)
  
  (import
    (chezscheme)
    (internal continuation)
    (internal suspend-resume)
    (libuv loop))
  
  ;; ================================================================
  ;; async 宏 - 创建异步任务
  ;; ================================================================
  
  (define-syntax async
    (syntax-rules ()
      [(async body ...)
       (make-async-task
         (lambda ()
           body ...))]))
  
  (define (make-async-task thunk)
    (let* ([loop (uv-default-loop)]
           [coro (make-coroutine 
                   (generate-id)
                   'created
                   #f
                   #f
                   loop)])
      ;; 创建包装函数
      (let ([task 
             (lambda ()
               (parameterize ([current-coroutine coro])
                 (set-coroutine-state! coro 'running)
                 (let ([result (thunk)])
                   (set-coroutine-state! coro 'completed)
                   result)))])
        ;; 加入任务队列
        (uv-loop-enqueue! loop task)
        coro)))
  
  ;; ================================================================
  ;; await 宏 - 等待 Promise 完成
  ;; ================================================================
  
  (define-syntax await
    (syntax-rules ()
      [(await promise)
       (suspend-current!
         (lambda (resume)
           (promise-then promise
             (lambda (value)
               (resume value))
             (lambda (error)
               (raise error))))))
      [(await promise on-error)
       (suspend-current!
         (lambda (resume)
           (promise-then promise
             (lambda (value)
               (resume value))
             on-error)))]))
  
  ;; ================================================================
  ;; spawn - 启动协程
  ;; ================================================================
  
  (define-syntax spawn
    (syntax-rules ()
      [(spawn expr)
       (make-async-task
         (lambda ()
           expr))]))
  
  ;; ================================================================
  ;; run-coroutines - 运行所有协程
  ;; ================================================================
  
  (define (run-coroutines . args)
    "运行事件循环，直到所有协程完成"
    (apply uv-run args)))
```

### 4. 与 libuv 事件循环集成

#### 4.1 扩展 uv-loop

```scheme
;; libuv/loop-extension.ss

(library (libuv loop-extension)
  (export
    uv-loop-task-queue
    uv-loop-enqueue!)
  
  (import
    (chezscheme)
    (libuv loop)
    (internal continuation))
  
  ;; 扩展 uv-loop，添加任务队列
  ;; 注意：这可能需要修改 FFI 绑定
  
  (define (uv-loop-task-queue loop)
    "获取事件循环的任务队列"
    ;; 使用弱引用表存储任务队列
    (loop-tasks loop))
  
  (define (uv-loop-enqueue! loop task)
    "将任务加入队列"
    (let ([queue (uv-loop-task-queue loop)])
      (queue-push! queue task)))
  
  ;; 修改 uv-run 以处理任务队列
  (define (uv-run-with-tasks loop mode)
    "修改后的 uv-run，支持协程任务调度"
    (let ([queue (uv-loop-task-queue loop)])
      (let loop ()
        ;; 1. 执行所有准备好的任务
        (until (queue-empty? queue)
          (let ([task (queue-pop! queue)])
            (execute-coroutine task)))
        
        ;; 2. 运行 libuv 事件循环（一次迭代）
        (libuv-uv-run loop 'UV_RUN_ONCE)
        
        ;; 3. 如果还有任务或活跃句柄，继续
        (when (or (not (queue-empty? queue))
                  (has-active-handles? loop))
          (loop)))))
```

#### 4.2 libuv 回调适配

```scheme
;; internal/uv-callback-adapter.ss

(library (internal uv-callback-adapter)
  (export
    wrap-callback-for-coroutine)
  
  (import
    (chezscheme)
    (internal continuation)))
  
  ;; 将 libuv 回调包装为协程友好的形式
  (define (wrap-callback-for-coroutine callback)
    (lambda args
      (if (current-coroutine)
          ;; 在协程中，调用 suspend
          (suspend-current!
            (lambda (resume)
              (apply callback 
                     (lambda (result)
                       (resume result))
                     args)))
          ;; 不在协程中，直接调用
          (apply callback args))))
```

### 5. 使用示例

#### 5.1 基础用法

```scheme
;; examples/async-await-cc-demo.ss

#!/usr/bin/env scheme-script

(import (async-await-cc)
        (http-client))

;; 简单的 HTTP GET
(define (fetch-url url)
  (async
    (printf "Fetching ~a~n" url)
    (let ([response (await (http-get url))])
      (printf "Status: ~a~n" (response-status response))
      (let ([body (await (read-body response))])
        (printf "Received ~a bytes~n" (bytevector-length body))
        body))))

;; 并发获取多个 URL
(define (fetch-multiple urls)
  (async
    (let ([tasks (map (lambda (url) 
                        (spawn (fetch-url url)))
                      urls)])
      ;; 等待所有任务完成
      (for-each (lambda (task) 
                  (await-task task))
                tasks)
      "Done!")))

;; 主程序
(define (main)
  (fetch-multiple 
    '("https://example.com"
      "https://github.com"
      "https://scheme.com"))
  
  (run-coroutines))

(main)
```

#### 5.2 错误处理

```scheme
(define (safe-fetch url)
  (async
    (guard (ex
            [(http-error? ex)
             (printf "HTTP error: ~a~%" ex)
             #f]
            [else
             (printf "Unexpected error: ~a~%" ex)
             #f])
      (let ([response (await (http-get url))])
        (await (read-body response))))))
```

#### 5.3 超时处理

```scheme
(define (fetch-with-timeout url timeout-ms)
  (async
    (let ([result-promise (make-promise)])
      ;; 启动 HTTP 请求
      (spawn
        (let ([data (await (http-get url))])
          (promise-resolve! result-promise data)))
      
      ;; 启动超时定时器
      (spawn
        (await (sleep timeout-ms))
        (promise-reject! result-promise 
                        (make-timeout-error)))
      
      ;; 等待结果或超时
      (await result-promise))))
```

### 6. 实现步骤

#### Phase 1: 核心基础设施（2-3 天）

**文件结构：**
```
internal/
  ├── continuation.ss        ; 协程数据结构
  ├── suspend-resume.ss      ; suspend/resume 原语
  └── task-queue.ss          ; 任务队列管理
```

**任务清单：**
- [ ] 实现 `coroutine` 记录类型
- [ ] 实现 `current-coroutine` 线程参数
- [ ] 实现 `suspend-current!` 和 `resume-coroutine!`
- [ ] 实现任务队列（基于 libuv 弱引用表）
- [ ] 单元测试：suspend/resume 基础功能

#### Phase 2: async/await 宏（1-2 天）

**文件结构：**
```
high-level/
  └── async-await-cc.ss      ; async/await 语法
```

**任务清单：**
- [ ] 实现 `async` 宏
- [ ] 实现 `await` 宏（支持 Promise）
- [ ] 实现 `spawn` 宏
- [ ] 实现 `run-coroutines`
- [ ] 集成测试：基础 async/await 功能

#### Phase 3: libuv 集成（2-3 天）

**文件结构：**
```
libuv/
  ├── loop-extension.ss       ; 扩展 uv-run
  └── callback-adapter.ss     ; 回调适配器
```

**任务清单：**
- [ ] 扩展 `uv-loop` 添加任务队列
- [ ] 修改 `uv-run` 处理任务队列
- [ ] 实现 `wrap-callback-for-coroutine`
- [ ] 测试 libuv 回调与协程的交互

#### Phase 4: 高级特性（1-2 天）

**任务清单：**
- [ ] 超时支持 (`timeout`, `sleep`)
- [ ] 并发原语 (`wait-all`, `race`)
- [ ] 取消令牌 (`cancellation-token`)
- [ ] 资源管理 (`with-async-resource`)

#### Phase 5: 测试和文档（1-2 天）

**任务清单：**
- [ ] 完整的单元测试套件
- [ ] 性能基准测试
- [ ] API 文档
- [ ] 使用示例
- [ ] 迁移指南

**总工作量：** 7-12 天

### 7. 技术挑战与解决方案

#### 7.1 Continuation 与 libuv 的集成

**挑战：** libuv 的事件循环是 C 实现的，如何与 Scheme 的 continuation 协作？

**解决方案：**
1. **任务队列桥接**：在 libuv 每次事件循环迭代中执行 Scheme 任务
2. **回调包装**：将 libuv 回调包装为 continuation 恢复点
3. **弱引用表**：使用弱引用避免循环引用

#### 7.2 内存管理

**挑战：** continuation 可能捕获大量状态，导致内存占用高

**解决方案：**
1. **作用域最小化**：只捕获必要的 continuation
2. **及时清理**：协程完成后清理 continuation
3. **对象池**：重用 coroutine 对象

#### 7.3 错误处理

**挑战：** continuation 中的错误如何正确传播？

**解决方案：**
1. **guard 集成**：在 suspend/resume 中正确处理 guard
2. **错误 Promise**：将错误转换为 rejected Promise
3. **堆栈跟踪**：保留有意义的调用栈信息

### 8. 性能考虑

#### 8.1 优化策略

| 优化点 | 方法 | 预期收益 |
|--------|------|----------|
| 任务调度 | 使用 FIFO 队列 | O(1) 入队/出队 |
| Continuation | 最小化捕获范围 | 减少内存占用 |
| libuv 集成 | 批量执行任务 | 减少上下文切换 |
| Promise 转换 | 零拷贝转换 | 减少分配 |

#### 8.2 性能基准

**目标：** 与纯 Promise 方案相比，性能开销 < 20%

```scheme
;; tests/benchmark.ss

(define (benchmark-async-await n)
  (time
    (run-coroutines
      (async
        (for-each 
          (lambda (i)
            (await (sleep 0))
            (+ i 1))
          (iota n))))))

(define (benchmark-promise n)
  (time
    (let loop ([i 0])
      (when (< i n)
        (make-promise
          (lambda (resolve)
            (uv-timer-start 
              (uv-timer) 0 0
              (lambda (t)
                (resolve (loop (+ i 1)))))))))))
```

### 9. 与现有代码兼容

#### 9.1 渐进式迁移

**阶段 1：双 API 共存**
```scheme
;; 旧代码
(define p1 (make-promise ...))
(promise-then p1 (lambda (v) ...))

;; 新代码
(define p2 (async (await ...)))
```

**阶段 2：包装函数**
```scheme
;; Promise -> async/await
(define (await* promise)
  (await promise))

;; async/await -> Promise  
(define (async->promise coro)
  (make-promise
    (lambda (resolve reject)
      (spawn
        (guard (e [else (reject e)])
          (resolve (await-task coro)))))))
```

#### 9.2 迁移指南

```markdown
## 从 Promise 迁移到 async/await

### 旧代码（Promise）
```scheme
(define (fetch-data url)
  (make-promise
    (lambda (resolve reject)
      (http-get url
        (lambda (response)
          (read-body response
            (lambda (body)
              (resolve body))))))))
```

### 新代码（async/await）
```scheme
(define (fetch-data url)
  (async
    (let ([response (await (http-get url))])
      (let ([body (await (read-body response))])
        body))))
```

### 优势
- 代码扁平，没有回调嵌套
- 可以使用 let 绑定变量
- 错误处理更自然（guard）
```

### 10. 风险与缓解

| 风险 | 概率 | 影响 | 缓解措施 |
|------|------|------|----------|
| Continuation 泄漏 | 中 | 高 | 严格的清理机制，弱引用 |
| libuv 兼容性 | 低 | 中 | 充分测试，适配器模式 |
| 性能开销 | 中 | 中 | 基准测试，优化热点 |
| 调试困难 | 高 | 低 | 详细日志，调试工具 |

### 11. 总结

本设计方案结合了：

1. **chez-socket 的 call/cc 调度经验**
   - 三层队列模型
   - yield-for-io! 原语
   - I/O 多路复用抽象

2. **chez-async 的 libuv 基础**
   - 跨平台事件循环
   - 丰富的 I/O 操作
   - 现有 Promise 层

3. **async/await 语法糖**
   - 类似 JavaScript/Python 的语法
   - 同步风格的异步代码
   - 自然的错误处理

**预期收益：**
- 更清晰的异步代码
- 更好的可维护性
- 更低的认知负担

**实现建议：**
- 分阶段实现，逐步验证
- 保持与 Promise API 的兼容
- 完善的测试覆盖
- 详细的文档和示例

---

**文档版本：** 1.0  
**创建日期：** 2026-02-04  
**状态：** 设计完成，待实施
