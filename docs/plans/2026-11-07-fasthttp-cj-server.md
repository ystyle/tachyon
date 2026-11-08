# fasthttp 服务端能力的仓颉实现方案（不依赖 stdx）

> 版本：调研稿 v1.0 · 2026-11-07
> 范围：**只做服务端（HTTP/1.1）**，不做客户端。原因：客户端必过 TLS，而 TLS 在仓颉只能落到
> `stdx.net.tls`（依赖 OpenSSL 3 动态库）——这是题目给定的边界，不是偷懒。
> 约束：**只允许 `std.*`**，(`import stdx.*` 一律禁止)。
> 参考实现：fasthttp master `000816e`（本地 `.scratch/ref/fasthttp`）。
> 全部结论都有实测支撑；证据文件见 §8。

---

## 0. 一页纸

### 0.1 结论先给

**可行，而且比预期好。** 我用 278 行仓颉（`.scratch/spike2`）写了一个 fasthttp 同构的
HTTP/1.1 服务端，在同一台机、同一个压测器、同样 128 连接下测得：

| 实现 | QPS（3 轮中位） | p50 | p99 | RSS |
|---|---:|---:|---:|---:|
| Go fasthttp hello | **745,900** | 137 µs | 605 µs | 14.6 MiB |
| **仓颉 spike（本方案验证件）** | **586,700** | 194 µs | 780 µs | 38.9 MiB |
| Go net/http hello | 412,800 | 189 µs | 1,518 µs | 20.8 MiB |

即：**仓颉版达到 fasthttp 的 79%、net/http 的 142%**，p99 介于两者之间。
而这个验证件**没有**做对象池、没有做 buffer 复用、每请求都在新建连接处理协程——
也就是说 **§6 的设计还没落地就已经到这个水平了**。

**三个决定性事实（各自都推翻了流行误解）：**

1. **`spawn` 是协程，不是 OS 线程。** 实测 20000 条**阻塞在内核 read 上**的连接，
   进程只有 **14 个内核线程**；每协程 ≈ **13 KB**。→ 每连接一协程完全可行，
   **不需要 event loop，也不需要 epoll 抽象**（标准库里本来也没有）。
2. **`Array<Byte>` 切片是零拷贝别名。** → header 的 key/value 可以做成
   "指向同一块读缓冲的视图"，这是 fasthttp argsKV 模型能照搬的前提。
3. **`-O2` 是生死线。** 同一段字节扫描代码：不开 `-O2` 是 **75 MB/s**，开了是 **4189 MB/s**（55 倍）。
   cjpm **默认不开 `-O2`**。→ 这条不写进 `cjpm.toml`，所有性能设计都是空谈。

**std 本体答不了的能力 —— 主模块一律不做，扩展成员各自声明依赖：**

仓颉标准库没有 SHA1/MD5、没有 base64、没有 gzip/deflate，也没有 WebSocket。
**主模块不提供这些能力**，但它们可以作为**同一个 workspace 里的其它成员**存在，
条件是：**依赖声明写在各自成员的 `cjpm.toml` 里，仓库根不写**。

> **stdx 传染边界（2026-11-07 完整实测，9 组对照）**
>
> | 判断 | 结论 |
> |---|---|
> | 依赖树里有 stdx 的包，下游构建需要 `CANGJIE_STDX_PATH`？ | ✅ 是（沿依赖路径） |
> | 同 workspace 的**兄弟成员**用 stdx，会传染给不依赖它的成员？ | ❌ **不会** |
> | 仓库根 `cjpm.toml` 必须写 stdx 吗？ | ❌ **不必** |
> | 从 workspace 根 `cjpm build` 会构建所有成员吗？ | ✅ 会（所以根构建仍需 env） |
> | 能让根构建跳过 stdx 成员吗？ | ✅ 用 `build-members` / `test-members` 过滤 |
> | 成员 toml 写了 `${CANGJIE_STDX_PATH}` 但不 import stdx、env 未设？ | ✅ 不报错（空变量=空路径） |
>
> 实测：消费者**只依赖 core**（同仓兄弟 `ext` 用 stdx）→ `cjpm build success`；
> 消费者**依赖 ext** → 才失败。完整矩阵见
> [`stdx-capability.md` §8](../notes/stdx-capability.md)。

**所以架构是「一个 workspace，成员各自声明依赖」**：

~~~text
<repo>/cjpm.toml                 [workspace] members/build-members  ← 不写 stdx
<repo>/tachyon/                   主模块：无 [dependencies]，仅 std
<repo>/tachyon_ext_compress/      依赖 cangjie_tpc::zlib4cj（零 stdx）
<repo>/tachyon_ext_crypto/        依赖 digest4cj（零 stdx）+ 自写 base64
<repo>/tachyon_ext_ws/            依赖 stdx.net.http + stdx.crypto.digest
~~~

| 能力 | 主模块 | 扩展成员 | 依赖 |
|---|---|---|---|
| HTTP/1.1 解析 + 连接管理 | ✅ 全部 | — | 仅 std |
| gzip / deflate | ❌ | `tachyon_ext_compress` | `cangjie_tpc::zlib4cj`（纯仓颉，**零 stdx**，实测） |
| SHA1/SHA256/MD5/HMAC | ❌ | `tachyon_ext_crypto` | `digest4cj`（**零 stdx**，实测） |
| base64 | ❌ | `tachyon_ext_crypto` | 自写（~60 行；中心仓只有 base85） |
| WebSocket | ❌ | `tachyon_ext_ws` | `stdx.net.http`（**唯一必须碰 stdx 的能力**） |
| TLS | ❌ | `tachyon_ext_ws` 或独立 | `stdx.net.tls`（OpenSSL 3） |

**HTTP/2 的结论**（详见 §2.6）：h2c（明文）**不需要加密库**但要 ~2000 行（HPACK+帧+流控+多路复用）；
h2（TLS，浏览器唯一支持）**必须 `stdx.net.tls`（OpenSSL 3）**。
**本方案不做 HTTP/2** —— fasthttp 本身也不支持，需要时用 `stdx.net.http` 或前面挂反代终结 TLS。

**唯一真正"只能接受"的缺口**：`std` 没有 `writev`、拿不到 socket fd →
header+body 合并成一次写（多一次 memcpy），静态文件无 sendfile 零拷贝。
这条**用扩展模块也解决不了**，但实测影响可忽略（见 §7.4）。

**一句话**：**做一个"fasthttp 风格"的仓颉 HTTP/1.1 服务端完全成立**，
它能在性能上打赢 `net/http`、逼近 fasthttp，**主模块只用标准库**；
使用方**只依赖 `tachyon` 就零配置**，要压缩/WebSocket 才按需多依赖一个成员。

### 0.2 决策清单

