# 仓颉标准库（无 stdx）服务端能力实测

> 目标：为"用**只用标准库、不引 stdx** 复刻 fasthttp 风格 HTTP 服务端"提供事实依据。
> 工具链：仓颉 1.2.0（cjnative, x86_64-unknown-linux-gnu），cjpm 1.2.0，Linux。
> 所有结论都来自 **./.scratch/probe-std** 里真实编译并运行过的探针（`p00`..`p27`），
> 每条附代码位置与实测输出。**没有一条是凭文档推测的**；文档与实际不符的地方单独标注。
>
> 复现方式：
> ```shell
> cd /home/ystyle/Projects/Cangjie/.scratch/probe-std
> eval "$(cjvs env zsh)"
> ./probe.sh p04        # 跑单个探针，日志落在 logs/p04.log
> ./probe.sh all        # 顺序跑全部（不含 p10b/p26 这类特殊项）
> ```
> 工程是 `output-type = "executable"`、`cjc-version = "1.2.0"`、`[dependencies]` 为空，
> 整包只 `import std.*`，**未引入任何 stdx**（本文第 7、8 节会给出反证：`import std.compress.zlib.*` /
> `import std.crypto.base64.*` 都会被 cjpm 以 "not added as a dependency" 拒绝）。
>
> ⚠️ **性能数字的两个前提（务必先看）**
> 1. **探针工程未开 `-O2`**（cjpm 默认不开）。纯计算型数字（字节扫描等）因此**偏慢约 30–55 倍**，
>    Lead 已用 `-O2` 重测并写在 **§2.4b**，那才是真实水平；其余偏 I/O/系统调用型的数字（线程、内存、
>    网络、GC）受优化影响小，可按下文数值理解。
> 2. **`spawn` 是协程（M:N 绿线程），不是 OS 线程**：2 万条阻塞连接只占 14–20 个内核线程。
>    每协程内存 ≈ **13 KB**（含栈/上下文），50 万协程级不可行，但万级完全可行。

---

## 0. 一页结论（TL;DR）

| 能力 | 标准库能做吗 | 关键事实 |
|---|---|---|
| TCP 服务端 | ✅ 完整够用 | `TcpServerSocket` + `accept()` / `accept(timeout:)`；**多线程可共享同一个 server socket 并发 accept**（p22） |
| 阻塞读写超时 | ✅ | `readTimeout`/`writeTimeout` 生效，抛 `SocketTimeoutException`；负值抛 `IllegalArgumentException`（p02、p19） |
| EOF 语义 | ✅ | 对端关闭 → `read()` 返回 **0**，不抛异常；持续返回 0（p02、p27） |
| 跨线程打断阻塞 | ✅ | 本端 `close()` 立刻打断阻塞的 `accept()`/`read()`，抛 `SocketException: Socket is already closed`（延迟≈0，实测 304/305ms 时点即返回，p03） |
| 半关闭 shutdown | ❌ **没有** | 无 `shutdown(SHUT_WR)`，也不能只关写方向（p19 + 负向编译验证） |
| 拿 socket 的 fd | ❌ **没有** | `TcpSocket` 无 `fd`/`asRawFd`（负向编译验证），所以 sendfile 零拷贝用不上 std.net 的 socket |
| Array<Byte> 切片 | ✅ 零拷贝视图 | `arr[a..b]` 是别名；改切片改原数组；切片会保活底层数组（p04、p17） |
| String ↔ 字节 | ⚠️ 双向都拷贝 | `toArray()` 拷贝、`String.fromUtf8` 拷贝 + 校验；1MiB 量级 340µs / 890µs（p04） |
| unsafe 裸指针 | ✅ | `acquireArrayRawData`/`releaseArrayRawData` 可做原地解析；GC 实测**不移动**对象（p05、p17、p24） |
| ByteBuffer | ✅ | `bytes()` 是零拷贝视图，`ByteBuffer(Array)` 也零拷贝；**非线程安全**（p06） |
| 并发原语 | ✅ 很全 | Atomic/Mutex/Condition/Barrier/Semaphore/SyncCounter/ReadWriteLock/Timer；**没有线程池**（p09、p16） |
| spawn 线程 | ✅ 极便宜 | 100k 线程 ≈ 49ms，约 **489 ns/个**，≈420 B/个；10k 活连接 ≈ 3.6 KiB/连接（p08、p26） |
| std.time | ✅ | 纳秒精度；`DateTime.now()` 约 20 ns——**没有缓存 Date 头的必要**（见第 5 节，与 fasthttp 结论相反） |
| 摘要算法 | ❌ 只有接口 | `std.crypto.digest` 只有 `Digest` 接口 + `digest()` 函数，**SHA1/MD5/SHA256 全都没有实现类**（p12） |
| base64 | ❌ 没有 | std 的 base64 不存在（p23 + 负向编译验证） |
| gzip/zlib | ❌ 没有 | 压缩全在 stdx（p23 + 负向编译验证） |
| 正则 | ✅ | `std.regex` 可用，但比手写字符串判断慢 1~2 个数量级（p13） |
| 静态文件 | ⚠️ 只能读后写 | `File` 有 read/seek，无 sendfile；64MiB 分块读 4ms（page cache），一次性读 66ms（p14） |
| GIL/多核 | ✅ 真并行 | 8 线程 fetchAdd 6ns/op、Mutex 40ns/op；10k 连接下 10002 仓颉线程只占 2 原生线程（p09、p26） |

**一句话**：网络/字节/并发/时间这四块标准库够用且性能不差（尤其线程极便宜，1 连接 1 线程完全可行）；
**卡脖子的是**：摘要算法（websocket/etag 必需）、base64、gzip 三样都得自己写，以及拿不到 fd 所以零拷贝做不到。

---


## 1. std.net：TcpServerSocket / TcpSocket 完整 API 与阻塞语义

### 1.1 API 清单（实测 + 文档核对）

**TcpServerSocket**（探针 p01/p03/p22）

| 成员 | 签名 | 实测行为 |
|---|---|---|
| 构造 | `init(bindAt!: UInt16)` / `init(bindAt!: SocketAddress)` | 只创建，未绑定 |
| `bind()` | `func bind(): Unit` | 绑定并 listen；失败抛 SocketException，不支持重试 |
| `accept()` | `func accept(): TcpSocket` | 阻塞等待 |
| `accept(timeout)` | `func accept(timeout!: ?Duration): TcpSocket` | **命名参数**，超时抛 SocketTimeoutException |
| `close()` | `func close(): Unit` | 幂等，可由其它线程调用打断 accept |
| `localAddress` | `prop localAddress: SocketAddress` | 实测 0.0.0.0:33101（未指定地址时绑 0.0.0.0） |
| `reuseAddress` / `reusePort` / `backlogSize` / `receiveBufferSize` / `sendBufferSize` | mut prop | backlogSize / reusePort 只能在 bind 前改 |

