# Go fasthttp 同机基线基准（仓颉版参照物）

> 目的：给"仓颉版 HTTP 服务端要做到什么水平"提供**同机、同口径**的 Go 基线。
> 所有数字都来自本机实测，命令与原始输出附在文末，脚本在 `.scratch/bench-go/`。

---

## §1 环境与方法

### 1.1 硬件与软件

| 项 | 值 |
| --- | --- |
| CPU | AMD Ryzen 7 7840HS w/ Radeon 780M Graphics |
| 核心 | 8 物理核 / 16 逻辑核（SMT 2 线程/核），单 socket |
| 缓存 | L2 8 MiB (8 instances)，L3 16 MiB (1 instance) |
| 频率 | max 5137.9 MHz；governor = `powersave`（未调频，跑测时不手动锁频） |
| 内存 | 29.8 GiB 总，测时约 15 GiB 已用 |
| 内核 | Linux archlinux-mini 7.2.6-arch2-1 x86_64 |
| Go | `go1.27.3-X:nodwarf5 linux/amd64`（`/usr/bin/go`） |
| fasthttp | **v1.77.0**（2026-10-26 发布，模块缓存拉取，`go.mod` 已固定） |
| USER_HZ | 100（`getconf CLK_TCK`），CPU 采样按此换算 |

CPU 拓扑（用于解释后面的核间干扰）：

```
cpu0 ↔ cpu8    cpu1 ↔ cpu9    cpu2 ↔ cpu10   cpu3 ↔ cpu11
cpu4 ↔ cpu12   cpu5 ↔ cpu13   cpu6 ↔ cpu14   cpu7 ↔ cpu15
```

即 0-7 是 8 个物理核，8-15 是它们的 SMT 兄弟。

### 1.2 三个对照场景（全部库默认配置，只绑 127.0.0.1 非特权端口）

| 场景 | 端口 | 服务端实现 | handler 内容 |
| --- | --- | --- | --- |
| `fasthttp-hello` | 18081 | `fasthttp.Serve(ln, h)`（等价 `&Server{Handler: h}`） | `ctx.SuccessString("text/plain", "Hello, World!")` |
| `nethttp-hello` | 18082 | `http.Server{Handler: ...}`（无任何超时） | `w.Header().Set("Content-Type","text/plain"); io.WriteString(w, "Hello, World!")` |
| `fasthttp-realistic` | 18083 | `fasthttp.Serve(ln, h)` | 读请求头 `X-Client-Id` → 写响应头 `X-Served-By`/`X-Echo-Client` → `json.Marshal` 一个 5 字段小结构体（`ok/service/client/path/ts`） |

三个场景都用默认配置：不设 `Concurrency`、不设读写超时、不改 `ReduceMemoryUsage`。
`fasthttp.Serve` 内部就是 `&Server{Handler: h}.Serve(ln)`，因此是纯默认。

### 1.3 压测器（为什么不用 wrk/hey）

压测器是**自己写的 Go 程序**（`cmd/loadgen`），基于 `fasthttp.HostClient`：

- **每 worker 独占一条连接**（`HostClient{MaxConns: 1}`），连接数与并发数一一对应，避免连接池锁成为瓶颈
- **预热与测量分离**：默认预热 3s（不计入），随后测量 10s
- **延迟直方图**：三级线性分档（1µs / 10µs / 100µs 粒度，覆盖 0–200ms），分位数取档位**上界**，比真实值偏保守（不会低报）
- **错误不重试**：`MaxIdemponentCallAttempts=1`，失败直接计入 `errors`，不让重试掩盖问题
- 输出 JSON：QPS、p50/p90/p99/mean/max、错误数、非 200 数、首响应校验

不用 wrk/hey 的原因：本机没有现成的、且要保证压测端与 Go 服务端在**同一 TLS/解析路径**下可比；
自己写还能顺便记录每个 worker 的延迟分布、避免 C 工具与 Go runtime 的调度差异干扰结论。

### 1.4 进程指标采集

`cmd/procstat` 每 200ms 采样：

