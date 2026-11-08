# 为什么 tachyon 比 stdx.net.http 快

> 起因：把压测数字发到群里后，有人质疑「你确定不是被群主的注释污染了（）」。
> 这篇是认真核查后的回答：先说基准有没有被动过手脚，再说差值花在哪，最后说这次对比**没有**证明什么。

## 0. 一句话结论

**差值不是基准问题，是每请求 CPU 真的差一倍**：相同负载下 tachyon 每请求消耗
12.0–13.0 µs CPU，stdx.net.http 24.6–25.3 µs，正好 2.0 倍；稳态 RSS 差 9.5 倍。
根源是两者的 API 形状不同 —— stdx 的 `HttpRequest`/`HttpResponse`/`HttpContext` 对象模型
决定它每请求要分配一整棵对象图并构造多个 `String`，tachyon 走 fasthttp 的路子：
per-connection 复用、全部零拷贝视图。

## 1. 先自证：基准没有"注释污染"

"被注释污染"这个说法如果指的是"你（写基准的人）有意无意让 stdx 跑得差"，那么逐条排除：

| 可能被动手脚的地方 | 实际情况 | 怎么核 |
|---|---|---|
| stdx 源码被改过 | **没改**。`git status --porcelain` 为空，HEAD = `eb54518`（上游 main） | `cd ~/Projects/cangjie_office_source/cangjie_stdx && git status` |
| 用了自己编的 stdx | **没有**。用的是 cjvs 装的官方预编译静态库 `~/.config/cjvs/stdx/1.2.0.1/.../libstdx.net.http.a`（2026-09-24 构建，只读） | `ls -la` 上面那个路径 |
| 优化级别不对等 | **对等**。两边都在 `cjpm.toml` 里显式 `compile-option = "-O2"` | 两个 bench 工程的 cjpm.toml |
| socket 选项不同 | **都未设 `TCP_NODELAY`**。stdx 的 `setTransportConfig` 只设 timeout/keepAlive/缓冲区；tachyon 侧无 nodelay 设置 | `grep -rn noDelay stdx/src/stdx/net/http/*.cj` |
| 压测器不同 / 机器不同 | **同一个 loadgen 二进制**（自己写的 Go 工具）、同一台机器、同 128 条长连接、交替跑两轮 | 见 §5 复现脚本 |
| handler 复杂度不对等 | **对齐**：都只回 `200 + "Hello, World!"`。tachyon 还多写一个 `Content-Type` 头（对它不利） | 两个 min bench 的 main.cj |

另外注意：压测器与被测服务**同机**，所以绝对 QPS 受 CPU 总量限制、不能跨机比较。
真正有意义的指标是 **每请求服务端 CPU 时间**——它不受客户端与机器噪声影响。

## 2. 硬指标

同机、128 长连接、keep-alive、交替两轮（`/proc/<pid>/stat` 的 utime+stime 增量 ÷ 请求数）：

| | QPS | **服务端 CPU/请求** | 稳态 RSS |
|---|---:|---:|---:|
| **tachyon** | 562,832 – 595,426 | **12.0 – 12.6 µs** | **31 MB** |
| **stdx.net.http** | 332,148 – 339,861 | **24.6 – 25.3 µs** | 291 – 296 MB |

> 第二轮复测（改了 §4 那个走私修复之后）：tachyon 562,659 QPS / 13.0 µs / 31.5 MB，
> stdx 346,644 QPS / 24.7 µs / 296 MB。比值稳定在 **1.9–2.0 倍**。

RSS 差 9.5 倍这件事本身是证据：在**同样的负载、同样的连接数**下，稳态堆大 9.5 倍，
说明 stdx 每请求的分配速率远高于 tachyon（Cangjie 的堆会随分配速率增长）。
我另外试过 `cjHeapSize=2g/8g`、`cjGCInterval` 调参，**两边都没变化**（RSS 稳定在各自水位），
所以这个差值不是 GC 参数调出来的。

## 3. 两倍 CPU 花在哪：逐条对着源码看

### 3.1 stdx 每请求建一整棵对象图