**TcpSocket**（探针 p01/p02/p19）

| 成员 | 签名 | 实测行为 |
|---|---|---|
| 构造 | `init(address: String, port: UInt16)` / `init(SocketAddress)` | |
| `connect()` | `func connect(timeout!: ?Duration = None): Unit` | |
| `read` | `func read(buffer: Array<Byte>): Int64` | 返回读到的字节数；**0 = 对端关闭(EOF)**；可传切片 `buf[4..12]` 直接读进视图 |
| `write` | `func write(payload: Array<Byte>): Unit` | 全部写出或抛异常（不会"写一半返回"） |
| `close()` | `func close(): Unit` | 幂等 |
| `isClosed()` | `func isClosed(): Bool` | |
| `readTimeout` / `writeTimeout` | mut prop ...: ?Duration | 默认 None |
| `noDelay` | mut prop: Bool | **默认 true** |
| `linger` | mut prop: ?Duration | |
| `keepAlive` | mut prop: ?SocketKeepAliveConfig | 构造 SocketKeepAliveConfig(interval:, count:)；读回 toString 显示 idle: 45s（内核默认） |
| `quickAcknowledge` | mut prop: Bool | 实测读回 **true**（文档说默认 false，实际由内核状态决定） |
| `receiveBufferSize` / `sendBufferSize` | mut prop: Int64 | 见 1.7 的坑 |
| `getSocketOptionIntNative` 等 | | 可直接操作 TCP_NODELAY 等底层选项 |
| **没有** `reuseAddress` / `reusePort` | — | 编译报错：'reuseAddress' is not a member of class 'TcpSocket' |
| **没有** `shutdown()` | — | 编译报错：'shutdown' is not a member of class 'TcpSocket' |
| **没有** `fd` / `asRawFd` | — | 编译报错：'fd' is not a member of class 'TcpSocket' |

### 1.2 readTimeout / writeTimeout 确实生效，异常类型明确

代码（`p02`）：

```cangjie
s.readTimeout = Duration.millisecond * 100
println("after set readTimeout = " + s.readTimeout.toString())   // Some(100ms)
let n1 = s.read(buf)                                            // n=3  "abc"
let t0 = MonoTime.now()
try {
    let n2 = s.read(buf)                                        // 数据没来
} catch (e: SocketTimeoutException) {
    let dt: Duration = MonoTime.now() - t0                       // 100ms
}
```

实测输出（`logs/p02.log`）：

```text
  default readTimeout = None
  after set readTimeout = Some(100ms)
  read#1 n=3 data=abc
  read#2 threw SocketTimeoutException after 100ms: SocketTimeoutException: Failed to read data: read data timeout.
  read#3 after peer close returned n=0
  readTimeout set to None -> None
  negative readTimeout threw IllegalArgumentException: Read timeout duration cannot be negative.
```

结论：

- `readTimeout` 生效，抛 **SocketTimeoutException**（不是 TimeoutException，两者无继承关系，catch 要写对）
- 设回 `None` = 无限阻塞
- 负值在 **setter 就抛** IllegalArgumentException（不是等到 read 时才抛）
- `accept` 的负超时同样抛 IllegalArgumentException，但消息是 "Timeout duration cannot be negative."

**writeTimeout 也生效**（p19）：

```text
  -- write 大块 / writeTimeout --
    写到 2 MiB 时抛 SocketTimeoutException（耗时 301ms）: Failed to write data: write data timeout.
    => writeTimeout 生效
```

场景：对端一直不读，本端 send buffer + 对端 recv buffer 塞满后阻塞 → 301ms 超时（设的 300ms）。

### 1.3 EOF 与对端关闭

p19 / p27 实测：

```text
    对端关闭后 read -> n=2  (0 => 正常 EOF)      # 缓冲里剩 2 字节先给你
    再 read 一次 -> n=0  (0 => 持续 EOF，不抛异常)
```

p27 专门验证"服务端正阻塞在 read 上，客户端突然 close"：

```text
[p27] peer-close vs self-close during blocked read
  (200ms 后) 客户端 close()，此时服务端 read() 正阻塞
  服务端 read 在客户端 close 后 0ms 返回: returned n=0
  => 对端关闭 => read 返回 n=0（EOF），不抛异常
```

**与 lead 的观察一致**（lead 测到约 201ms 后返回 n=0；本机实测延迟 <1ms，差别应在客户端是否还有未发出的数据）。
**两种情况结论相同：读端拿到 n=0，不抛异常。**

> 注意：read() 返回 0 **只有"对端关闭"这一种含义**。HTTP keep-alive 下必须靠应用层判据（Content-Length / chunked / 请求头结束空行）决定请求边界，不能靠 0。

### 1.4 跨线程 close() 能打断阻塞的 accept / read（对优雅关闭很关键）

p03：一条线程阻塞在 accept()/read()，另一条线程 300ms 后 close()。

实测输出（`logs/p03.log`）：

```text
  -- B. 跨线程 close() 能否打断阻塞中的 accept() --
    (300ms 后) 从另一线程 server.close()
    accept 实测耗时 304ms -> SocketException: Socket is already closed
    => close() 立刻打断了 accept()
  -- C. 跨线程 close() 能否打断阻塞中的 read() --
    (300ms 后) 从另一线程 sock.close()
    read 实测耗时 305ms -> SocketException: Socket is already closed
    sock.isClosed() = true
    => close() 立刻让阻塞的 read() 返回
```

结论：

- 本端 close() 会**立刻**让阻塞中的 accept() / read() 抛 **SocketException: Socket is already closed**
- 延迟≈0（300ms 触发点，304/305ms 就返回；不是等 accept/readTimeout 到期）
- 所以服务端 shutdown 只要 server.close() + 循环里 catch SocketException 判断 isClosed() 即可，**不需要 self-pipe 之类的自唤醒机制**

### 1.5 close 之后再用（use-after-close）——有个坑

p03 实测：

```text
  -- D. use after close --
    isClosed() = true
    read after close returned n=0 (no throw!)
    write after close threw SocketException: Socket is already closed
    second close() OK (幂等)
```

