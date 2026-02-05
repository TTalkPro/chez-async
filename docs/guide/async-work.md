# 异步任务 API 指南

## Quick Example

```scheme
#!/usr/bin/env scheme-script

(import (chezscheme) (chez-async))

;; CPU-intensive task: fibonacci
(define (fib n)
  (if (<= n 1) n
      (+ (fib (- n 1)) (fib (- n 2)))))

(define loop (uv-loop-init))

;; Execute in background
(async-work loop
  (lambda ()
    (printf "[Worker] Computing fib(40)...~n")
    (fib 40))
  (lambda (result)
    (printf "[Main] Result: ~a~n" result)
    (uv-stop loop)))

(printf "Event loop running (non-blocking)...~n")
(uv-run loop 'default)
(uv-loop-close loop)
```

Output:
```
Event loop running (non-blocking)...
[Worker] Computing fib(40)...
[Main] Result: 102334155
```

---

## 概述

chez-async 提供了基于 Chez Scheme 线程池的异步任务系统，允许你在后台线程执行 CPU 密集型或阻塞型任务，同时保持主事件循环的响应性。

## 架构

```
用户任务
    ↓
async-work (主线程)
    ↓
任务队列 (mutex 保护)
    ↓
工作线程 (Chez Scheme 线程)
    ↓ 执行任务
结果队列 (mutex 保护)
    ↓
uv_async_send (唤醒主线程)
    ↓
async callback (主线程)
    ↓
执行用户回调
```

## 核心特性

- **线程安全**: 使用 mutex 和 condition variables 保护共享数据
- **自动管理**: 每个事件循环自动创建关联的线程池
- **错误处理**: 支持在工作线程中捕获异常并传递到主线程
- **无阻塞**: 主线程通过 uv_async_t 接收通知，不会阻塞
- **GC 安全**: 使用 lock-object 防止对象被垃圾回收

## API 参考

### 高层 API

#### `async-work`

```scheme
(async-work loop work-fn callback) → task-id
```

提交后台任务到线程池。

**参数**:
- `loop`: uv-loop wrapper
- `work-fn`: `(lambda () ...)` - 在工作线程执行的函数
- `callback`: `(lambda (result) ...)` - 在主线程执行的回调函数

**返回值**: task-id (整数)

**示例**:

```scheme
(import (chezscheme) (chez-async))

(define loop (uv-loop-init))

(async-work loop
  (lambda ()
    ;; 在后台线程执行
    (fib 35))
  (lambda (result)
    ;; 在主线程执行
    (printf "Result: ~a~n" result)
    (uv-stop loop)))

(uv-run loop 'default)
(uv-loop-close loop)
```

#### `async-work/error`

```scheme
(async-work/error loop work-fn success-cb error-cb) → task-id
```

提交带错误处理的后台任务。

**参数**:
- `loop`: uv-loop wrapper
- `work-fn`: `(lambda () ...)` - 在工作线程执行的函数
- `success-cb`: `(lambda (result) ...)` - 成功时的回调
- `error-cb`: `(lambda (error) ...)` - 失败时的回调

**示例**:

```scheme
(import (chezscheme) (chez-async))

(define loop (uv-loop-init))

(async-work/error loop
  (lambda ()
    (if (< (random 10) 5)
        (error 'task "random failure")
        "success"))
  (lambda (result)
    (printf "Success: ~a~n" result)
    (uv-stop loop))
  (lambda (error)
    (printf "Error: ~a~n" (condition-message error))
    (uv-stop loop)))

(uv-run loop 'default)
(uv-loop-close loop)
```

#### `loop-threadpool`

```scheme
(loop-threadpool loop) → threadpool
```

获取或创建与事件循环关联的线程池（默认 4 个工作线程）。

#### `loop-set-threadpool!`

```scheme
(loop-set-threadpool! loop pool) → void
```

设置事件循环的线程池（用于自定义线程数）。

**示例**:

```scheme
(import (chezscheme) (chez-async))

(define loop (uv-loop-init))

;; 创建 8 个工作线程的线程池
(define pool (make-threadpool loop 8))
(threadpool-start! pool)
(loop-set-threadpool! loop pool)

;; 使用自定义线程池
(async-work loop
  (lambda () (expensive-computation))
  (lambda (result)
    (printf "Result: ~a~n" result)
    (uv-stop loop)))

(uv-run loop 'default)
(uv-loop-close loop)
```

### 低层 API

#### `make-threadpool`

```scheme
(make-threadpool loop size) → threadpool
```

创建线程池（尚未启动）。

**参数**:
- `loop`: uv-loop wrapper
- `size`: 工作线程数量

#### `threadpool-start!`

```scheme
(threadpool-start! pool) → void
```

启动线程池（创建工作线程和 async 句柄）。

#### `threadpool-submit!`

```scheme
(threadpool-submit! pool work callback error-handler) → task-id
```

直接提交任务到线程池。