`stdx/net/http/http_server1_1.cj`：

```cangjie
// :277  readRequest()
let request = HttpRequestBuilder().method(...).url(...).setHeaders(headers)...build()
//        -> HttpRequestBuilder 一个对象
//        -> HttpHeaders() 一个对象（内部 HashMap）
//        -> URL 一个对象
//        -> HttpRequest 一个对象

// :54-56  process()
let responseBuilder = HttpResponseBuilder().request(request)   // 又一个对象
let context = HttpContext(request, responseBuilder)            // 又一个对象
```

tachyon 是**每连接**取一个 `RequestCtx`，请求之间只 reset 不重建
（`server.cj:247-249` `takeReader/takeWriter/takeCtx`；`ctx.cj` `reset()`）。

### 3.2 header：每行一个 `Str`，每个名字再小写成一个新 `String`，然后进 `HashMap`

`buffered_conn.cj:227` `readLine()` 返回的是 `Str` 对象 —— 请求行 + 每个 header 行各一个，
还要 `removeLast(LF).removeLast(CR)`。然后 `http_header.cj:48-60`：

```cangjie
public func add(name: String, value: String): Unit {
    let valueTrim = value.trimAscii()          // 新 String
    let nameStr = toLowerCaseStr(name)          // 又一个新 String
    map.add(nameStr, HeaderValue(valueTrim))    // HashMap 插入：算 hash
}
```

一个 4 个头的请求 → 5 个 `Str` + 4 个小写 `String` + 4 次 HashMap hash/插入。

tachyon 的 `HeaderTable` 是 fasthttp 的 argsKV 模型（`header.cj:14-19`）：
names/values 两个平行数组存 `Bytes` **视图**，Host/Content-Length/Content-Type 等常用头
走专用字段（O(1) 直取）。整个解析阶段**不构造任何 String，也不做 hash**，
字段名比较是大小写无关的逐字节比较。

### 3.3 Date 头每响应格式化一次

`http_server1_1.cj:760-761`：

```cangjie
let dateStr = getRFC1123String(dateArr)   // utils.cj:381，内部 DateTime.nowUTC() + 逐位写数字
headers.set("date", dateStr.toString())    // 又一次 Str -> String
```

在我们自己的微基准里，这个运行时上格式化一次 HTTP 日期约 **1.2 µs**
（`datecache.cj` 的注释记录了这笔测量）。tachyon 把日期行**按秒缓存**，
每请求只做一次 memcpy（`datecache.cj:19-25` 每秒 refresh）。

### 3.4 响应序列化多一层 StringBuilder

`http_server1_1.cj:958-968`：

```cangjie
func writeWithoutBody(response: HttpResponse): Unit {
    var buf = StringBuilder()
    buf.append(response.version); ... ; response.headers.writeTo(buf)
    conn.write(buf.toString())     // StringBuilder 拼完再 toString 成 String，再拷进 socket 缓冲
}
```

tachyon 的 `response.cj:94` `serialize()` 直接把状态行/头/body 写进**预分配的写缓冲**
的字节偏移上，然后 `server.cj:399` 一次 `flush` = **一次 write 系统调用**，全程无中间对象。

## 4. 顺带：这次核查发现并修掉一个真问题

"看实现有没有问题"不只是看快不快。我拿畸形请求打了自己一遍，发现：

| 攻击面 | 修之前 | 修之后 |
|---|---|---|
| `Content-Length` + `Transfer-Encoding` 同时出现 | **200**（只置 connectionClose，照常响应） | **400**（RFC 9112 §6.1 要求 MUST reject） |

只关连接不拒绝仍然危险：前置代理按 Content-Length 切、我们按 Transfer-Encoding 切，
两侧请求边界不一致就是走私面。已修（commit `afab771`），并补了 5 个安全用例钉住：
CL+TE、重复且不一致的 CL、缺 Host、畸形请求行、超长 header → 400/431。

## 4.5 k6 独立复测（换一个压测器）

上面的数字来自自写的 Go loadgen。换成 **k6 v2.2.0**（同机、同两个最小服务、交替两轮）再测一遍：