**这是坑**：close() 之后 read() **不抛异常而是返回 0**，write() 才抛 SocketException。
所以读循环 `if (n <= 0) break` 能同时兼容"对端关闭"和"被自己关掉"；但**写路径必须 try/catch**。

### 1.6 多线程共享 accept（fasthttp 式多 reactor 的前提）

p22 实测：

```text
  -- 多线程 accept 同一 server socket --
    4 线程共享 accept，200 个连接 -> 被接受 200 个
    => 支持多线程 accept 同一个 TcpServerSocket（内核会分发连接），可做多 reactor
```

结论：**同一个 TcpServerSocket 可以被多个仓颉线程同时 accept()**，200 个连接全部分发、无丢失、无异常。
可以用"N 个 accept worker"，也可以"N 个 accept worker 各自再 spawn 处理线程"。

### 1.7 其它文档与实际不符之处

| 坑 | 实测 |
|---|---|
| read 传空数组 | 抛 **IllegalArgumentException: Buffer shouldn't be empty**，文档写的是 SocketException |
| accept() 位置参数 | `accept(Duration...)` 编译报错，必须写 `accept(timeout: ...)` |
| receiveBufferSize 设 65536 | 读回 **131072**（内核翻倍，Linux SO_RCVBUF 语义） |
| sendBufferSize 初始读回 | **2626560** 字节（2.5MiB，内核给的默认值） |
| quickAcknowledge 读回 true | 文档说默认 false，实际取决于内核 |
| accept() 无参 | 等价 accept(timeout: None)，无限等 |

---
## 2. 零拷贝与字节操作

### 2.1 Array\<Byte\> 切片 = 零拷贝别名（关键结论）

p04 实测：

```text
  arr      = [0, 1, 2, 3, 4, 5, 6, 7]
  arr[2..6]= [2, 3, 4, 5]  (size=4)
  after slice[0]=99:
    arr      = [0, 1, 99, 3, 4, 5, 6, 7]   <-- 改切片 -> 原数组变了 => 切片是 VIEW
  after arr[1]=77:
    slice    = [99, 3, 4, 5]   <-- slice 从 arr[2] 起，arr[1] 的变化不该出现 ✓
  after s2[0]=11: arr[0]=11
```

双向验证：改切片 -> 原数组变；写原数组对应位置 -> 也能看到。
切片成本实测 **27 ns/次（1KB 切片 x 1e6）**，与切片大小无关 -> 确认是 O(1) 视图构造，不是拷贝。

**切片会保活底层数组**（p17）：

```text
  -- 切片是否 keep 住底层数组 --
    离开作用域 + GC 后 slic = [20, 30, 40]  (可读 => 切片持有底层数组引用，不会被 GC 回收)
```

含义：**不能靠"原数组变量出作用域"来释放内存**，只要还有人持有切片，整块 buffer 就活着。
对 buffer 池是好事（切片不会悬垂），但要注意内存滞留（切一小片会钉住整块大 buffer）。

### 2.2 String 与 Array\<Byte\> 互转：**双向都拷贝**

p04 实测：

```text
  str=hello-cangjie size=13 toArray().size=13
  after bytes[0]=72: String.fromUtf8(bytes)=Hello-cangjie  str=hello-cangjie (str unchanged => copy)
  raw=[88, 98, 99] s4=abc  (s4 unchanged => fromUtf8 copies)
  String.fromUtf8(invalid utf8) threw: IllegalArgumentException: Invalid unicode scalar value.
  1MiB toArray x200: 68ms (343120 ns/op)
  1MiB fromUtf8 x200: 178ms (891543 ns/op)  (utf8 validation applies)
```

- str.toArray()：拷贝，**1MiB 约 343 us**
- String.fromUtf8(bytes)：拷贝 **且做 UTF-8 校验**，**1MiB 约 892 us**（慢 2.6 倍，慢在校验）
- 非法 UTF-8 抛 IllegalArgumentException: Invalid unicode scalar value.
- String.fromUtf8Unchecked 存在但是 **unsafe 函数**（不加 unsafe {} 编译报错）

p25 单独测校验成本（4096 字节 ASCII）：

```text
  String.fromUtf8(4096B, ASCII) x50k: 1754ms (35096 ns/op)
  String.fromUtf8Unchecked(4096B) x50k: 66ms (1329 ns/op)
```

**校验占了 96% 的耗时（35.1 us vs 1.3 us，26 倍差）**。

结论：HTTP 头部解析**不要走 String 中转**。一遍 Array\<Byte\> 扫到底，只在需要返回给用户的字段才 String.fromUtf8 拷一份。

### 2.3 unsafe 裸指针（可用，且实测 GC 不移动对象）

API（std.core，自动导入）：

```cangjie
public unsafe func acquireArrayRawData<T>(arr: Array<T>): CPointerHandle<T> where T <: CType
public unsafe func releaseArrayRawData<T>(handle: CPointerHandle<T>): Unit where T <: CType
// CPointerHandle<T> { let array: Array<T>; let pointer: CPointer<T> }
// CPointer<T>: read() / read(Int64) / write(T) / write(Int64,T) / +offset / -offset / toUIntNative() / isNull()
```

p05 实测：

```text
[p05] unsafe CPointer over Array<Byte>
  p.read(0)=0  p.read(7)=7  p.read(15)=15
  (p+3).read() = 3
  after raw writes: arr = [200, 1, 2, 3, ..., 250]   <-- 原地写生效 => 零拷贝视图
  released
```

- 通过裸指针写，Array 立即可见（**真别名，无拷贝**）
- 支持指针算术 p + n
- **完全没有边界检查**（越界读不报错，直接读内存）

**GC 移动问题（三重验证）**：

```text
[p05] GC count: 0 -> 16; usedHeap 1236992 -> 18571264 bytes
      raw ptr addr before GC = 140425824501776, after GC = 140425824501776  (same: true)
      raw read(0)=42 after GC read(0)=42 read(last)=43
      => GC 未移动该数组

[p17] -- 反复 GC 下裸指针的地址稳定性 --
      10 轮 gc(heavy) 后: 地址稳定=true  (GCCount=17, 已用堆=24846336B)
      初始地址=139650058616848 最终地址=139650058616848

[p24] 64 个小数组，8 轮 gc(heavy): 地址变化次数=0 数据不符次数=0
      => 实测 GC 不移动这些对象，裸指针跨 GC 保持有效（但文档无保证，属实现细节）
```

结论：