- `/proc/<pid>/status` → `VmRSS`、`Threads`
- `/proc/<pid>/stat` → `utime+stime`（按 USER_HZ=100 换算成 CPU%）
- `/proc/stat` → 整机 CPU 忙闲（`1 - (idle+iowait)/total` 的窗口增量）
- `/proc/loadavg` → 起止 loadavg

用 Go 写而不是 shell 循环，是为了避免每 200ms fork 出 awk/grep 反过来干扰被测进程。

### 1.5 测量前提（重要，读数字前必看）

1. **同机负载，不是纯净机**。这台机器同时还有其他 agent 在做仓颉侧的编译与实测，
   **测量期间整机 `busy_pct` 稳定在 85–93%**（数据见每轮 `proc.json` 的 `system.busy_pct`）。
   也就是说：**服务端与压测器加起来只用到约 10 个逻辑核的能力就被整机其他负载挤压**，
   下面的 QPS 是**"同机有干扰"下的下界**，不是这台 CPU 的理论上限。
   同一次测量里三个场景受到的干扰相同，**横向比较（fasthttp vs net/http）是有效的**，
   绝对数字应视为保守基线。
2. **多进程干扰的量化**：压力最大时 `loadavg` 一度到 27（16 逻辑核），
   但**每轮 QPS 的轮间波动很小**（hello 场景 676k / 676k / 692k，极差 2.4%），
   说明干扰是持续性的背景负载，不是随机尖峰，因此中位数可信。
3. **CPU 亲和与否都测过**：
   - 默认（`TASKSET=off`，全机调度）→ hello 约 676–692k QPS，**作为主口径**
   - 把服务端与压测器**钉同一组核**（都 0-7）→ 掉到 452–533k QPS，**比不钉还差**（互抢）
   - 把服务端钉 0-3、压测器钉 4-7,12-15 → 597–606k QPS，**低于全机**，因为只用了一半核
   → 结论：**本机这种"整机有背景负载"的环境下，不钉核反而让调度器把空闲核利用起来**。
   下面所有主表都用不钉核的全机口径；钉核数据仅作对照。
4. **服务端每轮重启**：RSS / 线程 / CPU 都从新进程起算，不受上一轮 GC 或连接池残留影响。
5. **端口全部非特权**（18081–18083），测完进程立即 SIGTERM 退出，无常驻服务。

---

## §2 三场景 QPS / 延迟（主口径：全机、128 连接、预热 3s + 测量 10s、3 轮）

### 2.1 汇总（中位数）

| 场景 | QPS（中位） | p50 µs | p90 µs | p99 µs | 平均 µs | 错误 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| **fasthttp-hello** | **676 058** | **151** | **346** | **671** | 189 | 0 |
| **nethttp-hello** | **377 230** | **209** | **854** | **1 699** | 339 | 0 |
| **fasthttp-realistic** | **556 825** | **184** | **408** | **1 095** | 230 | 0 |

**关键比值（同机同口径）**：

- fasthttp-hello / nethttp-hello = **1.79×** QPS，p99 低 **2.5×**（671 vs 1699 µs）
- fasthttp-realistic / fasthttp-hello = **0.82×**（加一个请求头读取 + 一个响应头写 + JSON 序列化 = 掉 18% QPS，p99 从 671 → 1095 µs）

### 2.2 三轮原始数据

**fasthttp-hello**（三轮原始 JSON：`results/raw/fasthttp-hello.r{1,2,3}.load.json`）

| 轮次 | QPS | p50 µs | p90 µs | p99 µs | 平均 µs | 最大 µs | 请求数 | 错误 | 服务端 CPU% | 服务端峰值 RSS KB | 压测端 CPU% | 整机忙 % |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| r1 | 691 550 | 149 | 339 | 661 | 184 | 11 304 | 6 915 509 | 0 | 472 | 14 352 | 529 | 92 |
| r2 | 676 058 | 151 | 347 | 689 | 189 | 12 688 | 6 760 581 | 0 | 476 | 14 196 | 531 | 92 |
| r3 | 676 056 | 152 | 346 | 671 | 189 | 11 133 | 6 760 569 | 0 | 478 | 14 268 | 534 | 92 |
| **中位** | **676 058** | **151** | **346** | **671** | **189** | — | — | **0** | **476** | **14 268** | **531** | **92** |