| # | 决策 | 理由 |
|---|---|---|
| D1 | 包名 `fasthttp`（仓颉），单模块包 + 子包，不做 workspace | 与 tang/cjxt 等仓一致；workspace 的 lockstep 版本是实打实成本 |
| D2 | 传输层用 `std.net.TcpServerSocket` / `TcpSocket` | 标准库唯一选择；实测超时/关闭/多线程 accept 都够用 |
| D3 | 并发模型：**每连接一协程**（`spawn`）+ 全局并发上限 | 实测协程 13 KB，且阻塞不占内核线程（§2.2） |
| D4 | 解析器：**`Array<Byte>` 原地解析 + 裸指针视图**，全程不构造 `String` | `String.fromUtf8` 带 UTF-8 校验（1 MiB 花 544 µs），热路径不能用 |
| D5 | Header 存储：**argsKV 式**（`ArrayList<Array<Byte>>` 双平行数组 + `[:0]` 截断复用） | 照搬 fasthttp 已验证的模型；不搞"单 slab + 偏移" |
| D6 | 对象池：**per-worker 无锁池 + 全局兜底** | 标准库没有 `sync.Pool`；per-worker 池彻底避开锁 |
| D7 | `-O2` 强制写进 `cjpm.toml` 的 `compile-option` | 见 §0.1 第 3 条 |
| D8 | 对外 `Bytes` 类型（`{buf, start, len}`）而不是 `String` | 用户要 `String` 时显式 `toStr()`，把拷贝摆到明面上 |
| **D9** | **单个 workspace，成员各自声明依赖；仓库根 `cjpm.toml` 不出现 stdx** | 实测：兄弟成员不传染（消费者只依赖 `tachyon` 时零配置），但根构建会构建全部 `build-members`（§0.1 矩阵） |
| **D10** | 扩展成员**不主张零 stdx**：压缩/摘要用中心仓零依赖包（`zlib4cj`/`digest4cj`），只有 WebSocket/TLS 接受 stdx | 中心仓已有纯仓颉实现；只有 WebSocket 没替代品 |
| **D11** | 仓库 CI 用 `build-members` 过滤 + 成员目录直构双保险，保证核心成员零 stdx | 根构建会带上全部成员；只 build 核心成员才能零 stdx 环境跑通 |

> **包名**：`tachyon` 与 `fasthttp` 在中心仓（default 与 ystyle 两个命名空间）**都还没被占用**（2026-11-07 实查）。
> 建议用 **`ystyle::tachyon`**，不用 `fasthttp` —— 与 Go 的 fasthttp 重名会导致检索混淆
> （社区搜 "fasthttp" 会同时命中 Go 库），而 `tachyon` 明确是仓颉的。

---

## 1. fasthttp 服务端到底快在哪

> 完整剖析（1553 行 / 423 处 `file:line`）在 `.scratch/notes/fasthttp-analysis.md`。
> 这里只留对移植有意义的结论。

### 1.1 主循环（一句话版）

```text
Serve(ln)  →  workerPool  →  serveConn(c)  →  for { ... }
                                                
  ① 等第一个字节（ReadTimeout / IdleTimeout 在这里设 deadline）   server.go:2570/2577
  ② 读 header（bufio + 一遍 scanner，边复制边规范化）              header.go:3347
  ③ parseURI（失败 → 400 + close）                                server.go:2688
  ④ 读 body（默认 handler 前读完，限 4 MB）                        server.go:2699
  ⑤ Expect: 100-continue 处理                                     server.go:2740
  ⑥ 调 handler                                                    server.go:2841
  ⑦ handler 返回后**才**综合判定 keep-alive（六源或）              server.go:2905-2913
  ⑧ 写响应（header 拼进 bufio 空闲区 + body；必要时 writev）       server.go:2949
  ⑨ Reset（截断不还内存），下一轮                                  server.go:3055
```

**移植价值最高的三点**：⑦ 的顺序（keep-alive 在 handler 之后算，所以 `ctx.SetConnectionClose()` 有效）、
④ 的"默认读完 body"（避免 handler 忘读导致的下一个请求错位）、⑨ 的"截断不释放"。

### 1.2 零分配是怎么做到的（14 条，逐条可移植性）

| # | 技巧 | Go 靠什么 | 仓颉能不能 | 本方案 |
|---|---|---|---|---|
| 1 | 每连接 buffer 池化复用 | `sync.Pool` 复用 `*bufio.Reader/Writer` | ✅ 手写池 | 采纳（§6.5） |
| 2 | Header 不建 map | `[]argsKV`，key/value 各自独立 `[]byte`，`append(x[:0],…)` 复用 | ✅ 切片别名已验证 | 采纳（§5.1） |
| 3 | Request/Response 每连接一次分配 | ctx 池 + `Reset()` 只截断 | ✅ | 采纳 |
| 4 | URI/Args 惰性解析 | 三个 bool 位 + 缓存（连 error 都缓存） | ✅ 纯算法 | 采纳 |
| 5 | `[]byte`↔`string` 零拷贝 | `unsafe.String`/`unsafe.Slice` | ❌ **做不到** | 改用 `Bytes` 视图（D9） |
| 6 | handler 是函数不是 interface | `type RequestHandler func(*RequestCtx)` | ✅ | 采纳 |
| 7 | Date 头缓存 | 后台协程每秒刷 + `atomic.Pointer[[]byte]` | ✅ `AtomicReference` | 采纳（§5.6） |
| 8 | 直接写进 writer 空闲区 | `w.AvailableBuffer()` | ✅ 切片别名可行 | 采纳（§5.5） |
| 9 | header+body 一次 writev | `net.Buffers` | ❌ **做不到** | 合并成一次 `write` |
| 10 | body 缓冲池 | 第三方 `bytebufferpool` | ✅ 手写 | 采纳 |
| 11 | SWAR 8 字节并行扫 | `binary.LittleEndian.Uint64` | ⚠️ 要 `unsafe` 取 8 字节 | **不采纳**（见下） |
| 12 | 常量字节切片 | 包级 `[]byte("HTTP/1.1")` | ✅ | 采纳 |
| 13 | 状态码文本表 | `status.go` 的 map | ✅ 用数组 | 采纳 |
| 14 | `noCopy` 标记 | 给 `go vet` 看 | — | 不需要 |

**为什么不做 SWAR（#11）**：实测在 `-O2` 下逐字节扫描已经是 **0.42–0.63 ns/B**
（4.8 GB/s 级），170 字节的请求头扫一遍只要 **106 ns**；而 SWAR 需要
`unsafe` + 每次 `acquireArrayRawData`（单次 50 ns）。**算了不划算**，
且 unsafe 会带来"GC 不移动对象"这个无保证的依赖。**收益不足以覆盖风险。**

### 1.3 一个常见误解：workerPool 是服务端的

任务书里曾以为 `workerpool.go` 是客户端 Dial 用的。**错**：全仓 `grep 'workerPool{' --include='*.go'`
只有 `server.go:2124` 一处，它把连接分发给复用的 worker（`WorkerFunc = s.serveConn`）。
客户端的连接池是完全另一套（`HostClient.conns`，`client.go:1031`）。

**但仓颉不需要移植 workerPool**：因为 `spawn` 是协程（13 KB、阻塞不占内核线程），
"每连接一协程"的开销已经在 Go 同一量级，不需要再用池去摊薄创建成本。
池的唯一价值变成**并发上限**（`Concurrency` 语义），那用一个 `Semaphore` 就够。

### 1.4 另一个误解：它就在用 bufio

"fasthttp 绕过 bufio 直接 syscall"这个说法**对当前 master 不成立**：
`acquireReader` → `bufio.NewReaderSize`（`server.go:3240`），配合 `sync.Pool` 复用。
真正绕过的只有 `ReduceMemoryUsage=true` 的 `acquireByteReader`（`server.go:3206`），
目的是让空闲 keep-alive 连接不占 ctx。

**移植启示**：**照搬 bufio 等价物**（自己写 `BufferedReader`/`BufferedWriter` 更好，
因为要暴露"空闲区"），而`ReduceMemoryUsage` 的"空闲连接还缓冲"优化值得做（§6.5）。

---

## 2. 仓颉标准库的能力边界（全部实测）