- 实测仓颉 1.2.0 的 GC **不移动** Array\<Byte\>（大对象、小对象都不移），裸指针可跨 GC 长期持有
- **但官方文档没有承诺**（acquireArrayRawData 文档只说"用完后及时 release，两者之间只应包含简单的 foreign 调用"）。这是**实现细节，不是语言保证** -> 升级版本有风险，生产代码要留非 unsafe 的降级路径
- 文档还警告：acquire/release 之间不要构造 CString 等仓颉对象

**acquire/release 的开销**（p25）：

```text
  acquire+read1+release x200k (同一数组，无分配): 10ms (50 ns/op)  => acquire 本身不便宜
```

50 ns/次约等于 100 次下标访问 -> **正确用法是 acquire 一次、持有整个连接生命周期，不要 per-request 包裹**。

### 2.4 三种字节扫描方式公平对比（p25，都扫 128 字节、都在第 127 字节停）

> ⚠️ **这一节的数字是"未开 -O2"测的，比真实情况慢约 30 倍，已作废。**
> 下面的 §2.4b 是 Lead 用 `compile-option = "-O2"` 重测的结果，**以 §2.4b 为准**。

```text
  acquire+read1+release x200k: 10ms (50 ns/op)
  裸指针扫描 128B x200k: 619ms (3096 ns/op, 24 ns/B)      ← 未开 -O2
  Array 下标扫描 128B x200k: 1190ms (5953 ns/op, 46 ns/B) ← 未开 -O2
  String for-in 扫描(扫到 127) x200k: 1395ms (6976 ns/op, 54 ns/B)
```

### 2.4b **修正版（-O2 开启）——这才是真实水平**

Lead 实测（`.scratch/probe-lead`，`compile-option = "-O2 -Woff unused"`）：

```text
[scan] CRLFCRLF 索引 4KB (4096B x200000): 1571 MB/s  (0.63 ns/B)
[scan] CRLFCRLF 裸指针 4KB (4096B x200000): 2320 MB/s  (0.43 ns/B)
[scan] 单字节 \n 索引 1MB (1048576B x500): 2356 MB/s  (0.42 ns/B)
[scan] 单字节 \n 裸指针 1MB (1048576B x500): 3201 MB/s  (0.31 ns/B)
```

对照实测（同一个探针，只改 `compile-option`）：

```text
=== 无 -O2 ===  scan 4KB x200000 = 10780847823 ns -> 75 MB/s
=== 加 -O2 ===  scan 4KB x200000 = 195541338 ns -> 4189 MB/s
```

**结论（修正）：**

1. **`-O2` 是生死线**：不开优化时逐字节扫描只有 **75 MB/s**（55 倍差距），
   开了 `-O2` 是 **1.5–4.8 GB/s**。任何性能结论都必须在 `-O2` 下测。
   （cjpm 默认 **不** 开 `-O2`，必须在 `cjpm.toml` 里写 `compile-option`。）
2. 开 `-O2` 后**索引扫描 0.42–0.63 ns/B、裸指针 0.31–0.43 ns/B**，
   和 Go 的 `bytes.IndexByte`（memchr/AVX2）仍在同一量级，**不是瓶颈**。
   裸指针比索引快约 1.4–1.6 倍（仍是 bounds-check 的差价）。
3. 所以 §3.3 的"HTTP 头部解析正确姿势"里"裸指针最快 24 ns/B"要按 0.4 ns/B 重新理解——
   **扫描从来不是仓颉写 HTTP 服务端的瓶颈，per-request 的固定开销才是**。

### 2.5 ByteBuffer：bytes() 是视图，对象本身非线程安全

p06 实测：

```text
  default capacity=32 length=0 position=0 remainLength=0
  after write: capacity=32 length=27 position=0 remainLength=27
  bytes() size=27
  after slice[0]=88 -> bb.bytes()[0]=88  ('X'=88 => bytes() 是视图（零拷贝）)
  修改 ByteBuffer 后再取 bytes(): size=31
    旧 slice2.size=27 slice2[0]=88  (旧切片能读 => 旧底层数组仍被引用)
  read 4 bytes: 'XET ' -> position=4 remainLength=27
  ByteBuffer(arr).bytes()[0]=90 -> arr[0]=90  (src=Zbcdef)
    => ByteBuffer(Array) 共享底层数组（零拷贝）
  写入 1MiB 到空 ByteBuffer: 1ms, capacity=1366188 length=1048576
  200k x write+41B+bytes+clear: 7ms (36 ns/op)
  -- ByteBuffer 并发写（无锁）--
  8 threads x 10000 x 100B writes -> length=6166300 (expect 8000000 if thread-safe)
  => 数据丢失/损坏 => ByteBuffer 非线程安全
```

结论：

- bytes() 返回**未读区间**的零拷贝视图；改视图改 buffer
- ByteBuffer(Array\<Byte\>) 构造**不拷贝**，直接接管
- clear() 保留 capacity -> **可 per-connection 复用**，200k 次 write+bytes+clear 只 36 ns/op
- **非线程安全**（8 线程并发写丢了 23% 数据）-> 每连接独占

---

## 3. String 解析性能

### 3.1 String.size 是 UTF-8 字节数，但**切片会校验 UTF-8**

p07 实测：

```text
  s = 'GET /路径 HTTP/1.1'
  s.size (字节) = 20
  s.toRuneArray().size (字符) = 16
    iterate[0]=71 iterate[1]=69 iterate[2]=84 iterate[3]=32   (静态类型是 UInt8 => 逐字节)
  iterate count = 20 (= 字节数 20?) true
  s[4..8] = '/路' size=4 (4 字节 = '/' + 3 字节汉字)
  s[4..7] (切在汉字中间) 直接抛 IllegalArgumentException: Invalid utf8 byte sequence.
  unsafe fromUtf8Unchecked(raw[4..7]) 成功, size=3  <-- 绕过了校验
```

结论：

- for (b in s) 迭代得到 **UInt8** -> 按字节扫描不需要转 Array
- String.size 是字节数（可直接当 HTTP 报文长度用）
- 但 s[a..b] 会**强制校验 UTF-8**，切在字符中间直接抛 -> **不能拿字节下标随便切 String**
- 突破办法：先 toArray()，或 unsafe fromUtf8Unchecked

### 3.2 各种扫描方式的实测成本（p07，扫 28 字节头部行，20 万次）