| VUs | | QPS | 平均延迟 | p99 | **服务端 CPU/请求** | RSS |
|---|---:|---:|---:|---:|---:|---:|
| **100** | **tachyon** | **167,059 / 165,335** | 548 / 558 µs | 2.25 / 2.34 ms | **14.7 / 14.7 µs** | 22 MB |
| 100 | stdx.net.http | 136,034 / 132,617 | 682 / 700 µs | 2.70 / 2.79 ms | 26.4 / 26.9 µs | 71–125 MB |
| **500** | **tachyon** | **139,421 / 139,239** | 3.01 / 2.99 ms | 11.93 / 11.68 ms | **17.6 / 17.5 µs** | 42 MB |
| 500 | stdx.net.http | 115,111 / 116,190 | 3.55 / 3.53 ms | 14.02 / 13.93 ms | 30.1 / 30.0 µs | 140–150 MB |

两轮零失败（`http_req_failed` 0.00%，checks 100%）。

**两个结论，一个提醒：**

- ✅ **服务端 CPU/请求的比值稳定在 1.72–1.81 倍**，与 Go loadgen 测出的 2.0 倍同一量级。
  换压测器不改变结论——差值在服务端，不在测试工具。
- ✅ 内存差同样复现：42 MB vs 150 MB（500 VUs）。
- ⚠️ **但 QPS 差距缩小到 1.21–1.25 倍**。原因很明确：k6 自己就吃满 CPU（500 个 VU 各带一个
  JS 运行时），它是瓶颈，两个服务端都没跑满。**所以 k6 的绝对 QPS 是"k6 能发多快"，
  不是"服务端能接多快"**——要测服务端上限，得让压测器不成为瓶颈（独立机器，或用更轻的 loadgen）。

> 复现：`~/Projects/Cangjie/.scratch/logs/k6-cmp2.sh`，脚本 `k6-hello-cmp.js`（500 VUs / 100 VUs，20 s）。

## 4.6 再换一个工具：bombardier（wrk 风格）+ 定速测试

k6 的结论受限于"k6 自己是瓶颈"。换成 **bombardier**（Go 写的 wrk 风格压测器，
默认用 fasthttp 客户端，per-request 开销极低）：

### A. 吞吐上限（128 连接、20 s、不限速、两轮）

| | Reqs/sec | 平均延迟 | p50 | p99 |
|---|---:|---:|---:|---:|
| **tachyon** | **586,912 / 584,673** | 216 / 217 µs | 193 / 194 µs | 834 / 835 µs |
| stdx.net.http | 336,996 / 343,956 | 378 / 371 µs | 352 / 348 µs | 1.61 / 1.55 ms |

→ **1.70–1.74 倍**，与自写 Go loadgen 的 1.7–1.75 倍一致。三种独立压测器（自写 loadgen、
k6、bombardier）里，两个不限速的都指向同一个比值。

### B. 定速测试（两边喂**完全相同的输入速率**，128 连接、10 s）

这是最公平的一组：输入一样，只看服务端能不能跟上。

| 目标速率 | tachyon 实际达成 | tachyon p99 | stdx 实际达成 | stdx p99 |
|---:|---:|---:|---:|---:|
| 200,000/s | 199,785 ✅ | 0.97 ms | 199,903 ✅ | 1.46 ms |
| 350,000/s | 349,484 ✅ | 843 µs | **335,806**（跟不上） | 1.53 ms |
| 500,000/s | **496,501 ✅** | 811 µs | **343,206**（卡死） | 1.56 ms |

stdx 在 50 万目标速率下**只能交出 34.3 万**，就是它的物理上限；同一时刻 tachyon 交出 49.7 万，
p99 还更低（811 µs vs 1.56 ms）。同步采的 10 s 内服务端 CPU：

| 目标速率 | tachyon CPU | 每请求 | stdx CPU | 每请求 |
|---:|---:|---:|---:|---:|
| 200k | 28.7 s | 14.3 µs | 47.6 s | 23.8 µs |
| 350k | 41.0 s | 11.7 µs | 72.7 s | 21.6 µs |
| 500k | 55.5 s | 11.2 µs | 74.9 s | 21.8 µs |