> 详细证据：`.scratch/notes/cangjie-std-capability.md`（828 行，27 个探针 p00–p27 + 负向编译验证）。
> 工具链仓颉 1.2.0 (cjnative)，Linux x86_64，AMD Ryzen 7 7840HS / 8C16T。

### 2.1 一张表：能做什么

| 能力 | 结论 | 关键数据 |
|---|---|---|
| TCP 服务端 | ✅ | `TcpServerSocket` + `accept()`；**多线程可共享同一 server socket 并发 accept**（实测 4 线程 200 连接全分发） |
| 读写超时 | ✅ | `readTimeout`/`writeTimeout = ?Duration`，超时抛 `SocketTimeoutException` |
| EOF 语义 | ✅ | 对端关闭 → `read()` 返回 **0**，不抛异常，持续 0 |
| 跨线程打断阻塞 | ✅ | 本端 `close()` 让阻塞中的 `accept()`/`read()` **立刻**抛 `SocketException`（延迟 ≈0） |
| 优雅关闭 | ✅ | 靠上面那条：`server.close()` + 循环里判 `isClosed()`。**不需要 self-pipe** |
| 零拷贝切片 | ✅ | `arr[a..b]` 是别名，27 ns/次（与切片大小无关） |
| 裸指针 | ✅ | `acquireArrayRawData` → `CPointer`，可原地读写；实测 GC **不移动**对象 |
| 协程 | ✅ | `spawn` ≈ **520 ns/个**（-O2），**13 KB/协程**，阻塞不占内核线程 |
| 同步原语 | ✅ | Atomic（6 ns）、Mutex（40 ns）、Condition、Semaphore、Barrier、ReadWriteLock |
| 时间 | ✅ | `DateTime.now()` ≈ 20 ns（比 Go 便宜），格式化 ≈ 1227 ns |
| 正则 | ⚠️ | 有，但比手写慢 14–23 倍 → 路由**必须手写前缀树** |
| 文件 | ⚠️ | 有 read/seek（支持 Range），**无 sendfile** |
| FFI | ✅ | 能直接调 libc（实测端到端自建 socket 跑通），是最后的逃生门 |

### 2.2 三个决定架构的实测

**(a) `spawn` 是协程（M:N 绿线程）—— 这条改变了整个并发设计**

```text
=== baseline ===                            Threads: 5
=== 20000 个存活且阻塞的协程（sleep） ===     Threads: 20    VmRSS: 260 MB
=== 20000 条阻塞在内核 read() 上的真实连接 === Threads: 14    VmRSS: 363 MB
=== 逐级内存 ===
  存活 1000 / 5000 / 20000 / 50000 → 每协程恒为 12–13 KB，内核线程 12→20
```

含义：**每连接一协程就是最优解**，与 Go 同构。
12000 连接 ≈ 160 MB，完全可接受；**上限在哪里**见 §6.9。

**(b) `-O2` 是生死线**

```text
同一段 4KB 逐字节扫描：
  无 -O2 : 10,780,847,823 ns → 75 MB/s
  加 -O2 :    195,541,338 ns → 4189 MB/s
```

**任何性能方案必须先把 `compile-option = "-O2"` 写进 `cjpm.toml`。** cjpm 默认不开。

**(c) `String` 是热路径的毒药**

```text
String.fromUtf8(4096B)  : 3718 ns/op     ← 带 UTF-8 校验
String.fromUtf8(1MiB)   : 543,770 ns/op
String.fromUtf8Unchecked(4096B): 1329 ns/op（unsafe，且快 2.8 倍）
```

header 里每个 key/value 都转 `String` = 每请求多花几微秒，直接把 QPS 砍半。
→ **D4/D9**：内部全程 `Array<Byte>`，对外只给 `Bytes` 视图。

### 2.3 做不到 / 有代价（明确列出）

| std 的缺口 | 影响 | 处理 |
|---|---|---|
| **无 SHA1 / MD5 / SHA256 实现**（`std.crypto.digest` 只有 `Digest` 接口，无任何算法类） | WebSocket 握手、`ETag`、`Digest` 认证 | **扩展模块**用 `stdx.crypto.digest`（2415 MB/s） |
| **无 base64** | WebSocket、`Basic Auth` | **扩展模块**用 `stdx.encoding.base64` |
| **无 gzip / deflate** | 压缩响应 | **扩展模块**用 `stdx.compress.zlib` |
| **无 WebSocket** | 实时通信 | **扩展模块**用 `stdx.net.http` 的 WebSocket |
| **拿不到 socket fd** | sendfile / splice 用不上 | 接受；静态文件走"读+写"（**扩展模块也解决不了**） |
| **无 `shutdown(SHUT_WR)`** | 不能只关写方向 | 只能整体 `close()`（无解，接受） |
| **无 `writev`** | header+body 需合并或分两次写 | 合并成一次写（多一次 memcpy，实测影响可忽略） |

> **主模块 vs 扩展成员的边界**：上表前 4 项主模块**不做**；
> 由同 workspace 的扩展成员提供（各自声明依赖，根不写，见 §9.5）。
> 扩展成员**优先用中心仓零依赖包**（`zlib4cj` / `digest4cj`），
> 只在没有替代品时（WebSocket / TLS）才引入 stdx。
> stdx 的具体能力与性能见 **§2.5** 与 [`stdx-capability.md`](../notes/stdx-capability.md)。

**纯语言/运行时的约束（主模块必须遵守）**：

| 约束 | 影响 | 处理 |
|---|---|---|
| `ArrayList`/`HashMap`/`ByteBuffer` **非线程安全** | 并发写静默丢数据（实测 8 线程写丢 23%） | 每个连接独占，跨线程共享一律加锁或换 `Concurrent*` |
| GC 不移动对象是**实测**不是**保证** | unsafe 裸指针长期持有有升级风险 | 裸指针只在连接生命周期内用，保留非 unsafe 降级路径 |

---

## 2.5 stdx 实测（扩展成员的能力依据）

> 工程：`.scratch/probe-stdx`、`.scratch/bench-stdx-http`、`.scratch/bench-ws-stdx`。
> 环境：仓颉 1.2.0 + **stdx 1.2.0.1**（`~/.config/cjvs/stdx/1.2.0.1`，通过 `cjvs stdx-env` 注入）。
> 完整记录：[stdx-capability.md](../notes/stdx-capability.md)。

### 2.5.1 能力可用性（全部实跑，不是查文档）

| 能力 | 包 | 实测结果 |
|---|---|---|
| SHA1 / SHA256 / MD5 | `stdx.crypto.digest` | ✅ 全部可用，与标准参考值一致 |
| Base64 | `stdx.encoding.base64` | ✅ `toBase64String` / `fromBase64String`（返回 `?Array<Byte>`，注意解包） |
| gzip / deflate | `stdx.compress.zlib` | ✅ 流式 `CompressOutputStream(wrap: GzipFormat)`，**必须 flush + close** |
| WebSocket 服务端 | `stdx.net.http` | ✅ `WebSocket.upgradeFromServer` **端到端跑通** |
| TLS | `stdx.net.tls` | 可用（需 OpenSSL 3），但本方案主模块不用 |

### 2.5.2 性能实测（-O2）

~~~text
SHA1   1MiB: 413 us/op  ->  2415 MB/s     （走 OpenSSL，比纯仓颉实现快一个数量级）
SHA256 1MiB: 439 us/op  ->  2272 MB/s
base64 编码 1MiB: 1621 us/op  (~646 MB/s)
gzip  压缩 1MiB: 3035 us/op  (~345 MB/s)
~~~