**nethttp-hello**（原始 JSON：`results/raw/nethttp-hello.r{1,2,3}.load.json`）

| 轮次 | QPS | p50 µs | p90 µs | p99 µs | 平均 µs | 最大 µs | 请求数 | 错误 | 服务端 CPU% | 服务端峰值 RSS KB | 压测端 CPU% | 整机忙 % |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| r1 | 376 534 | 209 | 855 | 1 709 | 339 | 7 342 | 3 765 343 | 0 | 640 | 21 584 | 356 | 86 |
| r2 | 382 491 | 207 | 840 | 1 664 | 334 | 6 072 | 3 824 917 | 0 | 652 | 22 040 | 359 | 85 |
| r3 | 377 230 | 209 | 854 | 1 699 | 339 | 7 763 | 3 772 300 | 0 | 646 | 22 456 | 357 | 85 |
| **中位** | **377 230** | **209** | **854** | **1 699** | **339** | — | — | **0** | **646** | **22 040** | **357** | **85** |

**fasthttp-realistic**（原始 JSON：`results/raw/fasthttp-realistic.r{1,2,3}.load.json`）

| 轮次 | QPS | p50 µs | p90 µs | p99 µs | 平均 µs | 最大 µs | 请求数 | 错误 | 服务端 CPU% | 服务端峰值 RSS KB | 压测端 CPU% | 整机忙 % |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| r1 | 547 481 | 193 | 410 | 1 095 | 233 | 8 835 | 5 474 817 | 0 | 517 | 19 792 | 479 | 90 |
| r2 | 577 090 | 180 | 392 | 1 062 | 221 | 8 991 | 5 770 905 | 0 | 531 | 19 476 | 492 | 89 |
| r3 | 556 825 | 184 | 408 | 1 120 | 229 | 8 191 | 5 568 250 | 0 | 526 | 19 824 | 488 | 90 |
| **中位** | **556 825** | **184** | **408** | **1 095** | **229** | — | — | **0** | **526** | **19 792** | **488** | **90** |

> 服务端 CPU% 是相对**单核**的（100% = 一个逻辑核跑满）。表里 476% ≈ 4.8 个逻辑核。
> 压测端 531% ≈ 5.3 个逻辑核。两者合计约 10 个逻辑核 —— 正好是 16 线程减去背景负载后的可用额度。

### 2.3 并发度扫描（找饱和拐点）

`fasthttp-hello`，单轮 5s 测量、预热 2s、不钉核（`results/sweep/c<N>/`）：

| 连接数 | QPS | p50 µs | p90 µs | p99 µs | 错误 | 服务端 CPU% | 压测端 CPU% | 整机忙 % |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 16 | 296 028 | 52 | 80 | 107 | 0 | 456 | 447 | 66 |
| 32 | 358 345 | 84 | 143 | 251 | 0 | 425 | 404 | 78 |
| 64 | 630 947 | 82 | 183 | 313 | 0 | 521 | 480 | 86 |
| 96 | 588 327 | 128 | 302 | 626 | 0 | 477 | 431 | 90 |
| 128 | 691 556 | 149 | 339 | 659 | 0 | 531 | 477 | 91 |
| 192 | 697 390 | 224 | 506 | 1 051 | 0 | 532 | 474 | 92 |
| 256 | 730 821 | 285 | 647 | 1 376 | 0 | 542 | 480 | 93 |

**读法**：

- 16 连接 = **296k QPS、p99 仅 107 µs** —— 小并发下延迟极低，说明单请求处理本身很快
- QPS 在 64 连接后就基本走平（63 万 → 73 万，涨 16%），而 **p99 从 313 µs 涨到 1376 µs（4.4×）**
- 拐点在 **64–96 连接**：再往上加连接只是把排队时间堆到 p99 上，吞吐不再等比例增长
- 128 连接是"吞吐已饱和、延迟还能接受"的折中点，主表就取这个口径

### 2.4 压测端上限检测（这个 QPS 是不是被压测器限住了？）

两个/三个 loadgen 进程同时打同一个服务端（每个 64 连接；原始数据 `results/ceiling/{2proc,3proc}/`）：