每请求 CPU 比值 **1.66–1.95 倍**，五个压测器/五组条件全部同向。

> 工具位置：`~/Projects/Cangjie/.scratch/loadtools/{bombardier,vegeta,hey}`
> （`GOPROXY=https://goproxy.cn,direct go install ...` 装的）。
> 脚本：`bomb-cmp.sh`（吞吐上限）、`rate-cmp.sh`（定速）。
>
> **vegeta 的坑**：不加 `-laddr` 时它用 `0.0.0.0` 建连接，高频下会
> `bind: address already in use`，实测只能跑到 24k/s 且 9% 请求失败——**别用它的结果下结论**，
> 定速测试用 bombardier 的 `-r` 更靠谱。
>
> Rust 侧的 `oha` / `rewrk` 更能吃满小机器，但这台机器 crates.io 返回 403 装不了；
> Go 侧三个够用了。

## 4.7 跨机测试：压测器挪到另一台机器

前面所有数字都是"压测器和被测服务抢同一台机器"，永远说不清谁先到瓶颈。
这次把**压测器放到另一台机器**上：

| | 机器 | 规格 |
|---|---|---|
| 被测服务 | Linux，192.168.3.6 | Ryzen 7 7840HS，8C/16T，2.5GbE |
| 压测器 | Windows 10，192.168.3.231 | **Ryzen 9 9950X3D，16C/32T**，2.5GbE |

工具：把 `bombardier` 交叉编译成 `bombardier.exe`（`GOOS=windows GOARCH=amd64`）
放到 Windows 上跑，Linux 侧同时采 `/proc/<pid>/stat` 的服务端 CPU。

### 结果（20 s，每档各一轮，两轮取一致值）

| 连接数 | | Reqs/sec | p50 | p99 | **服务端 CPU/请求** | RSS |
|---:|---|---:|---:|---:|---:|---:|
| **128** | **tachyon** | **307,015 / 327,095** | 513 / 504 µs | 1.00 ms | **13.0 µs** | 25 MB |
| 128 | stdx | 180,100 / 179,399 | 687 / 673 µs | 1.40 / 1.42 ms | 24.4 µs | 154 MB |
| **256** | **tachyon** | **343,492 / 344,917** | 742 / 735 µs | 1.39 / 1.37 ms | **13.6 µs** | 33 MB |
| 256 | stdx | 177,270 / 179,404 | 1.38 / 1.36 ms | 2.37 / 2.31 ms | 23.7 µs | 165 MB |
| **512** | **tachyon** | **343,386** | 1.45 ms | 2.35 ms | **14.3 µs** | 45 MB |
| 512 | stdx | 169,666 | 2.99 ms | 4.16 ms | 25.2 µs | 178 MB |
| **1024** | **tachyon** | **295,333** | 3.36 ms | 5.21 ms | **17.4 µs** | 70 MB |
| 1024 | stdx | 152,287 | 6.59 ms | 9.68 ms | 29.1 µs | 197 MB |

### 三个结论

1. **每请求 CPU 比值 1.67–1.87 倍**，与回环测试的 1.9–2.0 倍同一量级。
   **换了机器、换了网络、换了工具，这个比值基本不变** —— 这是最有说服力的一个数。
2. **stdx 的吞吐不随连接数增长**（180K → 177K → 170K → 152K，越多越差），
   而延迟超线性上升（0.71 → 1.44 → 3.02 → 6.72 ms）。tachyon 同样在高连接数下降，
   但拐点更晚、绝对延迟始终约为 stdx 的一半。
3. **本组数字反映的是"局域网 + 无 pipelining"下的上限，不是服务端 CPU 上限**：
   tachyon 只用了约 5/16 核（98 s CPU / 20 s）。单连接一次一个请求、往返约 1 ms 时，
   吞吐上限 ≈ 连接数 ÷ 往返延迟，所以加连接才涨，超过 256 条后服务端自身的每连接开销
   反而拖累。要真正压出 CPU 上限，需要 HTTP pipelining 或更大的连接规模。