```text
  for-in byte scan (28B) x200000: 5ms  (27 ns/op) acc=94400000
  toArray + index scan x200000:  38ms (193 ns/op)      <-- 每次 toArray 的代价
  cached Array + index scan x200000: 37ms (186 ns/op)
  String.indexOf(":") x200000:    2ms  (10 ns/op)
  String.split(":") x50000:       4ms  (85 ns/op) parts=150000
  toAsciiUpper+== x200000:        6ms  (31 ns/op)
  String == x200000:              0ms  (3 ns/op)
```

### 3.3 结论：HTTP 头部解析的正确姿势

1. **全程用 Array\<Byte\>，绝不转 String**：一次 read() 读进 per-connection buffer，后续字节下标/切片扫描。
   **-O2 下扫描只要 0.3–0.6 ns/B**（见 §2.4b），裸指针比下标快 1.4–1.6 倍。**扫描不是瓶颈。**
2. **不要用 String.split / indexOf**：indexOf 虽只要 10 ns，但前提是**你已经有 String**——构造 String 本身要 343 us/MiB 拷贝 + 校验。
3. **for-in 迭代 String 是逐字节、不慢（≈1 ns/B）**，但若数据源本来是字节数组，构造成 String 反而是最大开销（35 us/4KB，比 unchecked 慢 26 倍）。
4. **大小写无关比较**：不要 toAsciiUpper() 再比（31 ns + 分配），自己写 ASCII 逐字节比较。
5. **常量字符串比较很快（3 ns）**，少量确定字段可用 String ==。
6. 需要返回给用户的值（path、header value）才 String.fromUtf8(slice) 拷一份。

---
## 4. 并发：spawn 成本 / std.sync 原语 / 线程池 / 10k 连接

### 4.1 spawn 的真实成本（p08）

测量方法：`p08Batch(n)` 用 `MonoTime.now()` 包住 **for 循环 spawn n 次 + 全部 `f.get()` 收敛完** 的整段再除以 n，
所以数字含「创建 + 调度 + 执行 + 回收 + 聚合」全流程，是端到端成本。

```text
  processors=16 nativeThreads=1 threadCount=1
  spawn x1:      60us total (60374 ns/thread) sum=0
  spawn x1000:   3527us total (3527 ns/thread)  sum=499500     heap +507 B/thread
  spawn x10000:  6053us total (605 ns/thread)   sum=49995000   heap +482 B/thread
  spawn x100000: 48916us total (489 ns/thread)  sum=4999950000 heap +421 B/thread
  spawn 100000 live threads: 656ms; heap +68 B/thread; threadCount=100000 nativeThreads=2
```

**与 lead（1000 线程 2.4ms ≈ 2.4us/线程）的差异**：本机 1000 线程批测得 **3527 ns ≈ 3.5us**，与 lead 的 2.4us **同一量级**，
差异在机器负载与是否计入 `get()` 收敛。我的 489 ns 是 **100k 批量**的数字（预热效应摊薄），**不代表小批量**。
**保守取值：冷启动 ~3.5us/协程，稳定态 ~0.5us/协程，堆增量 ~420-510 B/协程。**
仓颉 `spawn` 是 **M:N 协程（用户态绿线程）**：100k 活协程时 nativeThreads=2（p08），10k 连接时 nativeThreads=1（p26）。

**补充（Lead 实测，纠正"真线程"的误判）**：协程**阻塞在内核 socket read 上**时也不占内核线程：

```text
=== baseline ===                         Threads: 5
=== 20000 个存活且阻塞的协程 ===           Threads: 20    VmRSS: 260 MB
=== 20000 条阻塞在 read() 的真实连接 ===   Threads: 14    VmRSS: 363 MB
=== 协程内存逐级实测 ===
  存活 1000:  (+13 kB/协程)  threads=12
  存活 5000:  (+13 kB/协程)  threads=16
  存活 20000: (+13 kB/协程)  threads=18
  存活 50000: (+12 kB/协程)  threads=20
```

**结论：每连接一协程 = 每连接 ~13 KB（含阻塞栈），与 Go goroutine（~2–8 KB + 堆）同一量级。
万级连接（13 万 KB ≈ 130 MB / 万连接）完全可行，不需要 event loop。**

### 4.2 10k 并发连接实测（p26）

```text
[p26] 10k concurrent connections
  建立 10000 连接（失败 0）耗时 467ms
  服务端 accepted=10000
  内存: 起始 0 MiB -> 连接后 35 MiB (增量 35912 KiB, 每连接 3677 B)
  线程: 起始 1 -> 10002 仓颉线程, 原生线程 1
  向 10000 个连接各写 1 个小请求: 89ms
  关闭 10000 连接: 94ms; 服务端 closed=10000
  结束时 threadCount=1 usedHeap=35 MiB
```

**1 连接 1 线程在 10k 规模完全可行**：每连接约 **3.6 KiB**，10000 连接 + 10000 仓颉线程 = 35 MiB，原生线程只要 **1 个**。
建连 467ms（≈47us/连接）；关闭 94ms；无失败无崩溃。100k 活线程也能跑通（p08：656ms）。

### 4.3 std.sync 原语清单与实测性能（p09）

```text
  AtomicInt64: load/fetchAdd/swap/compareAndSwap/fetchSub 全部可用
  AtomicBool: load/swap/compareAndSwap 可用
  AtomicReference<Box<String>>: load/swap 可用  <- T 必须是引用类型（class），String 是 struct 不能直接用
  8 threads x 500000 fetchAdd: 25ms (6 ns/op) total=4000000
  8x100000 synchronized(mtx) {shared+=1}: 32ms (40 ns/op) shared=800000
  tryLock when free = true / when held = true（可重入）
  Condition.wait / notifyAll / waitUntil OK
  SyncCounter(3).waitUntilZero() OK
  Barrier(4).wait() passed by 4 threads
  Semaphore(2) with 8 tasks -> peak concurrency = 2
  ReadWriteLock: writeLock.tryLock() while read held = false；isFair()=false
  Timer.once(50ms) fired=true；Timer.cancel() 可用（p16）
```

可用原语：`AtomicInt8/16/32/64`、`AtomicUInt*`、`AtomicBool`、`AtomicReference<T>`、`AtomicOptionReference<T>`、
`Mutex`（可重入，配 `synchronized`）、`Condition`、`SyncCounter`、`Barrier`、`Semaphore`、
`ReadWriteLock(fair!: Bool = false)`（`readLock: Lock` / `writeLock: UniqueLock`）、`Timer`、`Thread`/`ThreadLocal`。

### 4.4 Future.get() 的异常传播（p09）