#### `threadpool-shutdown!`

```scheme
(threadpool-shutdown! pool) → void
```

关闭线程池（停止所有工作线程）。

#### `make-task`

```scheme
(make-task id work callback error-handler) → task
```

创建任务对象。

## 使用场景

### 1. CPU 密集型计算

```scheme
(import (chezscheme) (chez-async))

(define loop (uv-loop-init))

;; 在后台计算斐波那契数
(async-work loop
  (lambda ()
    (fib 40)) ; CPU 密集型
  (lambda (result)
    (printf "fib(40) = ~a~n" result)
    (uv-stop loop)))

(uv-run loop 'default)
(uv-loop-close loop)
```

### 2. 阻塞 I/O

```scheme
(import (chezscheme) (chez-async))

(define loop (uv-loop-init))

;; 在后台执行阻塞 I/O
(async-work loop
  (lambda ()
    (call-with-input-file "large-file.txt"
      (lambda (port)
        (read port)))) ; 可能阻塞
  (lambda (data)
    (process-data data)
    (uv-stop loop)))

(uv-run loop 'default)
(uv-loop-close loop)
```

### 3. 并行任务

```scheme
(import (chezscheme) (chez-async))

(define loop (uv-loop-init))
(define completed 0)
(define total 5)

;; 同时执行多个任务
(for-each
  (lambda (i)
    (async-work loop
      (lambda () (expensive-computation i))
      (lambda (result)
        (handle-result i result)
        (set! completed (+ completed 1))
        (when (= completed total)
          (uv-stop loop)))))
  '(1 2 3 4 5))

(uv-run loop 'default)
(uv-loop-close loop)
```

### 4. 数据处理管道

```scheme
(import (chezscheme) (chez-async))

(define loop (uv-loop-init))

(async-work loop
  (lambda ()
    ;; Stage 1: 加载数据
    (load-data))
  (lambda (data)
    ;; Stage 2: 在后台处理
    (async-work loop
      (lambda () (process-data data))
      (lambda (processed)
        ;; Stage 3: 保存结果
        (save-results processed)
        (uv-stop loop)))))

(uv-run loop 'default)
(uv-loop-close loop)
```

## 最佳实践

### 1. 任务粒度

- ✅ 任务应该足够粗粒度（>10ms）
- ❌ 避免提交大量微小任务（会导致线程切换开销）

```scheme
;; 不好：提交 1000 个小任务
(for-each
  (lambda (x)
    (async-work loop
      (lambda () (* x 2))
      (lambda (result) (handle-result result))))
  (iota 1000))

;; 好：批量处理
(async-work loop
  (lambda () (map (lambda (x) (* x 2)) (iota 1000)))
  (lambda (results)
    (for-each handle-result results)))
```

### 2. 错误处理

- ✅ 使用 `async-work/error` 处理可能失败的任务
- ✅ 在工作函数中使用 `guard` 捕获特定错误

```scheme
(import (chezscheme) (chez-async))

(define loop (uv-loop-init))

(async-work/error loop
  (lambda ()
    (guard (e [(file-not-found? e) #f])
      (load-optional-file "config.txt")))
  (lambda (result)
    (when result (use-config result))
    (uv-stop loop))
  (lambda (error)
    (log-error error)
    (uv-stop loop)))

(uv-run loop 'default)
(uv-loop-close loop)
```

### 3. 资源管理

- ✅ 在任务完成后及时关闭文件/连接
- ❌ 不要在工作线程中访问主线程的 UI 或 libuv 句柄

```scheme
(import (chezscheme) (chez-async))

(define loop (uv-loop-init))

(async-work loop
  (lambda ()
    (call-with-port (open-file "data.txt" 'read)
      (lambda (port)
        ;; 使用 port
        (read-all port)))) ; port 会自动关闭
  (lambda (data)
    (process-data data)
    (uv-stop loop)))

(uv-run loop 'default)
(uv-loop-close loop)
```

### 4. 线程池大小

- 默认 4 个工作线程适合大多数情况
- CPU 密集型任务：`(+ 1 (cpu-count))`
- I/O 密集型任务：可以增加到 8-16

```scheme
(import (chezscheme) (chez-async))

(define loop (uv-loop-init))

;; 根据 CPU 核心数调整
(define pool-size
  (+ 1 (string->number
        (or (getenv "NPROC") "4"))))

(define pool (make-threadpool loop pool-size))
(threadpool-start! pool)
(loop-set-threadpool! loop pool)

;; 使用自定义线程池
(async-work loop
  (lambda () (compute))
  (lambda (result)
    (printf "Result: ~a~n" result)
    (uv-stop loop)))

(uv-run loop 'default)
(uv-loop-close loop)
```

### 5. 避免共享状态

- ✅ 通过返回值传递数据
- ❌ 不要在工作线程中修改全局变量