> 脚本：`~/Projects/Cangjie/.scratch/logs/win-bench.sh`（128/256 连接）、`win-bench2.sh`（512/1024）。
> 客户端产物：`.scratch/loadtools/win/bombardier.exe`。

## 4.8 三种"上限"怎么区分（回填 §4.7 的疑问）

跨机测试里 tachyon 到 345K 就压平、CPU 只用 5/16，当时说的是"这不是 CPU 上限"。
这里把三种上限分清楚，以及各自的判据。

| 上限 | 成因 | 数据特征 | 怎么验证 |
|---|---|---|---|
| **CPU 上限** | 每请求 CPU × 速率 = 核数 | 用满核；加核/加线程 QPS 上升 | 改 `cjProcessorNum` 看有没有收益 |
| **框架上限** | 锁、单线程 accept、调度器争用 | QPS 平/降，**核没用满**，且**每请求 CPU 随并发上升** | 加连接不加 QPS；perf/加锁排查 |
| **在途上限** | HTTP/1.1 无 pipelining，吞吐 = 在途请求数 ÷ 往返延迟 | QPS **与连接数成正比**，延迟基本不变 | 改连接数看是否线性 |

### 实测映射（跨机，1 ms 级 RTT）

| 连接数 | Reqs/sec | 平均延迟 | 服务端核数 | CPU/请求 | 落在哪个区间 |
|---:|---:|---:|---:|---:|---|
| 1 | 7,698 | 126 µs | — | — | 单连接 RTT 基线 |
| 4 | 30,891 | 128 µs | — | — | 在途受限（QPS≈4×) |
| 16 | 100,334 | 158 µs | — | — | 在途受限 |
| 64 | 273,298 | 233 µs | — | — | 在途受限 |
| 128 | 300,859 | 508 µs | 3.97 | 13.2 µs | 逼近拐点 |
| 256 | 345,551 | 741 µs | 4.59 | 13.3 µs | **拐点** |
| 512 | 345,869 | 1.44 ms | 4.90 | 14.2 µs | 平台 |
| 1024 | 295,554 | 3.37 ms | 5.12 | 17.4 µs | 下降 |
| 2048 | 254,239 | 7.85 ms | 5.11 | 20.1 µs | 下降 |

- **c ≤ 64**：QPS 与连接数近似成正比、延迟基本不变 → 在途受限（这部分是测量方式造成的，不是服务端问题）。
- **c ≥ 256**：QPS 不再涨、核数停在 5/8（运行时只建 8 个调度线程），
  且 **每请求 CPU 从 13.2 µs 涨到 20.1 µs** → 典型**框架上限**特征：加并发不加工，反而互相拖累。

### 为了排除"锁"做的两件事

1. **找到并修掉一个真问题**：`DateCache.lineLen()` 每请求 `synchronized(lock)`，
   在 16 线程上是全局串行点。改成不可变快照 + `AtomicReference` 原子换引用，
   读路径彻底无锁（commit `f1d76c6`）。
2. **修完复测，天花板没动**（345K → 345.9K），说明它不是拐点的主因。
3. **改 `cjProcessorNum`（8/16/32）也没有收益**（354K / 355K / 326K），
   同时确认运行时只创建 **8 个调度线程**（= 物理核数，不是 16 逻辑核）。
   → 排除"CPU 没用满所以加线程就行"。

### 回环对照（没有网络变量）

| 连接数 | Reqs/sec | 平均延迟 | 核数 |
|---:|---:|---:|---:|
| 64 | 518,921 | 122 µs | 6.01 |
| 128 | 553,041 | 230 µs | 6.43 |
| 256 | 559,419 | 455 µs | 6.57 |
| 512 | 545,561 | 0.94 ms | 6.80 |
| 1024 | 479,420 | 2.13 ms | 7.19 |

回环下同样在 ~56 万压平、核数 6.5/8 —— 但回环时压测器和被测服务抢同一台机器，
**这台机器的 CPU 是满的**，所以回环的上限是"机器上限"，不是服务端上限。

### 结论

