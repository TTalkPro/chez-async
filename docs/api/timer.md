# Timer API 参考

定时器允许你在延迟后执行回调，或按固定间隔重复执行。

## 快速示例

```scheme
(import (chezscheme) (chez-async))

(define loop (uv-loop-init))
(define timer (uv-timer-init loop))

;; 1 秒后触发
(uv-timer-start! timer 1000 0
  (lambda (t)
    (printf "Timer fired!~n")
    (uv-handle-close! t)))

(uv-run loop 'default)
(uv-loop-close loop)
```

## 定时器函数

### `uv-timer-init`

```scheme
(uv-timer-init loop) → timer
```

创建新的定时器句柄。

**参数：**
- `loop` - 事件循环

**返回：** 定时器句柄

**示例：**
```scheme
(define loop (uv-loop-init))
(define timer (uv-timer-init loop))

;; 使用简化 API 查看
(printf "Type: ~a~n" (handle-type timer))    ; timer
(printf "Closed?: ~a~n" (handle-closed? timer))  ; #f
```

---

### `uv-timer-start!`

```scheme
(uv-timer-start! timer timeout repeat callback) → void
```

启动定时器。

**参数：**
- `timer` - 定时器句柄
- `timeout` - 首次回调前的延迟（毫秒）
- `repeat` - 重复间隔（毫秒，0 表示一次性）
- `callback` - 定时器触发时调用的函数：`(lambda (timer) ...)`

**示例：**

```scheme
;; 一次性定时器（1 秒后触发一次）
(uv-timer-start! timer 1000 0
  (lambda (t)
    (printf "Fired!~n")
    (uv-handle-close! t)))

;; 重复定时器（每 500ms 触发一次）
(uv-timer-start! timer 500 500
  (lambda (t)
    (printf "Tick~n")))

;; 立即触发，然后每秒重复
(uv-timer-start! timer 0 1000
  (lambda (t)
    (printf "Immediate, then every 1s~n")))
```

**附带自定义数据：**

```scheme
;; 在定时器上存储数据
(handle-data-set! timer '(count 0 name "my-timer"))

(uv-timer-start! timer 1000 0
  (lambda (t)
    (let ([data (handle-data t)])
      (printf "Timer data: ~s~n" data))
    (uv-handle-close! t)))
```

---

### `uv-timer-stop!`

```scheme
(uv-timer-stop! timer) → void
```

停止定时器。句柄仍然有效，可以重新启动。

**示例：**
```scheme
;; 启动定时器
(uv-timer-start! timer 1000 1000 callback)

;; 停止
(uv-timer-stop! timer)

;; 使用不同参数重新启动
(uv-timer-start! timer 500 500 callback)
```

**注意：** 对尚未启动的定时器调用 stop 是无操作的。

---

### `uv-timer-again!`

```scheme
(uv-timer-again! timer) → void
```

使用上次的 `timeout` 和 `repeat` 值重新启动定时器。

**前提条件：**
- 必须之前调用过 `uv-timer-start!`，或
- 必须通过 `uv-timer-set-repeat!` 设置过重复间隔

**示例：**
```scheme
;; 初始启动
(uv-timer-start! timer 1000 500 callback)

;; 停止
(uv-timer-stop! timer)

;; 使用相同参数重启（1000ms 延迟，500ms 重复）
(uv-timer-again! timer)
```

**动态调整间隔：**
```scheme
(define ticks 0)
(uv-timer-start! timer 0 200
  (lambda (t)
    (set! ticks (+ ticks 1))
    (printf "Tick ~a~n" ticks)
    (when (= ticks 5)
      ;; 切换到较慢的间隔
      (uv-timer-set-repeat! t 500)
      (uv-timer-again! t))))
```

---

### `uv-timer-set-repeat!`

```scheme
(uv-timer-set-repeat! timer repeat) → void
```

设置重复间隔（毫秒）。

**参数：**
- `timer` - 定时器句柄
- `repeat` - 重复间隔（毫秒）

**注意：** 更改在下次 `uv-timer-start!` 或 `uv-timer-again!` 时生效。

**示例：**
```scheme
(uv-timer-set-repeat! timer 1000)  ; 1 秒
(uv-timer-again! timer)  ; 使用新间隔
```

---

### `uv-timer-get-repeat`

```scheme
(uv-timer-get-repeat timer) → uint64
```

获取当前重复间隔。

**返回：** 重复间隔（毫秒）

**示例：**
```scheme
(define interval (uv-timer-get-repeat timer))
(printf "Current repeat: ~ams~n" interval)
```

---

### `uv-timer-get-due-in`

```scheme
(uv-timer-get-due-in timer) → uint64
```

获取距离定时器触发的剩余时间。

**返回：** 距触发的毫秒数（未启动或已触发则为 0）

**示例：**
```scheme
(uv-timer-start! timer 5000 0 callback)
(printf "Timer fires in: ~ams~n" (uv-timer-get-due-in timer))
```

---

## 句柄 API

定时器是句柄，支持所有通用句柄操作：

### 句柄访问器（简化 API）

```scheme
(handle? timer)            ; #t
(handle-type timer)        ; 'timer
(handle-closed? timer)     ; #f（未关闭时）
(handle-ptr timer)         ; C 指针
(handle-data timer)        ; 关联数据
(handle-data-set! timer data)  ; 存储数据
```

### 句柄操作

