# F1 设计草案：协程调度器与事件循环集成

状态：**已实现**（方案 A，默认开启；经用户评审确认）
关联：TASK.md F1、F2

## 实现记录（2026-07-20）

已按方案 A 落地，22/22 测试通过。相对本草案第 4 节的两点调整：

1. **改用依赖注入，而非「event-loop import scheduler」。**
   实现时发现：只要把 `internal/coroutine`（scheduler 的传递依赖）拉进 `event-loop.ss`
   的**导入图**，`test-async.ss`（纯 threadpool，`async-work` + `fork-thread`）就会
   **确定性死锁**。根因是库初始化顺序：coroutine 顶层的 `make-thread-parameter` /
   `make-mutex` 与 threadpool 的 `fork-thread` 在该导入布局下产生死锁
   （把 coroutine 与 threadpool 放在同一顶层程序直接加载则无事——仅当 coroutine
   进入 event-loop 依赖图时触发）。
   解决：在 `internal/loop-registry` 定义 `scheduler-driver` 参数 +
   `install-scheduler-driver!`；`internal/scheduler` 加载时把 `drive-loop` 注入进去；
   `high-level/event-loop` 的 `uv-run` 读取该参数调用，**不再 import scheduler**。
   这与 promise-core 注入微任务调度器是同一模式，也保持了层次方向（event-loop 不反向依赖 scheduler）。
   → 纯 libuv 程序从不加载 scheduler，`scheduler-driver` 恒为 #f，`uv-run` 行为完全不变。

2. 其余同草案：`drive-loop` 在 `internal/scheduler`，`run-scheduler` = `(drive-loop loop 'scheduler)`；
   `uv-run 'default` 在 `(uv-loop-scheduler loop)` 非空且 driver 已注入时走 `(driver loop 'default)`。

测试：新增 `tests/test-scheduler-integration.ss`（6 例：async+uv-run'default、链式 await、
await resolved、协程与微任务共驱、协程完成后其余句柄继续、纯 libuv loop 不受影响）。

---

## （以下为原始草案，保留备查）

## 1. 问题

`async`/`await`（协程）目前**只能**由 `run-scheduler` 驱动（经 `run-async` / `run-async-loop`）。
普通的 `(uv-run loop 'default)` 驱动 libuv 句柄和 promise 的 `.then` 微任务，
但**不驱动协程的 runnable 队列**。

后果：
```scheme
(async (await (async-sleep 100)) (display "done"))
(uv-run loop 'default)     ; ← 协程永远不执行，"done" 不打印，无任何报错
```
用户必须知道要改用 `(run-async-loop)`。两套驱动入口（`uv-run` vs `run-scheduler`）
不能自由混用，这是最大的可用性陷阱。

## 2. 根因与硬约束

### 根因：两套独立的驱动世界
- promise `.then` 回调 → 微任务 idle handle（`high-level/promise.ss`）→ 任何 `uv_run` 中都会触发
- 协程 resume（来自 `await`）→ 调度器 runnable 队列 → **只有 `run-scheduler` 会抽干**

### 硬约束：call/cc 逃逸不能跨 C 栈
`suspend-for-promise!`（`internal/scheduler.ss:192`）用 `call/cc` 捕获 continuation，
挂起时经 `scheduler-k` **逃逸回调度器的 Scheme 栈循环**；resume 时重新调用该 continuation。
这些 continuation 跳转**必须发生在 Scheme 栈上，且在任何 `uv_run` 的 C 帧之外**。

若把协程放进某个 uv handle 回调里执行（idle/prepare/check —— 它们都在 `uv_run` 内部、
即 libuv 的 C 栈上运行），再经 `scheduler-k` 逃逸，就会**跨越 libuv 的 C 边界跳转 = 未定义行为**。
（这也是为什么微任务用的那套「idle handle 里跑回调」的模式**不能**直接照搬到协程上：
`.then` 回调只是入队/run-to-completion、没有 call/cc 逃逸，所以在 `uv_run` 内部是安全的；
协程不是。）

**结论**：协程的驱动循环必须**包裹 `uv_run`**，而不能住在某个 uv 回调内部。
因此正确的挂钩点是 `uv-run` 本身（或一个调度器感知的包装器），不是 prepare/check/idle handle。

## 3. 方案对比

### 方案 A —— 统一：让 `uv-run` 感知调度器（推荐）
把 `run-scheduler` 已被验证的「Scheme 栈抽干 runnable → `uv_run 'once` 推进」循环
抽取成一个共享驱动器。高层 `uv-run`（`event-loop.ss`）在 `'default` 模式下检查
`(uv-loop-scheduler loop)`：有调度器且有 runnable/pending 工作时，走统一驱动器；
否则退化为普通 `uv_run`。调度器工作抽干后，继续为其余非协程句柄跑普通 `uv_run 'default`，
保持 `'default` 语义。`run-scheduler` / `run-async-loop` 变成统一驱动器的薄封装。

- 优点：`async` + `uv-run`「就是能用」；单一心智模型；**保持 C 边界安全**（协程仍在 Scheme 栈上运行）。
- 代价：改动核心 `uv-run`；`event-loop.ss` 需 import `internal/scheduler`（已验证无环）；
  轻微行为变化（`uv-run 'default` 现在会抽干协程）。