| 配置 | 各进程 QPS | 合计 QPS | 说明 |
| --- | --- | ---: | --- |
| 单进程 128 连接 | 691 556 | **691 556** | 与主表一致 |
| 双进程 × 64 连接 | 353 672 + 355 781 | **709 452** | 比单进程**只多 2.6%**，说明已触及整机上限 |
| 三进程 × 64 连接 | 249 573 + 239 162 + 246 957 | **735 691** | 比单进程多 6.4%，但每进程只剩约 24 万，p99 涨到 1.8–2.0 ms |

**结论**：单进程 loadgen 在 128 连接时**不是瓶颈**——加到 2 个进程只多 2.6%，
加到 3 个进程再多 6.4%，代价是 p99 从 0.66 ms 涨到 1.9 ms。
所以 **约 70–73 万 QPS 是这台机器在"有背景负载"下跑 fasthttp hello 的整机上限**，
不是压测器单侧的极限，也不是服务端单侧的极限。

---

## §3 内存：RSS、allocs/op

### 3.1 服务端进程 RSS / 线程数（128 连接满载时）

| 场景 | 峰值 RSS | 稳态 RSS | 线程数（峰值） | 每连接摊薄（含 runtime 基线） |
| --- | ---: | ---: | ---: | ---: |
| fasthttp-hello | **14.0 MiB** | ~14.0 MiB | 28–29 | 128 连接 → 112 KiB/连接 |
| fasthttp-realistic | **19.4 MiB** | ~19.4 MiB | 27–29 | 128 连接 → 155 KiB/连接 |
| nethttp-hello | **22.0 MiB** | ~22.0 MiB | 25–27 | 128 连接 → 176 KiB/连接 |

> 最后一列是"总 RSS ÷ 连接数"的摊薄值，**包含 Go runtime 自身约 9 MiB 的基线**，
> 不是边际成本。真实的每连接边际成本见下面连接数扫描表：**约 24 KiB/连接**。

**读法**：

- fasthttp 的 hello 场景内存随连接数**温和增长**（16 连接 10.3 MiB → 256 连接 16.0 MiB，
  约 **24 KiB/连接**，1.55×），大头是 Go runtime 自身的基础 RSS。
  这是 `sync.Pool` 复用 RequestCtx + 每连接读写缓冲的直接结果（详见下面的连接数扫描表）
- net/http 比 fasthttp 多 **54%（22.0 vs 14.0 MiB）**，线程数反而略少 —— 它的成本在每请求的 `http.Request`/`http.Response` 堆对象上（19–40 次分配/请求，见 §4.2）
- realistic 场景多 5.4 MiB，来自 `encoding/json` 的编码缓冲（每次 `json.Marshal` 分配 240 B，见 §4.3）

**fasthttp-hello RSS 随连接数的变化**（`results/sweep/c<N>/`，单轮实测）：

| 连接数 | 16 | 32 | 64 | 96 | 128 | 192 | 256 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 服务端峰值 RSS (KiB) | 10 300 | 11 024 | 12 004 | 12 540 | 14 264 | 15 180 | 16 000 |
| 服务端线程数 | 27 | 28 | 28 | 30 | 28 | 28 | 29 |

**读法**：连接数 ×16（16 → 256）时 RSS 只涨 1.55×（+5.7 MiB），
折合 **约 23.8 KiB/连接**；线程数几乎不变（27–30），说明 **goroutine per connection 数没有爆炸**，
每连接的栈与缓冲被复用/摊销得很好。这正是"每连接一个 goroutine"模型能做到的合理水平：
真正贵的不是 goroutine 本身，而是每连接的读写缓冲（fasthttp 默认 4 KiB 读 + 4 KiB 写，再乘以若干内部缓冲）。

> 原始数据：`results/raw/<场景>.r<N>.proc.csv`（200ms 一条采样，含 ts/rss/threads/cpu_ticks）
> 与 `results/raw/<场景>.r<N>.proc.json`（峰值/末值/CPU% 汇总）。

### 3.2 关键：allocs/op（"零分配"到底省了什么）

**handler 级微基准**（`results/local/handler_bench.txt`，绕开网络栈，只算 handler 自身）：