### 2.5.3 WebSocket 握手的正确性（关键验收）

RFC 6455 规定 `Sec-WebSocket-Accept = base64(SHA1(clientKey + GUID))`。
用 RFC 示例 key `dGhlIHNhbXBsZSBub25jZQ==` 实算：

~~~text
WebSocket accept key = s3pPLMBiTxaQ9kYGzzhZRbK+xOo=   <- 与 RFC 6455 §1.3 期望值逐字节一致
~~~

端到端（python 手写 WS 帧当客户端）：

~~~text
HTTP/1.1 101 Switching Protocols
upgrade: websocket
connection: upgrade
sec-websocket-accept: 5OpwzkN7VSA6uQkHJi/rECDfyCA=
sec-websocket-protocol: echo
握手成功: True
收到帧: opcode=1 payload=b'hello from python'
回声一致: True
~~~

**35 行代码即可跑通**（`.scratch/bench-ws-stdx/src/main.cj`）。

### 2.5.4 stdx.net.http 的性能基线（用于对照主模块）

同机、同 loadgen、**1000 并发连接**、15 s、3 轮中位：

| 实现 | QPS | p50 | p99 | RSS |
|---|---:|---:|---:|---:|
| Go fasthttp | 675,357 | 1.3 ms | 5.1 ms | 29.8 MB |
| **仓颉主模块（spike2）** | **547,682** | 1.7 ms | 6.1 ms | 40.0 MB |
| Go net/http | 461,627 | 1.5 ms | 11.3 ms | 51.7 MB |
| **仓颉 stdx.net.http** | **251,762** | 3.5 ms | 24.6 ms | 338.1 MB |

用 **tang 原版 k6 脚本口径**（1000 VUs、`GET /hello` → `"hello world!"`）：

| 实现 | req/s | avg | p95 | RSS |
|---|---:|---:|---:|---:|
| Go fasthttp | 154,164 | 3.75 ms | 7.54 ms | 28.9 MB |
| **仓颉主模块（spike2）** | **147,983** | 5.08 ms | 12.28 ms | 45.9 MB |
| Go net/http | 136,568 | 4.75 ms | 12.55 ms | 49.8 MB |
| **仓颉 stdx.net.http** | **114,387** | 6.62 ms | 16.16 ms | 186.3 MB |

> 两组量级差 4–5 倍是压测器模型不同（loadgen 复用连接 vs k6 1000 独立 VU），**只做横向对比**。
>
> **与 tang 仓库记录对齐**：`tang/docs/advanced/benchmark.md` 记的是 **SDK 1.0.0 时代**的
> **122,157 RPS / tang 121,148 RPS**（本机测试）。本次在 **1.2.0 + stdx 1.2.0.1** 上重测
> stdx.net.http 得 **114,387 req/s** —— 量级一致，差异来自系统负载，不是回归。

**结论**：主模块比 stdx.net.http 快 **2.2 倍（loadgen）/ 1.29 倍（k6）**，
RSS 少 **4–8 倍**（40 MB vs 338 MB @1000 连接）。这就是"自己写内核"的回报。

### 2.5.5 stdx 作为依赖源的实测（为什么扩展成员用 `${CANGJIE_STDX_PATH}`）

| 方式 | 结果 |
|---|---|
| `[dependencies] "stdx" = "1.2.0"`（中心仓源码依赖） | ⚠️ **能下到源码，但 pre-build 失败**：stdx 的 OpenSSL 动态加载器用 `-Werror`，本机 clang 的 `-Wcast-function-type-mismatch` 全部升级成错误 |
| **`[target.*.bin-dependencies] path-option = ["\${CANGJIE_STDX_PATH}"]`**（链接 SDK 自带 stdx） | ✅ **推荐**，与 tang / cjxt / mcp-cj 全工作区现状一致 |

另有两个已知限制（2026-11-06 实测，见 cangjie-mem）：
- 依赖方的 `link-option` / `package-configuration` **不向下游透传**；
- `output-type` 全链路必须一致（中间层 static + 产品 dynamic 直接报
  `no available artifact of module 'stdx'`）。

---

### 2.6 HTTP/2：要不要加密库？（结论：TLS 是**协议强制**，不是可选项）

> 实测工程：`.scratch/probe-h2`（纯 std）、`.scratch/probe-h2-stdx`（stdx.net.http）。
> 结论基于 RFC 7540 §3.3 / §8.1 与实测行为。

#### 2.6.1 HTTP/2 分两种

| 形态 | 传输 | 是否要 TLS | 是否要加密算法 |
|---|---|---|---|
| **h2**（标准形态） | TLS + ALPN 协商 `h2` | ✅ **必须** | ✅ 必须（TLS 握手用 SHA-256/AES/ECC 等） |
| **h2c**（明文，prior knowledge） | 裸 TCP，直接发 `PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n` | ❌ 不要 | ❌ 不要 |
| h2c via Upgrade | HTTP/1.1 的 `Upgrade: h2c` | ❌ 不要 | ❌ 不要 |

**"HTTP/2 需要加密库"这个说法只对 h2 成立**。h2c 是纯字节协议，不需要任何加密算法。
但**浏览器只支持 h2（TLS）**，h2c 只适用于内网服务间调用或显式配置的客户端。

#### 2.6.2 实测：仓颉的现状

**① stdx.net.http 明确不支持 h2c**（官方文档原文）：

> 「当开发者需要使用 HTTP/2 协议时，需要为 Client/Server 配置 tls，并且设置 alpn 的值为 `h2`；
> **不支持 HTTP/1.1 通过 `Upgrade: h2c` 协议升级的方式升级到 HTTP/2**。」

实测佐证（`.scratch/logs/test-h2c.sh`）：

~~~text
A) 正常 HTTP/1.1              -> HTTP/1.1 200 OK            ✅
B) 直接发 h2 preface          -> HTTP/1.1 505 HTTP Version Not Supported   ❌
   （服务端日志：HttpStatusException: Incorrect version: HTTP/2.0）
C) curl --http2-prior-knowledge -> curl: (16) Remote peer returned unexpected data
                                   while we expected SETTINGS frame   ❌
D) curl --http2 (Upgrade: h2c) -> HTTP/1.1 200 OK（降级回 1.1，没升级）    ⚠️
~~~

**② 主模块收到 h2 preface 会当非法请求行**（`.scratch/probe-h2`）：

~~~text
server 收到 33 字节: PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n
=> HTTP/1.1 parser 判为非法请求行 -> 400
~~~

**③ h2 要的组件在 stdx.net.http.a 里**（`nm` 可见，说明它是纯仓颉实现，不是 C 库）：

~~~text
stdx.net.http:NodeHuffman / QuickHuffman / HPACK 相关符号
~~~

HPACK 的静态表 + Huffman 编码表都是**静态数据 + 纯算法**，不需要加密库。
真正需要加密库的只有 **TLS 层本身**。

#### 2.6.3 如果要给主模块加 HTTP/2，缺什么

