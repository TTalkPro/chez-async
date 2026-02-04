# 基于 call/cc 的 async/await 实现方案

## 1. 核心概念

### 1.1 为什么使用 call/cc？

**call/cc (call-with-current-continuation)** 是 Scheme 的一等公民特性，能够捕获当前的 continuation（计算上下文）。这为实现协程和异步编程提供了强大的基础。

**优势：**
- ✅ **真正的暂停/恢复** - call/cc 可以暂停执行并在稍后恢复
- ✅ **无需手动状态机** - continuation 保存了完整的调用栈
- ✅ **自然的异步语法** - 代码看起来是同步的，实际是异步的
- ✅ **零成本抽象** - 不需要手动传递回调函数

### 1.2 与当前 Promise 方案的对比

| 特性 | Promise (当前) | call/cc (建议) |
|------|----------------|----------------|
| 代码可读性 | ⚠️ 回调嵌套 | ✅ 同步风格 |
| 错误处理 | ⚠️ 需要 promise-catch | ✅ 普通 try/catch |
| 变量作用域 | ⚠️ lambda 隔离 | ✅ 自然作用域 |
| 实现复杂度 | ✅ 简单 | ⚠️ 需要任务调度 |
| 性能 | ✅ 轻量级 | ⚠️ continuation 开销 |

## 2. 架构设计

### 2.1 核心组件

```
┌─────────────────────────────────────────────────────┐
│                    Event Loop                        │
│  ┌───────────────────────────────────────────────┐  │
│  │         Task Queue (per loop)                  │  │
│  │  ┌─────────┐ ┌─────────┐ ┌─────────┐         │  │
│  │  │ Task 1  │ │ Task 2  │ │ Task 3  │ ...     │  │
│  │  └────┬────┘ └────┬────┘ └────┬────┘         │  │
│  │       │           │           │               │  │
│  │       ▼           ▼           ▼               │  │
│  │  ┌─────────────────────────────────────┐     │  │
│  │  │     call/cc Scheduler                │     │  │
│  │  │  - pause current continuation        │     │  │
│  │  │  - resume when ready                 │  │  │
│  │  └─────────────────────────────────────┘     │  │
│  └───────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

### 2.2 数据结构

```scheme
;; Task 状态
(define-record-type task
  (fields
    (mutable continuation)    ; 存储的 call/cc continuation
    (mutable state)           ; 'running | 'paused | 'completed
    (mutable result)          ; 结果值
    (mutable error)           ; 错误信息
    (loop)))                 ; 关联的事件循环

