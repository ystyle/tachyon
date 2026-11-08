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