```scheme
;; 关闭定时器
(uv-handle-close! timer [callback])

;; 引用计数（影响事件循环退出）
(uv-handle-ref! timer)     ; 保持事件循环活跃
(uv-handle-unref! timer)   ; 允许事件循环退出
(uv-handle-has-ref? timer) ; 查看引用状态

;; 状态查询
(uv-handle-active? timer)  ; 定时器是否运行中？
(uv-handle-closing? timer) ; 是否正在关闭？
```

---

## 常见模式

### 一次性定时器

延迟后执行代码：

```scheme
(define timer (uv-timer-init loop))
(uv-timer-start! timer 1000 0
  (lambda (t)
    (printf "One time only!~n")
    (uv-handle-close! t)))
```

### 重复定时器

按固定间隔执行代码：

```scheme
(define timer (uv-timer-init loop))
(uv-timer-start! timer 0 1000  ; 立即触发，每秒重复
  (lambda (t)
    (printf "Every second~n")))
```

### 倒计时

从指定值倒数：

```scheme
(define count 10)
(define timer (uv-timer-init loop))

(uv-timer-start! timer 0 1000
  (lambda (t)
    (printf "~a~n" count)
    (set! count (- count 1))
    (when (< count 0)
      (printf "Done!~n")
      (uv-timer-stop! t)
      (uv-handle-close! t))))
```

### 可取消的超时

设置可取消的超时：

```scheme
(define timer (uv-timer-init loop))

(uv-timer-start! timer 5000 0
  (lambda (t)
    (printf "Timeout!~n")
    (uv-handle-close! t)))

;; 满足条件时取消
(when some-condition?
  (uv-timer-stop! timer)
  (uv-handle-close! timer))
```

### 频率限制器

限制操作频率：

```scheme
(define timer (uv-timer-init loop))
(define pending-op #f)

(define (rate-limited-op data)
  (set! pending-op data))

(uv-timer-start! timer 0 100  ; 最多每秒 10 次操作
  (lambda (t)
    (when pending-op
      (process-operation pending-op)
      (set! pending-op #f))))
```

### 延迟重试

带退避的失败重试：

```scheme
(define (retry-with-backoff operation max-retries delay)
  (let ([timer (uv-timer-init loop)]
        [attempts 0])
    (define (try-operation)
      (guard (e [else
                 (set! attempts (+ attempts 1))
                 (if (< attempts max-retries)
                     (begin
                       (printf "Retry ~a/~a in ~ams~n"
                               attempts max-retries delay)
                       (uv-timer-start! timer delay 0
                         (lambda (t) (try-operation))))
                     (begin
                       (printf "Max retries reached~n")
                       (uv-handle-close! timer)))])
        (operation)
        (uv-handle-close! timer)))
    (try-operation)))
```

### 防抖

活动停止后才执行：

```scheme
(define debounce-timer (uv-timer-init loop))
(define pending-action #f)

(define (debounce action delay)
  (set! pending-action action)
  (uv-timer-stop! debounce-timer)
  (uv-timer-start! debounce-timer delay 0
    (lambda (t)
      (when pending-action
        (pending-action)
        (set! pending-action #f)))))
```

### 节流

每个间隔内最多执行一次：

```scheme
(define throttle-timer (uv-timer-init loop))
(define can-execute? #t)

(define (throttled-action action interval)
  (when can-execute?
    (action)
    (set! can-execute? #f)
    (uv-timer-start! throttle-timer interval 0
      (lambda (t)
        (set! can-execute? #t)))))
```

---

## 最佳实践

### 1. 始终关闭定时器

```scheme
;; 正确 - 完成后关闭
(uv-timer-start! timer 1000 0
  (lambda (t)
    (do-work)
    (uv-handle-close! t)))

;; 错误 - 忘记关闭
(uv-timer-start! timer 1000 0
  (lambda (t)
    (do-work)))  ; 内存泄漏！
```

### 2. 使用 handle-data 存储状态

```scheme
;; 正确 - 使用 handle-data 存储定时器状态
(handle-data-set! timer '(count 0 max 10))

(uv-timer-start! timer 0 1000
  (lambda (t)
    (let* ([data (handle-data t)]
           [count (cadr (memq 'count data))]
           [max (cadr (memq 'max data))])
      (when (>= count max)
        (uv-timer-stop! t)
        (uv-handle-close! t)))))
```

### 3. 处理回调中的错误

```scheme
(uv-timer-start! timer 1000 0
  (lambda (t)
    (guard (e [else
               (fprintf (current-error-port)
                       "Timer error: ~a~n" e)
               (uv-handle-close! t)])
      (risky-operation))))
```

### 4. 退出时清理

```scheme
(define timer (uv-timer-init loop))

(guard (e [else
           (uv-handle-close! timer)
           (uv-loop-close loop)
           (raise e)])
  (uv-timer-start! timer 1000 0 callback)
  (uv-run loop 'default))

(uv-loop-close loop)
```

---

## 注意事项

- **精度**：定时器精度约 ~1ms，取决于系统定时器分辨率
- **线程安全**：定时器函数必须在主线程中调用
- **关闭**：完成后始终关闭定时器以释放资源
- **可重用**：已停止的定时器可以使用新参数重新启动
- **回调**：回调函数的第一个参数是定时器句柄
- **数据存储**：使用 `handle-data` 将自定义数据与定时器关联

---

## 参见

- [快速入门指南](../guide/getting-started.md)
- [句柄 API](#句柄-api)
- [异步任务指南](../guide/async-work.md)
- [示例代码](../../examples/timer-demo.ss)