```text
  -- Future.get() exception propagation --
    f1.get() rethrew IllegalArgumentException: boom from thread  <-- 异常传播到调用方
    f2.get() threw Exception: generic
    f3.get() rethrew IndexOutOfBoundsException: ...
```
**子线程异常被 `Future.get()` 原样重抛（保留具体类型），不吞不包装。**

### 4.5 有没有线程池 / 阻塞队列（p16）

```text
  std.sync 只有 Thread / ThreadLocal / Mutex / Condition / Barrier / Semaphore / SyncCounter / ReadWriteLock / Atomic / Timer
  std 里没有 ExecutorService / ThreadPool / Executor 类
  => 线程池要自己用 spawn + ArrayBlockingQueue 搭
  自建 8 worker pool 跑 100k 任务: 30ms (300 ns/task)

  ConcurrentHashMap 8x100000 add: 445ms size=800000
  ConcurrentLinkedQueue 8x100000 add: 35ms size=800000
  ArrayBlockingQueue 200k 生产/消费: 152ms consumed=200000 balanced=true
```

- **没有线程池**（负向编译：`ThreadPool(4)` -> `undeclared identifier 'ThreadPool'`）。自建 8 worker pool 300 ns/task，够用。
- 阻塞队列：`ArrayBlockingQueue<E>(capacity)` / `LinkedBlockingQueue<E>(capacity)`，方法 `add` / `add(E,Duration)` / `tryAdd` / `remove()` / `remove(Duration): Option<E>` / `tryRemove` / `peek`
- 非阻塞：`ConcurrentLinkedQueue<E>`；线程安全 map：`ConcurrentHashMap<K,V>(concurrencyLevel:)`

### 4.6 std.collection 容器**不是**线程安全的（p09）

```text
  ArrayList: 8x10000 add -> size=31294 (expect 80000); 数据丢失/损坏 => 非线程安全
  HashMap:   8x10000 add -> size=63760 (expect 80000); 数据丢失/损坏 => 非线程安全
```
`ArrayList` / `HashMap` 并发写会**丢数据且不报错**。多线程共享必须用 Concurrent* 或自己加锁。

---

## 5. 时间：精度足够，Date 头缓存收益远小于 Go

p11 实测：
```text
  MonoTime.now() 连续两次差 = 30 ns
  1000 次采样最小间隔 = 10 ns  (时钟分辨率)
  DateTime.now().nanosecond = 164345158  (纳秒字段有效)
  DateTime.now() x100000: 2ms (20 ns/op)
  MonoTime.now() x1e6: 31ms (31 ns/op)
  DateTime.now().format(Date 头格式) x20000: 24ms (1227 ns/op)
    样例: EEE, 07 Nov 2026 20:27:56 CST
  DateTime.now().second x1e6: 89ms (89 ns/op)
  手工拼 ISO-ish 字符串 x100000: 85ms (851 ns/op)
  Duration.nanosecond.toNanoseconds() = 1  (纳秒精度)
  epoch.toUnixTimeStamp() = 0s；DateTime.fromUnixTimeStamp(...) 可用
```

**结论**：
- `DateTime.now()` **只要 20 ns**。fasthttp 缓存 Date 头是因为 Go 的 `time.Now()+Format` 昂贵；
  仓颉取时间 20 ns、**格式化 1227 ns**，按秒缓存 Date 头**仍有价值（省 1227 ns/响应）但收益远小于 Go 场景**。
- 优化替代：手工拼字符串 851 ns（比 format 快 30%），或用 `DateTime.now().second` 做 key 缓存（89 ns/op）。
- 精度：MonoTime 纳秒级（分辨率 10ns），适合 keep-alive 超时、限流窗口。
- 时区：`DateTime.now().zoneId = Asia/Chongqing`，`zoneOffset = 8h`。

---

## 6. crypto：**只有接口，没有任何算法实现**（严重缺口）

p12 实测 + 逐类编译验证：
```text
[p12] std.crypto.digest / base64
  Digest interface importable; 用自定义实现验证接口形状与 digest() 泛型函数
  digest() generic works, size=16
  algorithm=MyDigest blockSize=64
  => 标准库只有 Digest 接口 + digest() 函数，没有 SHA1/MD5/SHA256 等实现类

SHA1:   FAIL -> error: undeclared identifier 'SHA1'
MD5:    FAIL -> error: undeclared identifier 'MD5'
SHA256: FAIL -> undeclared identifier 'SHA256'
SHA224/SHA384/SHA512/HMAC/SM3: 同样 undeclared
```

`std.crypto.digest` 只有：`interface Digest { prop size/blockSize/algorithm; write(Array<Byte>); finish(): Array<Byte>; finish(to!: Array<Byte>); reset() }`
和 `digest<T>(T, Array<Byte>)` / `digest<T>(T, InputStream)`。**没有任何具体算法**（文档 overview 说支持 MD5/SHA1 是误导，实现在 stdx）。

**base64 / gzip 也不存在**（负向编译）：
```text
import std.crypto.base64.* -> Error: root package 'probe_std' imports package 'std.crypto.base64' ... not added as a dependency
import std.compress.zlib.*  -> 同样的错误
（对照：import std.netx.notreal.* 报同样错误 -> 「包不存在」就是这个报错）
```

**影响**：WebSocket 握手（SHA1+base64）、ETag/内容摘要（MD5/SHA1）、gzip 响应全部无法用标准库实现。
要自己写 SHA1(~150 行)+MD5(~200 行)+base64(编 20/解 40 行)+deflate(800-1500 行)，或引入 stdx。

---

## 7. 其它影响服务端的能力

### 7.1 正则（p13）
```text
  find("/api/v2/users/12345") -> matchString="/api/v2/users/12345" groupCount=2
  Regex.matches(简单模式) x100000: 11ms (113 ns/op)
  Regex.find(带 2 命名组) x100000: 18ms (181 ns/op)
  String.startsWith x100000: 0ms (8 ns/op)
```
**有 `std.regex`，功能完整**（命名组、matchPosition、lazyFindAll）。但路由匹配**建议手写前缀树**：正则比 `startsWith` 慢 14-23 倍。

### 7.2 静态文件（p14）
```text
  File.readFrom(small) = "hello static file" size=17
  FileInfo.name=small.txt size=17  lastModificationTime=2026-11-07T12:27:51Z
  64KiB 分块读完 64MiB: 4ms total=67108864   (page cache 命中)
  File.readFrom(64MiB) 一次性: 66ms
  seek(1MiB) -> position=1048576 length=67108864
```
- `File` 实现 `IOStream & Seekable`（read/write/seek/position/length）-> **支持 Range 请求**
- **没有 sendfile / splice / fd** -> 只能 read 到 `Array<Byte>` 再 `socket.write`，**至少一次用户态拷贝**
- 一次性读 64MiB 要分配 64MiB（66ms），大文件必须分块（64KiB 分块仅 4ms，page cache）