### 方案 B —— 保持分离 + 自动触发
保留独立 `run-scheduler`，但让 `spawn-coroutine!` 在「未处于调度器运行中」时自动启动驱动。
问题：没有干净的挂钩点——`spawn` 返回后控制权就回到用户，无处自动运行。**否决**。

### 方案 C —— 仅文档 + 告警
检测「`async` 结果 promise 被忽略 / 没有调度器在跑」并打印告警。
价值低，不消除陷阱。**否决**。

## 4. 推荐实现（方案 A，分阶段）

### 统一驱动器（草图，置于 `internal/scheduler.ss`）
本质是把现有 `run-scheduler` 的退出条件泛化：不仅在「runnable + pending 皆空」时退出，
还要在 `'default` 模式下继续驱动其余活跃句柄。

```scheme
;; drive-loop: 统一的协程 + 事件循环驱动器
;;   mode: 'default（跑到无协程工作且无活跃句柄）| 'scheduler（仅跑到协程工作完成，旧 run-scheduler 语义）
(define (drive-loop loop mode)
  (let ([sched (get-scheduler loop)]
        [ptr   (uv-loop-ptr loop)])
    (let drive ()
      ;; 每轮重设 scheduler-k，供 suspend-for-promise! 逃逸回本 Scheme 栈
      (call/cc (lambda (k) (scheduler-state-scheduler-k-set! sched k)))
      (cond
        ;; 情况 1：有可运行协程 —— 在 Scheme 栈上运行一个（await 会逃逸回这里）
        [(queue-not-empty? (scheduler-state-runnable sched))
         (guard (ex [else (记录协程错误)])
           (run-coroutine! sched (queue-dequeue! (scheduler-state-runnable sched))))
         (drive)]
        ;; 情况 2：有协程在等待 —— 跑一次 uv_run（微任务/IO/timer 会触发 resume，仅入队，不跨 C 栈）
        [(> (hashtable-size (scheduler-state-pending sched)) 0)
         (%ffi-uv-run ptr (uv-run-mode->int 'once))
         (drive)]
        ;; 情况 3：协程工作已清空
        [else
         (when (eq? mode 'default)
           ;; 收尾：为其余非协程句柄跑完普通 default 循环，保持 uv-run 'default 语义
           (%ffi-uv-run ptr (uv-run-mode->int 'default)))
         (void)]))))
```

### 高层 `uv-run` 委托（`event-loop.ss`）
```scheme
(define (uv-run loop mode)
  (cond
    ;; 仅 'default 感知调度器；'once/'nowait 保持手动逐步语义，直通 FFI
    [(and (eq? mode 'default) (uv-loop-scheduler loop))
     (drive-loop loop 'default)
     0]
    [else
     (%ffi-uv-run (uv-loop-ptr loop) (uv-run-mode->int mode))]))
```
> 注：`uv-loop-scheduler` 仅在首次 `spawn-coroutine!` 时被创建，因此纯 libuv 程序
> （从不用协程）此分支恒为 #f，`uv-run` 行为完全不变。

### 阶段
1. 在 `internal/scheduler.ss` 抽出 `drive-loop`，`run-scheduler` 改为 `(drive-loop loop 'scheduler)`。
   —— 此步不改任何外部行为，现有协程测试应保持全绿。
2. `event-loop.ss` import scheduler，`uv-run 'default` 委托 `drive-loop`（当存在调度器时）。
3. 回归测试：`(async ...)` 后用 `(uv-run loop 'default)` 应正确执行并完成。
4. 复查 `run-async` 的双重驱动（`run-scheduler` 后再 `promise-wait`），可简化但留作后续。

## 5. 风险与测试影响
- 现有协程测试全部用 `run-async` / `run-scheduler` → 阶段 1 保证语义不变，应保持全绿。
- 层次：`event-loop`(high) → `internal/scheduler` 已验证无环（scheduler 不 import event-loop）。
- 无递归：`drive-loop` 内部用 `%ffi-uv-run`（FFI 直调），不经高层 `uv-run`；
  promise/微任务用 low-level timer/idle，也不经高层 `uv-run`。
- 与 F2（忙等自旋）的交互：统一驱动器**可以**顺带缓解 F2 —— 在情况 2 检测
  「`uv_run 'once` 返回 0（无活跃 ref 句柄）且 runnable 仍空且 pending 非空」时判定死锁并报错，
  而非空转。**但**微任务 idle handle 是 unref 的，pending 微任务时 `uv_run` 也返回 0，
  且微任务状态在 `high-level/promise.ss`、`internal/scheduler` 看不到——所以 F2 的完整修复
  需要跨模块暴露「是否有待处理微任务」，**建议 F2 仍单独处理**，不塞进本次。

## 6. 需要你拍板的决策

1. **是否采用方案 A（让 `uv-run 'default` 感知并驱动协程）？**
   备选是维持现状、仅加「检测到 async 未被调度器驱动时打印告警」的低风险改动
   （不消除陷阱，但零行为变更）。
2. 若采用 A：协程驱动**默认开启**（推荐，纯 libuv 程序不受影响），
   还是**藏在开关后**以彻底避免任何行为意外？
3. `'once` / `'nowait` 模式**保持直通**（推荐，属手动逐步控制），确认无需感知调度器？