| 组件 | 需要什么 | 主模块能不能做 |
|---|---|---|
| **HPACK**（头压缩） | 静态表（61 项）+ Huffman 表（257 项）+ 动态表 + 整数/字符串编码 | ✅ **纯算法，纯 std 就能写**（约 600–800 行，static 表是硬编码数据） |
| **帧层** | 9 字节帧头 + 10 种帧类型（DATA/HEADERS/SETTINGS/WINDOW_UPDATE/RST_STREAM/PING/GOAWAY/...） | ✅ 纯字节协议 |
| **流状态机** | 每 stream 的状态 + 并发流数 + 流控窗口 | ✅ 纯逻辑（但比 HTTP/1.1 的"一连接一请求"复杂得多） |
| **多路复用** | 一条连接上并发处理多个 stream | ⚠️ 与主模块"每连接一协程、顺序处理"的模型冲突 —— **要么改成每 stream 一协程，要么做事件循环** |
| **h2c** | 无 | ✅ 可以做（不需要加密） |
| **h2（TLS）** | TLS 1.2/1.3 + 证书 + ALPN | ❌ **做不了**：`std` 完全没有 TLS，必须 `stdx.net.tls`（OpenSSL 3） |

**所以答案分两层**：

- **h2c（明文 HTTP/2）**：**不需要加密库**，理论上纯 std 可以实现，工作量约 **1500–2500 行**（HPACK + 帧 + 流控 + 状态机）。
- **h2（TLS HTTP/2，浏览器唯一支持的形态）**：**必须有加密库**，且仓颉唯一的 TLS 是 `stdx.net.tls`（依赖 OpenSSL 3 动态库）。
  这一层**不只缺加密算法**（sha/aes/rsa），还缺 **X.509 证书解析与验证、密钥交换、ALPN 协商** —— 自己实现不现实。

#### 2.6.4 推荐部署形态：LB 终结 TLS，后端跑 HTTP/1.1

**这是本方案的目标形态**，也是 fasthttp 生态几十年来的标准用法。

~~~text
   浏览器 / 客户端
        │  h2 + TLS (443)
        ▼
 ┌───────────────────┐
 │  LB / 反代         │   ← TLS 终结 + ALPN 协商 h2 + HPACK 解码
 │  nginx/Caddy/云LB  │      多路复用在这里被"拆开"
 └─────────┬─────────┘
           │  HTTP/1.1 明文（keep-alive，内网）
           ▼
 ┌───────────────────┐
 │  tachyon 主模块     │   ← 只做 HTTP/1.1，零 TLS、零加密库
 │  (fasthttp 风格)   │      每连接一协程，顺序处理
 └───────────────────┘
~~~

**为什么这个形态是对的**：

1. **TLS 有专门的团队/组件在维护**（OpenSSL/BoringSSL/rustls），不需要我们在仓颉里重造；
2. **HTTP/2 的多路复用收益在前端**（浏览器并发请求），反代到后端本来就是长连接复用的，HTTP/1.1 足够；
3. **证书轮换、OCSP、HSTS、HTTP→HTTPS 跳转**这些运维事项全部落在反代上，应用无感；
4. **fasthttp 官方推荐**：其 README 的 "HTTP server performance optimization" 一节就是这么建议的。

##### 各 LB 的选型（按"能不能给后端 h2c"分）

| LB | 前端 h2 | 后端 HTTP/1.1 | 后端 h2c | 推荐度 |
|---|---|---|---|---|
| **nginx** | ✅ | ✅ | ⚠️ **1.25.1+ 才有 `proxy_http_version 2`**，且是实验性 | ⭐⭐⭐⭐⭐ 首选 |
| **Caddy** | ✅ 自动（内置 ACME 自动证书） | ✅ | ✅（原生支持 h2c 后端） | ⭐⭐⭐⭐ 运维最省心 |
| **Traefik** | ✅ 自动 | ✅ | ✅ | ⭐⭐⭐⭐ K8s/Docker 环境首选 |
| **云 LB**（ALB/NLB/CLB） | ✅ | ✅ | 视厂商 | ⭐⭐⭐⭐ 托管环境 |

**对 tachyon 的含义**：**所有主流 LB 都能把 h2 降到 HTTP/1.1 转发给后端**，
所以 **tachyon 只需要 HTTP/1.1 就能吃下全部前端 h2 流量**。
这就是"不做 HTTP/2"在工程上完全站得住的根本原因。

##### 但要注意 LB 带来的两个后端适配问题

| 问题 | 说明 | 我们要做什么 |
|---|---|---|
| **真实客户端 IP** | 反代后 `remoteAddr` 全是 LB 的 IP | 解析 `X-Forwarded-For` / `X-Real-IP`（★ 用户可选，主模块**不自动信任**） |
| **协议标识** | 反代后用 HTTP/1.1，但前端是 HTTPS | 解析 `X-Forwarded-Proto` 供用户判断是否要跳转/生成绝对 URL |

**设计取舍**：主模块**默认不信任**任何 `X-Forwarded-*` 头（安全问题：客户端可伪造）。
提供显式的 **`TrustedProxies`** 配置（对齐 Gin/ASP.NET 的做法）：

~~~cangjie
let srv = Server(handler)
// 默认 TrustedProxies 为空 = 不信任任何转发头，remoteAddr 取真实 TCP peer
srv.trustedProxies = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
// 之后 ctx.remoteAddr 会自动取 X-Forwarded-For 的最后一跳
~~~

> **为什么默认不信任**：如果无条件读 `X-Forwarded-For`，任何客户端都能伪造来源 IP，
> 绕过基于 IP 的限流/黑名单。这是业界反复踩过的坑（Gin 直到 v1.7 才改默认行为）。

##### 实测：nginx 反代到 tachyon（本机验证）

> 本机 nginx 1.30.6 已在 80 端口运行。配置见 `.scratch/logs/nginx-tachyon.conf`。