### 7.3 压缩（p23）
```text
  std 的包列表（SDK modules/linux_x86_64_cjnative/std/*.cjo）里没有 compress/zlib 系列
  std.crypto 只有 digest/cipher 接口，没有压缩
  => gzip 必须用 stdx.compress.zlib（或自己写 deflate）
```

### 7.4 HashMap 性能（p15）
```text
  构造+8 插入+8 查找 x200000: 785ms (3927 ns/op)
  HashMap<String,String>.get x2e6: 254ms (127 ns/op)
  HashMap<Int64,Int64> 插入 1e6: 520ms (520 ns/op) capacity=1347984
  HashMap<Int64,Int64> 查找 1e6(全命中): 120ms (120 ns/op)
  HashMap<Int64,Int64> 查找 1e6(全未命中): 86ms (86 ns/op)
  Array 线性扫描定位 Content-Length x1e6: 164ms (164 ns/op)
```
**HashMap get ≈ 120-127 ns**。HTTP header（8-20 个）用**数组线性扫描（164 ns）与 HashMap 同量级**，但省掉 hash + 节点分配 -> 小 header 集合建议用数组。

### 7.5 FFI 可以直连 libc（p20/p21）
```text
[p20] foreign func getpid() -> 302  (FFI 链接可用)
      foreign: socket/bind/listen/accept/recv/send/setsockopt/sendfile 均声明并链接通过
[p21] socket() -> fd=3；bind() -> 0；listen() -> 0
      FFI accept() -> clientFd=4
      FFI recv() -> n=6   收到的内容: "FFI-OK"
```
**可以完全绕过 std.net 用 FFI 自建 socket**（p21 端到端跑通）。但 `TcpSocket` **拿不到 fd**（负向编译：`'fd' is not a member of class 'TcpSocket'`），
所以要么全 FFI（自己做 DNS/IPv6/超时/错误码），要么接受 std.net 的一次拷贝。
`foreign` 函数名必须与 libc 符号**完全一致**（用 `socketCreate` 别名会链接期 `undefined reference`）。

---

## 8. 运行时细节

### 8.1 线程安全地共享 Array<Byte>？
```text
  -- 多线程分区间读写同一数组（无重叠，安全）--
    8 线程各写 1MiB 不重叠区间: total=1069547520  (无崩溃、无越界)
  -- 多线程裸指针同时 read-modify-write 同一单元（无锁）--  (p05)
    8 threads x 200000 non-atomic ++ -> counter=252336 (expect 1600000)
    => 丢失 1336484 次更新 => 裸指针无任何原子性
```
- **不同线程写不同区间**：安全
- **不同线程写同一区间**：静默丢更新，必须 Atomic/Mutex

### 8.2 GC 会不会移动对象（p05/p17/p24 三重验证）
```text
[p05] 16 次 GC 前后裸指针地址相同；大数组首尾数据完好
[p17] 10 轮 gc(heavy) 后地址稳定；GCCount=17，堆 24MB
[p24] 64 个小数组（64B）8 轮 gc(heavy)：地址变化 0 次，数据不符 0 次
```
**实测不移动，但这是实现细节不是语言保证** —— 文档没承诺，升级需重测。

### 8.3 unsafe 块语法要求
必须显式 `unsafe { }`，否则编译报错：`acquireArrayRawData`/`releaseArrayRawData`、`CPointer.read()/.write()/+/-/toUIntNative()`、`String.fromUtf8Unchecked`、所有 `foreign` 调用。

### 8.4 异常会不会终止进程（p10 + p10b）
**spawn 子线程抛异常：不终止进程**（p10）
```text
  after child threw & nobody .get(): main thread still running
  f.get() rethrew: thrown in child, nobody calls get()
```
- 没人调 `get()` -> 异常被丢弃，但 **stderr 打印 `An exception has occurred:` + 堆栈**
- 调了 `get()` -> 原样重抛（保留具体类型）

**主线程未捕获异常：进程退出，exit code = 1**（p10b 独立进程实测）
```text
--- STDOUT ---
[p10b] main thread about to throw uncaught
--- STDERR ---
An exception has occurred:
ArithmeticException: Divided by zero!
   at probe_std::p10bMainThreadUncaught()(...p10b.cj:6)
   at probe_std::main(...main.cj:47)
--- [exit 1] ---
```
服务端 accept 循环 / 连接处理**必须自己 try/catch**，不能让异常逃到 main。

### 8.5 运行时信息与退出钩子（p18）
```text
  processId=645 processorCount=16 nativeThreadCount=1 threadCount=1
  maxHeapSize = 268435456 B   (256 MiB)
  getAllocatedHeapSize/getUsedHeapSize/getGCCount/getGCTime/getBlockingThreadCount 均可用
  env PATH size = 743；getVariable("CANGJIE_HOME") = /tmp/...
  atExit(...) 注册成功 -> [p18] atExit hook fired（退出时触发）
  setGCThreshold / gc(heavy: true) / blackBox / dumpHeapData / startCPUProfiling 可用
```
- **`atExit()` 可做优雅关闭钩子**（实测触发）
- `gc(heavy!: Bool)` 是**命名参数**（`gc(true)` 编译报错：missing argument prefix 'heavy:'）
- 堆上限默认 **256 MiB**，大 buffer/大文件要留意，可用 `setGCThreshold` 调

---

## 9. 对复刻 fasthttp 的可行性结论

### 能做（标准库足够）
| 组件 | 做法 |
|---|---|
| HTTP/1.1 解析 | `Array<Byte>` + 裸指针逐字节扫描（**-O2 下 0.3–0.4 ns/B**）；只在产出字段时一次 `fromUtf8` |
| 连接管理 | 1 连接 1 仓颉线程（10k 连接 35 MiB / 1 原生线程）；或 N accept worker |
| 超时 | `readTimeout`/`writeTimeout` 原生支持，抛 `SocketTimeoutException` |
| 优雅关闭 | 其它线程 `server.close()` 立刻打断 accept/read，抛 `SocketException`，无需 self-pipe |
| keep-alive | `read()` 返回 0 = 对端关闭；请求边界靠 Content-Length/chunked |
| 路由 | 手写前缀树（正则慢 14-23 倍） |
| 缓冲复用 | `ByteBuffer.clear()` 保留容量（36 ns/op）；`ObjectPool` 已 deprecated |
| 限流/统计 | `AtomicInt64`（6 ns/op）、`Mutex`（40 ns/op） |
| 静态文件 | `File` read + seek 支持 Range；无 sendfile，有一次拷贝 |