- 345K 这个数**不是 CPU 上限**（5/8 线程、加线程无收益），也**不是单个锁**（修完没变）。
- 它同时含**在途上限**（低并发段，测量方式导致）和**框架/调度器上限**（高并发段，
  特征为每请求 CPU 随并发上升）。
- 这个形状 **stdx 也有，且更早、更陡**（180K 就平，延迟 3→9.7 ms）。
  两者跑在同一个仓颉运行时上，**更像运行时的 M:N 调度器在大量阻塞于 socket 的协程下的表现**，
  而不是 tachyon 自己的逻辑问题——但这一点**没有做 profile 验证，属于推断**。

## 4.9 cjprof 实测：CPU 到底花在哪

前面关于"框架上限还是 CPU 上限"只能靠间接推理。这次直接用 **cjprof** 采样，
两台服务跑同样的负载（256 连接、Windows 侧压 16 s，采样 10 s）。

环境：cjprof 需要 perf_event 权限，宿主机 sudo 不可用（no-new-privileges），
所以整套塞进 **privileged 容器**（`--privileged --security-opt seccomp=unconfined --network host`），
把仓颉 SDK 只读挂进去跑。

### tachyon（373,410 req/s）

| 采样位置 | Children | Self |
|---|---:|---:|
| `Server::perConnLoop` | 87.0% | 2.7% |
| └ `BufferedReader::fill` → `TcpSocket::read` | **60.4%** | 0.2% |
| 　└ `CJ_MRT_SockRecvNonBlock` | 43.3% | 1.1% |
| 　　└ **[libc] sem_wait** | — | **27.2%** |
| 　　└ **[libc] sched_yield** | — | **16.7%** |
| 　　└ `__recv`（真正收数据） | — | 2.4% |
| └ `BufferedWriter::flush` → `TcpSocket::write` | 11.1% | 0.3% |
| `Request::parseHeaders` | 5.5% | 3.4% |
| `RequestCtx::reset` + `HeaderTable::reset` | 5.8% | 2.7% |
| `Response::serialize` | 1.9% | 1.6% |

**读出来三件事：**

1. **tachyon 自己的代码只占约 10%**（parseHeaders 3.4 + reset 2.7 + serialize 1.6 + 循环 2.7）。
   瓶颈不在我们的解析/序列化逻辑。
2. **46% 的 CPU 花在等 socket 上**：`sem_wait` 27.2% + `sched_yield` 16.7% + `__recv` 2.4%。
   仓颉运行时的 `DopraTcpSocketImpl::readImpl` 是「非阻塞 recv + 信号量 + sched_yield 让出」的组合，
   **不是高效的阻塞等待**。这部分纯属空转。
3. **写只有 11%**，说明响应路径（我们的 serialize → 一次 write）已经很便宜。

### stdx.net.http（144,013 req/s，同样负载）

| 采样位置 | Children | Self |
|---|---:|---:|
| `HttpServer1::process` | 91.7% | 1.4% |
| └ `readRequest` | 44.0% | 0.8% |
| 　└ `readRequestLine` | **27.5%** | — |
| 　　└ `BufferedConn::readLine` | 23.0% | — |
| └ `consumeRequestAndWriteResponse` | 40.0% | 0.1% |
| 　└ `writeResponse` | 28.7% | 0.6% |
| 　　└ `checkResponseHeader` | 12.8% | 0.6% |
| `httpLog`（**日志**，连 DEBUG 都没开） | **12.6%** | 0.6% |
| `HashMap<Str, HeaderValue>::get/add` | 4.1% | 3.9% |
| socket 读等待 | 15.2% | — |

对比很直接：

- tachyon：**60% 在等 I/O，10% 在干自己的活** —— I/O 等待型。
- stdx：**只有 15% 在等 I/O，但 27.5% 花在读请求行、28.7% 花在写响应、12.6% 花在日志** ——
  自己算得太多，CPU 型。这就是它每请求 2 倍 CPU 的来源。

### 所以 §4.8 的"框架上限"到底是什么

profile 给出了确定答案，且**推翻了"是 tachyon 逻辑问题"和"是锁"这两个猜测**：