```scheme
(import (chezscheme) (chez-async))

(define loop (uv-loop-init))

;; 不好：修改全局变量
(define *global-result* #f)
(async-work loop
  (lambda ()
    (set! *global-result* (compute)) ; 竞态条件！
    #t)
  (lambda (ok) (uv-stop loop)))

;; 好：返回结果
(async-work loop
  (lambda () (compute))
  (lambda (result)
    (set! *global-result* result) ; 在主线程安全
    (uv-stop loop)))

(uv-run loop 'default)
(uv-loop-close loop)
```

## 内部实现

### 线程安全机制

1. **任务队列**: 使用 mutex 保护，condition variable 通知
2. **结果队列**: 使用 mutex 保护
3. **uv_async_t**: 唯一的线程间通信机制（线程安全）
4. **lock-object**: 防止 GC 回收使用中的对象

### 生命周期

```
1. 用户调用 async-work
   ↓
2. 任务加入队列，lock-object task
   ↓
3. 工作线程取出任务
   ↓
4. 执行 work-fn（捕获异常）
   ↓
5. 结果加入结果队列
   ↓
6. uv_async_send 通知主线程
   ↓
7. async callback 执行用户回调
   ↓
8. 从 task-map 删除，unlock-object
```

## 性能考虑

### 开销

- 创建任务: ~1-5 μs
- 线程通信: ~10-50 μs
- async 通知: ~5-20 μs

### 适用场景

- ✅ 任务执行时间 > 100 μs
- ✅ 需要并行化的 CPU 密集型计算
- ✅ 阻塞型 I/O 操作

### 不适用场景

- ❌ 微小任务（< 100 μs）
- ❌ 需要实时响应的操作
- ❌ 大量短期任务（考虑批处理）

## 调试技巧

### 1. 打印调试信息

```scheme
(import (chezscheme) (chez-async))

(define loop (uv-loop-init))

(async-work loop
  (lambda ()
    (fprintf (current-error-port) "[Worker ~a] Start~n" (current-thread))
    (let ([result (compute)])
      (fprintf (current-error-port) "[Worker ~a] Done~n" (current-thread))
      result))
  (lambda (result)
    (fprintf (current-error-port) "[Main] Result: ~a~n" result)
    (uv-stop loop)))

(uv-run loop 'default)
(uv-loop-close loop)
```

### 2. 测量执行时间

```scheme
(import (chezscheme) (chez-async))

(define loop (uv-loop-init))

(async-work loop
  (lambda ()
    (let ([start (current-time 'time-monotonic)])
      (let ([result (compute)])
        (let ([elapsed (time-difference (current-time 'time-monotonic) start)])
          (fprintf (current-error-port) "Elapsed: ~as~n"
                  (+ (time-second elapsed)
                     (/ (time-nanosecond elapsed) 1e9)))
          result))))
  (lambda (result)
    (printf "Result: ~a~n" result)
    (uv-stop loop)))

(uv-run loop 'default)
(uv-loop-close loop)
```

### 3. 错误回溯

```scheme
(import (chezscheme) (chez-async))

(define loop (uv-loop-init))

(async-work/error loop
  (lambda ()
    (guard (e [else
               (fprintf (current-error-port) "Worker error: ~a~n"
                       (call-with-string-output-port
                         (lambda (p) (display-condition e p))))
               (raise e)])
      (risky-operation)))
  (lambda (result)
    (printf "Success: ~a~n" result)
    (uv-stop loop))
  (lambda (error)
    (fprintf (current-error-port) "Error caught in main thread: ~a~n" error)
    (uv-stop loop)))

(uv-run loop 'default)
(uv-loop-close loop)
```

## 常见问题

### Q: 如何等待所有任务完成？

A: 使用计数器：

```scheme
(import (chezscheme) (chez-async))

(define loop (uv-loop-init))
(define total 10)
(define completed 0)

(let task-loop ([i 0])
  (when (< i total)
    (async-work loop
      (lambda () (compute i))
      (lambda (result)
        (set! completed (+ completed 1))
        (when (= completed total)
          (printf "All done!~n")
          (uv-stop loop))))
    (task-loop (+ i 1))))

(uv-run loop 'default)
(uv-loop-close loop)
```

### Q: 工作线程可以访问什么？

A: 工作线程可以：
- ✅ 执行纯计算
- ✅ 访问不可变数据
- ✅ 打开文件、网络连接（但要在本线程关闭）

工作线程不能：
- ❌ 调用 libuv API
- ❌ 修改主线程的 UI
- ❌ 访问未锁定的共享对象

### Q: 如何优雅关闭？

A: 先停止事件循环，再关闭线程池：

```scheme
(import (chezscheme) (chez-async))

;; 在程序结束时
(uv-stop loop)
(uv-run loop 'default) ; 清理剩余事件

(let ([pool (loop-threadpool loop)])
  (threadpool-shutdown! pool))

(uv-loop-close loop)
```

## 更多示例

查看 `examples/async-work-demo.ss` 获取完整示例代码。