### 做不到 / 有代价（明确写出来）
| 缺口 | 影响 | 代价 |
|---|---|---|
| **无 SHA1/MD5/SHA256 实现** | WebSocket 握手、ETag、内容摘要全废 | 自己写 SHA1(150行)+MD5(200行)，或引 stdx |
| **无 base64** | WebSocket、Basic Auth 全废 | 自己写（编 20/解 40 行），或引 stdx |
| **无 gzip/deflate** | 无法压缩响应 | 自己写 deflate（800-1500 行）、FFI 调 zlib，或引 stdx |
| **拿不到 socket fd** | 无法 sendfile/splice 零拷贝 | 全 FFI 自建 socket（放弃 std.net），或接受一次拷贝 |
| **无 shutdown 半关闭** | 无法只关写方向 | 无解，只能 close() 整个连接 |
| **无线程池** | 需自己搭 | +30 行（spawn + ArrayBlockingQueue），300 ns/task |
| **ArrayList/HashMap/ByteBuffer 非线程安全** | 共享即静默丢数据 | 用 Concurrent* 或加锁 |
| **GC 不移动是实测不是保证** | 裸指针长期持有有版本风险 | 留非 unsafe 降级路径；升级必须重测 p05/p17/p24 |
| **String 切片校验 UTF-8** | 不能用字节下标切 String | 全程用 Array<Byte> |

### 最小可行技术选型
1. 单进程 + N 个 accept worker（`TcpServerSocket` 多线程 accept 已验证可行）
2. 每连接一个仓颉线程（10k 连接仅 35 MiB，原生线程 1-2 个）
3. 每连接持有一个 `Array<Byte>` + 一次 `acquireArrayRawData`（连接生命周期内不复 acquire）
4. 解析全程裸指针/字节下标，不构造 String；需要 String 的字段才 `String.fromUtf8(slice)`
5. 优雅关闭用 `server.close()`（已实测能打断所有阻塞中的 accept/read）
6. 压缩/摘要/base64 三选一：引 stdx（违背题目）/ 自己写 / 不实现

---

## 10. 探针索引与复现

工程：`.scratch/probe-std/`（cjpm executable，cjc-version 1.2.0，`[dependencies]` 为空，只 import std）

| 探针 | 覆盖 | 源文件 | 日志 |
|---|---|---|---|
| p00 | 探针框架 sanity | `src/p00.cj` | — |
| p01 | TCP 基本 accept/read/write/close | `src/p01.cj` | `logs/p01.log` |
| p02 | readTimeout / EOF 语义 | `src/p02.cj` | `logs/p02.log` |
| p03 | accept 超时 / 跨线程 close 打断 / use-after-close | `src/p03.cj` | `logs/p03.log` |
| p04 | Array 切片零拷贝 / String 互转 | `src/p04.cj` | `logs/p04.log` |
| p05 | unsafe 裸指针 / GC 移动 / 并发竞态 | `src/p05.cj` | `logs/p05.log` |
| p06 | ByteBuffer 语义 / 线程安全 | `src/p06.cj` | `logs/p06.log` |
| p07 | String 字节访问与解析成本 | `src/p07.cj` | `logs/p07.log` |
| p08 | spawn 成本 / 线程上限 / 100k 活线程 | `src/p08.cj` | `logs/p08.log` |
| p09 | std.sync 全原语 / Future 异常传播 / 容器线程安全 | `src/p09.cj` | `logs/p09.log` |
| p10 / p10b | 子线程异常 / 主线程异常 | `src/p10.cj`, `src/p10b.cj` | `logs/p10.log`, `logs/p10b.log` |
| p11 | std.time 精度与成本 | `src/p11.cj` | `logs/p11.log` |
| p12 | crypto digest 有无算法 / base64 | `src/p12.cj` | `logs/p12.log` |
| p13 | std.regex 与路由性能 | `src/p13.cj` | `logs/p13.log` |
| p14 | 静态文件 / sendfile 缺失 / seek | `src/p14.cj` | `logs/p14.log` |
| p15 | HashMap 性能 / 数组线性扫描对比 | `src/p15.cj` | `logs/p15.log` |
| p16 | 并发集合 / 自建线程池 | `src/p16.cj` | `logs/p16.log` |
| p17 | 反复 GC 下裸指针 / 切片保活 / 多线程分区间写 | `src/p17.cj` | `logs/p17.log` |
| p18 | 运行时信息 / atExit / GC 调参 | `src/p18.cj` | `logs/p18.log` |
| p19 | TcpSocket 属性 / writeTimeout / 半关闭缺失 | `src/p19.cj` | `logs/p19.log` |
| p20 | FFI 声明与链接 | `src/p20.cj` | `logs/p20.log` |
| p21 | FFI 自建 socket 端到端 | `src/p21.cj` | `logs/p21.log` |
| p22 | 多线程 accept / 最小 HTTP 吞吐 | `src/p22.cj` | `logs/p22.log` |
| p23 | 压缩/base64/ObjectPool 可用性 | `src/p23.cj` | `logs/p23.log` |
| p24 | 小对象 GC 移动 + acquire 开销 | `src/p24.cj` | `logs/p24.log` |
| p25 | 三种字节扫描方式公平对比 | `src/p25.cj` | `logs/p25.log` |
| p26 | 10k 并发连接内存/线程/稳定性 | `src/p26.cj` | `logs/p26.log` |
| p27 | 对端 close 时阻塞 read 的返回 | `src/p27.cj` | `logs/p27.log` |

辅助脚本：
- `probe.sh <case>`：编译 + 运行单个探针，日志写 `logs/<case>.log`；编译失败诊断写 `logs/_build.err`（ANSI 已剥离）
- `neg.sh`：负向编译验证（确认某个 API「不存在」），结果写 `logs/negative/<name>.txt`

复现：
```shell
cd /home/ystyle/Projects/Cangjie/.scratch/probe-std
eval "$(cjvs env zsh)"
./probe.sh p04      # 单个
./probe.sh all      # 顺序全部
./neg.sh            # 负向验证
```

> 注：所有数字都是本机（16 核）单次运行的实测值，跨机器/负载会有波动；量级结论稳定，精确数字仅供参照。