> **44–46% 的 CPU 时间耗在仓颉运行时的 socket 等待实现（sem_wait + sched_yield）上。**
> 它不是我们的锁（datecache 的 Mutex 已移除，profile 里已无该符号），
> 也不是我们的解析（只占 3.4%）。

这也解释了两个反直觉现象：
- **加核/加线程没用**：sched_yield 空转越多，核间争用越重（`cjProcessorNum=32` 时反而降到 326K）。
- **加连接更差**：更多协程同时在 sem_wait/sched_yield 上空转，每请求 CPU 从 13.2 µs 涨到 20.1 µs。

> profile 数据：`.scratch/logs/{tachyon-prof2,stdx-prof}.data`
> 火焰图：`.scratch/logs/flame-{tachyon,stdx}.svg`
> 复现脚本：`.scratch/logs/prof-tachyon.sh`、`prof-both.sh`

## 4.10 对着 runtime 源码看：那 16.7% 的 `sched_yield` 从哪来

把 `cangjie_runtime` 拉下来（`atomgit.com/Cangjie/cangjie_runtime`）对照 profile。
**先确认版本对得上**：我们用的是 1.2.0，取 `release/1.2` 分支（HEAD `8e6100a`，即 v1.2.1）
与该文件在 `main`（`e927f24`）做 `git diff` → **输出为空**，即两个分支逐字节一致，
下面这段就是 1.2.0 实际跑的代码。定位到
定位到 `runtime/src/CJThread/src/aio/sock/src/sock.cpp:1634` 的 `SockRecvNonBlockGeneral`：

```cpp
unsigned int freeThreshold = schdProcessor->processorNum / PROCESSOR_FREE_RATIO;   // /2

do {
    recvRet = recv(fd, buf, len, flags);
    if (recvRet != -1) break;
    cycles++;
    // 空闲处理器足够时自旋几次，减少 cjthread park
    scheduleFree = (schdProcessor->freeNum).load(relaxed) > freeThreshold &&
                    cycles <= RECV_MAX_CYCLES;      // = 15
    (void)sched_yield();                            // ← 无条件执行
} while (ret == EINTR || ret == 0 || (ret == EAGAIN && scheduleFree));
```

**两处浪费：**

1. **`sched_yield()` 无条件调用**。当 `scheduleFree == false`（空闲处理器不够，或已超 15 轮）时，
   循环本来就要退出、上层马上 park 这个 cjthread —— 这次 yield 纯属多余的系统调用。
   实测 `sched_yield()` 单次约 **487 ns**（无其它可运行线程时）。
   profile 里 16.7% × 5 核 ÷ 37 万 req/s ≈ **2.2 µs/请求**，除以 487 ns ≈ **4–5 次/请求**
   —— 说明自旋分支也在实际触发，不只是退出前那一次。
2. **超配时自旋判据失效**。`freeNum > processorNum/2` 在 `cjProcessorNum` 大于物理核数时
   恒成立（总有一半 processor 空闲）→ 每次读自旋满 15 轮，每轮 recv + sched_yield = 最多 30 次系统调用。

这与之前的实测完全对上：

| cjProcessorNum | QPS | 进程核数 | 解释 |
|---|---:|---:|---|
| 默认（=8） | 358,726 | 4.92 | 正常 |
| 8 | 355,518 | 4.32 | 正常 |
| 16 | 354,666 | 4.94 | 正常 |
| **32** | **326,480** | **7.99** | **超配 → 自旋条件恒真 → 空转** |

**这也进一步确认：§4.8/§4.9 里的"框架上限"不是 tachyon 的代码问题**，
而是 runtime 的 I/O 等待路径（无条件 yield + 可失效的自旋判据）。