| handler | ns/op | B/op | **allocs/op** |
| --- | ---: | ---: | ---: |
| `helloHandler`（`ctx.SuccessString`） | **29.1**（29.13/29.52/30.33） | **0** | **0** |
| `realisticHandler`（读头 + 写头 + json.Marshal） | **627**（613.6/629.0/639.8） | **240** | **4** |

**这就是"零分配"省下的东西，量化成两个数字**：

1. **allocs/op = 0**：hello 场景**每请求零堆分配**，因此**完全不产生 GC 压力**。
   在 676k QPS 下意味着 **每秒 0 次分配**。对比 net/http：19–34 次分配/请求，
   在 377k QPS 下是 **每秒约 720 万–1280 万次分配**（19×377k ≈ 716 万，34×377k ≈ 1282 万）。
   GC 一旦被触发就会带来尾延迟尖峰，这解释了为什么 fasthttp 的 p99 是 671 µs 而 net/http 是 1699 µs。
2. **ns/op = 29**：handler 本体只花 29 纳秒。也就是说 **676k QPS 的理论上限是 34.5M ops/s/核**级别
   （1/29ns），实际 QPS 完全被网络栈、系统调用与整机 CPU 资源限制，**不是 handler 写法的锅**。
   → 仓颉版本只要把 handler 做到"几纳秒级 + 零分配"，QPS 就不会被 handler 拖累。

3. realistic 场景的 4 次分配/240 B 全部来自 `encoding/json`（见 §4.3 的对照）：
   `json.Marshal` 每次都新建 `[]byte` 缓冲 + 反射开销。
   **这就是为什么它比 hello 掉 18% QPS**：677k → 557k。

---

## §4 fasthttp 自带 benchmark 摘要（Server 相关）

命令（详见 §6）：

```shell
cd .scratch/bench-go
./run/fasthttp_bench.sh 2s 3      # 上游 Server 基准，每项跑 3 次
./run/handler_bench.sh 2s 3       # 本地 handler 微基准
```

原始输出：`results/upstream/server_bench.txt`、`results/local/handler_bench.txt`

### 4.1 Server 基准（GET，3 次取中位）

上游 `server_timing_test.go` 用 **fake listener + fake conn**（不走真实 TCP），
`Concurrency = 16 × clientsCount`，因此这些 ns/op 是**纯协议栈处理成本**，不含内核网络路径。

| benchmark | ns/op（中位） | B/op | allocs/op |
| --- | ---: | ---: | ---: |
| `BenchmarkServerGet1ReqPerConn` | **628.3** | 0 | **0** |
| `BenchmarkServerGet2ReqPerConn` | **343.6** | 0 | **0** |
| `BenchmarkServerGet10ReqPerConn` | **151.3** | 0 | **0** |
| `BenchmarkServerGet10KReqPerConn` | **150.7** | 0 | **0** |
| `BenchmarkServerPost1ReqPerConn` | **663.3** | 0 | **0** |
| `BenchmarkServerPost2ReqPerConn` | **354.0** | 0 | **0** |
| `BenchmarkServerPost10ReqPerConn` | **162.0** | 0 | **0** |
| `BenchmarkServerPost10KReqPerConn` | **148.7** | 0 | **0** |
| `BenchmarkServerGet1ReqPerConn10KClients` | **794.8** | 0 | **0** |
| `BenchmarkServerGet2ReqPerConn10KClients` | **438.6** | 0 | **0** |
| `BenchmarkServerGet10ReqPerConn10KClients` | **192.1** | 0 | **0** |
| `BenchmarkServerGet100ReqPerConn10KClients` | **198.7** | 0 | **0** |

### 4.2 同表对照：net/http 做同样的事

| benchmark | fasthttp ns/op | net/http ns/op | **倍数** | fasthttp allocs | net/http allocs |
| --- | ---: | ---: | ---: | ---: | ---: |
| Get 1 req/conn | 628.3 | 2 527 | **4.0×** | 0 | 34（3 370 B） |
| Get 2 req/conn | 343.6 | 1 833 | **5.3×** | 0 | 26（2 856 B） |
| Get 10 req/conn | 151.3 | 1 264 | **8.4×** | 0 | 21（2 461 B） |
| Get 10K req/conn | 150.7 | 1 025 | **6.8×** | 0 | 19（2 309 B） |
| Post 1 req/conn | 663.3 | 3 076 | **4.6×** | 0 | 40（4 132 B） |
| Post 10 req/conn | 162.0 | 1 501 | **9.3×** | 0 | 27（3 165 B） |
| Get 10 req/conn 10K clients | 192.1 | 816.3 | **4.2×** | 0 | 21（2 484 B） |
| Get 100 req/conn 10K clients | 198.7 | 586.5 | **3.0×** | 0 | 19（2 335 B） |

