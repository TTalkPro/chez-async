# DNS 服务器实现方案

> 基于现有 chez-async 代码库实现智能 DNS 服务器的技术方案

---

## 目录

- [现有基础设施](#现有基础设施)
- [已有的 DNS 缓存代理架构](#已有的-dns-缓存代理架构)
- [核心需求实现方案](#核心需求实现方案)
  - [1. 同时查询多个 DNS 服务器](#1-同时查询多个-dns-服务器)
  - [2. 根据特定策略返回 DNS 结果](#2-根据特定策略返回-dns-结果)
  - [3. 根据策略查询特定 DNS](#3-根据策略查询特定-dns)
- [建议的项目结构](#建议的项目结构)
- [核心实现代码框架](#核心实现代码框架)
- [关键技术要点](#关键技术要点)
- [实现路线图](#实现路线图)

---

## 现有基础设施

| 组件 | 位置 | 状态 | 说明 |
|------|------|------|------|
| **UDP 套接字** | `low-level/udp.ss` | ✅ 完整 | 发送/接收/绑定/多播支持 |
| **DNS 协议解析** | `examples/dns-cache-proxy.ss` | ✅ 完整 | RFC 1035 最小子集实现 |
| **async/await** | `high-level/async-await.ss` | ✅ 完整 | call/cc 协程实现 |
| **并发组合器** | `high-level/async-combinators.ss` | ✅ 完整 | async-all, async-race, async-timeout |
| **DNS 客户端** | `low-level/dns.ss` | ⚠️ 仅客户端 | libuv getaddrinfo 封装 |

### 现有 API 参考

#### UDP 操作 (`low-level/udp.ss`)

```scheme
;; 创建 UDP 句柄
(uv-udp-init loop)
(uv-udp-init-ex loop flags)

;; 绑定/连接
(uv-udp-bind udp addr port [flags])
(uv-udp-connect udp addr port)
(uv-udp-disconnect udp)

;; 发送/接收
(uv-udp-send! udp data [addr port] callback)
(uv-udp-try-send udp data [addr port])
(uv-udp-recv-start! udp callback)
(uv-udp-recv-stop! udp)

;; 地址信息
(uv-udp-getsockname udp)    ; => (ip . port)
(uv-udp-getpeername udp)    ; => (ip . port)

;; 多播支持
(uv-udp-join-multicast-group! udp multicast-addr [interface-addr])
(uv-udp-leave-multicast-group! udp multicast-addr [interface-addr])
(uv-udp-set-multicast-loop! udp enable?)
(uv-udp-set-multicast-ttl! udp ttl)
```

#### async/await (`high-level/async-await.ss`)

```scheme
;; 创建异步任务
(async body ...)              ; 返回 Promise
(async/loop loop body ...)    ; 指定事件循环
(await promise)               ; 等待 Promise 完成

;; 运行
(run-async promise)           ; 同步等待完成
(run-async-loop)              ; 运行调度器
```

#### 并发组合器 (`high-level/async-combinators.ss`)

```scheme
(async-all promises)          ; 等待全部完成
(async-race promises)         ; 返回最快的
(async-any promises)          ; 返回首个成功
(async-timeout promise ms)    ; 添加超时
(async-sleep ms)              ; 延迟
(async-delay ms thunk)        ; 延迟执行
```

---

## 已有的 DNS 缓存代理架构

`examples/dns-cache-proxy.ss` 已经实现了核心框架：

```
┌─────────────────────────────────────────────────────────┐
│                    DNS Cache Proxy                       │
├─────────────────────────────────────────────────────────┤
│  ┌─────────────┐    ┌──────────────┐    ┌────────────┐ │
│  │ UDP Server  │───▶│ DNS Parser   │───▶│   Cache    │ │
│  │ (recv/send) │    │ (RFC 1035)   │    │  (hashtable)│ │
│  └─────────────┘    └──────────────┘    └────────────┘ │
│         │                   │                   │       │
│         ▼                   ▼                   ▼       │
│  ┌─────────────┐    ┌──────────────┐    ┌────────────┐ │
│  │ async 协程  │    │ query-upstream│   │ TTL 管理   │ │
│  │ (handle-query)│   │ (Promise)    │    │            │ │
│  └─────────────┘    └──────────────┘    └────────────┘ │
└─────────────────────────────────────────────────────────┘
```

### 关键实现点

1. **哨兵协程** - 永不 resolve 的 Promise 保持调度器活跃
2. **UDP recv 回调** - 在回调中 spawn async 协程处理每个查询
3. **Promise 包装** - `udp-send-async` 和 `query-upstream` 返回 Promise
4. **缓存机制** - 基于 TTL 的哈希表缓存

---

## 核心需求实现方案

### 1. 同时查询多个 DNS 服务器

**实现方案**：使用 `async-all` 或 `async-race` 组合器

```scheme
;; dns-server/upstream.ss

;; 单个上游查询
(define (query-upstream-specific query-bv addr port)
  "向指定上游 DNS 发送查询，返回 Promise<bytevector>"
  (let ([loop (uv-default-loop)])
    (make-promise loop
      (lambda (resolve reject)
        (let ([tmp-udp (uv-udp-init loop)]
              [timer (uv-timer-init loop)]
              [done? #f])

          (define (cleanup!)
            (uv-handle-close! timer)
            (uv-udp-recv-stop! tmp-udp)
            (uv-handle-close! tmp-udp))

          (uv-udp-recv-start! tmp-udp
            (lambda (udp data-or-error sender-addr flags)
              (when (and (not done?) (bytevector? data-or-error)
                         (>= (bytevector-length data-or-error) 12))
                (set! done? #t)
                (cleanup!)
                (resolve data-or-error))))

          (uv-timer-start! timer 3000 0
            (lambda (t)
              (unless done?
                (set! done? #t)
                (cleanup!)
                (reject (make-timeout-error 3000)))))

          (uv-udp-send! tmp-udp query-bv addr port
            (lambda (err)
              (when (and err (not done?))
                (set! done? #t)
                (cleanup!)
                (reject err))))))))

;; 并发查询多个上游
(define (query-multiple-upstreams query-bv upstreams)
  "并发查询多个上游 DNS，返回 Promise<(result . upstream)>"
  (async
    (let* ([promises (map (lambda (up)
                            (async
                              (cons (await (query-upstream-specific 
                                            query-bv (car up) (cdr up)))
                                    up)))
                          upstreams)])
      ;; 等待所有结果
      (await (async-all promises)))))

;; 竞速查询（返回最快的）
(define (query-race-upstreams query-bv upstreams)
  "竞速查询，返回最快响应的结果"
  (async
    (let* ([promises (map (lambda (up)
                            (query-upstream-specific 
                              query-bv (car up) (cdr up)))
                          upstreams)])
      (await (async-race promises)))))
```

**配置示例**：

```scheme
;; 多个上游 DNS 配置
(define *upstreams*
  '(("8.8.8.8" . 53)           ; Google DNS
    ("1.1.1.1" . 53)           ; Cloudflare DNS
    ("114.114.114.114" . 53)   ; 114 DNS
    ("223.5.5.5" . 53)))       ; 阿里 DNS
```

---

### 2. 根据特定策略返回 DNS 结果

**实现方案**：策略函数 + 结果选择器

```scheme
;; dns-server/strategy.ss

(library (chez-async dns-server strategy)
  (export
    ;; 策略类型
    dns-strategy?
    make-dns-strategy
    dns-strategy-name
    
    ;; 内置策略
    strategy-fastest
    strategy-majority
    strategy-priority
    strategy-first-valid
    
    ;; 策略应用
    apply-strategy)
  
  (import (chezscheme)
          (chez-async dns-server protocol))

  ;; 策略记录类型
  (define-record-type dns-strategy
    (fields
      (immutable name)       ; 策略名称
      (immutable selector))) ; 选择函数: (list result) -> result

  ;; 策略 1: 最快响应（第一个有效结果）
  (define strategy-fastest
    (make-dns-strategy 'fastest
      (lambda (results)
        (let ([valid (filter valid-response? results)])
          (if (null? valid)
              (car results)  ; 全部失败时返回第一个
              (car valid))))))

  ;; 策略 2: 多数投票（相同答案最多的）
  (define strategy-majority
    (make-dns-strategy 'majority
      (lambda (results)
        (let* ([valid (filter valid-response? results)]
               [groups (group-by-answer valid)])
          (if (null? groups)
              (car results)
              (car (max-by-length groups)))))))

  ;; 策略 3: 按上游优先级
  (define strategy-priority
    (make-dns-strategy 'priority
      (lambda (results)
        ;; results 已按优先级排序
        (let ([valid (filter valid-response? results)])
          (if (null? valid)
              (car results)
              (car valid))))))

  ;; 策略 4: 第一个有效结果
  (define strategy-first-valid
    (make-dns-strategy 'first-valid
      (lambda (results)
        (let ([valid (filter valid-response? results)])
          (if (null? valid)
              #f
              (car valid))))))

  ;; 应用策略
  (define (apply-strategy strategy results)
    ((dns-strategy-selector strategy) results))

  ;; 辅助函数
  (define (valid-response? result)
    "检查 DNS 响应是否有效"
    (and (bytevector? result)
         (>= (bytevector-length result) 12)
         (= (dns-rcode result) 0)))  ; NOERROR

  (define (group-by-answer results)
    "按答案内容分组"
    (let ([table (make-hashtable equal-hash equal?)])
      (for-each
        (lambda (result)
          (let ([key (extract-answer-key result)])
            (hashtable-update! table key
              (lambda (lst) (cons result lst))
              '())))
        results)
      (hashtable-values table)))

  (define (max-by-length groups)
    "返回长度最大的组"
    (if (null? groups)
        '()
        (let loop ([rest (cdr groups)] [max (car groups)])
          (if (null? rest)
              max
              (let ([curr (car rest)])
                (loop (cdr rest)
                      (if (> (length curr) (length max))
                          curr
                          max)))))))
  )
```

---

### 3. 根据策略查询特定 DNS

**实现方案**：域名匹配规则 + DNS 服务器选择

```scheme
;; dns-server/router.ss

(library (chez-async dns-server router)
  (export
    ;; 路由类型
    dns-route?
    make-dns-route
    dns-route-pattern
    dns-route-upstreams
    dns-route-strategy
    
    ;; 路由表
    make-router
    router-add-route!
    router-find-route
    
    ;; 便捷路由创建
    make-suffix-route
    make-regex-route
    make-default-route)
  
  (import (chezscheme)
          (chez-async dns-server strategy))

  ;; 路由规则记录类型
  (define-record-type dns-route
    (fields
      (immutable pattern)    ; 域名匹配谓词: (domain -> bool)
      (immutable upstreams)  ; 上游 DNS 列表: ((ip . port) ...)
      (immutable strategy))) ; 选择策略

  ;; 路由器
  (define-record-type router
    (fields
      (mutable routes)))

  (define (make-router)
    (make-router '()))

  (define (router-add-route! router route)
    "添加路由规则（添加到列表头部，优先匹配）"
    (router-routes-set! router
      (cons route (router-routes router))))

  (define (router-find-route router domain)
    "查找匹配的路由规则"
    (let loop ([routes (router-routes router)])
      (if (null? routes)
          #f
          (let ([route (car routes)])
            (if ((dns-route-pattern route) domain)
                route
                (loop (cdr routes)))))))

  ;; 便捷路由创建函数

  (define (make-suffix-route suffix upstreams strategy)
    "创建后缀匹配路由"
    (make-dns-route
      (lambda (domain)
        (string-suffix? suffix (string-downcase domain)))
      upstreams
      strategy))

  (define (make-regex-route pattern upstreams strategy)
    "创建正则匹配路由"
    (let ([regex (regexp pattern)])
      (make-dns-route
        (lambda (domain)
          (regexp-match regex domain))
        upstreams
        strategy)))

  (define (make-default-route upstreams strategy)
    "创建默认路由（匹配所有）"
    (make-dns-route
      (lambda (domain) #t)
      upstreams
      strategy))
  )
```

**路由配置示例**：

```scheme
;; dns-server/config.ss

(define (make-default-routes)
  (let ([r (make-router)])
    
    ;; 国内域名 -> 使用 114 DNS
    (router-add-route! r
      (make-suffix-route ".cn"
        '(("114.114.114.114" . 53)
          ("223.5.5.5" . 53))
        strategy-fastest))

    ;; 公司内网域名 -> 使用内部 DNS
    (router-add-route! r
      (make-suffix-route ".corp.example.com"
        '(("10.0.0.1" . 53))
        strategy-fastest))

    ;; 特殊域名 -> 使用特定 DNS
    (router-add-route! r
      (make-suffix-route ".google.com"
        '(("8.8.8.8" . 53)
          ("8.8.4.4" . 53))
        strategy-majority))

    ;; 广告域名拦截 -> 返回 0.0.0.0
    (router-add-route! r
      (make-regex-route "^(ad|ads|adv|tracking)\\."
        'block
        strategy-first-valid))

    ;; 默认 -> 多 DNS 并发
    (router-add-route! r
      (make-default-route
        '(("8.8.8.8" . 53)
          ("1.1.1.1" . 53)
          ("114.114.114.114" . 53))
        strategy-majority))

    r))
```

---

## 建议的项目结构

```
chez-async/
├── dns-server/                    # DNS 服务器模块
│   ├── protocol.ss               # DNS 协议解析（RFC 1035）
│   │   - dns-id, dns-flags, dns-qr?
│   │   - dns-parse-name, dns-parse-question
│   │   - dns-parse-answer, dns-extract-min-ttl
│   │   - build-dns-query, encode-dns-name
│   │
│   ├── upstream.ss               # 上游查询
│   │   - query-upstream-specific (单个)
│   │   - query-multiple-upstreams (并发)
│   │   - query-race-upstreams (竞速)
│   │
│   ├── strategy.ss               # 结果选择策略
│   │   - strategy-fastest
│   │   - strategy-majority
│   │   - strategy-priority
│   │   - strategy-first-valid
│   │
│   ├── router.ss                 # 域名路由规则
│   │   - dns-route, router
│   │   - make-suffix-route
│   │   - make-regex-route
│   │
│   ├── cache.ss                  # 缓存层
│   │   - dns-cache
│   │   - cache-lookup, cache-store!
│   │   - cache-invalidate!
│   │
│   ├── server.ss                 # UDP 服务器主入口
│   │   - make-dns-server
│   │   - dns-server-start!
│   │   - dns-server-stop!
│   │
│   └── config.ss                 # 配置示例
│
├── examples/
│   ├── dns-cache-proxy.ss        # 现有（保留）
│   ├── dns-smart-server.ss       # 智能DNS服务器
│   └── dns-load-balancer.ss      # DNS 负载均衡器
│
└── docs/
    └── dns-server-implementation.md  # 本文档
```

---

## 核心实现代码框架

### 完整服务器实现

```scheme
;; dns-server/server.ss

(library (chez-async dns-server)
  (export
    ;; 服务器
    make-dns-server
    dns-server-start!
    dns-server-stop!
    dns-server?
    
    ;; 配置
    dns-server-add-route!
    dns-server-set-default-upstreams!
    
    ;; 统计
    dns-server-stats
    dns-server-reset-stats!)
  
  (import (chezscheme)
          (chez-async)
          (chez-async dns-server protocol)
          (chez-async dns-server upstream)
          (chez-async dns-server strategy)
          (chez-async dns-server router)
          (chez-async dns-server cache))

  ;; DNS 服务器记录类型
  (define-record-type dns-server
    (fields
      (mutable udp-handle)
      (mutable router)
      (mutable cache)
      (mutable stats)))

  (define (make-dns-server)
    (let ([loop (uv-default-loop)])
      (make-dns-server
        (uv-udp-init loop)
        (make-router)
        (make-dns-cache)
        (make-stats))))

  ;; 统计信息
  (define-record-type stats
    (fields
      (mutable queries)
      (mutable cache-hits)
      (mutable cache-misses)
      (mutable upstream-queries)
      (mutable errors)))

  (define (make-stats)
    (make-stats 0 0 0 0 0))

  ;; 处理单个查询（核心逻辑）
  (define (handle-query server query-bv client-addr)
    (async
      (guard (ex [else
                  (format #t "[ERROR] ~a~%" ex)
                  (stats-errors-set! (dns-server-stats server)
                    (+ 1 (stats-errors (dns-server-stats server))))])
        
        ;; 解析查询
        (let-values ([(qname qtype _ _) (dns-parse-question query-bv 12)])
          (format #t "[QUERY] ~a ~a from ~a:~a~%"
                  qname (dns-type->string qtype)
                  (car client-addr) (cdr client-addr))
          
          (stats-queries-set! (dns-server-stats server)
            (+ 1 (stats-queries (dns-server-stats server))))
          
          ;; 查找缓存
          (let ([cached (cache-lookup (dns-server-cache server) qname qtype)])
            (if cached
                ;; 缓存命中
                (begin
                  (stats-cache-hits-set! (dns-server-stats server)
                    (+ 1 (stats-cache-hits (dns-server-stats server))))
                  (format #t "  -> CACHE HIT~%")
                  (let ([response (bytevector-copy cached)])
                    (dns-set-id! response (dns-id query-bv))
                    (await (udp-send-async (dns-server-udp-handle server)
                             response (car client-addr) (cdr client-addr)))))
                
                ;; 缓存未命中，查询上游
                (begin
                  (stats-cache-misses-set! (dns-server-stats server)
                    (+ 1 (stats-cache-misses (dns-server-stats server))))
                  
                  ;; 查找路由
                  (let* ([route (router-find-route (dns-server-router server) qname)]
                         [upstreams (dns-route-upstreams route)]
                         [strategy (dns-route-strategy route)])
                    
                    ;; 检查是否为拦截
                    (if (eq? upstreams 'block)
                        (begin
                          (format #t "  -> BLOCKED~%")
                          (let ([response (build-blocked-response query-bv)])
                            (await (udp-send-async (dns-server-udp-handle server)
                                     response (car client-addr) (cdr client-addr)))))
                        
                        ;; 并发查询上游
                        (begin
                          (format #t "  -> Forwarding to ~a upstreams~%" (length upstreams))
                          (stats-upstream-queries-set! (dns-server-stats server)
                            (+ (length upstreams)
                               (stats-upstream-queries (dns-server-stats server))))
                          
                          (let* ([results (await (query-multiple-upstreams query-bv upstreams))]
                                 [selected (apply-strategy strategy results)])
                            
                            ;; 缓存结果
                            (when selected
                              (let ([ttl (extract-ttl selected)])
                                (cache-store! (dns-server-cache server)
                                  qname qtype selected ttl)))
                            
                            ;; 发送响应
                            (await (udp-send-async (dns-server-udp-handle server)
                                     selected (car client-addr) (cdr client-addr)))))))))))))

  ;; 启动服务器
  (define (dns-server-start! server port)
    (let ([udp (dns-server-udp-handle server)])
      (uv-udp-bind udp "0.0.0.0" port)
      (let ([addr (uv-udp-getsockname udp)])
        (format #t "DNS server listening on ~a:~a~%" (car addr) (cdr addr)))
      (uv-udp-recv-start! udp
        (lambda (udp data-or-error sender-addr flags)
          (when (and (bytevector? data-or-error)
                     (>= (bytevector-length data-or-error) 12)
                     (not (dns-qr? data-or-error)))
            (handle-query server data-or-error sender-addr))))))

  ;; 停止服务器
  (define (dns-server-stop! server)
    (let ([udp (dns-server-udp-handle server)])
      (uv-udp-recv-stop! udp)
      (uv-handle-close! udp)))

  ;; 添加路由
  (define (dns-server-add-route! server route)
    (router-add-route! (dns-server-router server) route))

  ;; 获取统计
  (define (dns-server-stats server)
    (let ([s (dns-server-stats server)])
      `((queries . ,(stats-queries s))
        (cache-hits . ,(stats-cache-hits s))
        (cache-misses . ,(stats-cache-misses s))
        (hit-rate . ,(if (> (stats-queries s) 0)
                        (* 100.0 (/ (stats-cache-hits s) (stats-queries s)))
                        0))
        (upstream-queries . ,(stats-upstream-queries s))
        (errors . ,(stats-errors s)))))

  ;; UDP Promise 包装器
  (define (udp-send-async udp data addr port)
    (make-promise (uv-default-loop)
      (lambda (resolve reject)
        (uv-udp-send! udp data addr port
          (lambda (err)
            (if err (reject err) (resolve #t)))))))
  )
```

---

## 关键技术要点

| 功能 | 现有支持 | 需要新增 | 复杂度 |
|------|---------|---------|--------|
| UDP 收发 | ✅ `low-level/udp.ss` | - | - |
| DNS 协议解析 | ✅ `dns-cache-proxy.ss` | 提取为独立模块 | 低 |
| async/await | ✅ 完整 | - | - |
| 并发查询 | ⚠️ `async-all` 可用 | 封装 `query-multiple` | 低 |
| 策略选择 | ❌ | 新增 `strategy.ss` | 中 |
| 域名路由 | ❌ | 新增 `router.ss` | 中 |
| 缓存管理 | ⚠️ 简单实现 | 增强 TTL/清理 | 低 |

---

## 实现路线图

### Phase 1: 协议层提取 (1-2 天)

- [ ] 创建 `dns-server/protocol.ss`
- [ ] 从 `dns-cache-proxy.ss` 提取协议解析代码
- [ ] 添加更多 DNS 记录类型支持 (AAAA, MX, TXT, CNAME)
- [ ] 编写单元测试

### Phase 2: 上游查询 (1 天)

- [ ] 创建 `dns-server/upstream.ss`
- [ ] 实现 `query-upstream-specific`
- [ ] 实现 `query-multiple-upstreams`
- [ ] 添加超时和重试机制

### Phase 3: 策略层 (1 天)

- [ ] 创建 `dns-server/strategy.ss`
- [ ] 实现基础策略 (fastest, majority, priority)
- [ ] 设计策略扩展接口

### Phase 4: 路由层 (1 天)

- [ ] 创建 `dns-server/router.ss`
- [ ] 实现路由匹配
- [ ] 支持后缀/正则/通配符匹配

### Phase 5: 服务器整合 (1-2 天)

- [ ] 创建 `dns-server/server.ss`
- [ ] 整合所有组件
- [ ] 添加统计和监控
- [ ] 创建示例程序

### Phase 6: 测试和文档 (1 天)

- [ ] 编写集成测试
- [ ] 编写使用文档
- [ ] 性能测试和优化

---

## 参考资源

- [RFC 1035 - Domain Names](https://tools.ietf.org/html/rfc1035) - DNS 协议规范
- [RFC 3596 - IPv6 DNS Extensions](https://tools.ietf.org/html/rfc3596) - AAAA 记录
- [libuv DNS documentation](https://docs.libuv.org/en/latest/dns.html)
- 现有代码: `examples/dns-cache-proxy.ss`