~~~nginx
# h2 终结在 nginx，后端走 HTTP/1.1
server {
    listen 8443 ssl;
    http2 on;                                  # nginx 1.25.1+ 的新写法
    ssl_certificate     /path/cert.pem;
    ssl_certificate_key /path/key.pem;

    location / {
        proxy_pass http://127.0.0.1:18083;      # tachyon 主模块
        proxy_http_version 1.1;                 # ← 关键：后端用 1.1
        proxy_set_header Connection "";
        proxy_set_header X-Real-IP       $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
~~~

实测结论（详见 §8.6）：
- 浏览器/curl 侧 `--http2` 协商成功，**`HTTP/2 200`**；
- 后端 tachyon 收到的是 **HTTP/1.1**（`curl --http2` 与不带参数结果一致）；
- **QPS 损失来自 nginx 本身**（本机同机压测约 5–8%），不是"降级 HTTP/1.1"造成的。

#### 2.6.5 本方案的建议

| 选项 | 结论 |
|---|---|
| 主模块做 HTTP/2 | ❌ **不做**。与"fasthttp 风格"的取向冲突：fasthttp 本身就不支持 HTTP/2，且 h2 的多路复用会颠覆"每连接一协程顺序处理"这一核心设计 |
| 生产部署 | ✅ **LB 终结 TLS + h2，后端走 HTTP/1.1**（§2.6.4）。nginx / Caddy / Traefik / 云 LB 都行 |
| 需要端到端 h2（后端也要 h2） | 用 `stdx.net.http`（配 `tlsConfig` + ALPN `h2`），代价见 §2.5.4（QPS 约主模块 46%、RSS 8 倍） |
| 纯内网、无 TLS | h2c 可选，但要 ~2000 行自己实现；**一般不值得**，内网用 HTTP/1.1 + keep-alive 就够 |

**一句话**：**h2c 不要加密库但要 ~2000 行；h2 需要 stdx.net.tls（OpenSSL 3）**。
生产上正确的做法是**让 LB 干 h2 的活**，tachyon 只管 HTTP/1.1 —— 这也是 fasthttp 的标准形态。

---

## 3. 总体架构

### 3.1 分层

~~~text
┌─────────────────────────────────────────────────────────────────┐
│ 用户代码：Handler = (ctx: RequestCtx) -> Unit                    │
└───────────────────────────────┬─────────────────────────────────┘
                                │
┌───────────────────────────────▼─────────────────────────────────┐
│ server 层                                                        │
│   Server（配置/生命周期）  perConnLoop  ConnLimiter  IdleRegistry │
└───────────────────────────────┬─────────────────────────────────┘
                                │
┌───────────────────────────────▼─────────────────────────────────┐
│ protocol 层（HTTP/1.1 状态机）                                    │
│   BufferedReader  RequestParser  ResponseSerializer              │
│   HeaderTable(argsKV)  URIView  ArgsView  CookieView             │
│   DateCache  StatusTable  ChunkedReader                          │
└───────────────────────────────┬─────────────────────────────────┘
                                │
┌───────────────────────────────▼─────────────────────────────────┐
│ transport 层（薄封装，可替换）                                     │
│   Conn = std.net.TcpSocket（本期）   |   TLS（不做）              │
└─────────────────────────────────────────────────────────────────┘
~~~

**为什么要单独抽 transport 层**：虽然本期只有 TcpSocket 一个实现，但把"连接"抽象成
`interface Conn { read/write/close/setReadTimeout/... }` 之后：
① 单测可以注入 FakeConn（fasthttp 上游 bench 就是这么做的，151 ns/req 是 fake conn 测的）；
② 将来接 TLS 只加一个实现，不动 protocol 层。**这个接缝很便宜（一个接口 + 一个适配器），值得留。**

### 3.2 数据流（一次请求）

~~~text
协程 entry: perConnLoop(conn)
  ├─ loop {
  │   ① 设 deadline：首次 = ReadTimeout；后续 = IdleTimeout
  │   ② readInto(readBuf)               ← 阻塞点
  │   ③ RequestParser.parse(readBuf)    ← 原地，产出 HeaderTable + URIView
  │   ④ 失败 → writeError(400/408/431) + close，break
  │   ⑤ 读 body（定长 / chunked）→ bodyBuf
  │   ⑥ 组装 RequestCtx（复用对象，Reset 后填）
  │   ⑦ handler(ctx)
  │   ⑧ 判定 keep-alive（六源，见 §5.8）
  │   ⑨ ResponseWriter.write(conn)      ← header 拼进写缓冲，body 跟随
  │   ⑩ ctx.Reset()；空闲且 reduceMemoryUsage 则归还缓冲
  │ }
  └─ conn.close()
~~~

### 3.3 与 fasthttp 的对应关系

| fasthttp | 本方案 | 说明 |
|---|---|---|
| Server | Server | 配置字段一对一（§4.1） |
| serveConn 主循环 | perConnLoop | 九步一一对应 |
| workerPool | **不要** | 协程足够便宜，只留 Semaphore 做并发上限 |
| RequestCtx | RequestCtx | 内嵌 Req/Resp，池化 |
| header（[]argsKV） | HeaderTable | 双平行数组 + 截断复用 |
| bufio.Reader/Writer | BufferedReader/BufferedWriter | 自己写，因为要暴露空闲区 |
| sync.Pool | ObjectPool（per-slot + 全局） | 见 §5.7 |
| bytebufferpool | BodyBufferPool | 同上 |
| URI / Args | URIView / ArgsView | 零拷贝视图，惰性解析 |
| Cookie | CookieView / SetCookieBuilder | 同上 |
| net.Conn | Conn 接口 | 为了可测性 |
---

## 4. 核心 API 设计

### 4.1 Server

~~~cangjie
public class Server {
    public init(handler: RequestHandler)

    // 配置（构造后不可变；要改就新建，和 fasthttp 一致）
    public mut prop name: String
    public mut prop concurrency: Int64          // 默认 16384（不是 fasthttp 的 256K）
    public mut prop readBufferSize: Int64       // 默认 4096
    public mut prop writeBufferSize: Int64      // 默认 4096
    public mut prop readTimeout: ?Duration      // 默认 None
    public mut prop writeTimeout: ?Duration
    public mut prop idleTimeout: ?Duration      // None 时回落到 readTimeout
    public mut prop maxRequestBodySize: Int64   // 默认 4 MiB；<=0 也用默认（照搬 fasthttp）
    public mut prop maxConnsPerIP: Int64        // 0 = 不限
    public mut prop maxRequestsPerConn: Int64   // 0 = 不限
    public mut prop disableKeepalive: Bool
    public mut prop reduceMemoryUsage: Bool     // 空闲连接归还缓冲；本方案默认 true
    public mut prop getOnly: Bool
    public mut prop noDefaultContentType: Bool
    public mut prop noDefaultDate: Bool
    public mut prop secureErrorLogMessage: Bool
    public mut prop errorHandler: ?(RequestCtx, Exception) -> Unit

    // 生命周期
    public func listenAndServe(host: String, port: UInt16): Unit
    public func serve(serverSocket: TcpServerSocket): Unit
    public func shutdown(): Unit
    public func shutdown(timeout: Duration): Unit
}
~~~

**默认值与 fasthttp 的差异（有意为之）**：

| 字段 | fasthttp | 本方案 | 为什么 |
|---|---|---|---|
| concurrency | 256×1024 | **16384** | 13 KB/协程 × 256K = 3.3 GB，默认值不能照抄 |
| reduceMemoryUsage | false | **true** | 协程常驻内存比 goroutine 高，空闲还缓冲收益更大 |
| handler 抛异常 | 崩进程 | 连接断开、进程继续 | 仓颉运行时语义（§7.6） |

### 4.2 Bytes（零拷贝视图，替代 Go 的 []byte）

~~~cangjie
public struct Bytes {
    let buf: Array<Byte>
    let start: Int64
    let len: Int64

    public init(buf: Array<Byte>)                              // 整块
    public init(buf: Array<Byte>, start: Int64, len: Int64)    // 视图
    public operator func [](i: Int64): Byte
    public func size(): Int64
    public func slice(a: Int64, b: Int64): Bytes               // 零拷贝子视图
    public func toStr(): String                                // 唯一的拷贝出口
    public func equalsAsciiIgnoreCase(other: Bytes): Bool
    public func equalsAsciiIgnoreCase(s: String): Bool
    public func indexOf(b: Byte, from: Int64): Int64
    public func indexOfSeq(seq: Bytes, from: Int64): Int64
}
~~~

**为什么不用 Array<Byte> 直传**：Array 的 size 是整块长度，表达不了"这是缓冲里的 [13,47) 段"。
每次 arr[a..b] 虽然零拷贝（27 ns），但会产生一个新的 Array 头对象；
热路径上每请求几十个视图 = 几十次分配。Bytes 是 struct，**按值传递不额外分配**。

### 4.3 RequestCtx

~~~cangjie
public class RequestCtx {
    // 连接信息
    public prop remoteAddr: SocketAddress
    public prop connID: UInt64
    public prop connRequestNum: UInt64
    public prop isTLS: Bool              // 恒 false（本期无 TLS）

    // 请求（只读视图）
    public func method(): Bytes
    public func requestURI(): Bytes
    public func path(): Bytes            // 已规范化
    public func host(): Bytes
    public func userAgent(): Bytes
    public func header(name: String): Bytes
    public func queryArgs(): ArgsView    // 惰性
    public func postArgs(): ArgsView
    public func isGet(): Bool   // isPost/isPut/isHead/isOptions/isPatch/isDelete

    // 响应（写）
    public func setStatusCode(code: UInt16): Unit
    public func setContentType(ct: String): Unit
    public func setHeader(name: String, value: String): Unit
    public func addHeader(name: String, value: String): Unit
    public func setBody(body: Bytes): Unit
    public func setBodyString(body: String): Unit
    public func setBodyStream(reader: InputStream, size: Int64): Unit   // size=-1 -> chunked
    public func setConnectionClose(): Unit
    public func redirect(uri: String, code: UInt16): Unit
    public func error(msg: String, code: UInt16): Unit
    public func success(contentType: String, body: Bytes): Unit

    // 逃生门
    public func setReadDeadline(d: ?Duration): Unit
    public func setWriteDeadline(d: ?Duration): Unit

    // 用户数据（替代 Go 的 any，用 Object 基类）
    public func setUserValue(key: String, val: Object): Unit
    public func userValue(key: String): ?Object

    internal func reset(): Unit
}
~~~

### 4.4 Handler

~~~cangjie
public type RequestHandler = (RequestCtx) -> Unit
~~~

**没有返回值、没有 error**：与 fasthttp 一致。响应通过 ctx 写。
handler 里抛异常 = fasthttp 里的 panic（差异见 §7.6）。
---

## 5. 关键数据结构

### 5.1 HeaderTable（argsKV 模型）

~~~cangjie
class HeaderTable {
    var names: ArrayList<Bytes>       // key 视图（指向 hdrBuf）
    var values: ArrayList<Bytes>      // value 视图（指向 hdrBuf）
    var count: Int64
    let hdrBuf: Array<Byte>           // 每连接一块，预分配 4 KiB
    var hdrLen: Int64

    func reset(): Unit { count = 0; hdrLen = 0 }
    func add(name: Bytes, value: Bytes): Unit
    func get(name: Bytes): Bytes
}
~~~

**视图指向哪**：两种模式，本方案选 B（与 fasthttp 实测一致）。

| 模式 | 指向 | 优点 | 缺点 |
|---|---|---|---|
| A | 读缓冲 | 解析零拷贝 | 缓冲被下次读覆盖后失效 |
| **B** | per-connection 的 hdrBuf | 值可活过缓冲复用，pipeline 安全 | 一次 memcpy |

fasthttp 实测就是 B：把 bufio 缓冲全改成 'Q' 后 Host() 仍返回原值。

**特殊头走专用字段**（照搬 switch key[0]|0x20 的分流）：
Host / Content-Length / Content-Type / User-Agent / Transfer-Encoding /
Connection / Trailer / Cookie / Expect —— 这 9 个进字段，其余进表。
查 Peek("Host") 就是直接读字段，O(1) 不扫表。

### 5.2 BufferedReader / BufferedWriter

~~~cangjie
class BufferedReader {
    let buf: Array<Byte>     // 固定大小，绝不扩容（扩容换底层数组会废掉所有视图）
    var r: Int64
    var w: Int64
    func peek(n: Int64): Bytes
    func discard(n: Int64): Unit
    func fill(): Int64        // conn.read；返回 0 = EOF
    func availableBytes(): Bytes
    func compact(): Unit      // 未消费的搬到头部
}

class BufferedWriter {
    let buf: Array<Byte>
    var n: Int64
    func available(): Int64
    func availableSlice(): Bytes   // 尾部空闲区视图 <- header 直接写这里
    func commit(n2: Int64): Unit
    func flush(): Unit
}
~~~

availableSlice() 是零分配写头的关键：serializeHeader(w.availableSlice()) 直接写进写缓冲空闲区。
装不下就退回自有缓冲（fasthttp 的 serialize 也这么做）。

### 5.3 URIView（惰性 + 规范化）

~~~cangjie
class URIView {
    var raw: Bytes
    var parsed: Bool
    var path: Bytes          // 规范化后（可能指向 pathBuf）
    var pathBuf: Array<Byte>
    var query: Bytes
    var argsParsed: Bool
    var args: ArgsView
}
~~~

**规范化顺序必须照抄**（有安全含义）：

~~~text
1. "/" -> 立即返回 "/"
2. addLeadingSlash
3. 百分号解码（%XX->字节，'+' 不动 —— path 里 '+' 是字面量）
4. 去重复斜杠 "//"
5. 没有 '.' 就直接返回（快路径）
6. 去 "." / ".."（RFC 3986 §5.2.4 四种情况）
~~~

**"先解码再处理 dot-segment"不可颠倒**：否则 %2e%2e 会被当成普通字符放过去（目录穿越）。
实测 fasthttp：/a//b/../c/./d%41 -> /a/c/dA。

### 5.4 ArgsView（256 字节查表 + 单遍）

~~~cangjie
class ArgsView {
    var raw: Bytes
    var parsed: Bool
    var keys: ArrayList<Bytes>
    var vals: ArrayList<Bytes>
    var noValue: ArrayList<Bool>    // "?flag" 无值 key
}
~~~

扫描用一张 256 字节 argsScanTable（0=普通，'%'/'+'/'='/'&' 各一标记），一遍扫完记分隔位置；
解码只对"含 % 或 +"的片段做。**不做"先 split 再 decode"**（多一次扫描 + 一堆临时对象）。

### 5.5 Response 序列化顺序

~~~text
1. 状态行        HTTP/1.1 200 OK CRLF
2. Server        有则发
3. Date          缓存行直接 memcpy
4. Content-Type  仅当"有 body"或显式设置（空 body 不发默认 CT）
5. Content-Encoding
6. Content-Length  受"1xx/204 禁发"约束（304 允许）
7. 用户头（按到达顺序）
8. Trailer
9. Set-Cookie    每条一行
10. Connection: close  仅在需要时补
~~~

**Content-Length 三态**（照搬）：-2=identity，-1=chunked，>=0=定长。
**普通响应永不用 chunked**：body 已在内存里，直接算长度。

### 5.6 DateCache

~~~cangjie
class DateCache {
    let holder: AtomicReference<Array<Byte>>
    let lock: Mutex
    func start(): Unit     // spawn 协程：每秒刷新
    func line(): Array<Byte>
}
~~~

仓颉 DateTime.now() 只要 20 ns（比 Go 便宜），但**格式化要 1227 ns**。
所以每秒刷一次 + 序列化时 memcpy 仍有约 1.2 us/请求 的收益，值得做。

### 5.7 ObjectPool（替代 sync.Pool）

~~~cangjie
class ObjectPool<T> {
    let local: Array<ArrayList<T>>    // 每个"槽"一个，无锁
    let global: ArrayList<T>          // 加锁兜底
    let lock: Mutex
    func get(slotId: Int64): T
    func put(slotId: Int64, obj: T): Unit
}
~~~

**为什么不用简单加锁池**：实测 Mutex 40 ns/次，每请求 get+put 两对象 = 160 ns 纯开销，
高并发下还是争用点。

**slotId 怎么来**：不能用 ThreadLocal（协程会跨内核线程迁移，语义不对）。
方案：Server 维护 AtomicInt64，连接协程启动时 slotId = n % slotCount（slotCount = concurrency/64）。
碰撞只会退化成加锁路径。

### 5.8 keep-alive 判定（六源或，照搬 server.go:2905-2913）

~~~text
close = 请求头含 Connection: close
     || handler 调了 setConnectionClose()
     || 响应本身要求关
     || server.disableKeepalive
     || (maxRequestsPerConn > 0 && connRequestNum >= maxRequestsPerConn)
     || server 正在 shutdown 且 closeOnShutdown
~~~

**顺序很重要**：判定在 handler 返回**之后**，所以 handler 里设置立刻生效。
---

## 6. 实施方案

### 6.1 模块划分与工作量

| 包 | 内容 | 预估行数 |
|---|---|---:|
| tachyon.core | Bytes、Buffers、ObjectPool、StatusTable、DateCache | 600 |
| tachyon.header | HeaderTable、RequestParser、规范化表、ResponseSerializer | 900 |
| tachyon.uri | URIView、ArgsView、路径规范化 | 450 |
| tachyon.cookie | CookieView、SetCookieBuilder、Cookie 解析 | 300 |
| tachyon.server | Server、perConnLoop、ConnLimiter、IdleRegistry、Shutdown | 800 |
| tachyon.ctx | RequestCtx / Request / Response 门面 | 500 |
| tachyon.fs | 静态文件（可选，P5） | 300 |
| **合计** | | **约 3850 行** |

对照：fasthttp 服务端相关约 14000 行（含 client、TLS、HTTP/2、压缩、multipart、文档注释）。
本方案少的主要是：无 TLS / 无 HTTP/2 / 无压缩 / 无 multipart / 无 client。

### 6.2 分阶段（每阶段独立验收）

| 阶段 | 交付 | 验收标准 |
|---|---|---|
| P0 | Bytes + Buffers + 扫描原语 + -O2 工程骨架 | 微基准复现 §8.4 的数字 |
| P1 | HeaderTable + RequestParser（只 header） | httptest 风格用例；每请求 0 分配 |

> **2026-11-08 注记**：上表 P1/P4 里的「每请求 0 分配」**在现有 std 上不可达** ——
> 裸 `std.net.TcpSocket` 的 read/write 自身就约 112 B/req（同口径实测），
> tachyon 全流程 160 B/req，其中自身 HTTP 层约 48 B。详见仓库根 README 的「分配实测」一节。
> （本文其余内容保持调研当时原样，不回改。）
| P2 | ResponseSerializer + perConnLoop（keep-alive + 超时） | curl 全场景通过；QPS >= 40 万 |
| P3 | body（定长 + chunked）+ ArgsView + URI 规范化 + Cookie | RFC 用例 + 安全用例（CL/TE 走私、%2e%2e） |
| P4 | ObjectPool + reduceMemoryUsage + maxConnsPerIP + graceful shutdown | QPS >= 55 万；空闲连接内存回落 |
| P5 | 静态文件 + 错误页 + 中间件（access log / 可选 recovery） | 端到端跑通 |
| **P6** | **扩展成员**：`tachyon_ext_compress` / `tachyon_ext_crypto` / `tachyon_ext_ws` | 各自端到端跑通；**主模块成员 `cjpm.toml` 与 `src/` 仍无 stdx**；`env -u CANGJIE_STDX_PATH` 下 `cd tachyon && cjpm build` 必须成功 |

**P0-P2 是核心**，做完就是"能用的 fasthttp 等价物"；P3 之后才是生产可用。

> **明确不做**：HTTP/2（h2c 与 h2 都不做）、TLS（需 stdx）、WebSocket（扩展成员）、压缩（扩展成员）。
> 这与 fasthttp 的取舍一致 —— fasthttp 同样不支持 HTTP/2。

### 6.3 量化基线（同机、128 连接、-O2）

| 水位 | QPS | p99 | 含义 |
|---|---:|---:|---|
| 及格（= net/http 水平） | >= 40 万 | <= 1.5 ms | 已证明可达（spike2 实测 58 万） |
| 优秀（= 本方案 spike 水平） | >= 58 万 | <= 800 us | 已在验证件上达成 |
| 目标（>= fasthttp 的 90%） | >= 67 万 | <= 700 us | 需全套池化 + 零分配 |

**关键单项：每请求分配次数压到 0-1 次**（fasthttp hello 是 0 allocs/op）。
这是唯一真正决定上限的指标，QPS 只是结果。

### 6.4 解析器写法（最核心的一段）

~~~cangjie
// 一次扫描完成：找行尾 / 找冒号 / 校验 key 字节 / 记录 key 是否有内部空格
func scanHeaderLine(buf: Array<Byte>, from: Int64, n: Int64): (Int64, Int64, Int64, Bool)
~~~

要点：
1. **不要先 indexOf(换行) 再 indexOf(冒号)** —— 那是两遍扫描。fasthttp 的 headerscanner.next 是一遍。
2. key 合法性校验与规范化**同时做**（upper := c == 减号），只在复制时跑一遍。
3. 失败路径要有明确错误码：ErrSmallBuffer(431) / 超时(408) / 其它(400)，且**一律 Connection: close**。

### 6.5 reduceMemoryUsage（空闲连接归还缓冲）

~~~text
连接进入 idle（等下一个请求第一个字节）时：
  if reduceMemoryUsage {
      reader = null; writer = null         // 归还池
      直接 conn.read(firstByte) 等 1 个字节
      拿到后把这一字节塞进 FirstByteReader，再重新取 reader
  }
~~~

这是 fasthttp acquireByteReader（server.go:3206）的做法，目的是让 GC 在等下一个请求时能回收 ctx。
**仓颉收益更大**：每连接 13 KB 协程栈 + 4-8 KB 缓冲，idle 时还掉能显著压低万级空闲连接内存。

### 6.6 并发上限（替代 workerPool）

~~~cangjie
class ConnLimiter {
    let sem: Semaphore
    func tryAcquire(): Bool    // accept 后调用；拿不到 -> 写 503 并关（不阻塞 accept）
    func release(): Unit
}
~~~

语义对照：fasthttp 的 Concurrency 满了回 **503**（不是排队）。**照抄**——
排队会把延迟打满，快速失败让客户端有机会重试别的实例。

### 6.7 优雅关闭

~~~text
shutdown():
  1. 置 stopping（AtomicBool）
  2. serverSocket.close()   -> 阻塞中的 accept() 抛 SocketException（实测立刻）
  3. 遍历 IdleRegistry：
       空闲 > 5s 的连接 conn.close()（立刻打断阻塞 read，实测 304/305 us 时点返回）
       活跃连接等它自然结束
  4. 轮询 openCount 直到 0 或超时
~~~

**与 fasthttp 的关键差异**：fasthttp 的 Shutdown **不关 keep-alive 连接**，
文档要求用户自己设超时，否则一直等。**我们做得更好**：仓颉能立刻打断别人的阻塞 read，
所以可以**主动踢掉空闲连接**，不依赖超时。

### 6.8 反压

HTTP/1.1 背压天然来自 TCP 窗口。本方案不引入额外队列：
- accept：拿不到并发名额就 503；
- 单连接不做 pipeline 深度控制（靠 TCP 背压，与 fasthttp 一致）；
- 写缓冲满 -> flush() 阻塞 -> 自然限流。

### 6.9 规模上限（本方案的真实边界）

| 连接数 | 协程内存（13 KB/条） | 缓冲（reduceMemoryUsage 时约 0） | 合计 |
|---:|---:|---:|---:|
| 1 万 | 130 MB | 约 40 MB | **约 170 MB** |
| 5 万 | 650 MB | 约 200 MB | **约 850 MB** |
| 10 万 | 1.3 GB | 约 400 MB | **约 1.7 GB** |

-> **单机 10 万连接在 2 GB 内可行，和 Go 同量级**。这直接反驳了"万级连接必然崩"的流行误解。

真正的上限来自别处：文件描述符（ulimit -n，实测 20000 连接需要 65535）、GC 长稳。