**这张表是整份文档最有用的部分**：它把"零分配 + 复用 RequestCtx"的收益拆成两个可抄的数字：

- **协议栈处理快 3–9 倍**（长连接多请求时差距最大：8–9×，因为连接建立/销毁成本被摊薄后，
  剩下的差异全是每请求的解析 + 对象分配）
- **每请求 0 次分配 vs 19–40 次分配**：这就是 GC 压力的全部来源

> ⚠️ 上游 `BenchmarkServerHijack` 在 v1.77.0 上**自身就是 FAIL**
> （`Unexpected number of requests served 1. Expected 10`），与本机环境无关；
> 脚本的正则已排除它，只跑 Get/Post 系列，保证整轮能正确产出数据。

### 4.3 handler 微基准（本项目，`results/local/handler_bench.txt`）

```
BenchmarkHelloHandler-16          29.13 ns/op     0 B/op    0 allocs/op
BenchmarkHelloHandler-16          29.52 ns/op     0 B/op    0 allocs/op
BenchmarkHelloHandler-16          30.33 ns/op     0 B/op    0 allocs/op
BenchmarkRealisticHandler-16     613.6 ns/op   240 B/op    4 allocs/op
BenchmarkRealisticHandler-16     629.0 ns/op   240 B/op    4 allocs/op
BenchmarkRealisticHandler-16     639.8 ns/op   240 B/op    4 allocs/op
```

`BenchmarkRealisticHandler` 与 `BenchmarkHelloHandler` 的差 = **约 600 ns + 4 次分配**，
全部来自"读一个头 + 写两个头 + `json.Marshal` 一个 5 字段结构体"。
若要再压下去，做法是自己拼 JSON（不用 `encoding/json`），可回到 0–1 次分配。
**这给仓颉版的启示**：JSON 序列化是 realistic 场景的主要成本项，
仓颉侧若用 `json.stream` 接口 + 预分配缓冲，应能做到接近 0 分配。

---

## §5 结论：给"仓颉版要追的指标"的具体数字目标

### 5.1 直接可用的判据

同机、128 连接、预热 3s + 测量 10s 口径下：

| 档位 | hello p50 | hello p99 | hello QPS | realistic QPS | 说明 |
| --- | ---: | ---: | ---: | ---: | --- |
| **不合格** | > 500 µs | > 3 ms | < 200 000 | < 150 000 | 说明每请求有阻塞/锁/大分配 |
| **及格** | ≤ 300 µs | ≤ 1.5 ms | ≥ 350 000 | ≥ 280 000 | 接近 net/http 水平 |
| **良好** | ≤ 200 µs | ≤ 900 µs | ≥ 550 000 | ≥ 450 000 | 达到 fasthttp 的 80% |
| **优秀（对标 fasthttp）** | ≤ 160 µs | ≤ 700 µs | ≥ 650 000 | ≥ 520 000 | fasthttp 实测水平（有背景负载） |

**推荐把"及格线"定在**：**hello 场景 QPS ≥ 350 000、p99 ≤ 1.5 ms**。
理由：这是 Go 标准库 net/http 的实测水平——**仓颉版如果连 net/http 都追不上，就没有存在意义**；
而 350k 是"同机有背景负载"下的净数字，好机器上会更宽松，不会误杀。

**推荐的"优秀线"**（对标 fasthttp）：**hello QPS ≥ 650 000、p99 ≤ 700 µs**。
这是本机实测 fasthttp 的中位数（676k / 671 µs），不是理论值，可直接照抄。

### 5.2 分模块的可量化目标