;; 每个事件循环的任务队列
(uv-loop-task-queue loop)  ; => (queue task)
```

## 3. 实现方案

### 3.1 核心：暂停和恢复机制

#### 3.1.1 暂停当前执行 (suspend)

```scheme
;; 暂停当前 async 任务，等待事件完成
(define (suspend-task callback)
  "暂停当前任务，注册回调后恢复"
  (call/cc (lambda (k)
             ;; k 是当前的 continuation
             (let ([task (current-task)])
               ;; 保存 continuation
               (task-continuation-set! task k)
               (task-state-set! task 'paused)
               ;; 注册回调 - 当事件发生时调用 resume-task
               (callback (lambda (result)
                          (resume-task task result)))))))
```

#### 3.1.2 恢复任务 (resume)

```scheme
;; 恢复暂停的任务
(define (resume-task task result)
  "恢复任务执行，传入结果"
  (task-result-set! task result)
  (task-state-set! task 'running)
  ;; 将任务重新加入队列
  (enqueue! (uv-loop-task-queue (task-loop task)) task))

;; 实际恢复 continuation
(define (execute-task task)
  (if (task-state task)
      ((task-continuation task) (task-result task))
      ;; 首次执行，没有保存的 continuation
      (values)))
```

### 3.2 async/await 宏实现

#### 3.2.1 await 宏

```scheme
(define-syntax await
  (syntax-rules ()
    [(await promise)
     ;; 展开为暂停当前任务，等待 promise
     (suspend-task
       (lambda (resume)
         (promise-then promise
           (lambda (value)
             (resume value)))))]))
```

#### 3.2.2 async 宏

```scheme
(define-syntax async
  (syntax-rules ()
    [(_ body ...)
     (make-async-task
       (lambda ()
         body ...))]))

(define (make-async-task thunk)
  "创建并启动异步任务"
  (let* ([loop (uv-default-loop)]
         [task (make-task loop)])
    (enqueue! (uv-loop-task-queue loop) task)
    task))
```

### 3.3 事件循环集成

```scheme
;; 修改 uv-run 以支持任务调度
(define (uv-run loop . args)
  ;; 原有的 libuv 事件循环
  (libuv-uv-run loop)

  ;; 执行所有准备好的任务
  (unless (queue-empty? (uv-loop-task-queue loop))
    (let ([task (dequeue! (uv-loop-task-queue loop))])
      (execute-task task)
      ;; 递归运行直到队列为空
      (uv-run loop 'once))))
```

## 4. 使用示例

### 4.1 基本用法

```scheme
;; 使用 call/cc 版本的 async/await
(define (fetch-data url)
  (async
    (let ([response (await (http-get url))])
      (let ([data (await (read-body response))])
        (process data)))))

;; 看起来是同步代码，实际是异步执行！
(fetch-data "https://example.com")
```

### 4.2 错误处理

```scheme
(define (fetch-with-error-handling url)
  (async
    (guard (e [else
               (format #t "Error: ~a~%" e)
               #f])
      (let ([data (await (http-get url))])
        (process data)))))
```

### 4.3 并行执行

```scheme
(define (fetch-multiple urls)
  (async
    (let* ([promises (map http-get urls)]
           [results (await (promise-all promises))])
      results)))
```

## 5. 实现步骤

### Phase 1: 核心调度器 (2-3 天)

**文件：** `internal/continuation-scheduler.ss`

- [ ] 实现 `task` 记录类型
- [ ] 实现 `suspend-task` 和 `resume-task`
- [ ] 实现任务队列管理
- [ ] 与现有事件循环集成

### Phase 2: async/await 宏 (1-2 天)

**文件：** `high-level/async-await-cc.ss`

- [ ] 实现 `await` 宏（基于 suspend-task）
- [ ] 实现 `async` 宏（创建任务）
- [ ] 实现 `async*` 宏（带参数版本）
- [ ] 错误处理集成

### Phase 3: 示例和测试 (1-2 天)

**文件：** `tests/test-async-await-cc.ss`, `examples/async-await-cc-demo.ss`

- [ ] 基本功能测试
- [ ] 错误处理测试
- [ ] 性能基准测试
- [ ] 与 Promise 版本对比

### Phase 4: 文档和优化 (1 天)

- [ ] API 文档
- [ ] 设计文档
- [ ] 性能优化
- [ ] 迁移指南

## 6. 技术细节

### 6.1 Continuation 捕获

```scheme
;; call/cc 捕获当前的计算状态
(define x 10)
(+ 1 (call/cc (lambda (k)
                ;; k 保存了 "从 call/cc 返回后的计算"
                ;; 即 (+ 1 _) 的状态
                (k 5))))  ;; => (+ 1 5) => 6

;; 暂停和恢复
(define saved-cont #f)

(define (pause)
  (call/cc (lambda (k)
             (set! saved-cont k)
             "paused")))

(define (resume value)
  (saved-cont value))  ;; 从暂停处继续执行
```

### 6.2 任务生命周期

```
created -> queued -> running -> paused <-> running
                                        |
                                        v
                                    completed
```

### 6.3 与 libuv 集成

```scheme
;; 每个 libuv 回调都可以恢复任务
(uv-timer-start! timer 1000 0
  (lambda (handle)
    ;; 定时器到期，恢复任务
    (resume-task current-task "timeout")))
```

## 7. 性能考虑

### 7.1 优化策略

1. **Continuation 池化** - 重用 continuation 对象
2. **任务窃取** - 多个事件循环间平衡负载
3. **惰性恢复** - 只在需要时才恢复任务
4. **避免过度捕获** - 最小化 continuation 作用域

### 7.2 内存管理

```scheme
;; 任务完成后清理 continuation
(define (cleanup-task task)
  (when (eq? (task-state task) 'completed)
    (task-continuation-set! task #f)
    (task-result-set! task #f)))
```

## 8. 兼容性

### 8.1 与现有代码共存

```scheme
;; Promise API 仍然可用
(define p1 (promise-resolved 42))

;; 新的 call/cc API
(define p2 (async (await (promise-resolved 42))))

;; 可以互操作
(define p3 (async (await p1)))
```

### 8.2 渐进式迁移

1. **Phase 1**: 保留 Promise API，添加 call/cc API
2. **Phase 2**: 新代码优先使用 call/cc
3. **Phase 3**: 旧代码逐步迁移
4. **Phase 4**: 废弃 Promise（可选）

## 9. 风险和挑战

### 9.1 技术风险

| 风险 | 影响 | 缓解措施 |
|------|------|----------|
| Continuation 泄漏 | 内存泄漏 | 严格的清理机制 |
| 调试困难 | 开发效率 | 添加详细日志 |
| 性能开销 | 响应时间 | 基准测试和优化 |
| 状态管理复杂 | Bug 增多 | 完善的状态机 |

### 9.2 实现风险

- ⚠️ **Chez Scheme continuation 实现细节** - 需要深入理解
- ⚠️ **与 libuv 的交互** - 可能需要调整事件循环
- ⚠️ **测试覆盖率** - 需要大量测试用例

## 10. 参考资源

### 学术论文
- [Continuations and Coroutines](https://www.cs.tufts.edu/~nr/cs257/archive/kent-dybvig/stack.pdf)
- [Implementation Strategies for First-Class Continuations](https://www.researchgate.net/publication/220606970_Implementation_Strategies_for_First-Class_Continuations)

### 实现参考
- [Scheme Coroutine Implementation](https://stackoverflow.com/questions/13338559/scheme-how-does-a-nested-call-cc-work-for-a-coroutine)
- [Call with Current Continuation Patterns](https://www.plopcon.org/pastplops/plop2001/accepted_submissions/PLoP2001_dferguson0_1.pdf)

### 教程
- [Understanding call/cc](https://www.callcc.dev/scheme-continuation)
- [Call With Current Continuation - Dmitry's Blog](https://dkandalov.github.io/call-with-current-continuation)

## 11. 总结

基于 call/cc 的 async/await 实现提供了：

✅ **更自然的语法** - 代码看起来是同步的
✅ **更好的错误处理** - 使用普通的 guard/try-catch
✅ **真正的暂停/恢复** - 不是状态机模拟
✅ **类型安全** - 编译时检查

但也带来了：

⚠️ **实现复杂度** - 需要理解 continuation
⚠️ **性能开销** - continuation 捕获和恢复有成本
⚠️ **调试难度** - continuation 调试比较困难

**建议：**
- 对于新项目，可以考虑使用 call/cc 实现
- 对于已有项目，可以保持 Promise 方案
- 两种 API 可以共存，用户可以选择

---

**下一步：** 创建一个概念验证 (PoC) 实现，测试基本功能