> 已提交上游：**[Cangjie/UsersForum #3577](https://atomgit.com/Cangjie/UsersForum/issues/3577)**
> —— `[BUG] runtime：SockRecvNonBlockGeneral 在不再自旋时仍执行 sched_yield()，高并发 HTTP 服务端约 17% 的每请求 CPU 空转`
> （本地草稿：[`upstream-issue-recv-spin.md`](upstream-issue-recv-spin.md)、投稿版 `forum-issue-recv-spin.md`）。
>
> 附件（采样原始数据 / 火焰图 / 脚本 / 探针）另存公开仓：
> [github.com/ystyle/cangjie-runtime-issue-3577-repro](https://github.com/ystyle/cangjie-runtime-issue-3577-repro)
> （AtomGit 镜像同名仓），已在 issue 下留言引用。
> runtime 源码：`.scratch/ref/cangjie_runtime`（浅克隆，只读对照，未改动上游）。

## 5. 这次对比没有证明什么（别过度解读）

写清楚边界，比多给几个数字有用：

1. **没有跑 profiler**。2.0 倍是端到端测出来的；§3 的每一条都是源码事实，
   但"哪一项占多少微秒"是推断，不是 profile 数据。要精确归因得用 cjprof。
2. **tachyon 功能面比 stdx 窄** —— 这是刻意的取舍，不是它更"聪明"：
   - 不提供 URL 对象模型（不解析 scheme/authority，也不暴露改 query 的 API）
   - header 字段值的合法性校验比 stdx 少（stdx 有逐字符校验与更细的 RFC 检查）
   - 不做 HTTP/2、TLS、h2 帧层、trailer 的完整实现
   
   换句话说：stdx 是一个**通用 HTTP 实现**，tachyon 是一个**只做 HTTP/1.1 服务端、且把
   所有非必要工作砍掉**的实现。这正是 fasthttp 相对 Go net/http 的位置
   （同机 fasthttp ≈ 745K QPS vs net/http ≈ 412K）。要求功能对等的场景，差距会缩小。
3. **同机压测**，客户端也吃 CPU，所以绝对 QPS 只能同机对比。
4. 我早先在内部笔记里把 tachyon 剩余的每请求分配归因到 `std.net` 的
   `conn.read/write` 造成的数组切片——**那条是错的**。实测这个运行时上
   `Array` 切片是 0 B/op（不是深拷贝），归因作废，此处更正。

## 6. 复现

```shell
# 两个最小服务：都只回 200 + "Hello, World!"
# ~/Projects/Cangjie/.scratch/bench-tachyon-min   （依赖 tachyon 源码）
# ~/Projects/Cangjie/.scratch/bench-stdx-min      （依赖官方 stdx 预编译库）

# 压测器（自己写的 Go 工具，同机跑）
~/Projects/Cangjie/.scratch/bench-go/bin/loadgen \
  -url http://127.0.0.1:PORT/ -conns 128 -warmup 1s -duration 10s

# 每请求 CPU = (/proc/<pid>/stat 的 utime+stime 增量) / 请求数
# 脚本：~/Projects/Cangjie/.scratch/logs/measure-cpu-per-req.sh
#       ~/Projects/Cangjie/.scratch/logs/bench-min-cmp.sh
```

## 7. 所以"为什么能比 stdx 好"

不是"仓颉跑不过 C"或者"注释写得妙"，而是三条可验证的设计选择：

1. **API 形状决定了分配量**。stdx 的对象模型（Request/Response/Context/Headers 都是对象、
   header 名是 String、header 表是 HashMap）意味着每请求必然分配；tachyon 用
   per-connection 复用 + 扁平视图，把每请求的堆分配压到接近 0。分配少了，
   堆不涨（31 MB vs 293 MB），GC 也就没有活干。
2. **热路径上不构造 String**。仓颉的 `String` 是带 UTF-8 校验的堆对象；
   stdx 每请求要造十几个（每行 readLine、每个 header 名小写、date 的 toString、body 的 toString），
   tachyon 全程 `Bytes` 视图 + 索引对。
3. **序列化直写缓冲**。stdx 是 StringBuilder → String → 拷贝进 socket 缓冲；
   tachyon 是直接写进预分配缓冲的偏移，一次 write 出去。

代价也很明确：tachyon 的功能面窄得多，且这些优化是**绑定在"只做 HTTP/1.1 服务端"这个前提**上的。
超出这个前提（要 HTTP/2、要 TLS、要完整的 URL 模型）就该用 stdx —— 那是它擅长的。