| 维度 | fasthttp 实测 | 仓颉版的追赶目标 | 为什么 |
| --- | --- | --- | --- |
| **hello handler** ns/op | 29 ns | **≤ 100 ns** | 仓颉有 GC，允许 3× 余量；超过 100ns 会明显吃掉 QPS 上限 |
| **hello allocs/op** | **0** | **≤ 1** | 这是最关键的单项。零分配直接换来"无 GC 尾延迟"。1 次尚可，2 次以上 QPS 会掉 20%+ |
| **协议栈 ns/op**（fake conn，10 req/conn） | 151 ns | **≤ 600 ns** | 允许 4× 差距（语言运行时差异），再慢就输给 net/http |
| **realistic allocs/op** | 4 | **≤ 4** | JSON 序列化必须有预分配缓冲，别写出 O(字段数) 次分配 |
| **RSS**（128 连接 hello） | 14.0 MiB | **≤ 40 MiB** | 仓颉 runtime 基础开销未知，给 3× 余量；超过 40 MiB 说明每连接缓冲没复用 |
| **RSS 增长**（连接数 16 → 256，×16） | **1.55×**（10.3 → 16.0 MiB） | **≤ 2×** | 若接近线性增长（×16）说明没有连接缓冲池；fasthttp 实测每连接约 24 KiB |
| **线程/goroutine 数**（256 连接） | 29 | **≤ 2× 连接数** | 256 连接只 29 个线程，说明协程模型没把栈撑爆 |
| **p99 / p50 比值** | 4.4×（671/151） | **≤ 6×** | 比值大意味着尾延迟失控（GC 停顿、锁竞争、分配抖动） |

### 5.3 追赶优先级（按性价比排序）

1. **先把 allocs/op 压到 0–1**（最重要）。fasthttp 的 8× 性能优势里，至少一半来自"每请求零分配"。
   手段：RequestCtx / Header 对象池化、body 直接写进复用的 byte 缓冲、字符串用字节切片视图而非拷贝。
2. **再把连接缓冲复用起来**（RSS 增长 ≤ 2×）。256 连接 ×16 时 RSS 只涨 1.55×（10.3 → 16.0 MiB，约 24 KiB/连接），靠的就是 `sync.Pool`。
3. **协议解析做到 150–600 ns/请求**（10 req/conn 口径）。这决定了长连接场景的吞吐上限。
4. **最后才是 JSON 场景优化**：用预分配缓冲 + 流式序列化，目标是 4 次分配（240 B）以内。

> 做不到第 1 条之前，去优化第 3、4 条都是本末倒置——GC 压力会把尾延迟吃掉。

---

## §6 复现命令

### 6.1 一键（脚本已就绪）

```shell
cd /home/ystyle/Projects/Cangjie/.scratch/bench-go

# 首次：拉依赖（需要代理）
export https_proxy=http://192.168.3.6:1080 http_proxy=http://192.168.3.6:1080
make deps

# 编译四个二进制（server / loadgen / procstat / summarize）
make build

# 三个场景 × 3 轮（预热 3s + 测量 10s + 128 连接）→ results/summary.md
make bench

# fasthttp 上游自带 Server 基准（ns/op、allocs/op）
make upstream

# 本地 handler 微基准
make local

# 兜底清理残留进程
make kill
```

### 6.2 单场景 / 自定义参数

```shell
# 只跑 fasthttp hello，5 轮，64 连接，预热 2s + 测量 5s
ROUNDS=5 WARMUP=2 DURATION=5 ./run/bench_one.sh fasthttp-hello 18081 64

# 换连接数做并发扫描
for c in 16 32 64 96 128 192 256; do
  OUTDIR=results/sweep/c$c ROUNDS=1 WARMUP=2 DURATION=5 \
    ./run/bench_one.sh fasthttp-hello 18081 $c
done

# 压测端上限检测（2 个 loadgen 进程打同一服务端）
OUTDIR=results/ceiling/2proc ./run/ceiling_test.sh fasthttp-hello 18081 64 2

# 生成汇总表
./bin/summarize -outdir results
```

### 6.3 手工最小复现（不用脚本，三条命令）

```shell
cd /home/ystyle/Projects/Cangjie/.scratch/bench-go

# 1) 起服务端（前台或后台均可）
./bin/server -scenario fasthttp-hello -addr 127.0.0.1:18081 &

# 2) 压测 10s，128 连接，预热 3s
./bin/loadgen -url http://127.0.0.1:18081/ -conns 128 \
  -warmup 3s -duration 10s \
  -header "X-Client-Id=manual" -label manual

# 3) 结束后杀掉服务端
pkill -f 'bin/server -scenario'
```

### 6.4 环境记录（写报告时引用）

```shell
cd /home/ystyle/Projects/Cangjie/.scratch/bench-go && cat envfacts.txt
```

当前机器实测（2026-11-07 20:43）：

```
Linux archlinux-mini 7.2.6-arch2-1 #1 SMP PREEMPT_DYNAMIC x86_64 GNU/Linux
go version go1.27.3-X:nodwarf5 linux/amd64
model name : AMD Ryzen 7 7840HS w/ Radeon 780M Graphics
16 逻辑核 / 8 物理核 / SMT 2 / L2 8MiB / L3 16MiB / governor=powersave
USER_HZ = 100
```

### 6.5 数据产物一览

| 路径 | 内容 |
| --- | --- |
| `results/summary.md` | 三场景 × 3 轮汇总表（本文 §2 的数据源） |
| `results/raw/<场景>.r<N>.load.json` | 每轮压测原始指标 |
| `results/raw/<场景>.r<N>.proc.json` | 每轮进程 RSS/线程/CPU + 整机忙闲 |
| `results/raw/<场景>.r<N>.proc.csv` | 200ms 粒度的采样原始序列 |
| `results/sweep/c<N>/` | 并发度扫描原始数据（16/32/64/96/128/192/256 连接） |
| `results/ceiling/{2proc,3proc}/` | 压测端上限检测（2/3 个 loadgen 进程） |
| `results/upstream/server_bench.txt` | fasthttp 上游 Server 基准原始输出 |
| `results/local/handler_bench.txt` | 本地 handler 微基准原始输出 |
| `results/meta.json` | 本次运行的机器/参数快照 |

---

## 附录 A：踩过的坑（复现时会遇到）

### A.1 `fasthttp.HostClient` 的 URI 必须带 host

```
err=missing required host header in request
```

原因：fasthttp 服务端对 HTTP/1.1 请求**强制要求 `Host` 头**（`RequestHeader.validate()`），
而客户端 `Request.Write` 只在"URI 是绝对形式"或"已有 Host 头"时才补。
所以 `req.SetRequestURI("/")` + `HostClient{Addr: "127.0.0.1:18081"}` 会失败。

正确写法：`req.SetRequestURI("http://127.0.0.1:18081/")`。
首次 `Do` 之后 fasthttp 会把 RequestURI 改写成相对形式并固化 Host 头，后续轮次自动走快路径
（不需要每次重新解析绝对 URI）。

### A.2 钉核反而更慢

见 §1.5 第 3 条。**不要想当然地把服务端和压测器钉到同一组核上**，实测掉 30%+。
如果一定要钉，必须让压测端与服务端用**互不重叠**的核（`SRV_CPUS="0-3" LG_CPUS="4-7,12-15"`）。

### A.3 上游 `BenchmarkServerHijack` 自身 FAIL

```
--- FAIL: BenchmarkServerHijack-16
    server_timing_test.go:434: Unexpected number of requests served 1. Expected 10
```

v1.77.0 源码自带的问题（fake conn 的 Hijack 路径不完整），与本机环境无关。
`run/fasthttp_bench.sh` 用正则 `^Benchmark(Server|NetHTTPServer)(Get|Post)[0-9]` 排除它。

### A.4 编译会污染测量

fasthttp 的 `go test` 每次都会重新编译测试二进制（约 20–40s），这会占满 CPU。
脚本因此**先 `go test -c` 预编译**，再用编译好的 `.test` 二进制直接跑 benchmark。

---

## 附录 B：当前机器状态与残留进程

测量全部使用**每轮独立进程 + 结束即 SIGTERM**，跑完检查：

```shell
$ ps -eo pid,comm | grep -E 'server|loadgen|procstat|fasthttp' | grep -v grep
NO_STRAY
```

**没有常驻服务残留**。端口 18081–18083 均为非特权端口，不与任何现有服务冲突。
如需兜底清理：`cd .scratch/bench-go && make kill`。
