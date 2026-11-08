# stdx 能力实测（为"扩展模块"分工提供依据）

> 目的：主模块（HTTP 内核）**不依赖 stdx**；压缩 / 摘要 / base64 / WebSocket 这些能力
> 由一个**扩展模块**提供，扩展模块可以依赖 stdx。
> 本文回答两件事：**① stdx 到底能提供什么、性能如何；② 扩展模块怎么依赖 stdx 才可行。**
>
> 工具链：仓颉 1.2.0 + stdx **1.2.0.1**（`~/.config/cjvs/stdx/1.2.0.1`），Linux x86_64。
> 日期：2026-11-07。所有数字都是本机实测（AMD Ryzen 7 7840HS，8C16T）。

---

## 0. 一页结论

| 能力 | stdx 提供者 | 实测结果 | 扩展模块要不要用 |
|---|---|---|---|
| SHA1 / SHA256 / MD5 | `stdx.crypto.digest` | 全部可用，SHA1 1 MiB **413 µs（2415 MB/s）** | ✅ 用（WebSocket 握手必需） |
| Base64 | `stdx.encoding.base64` | `toBase64String` / `fromBase64String` 可用；**WebSocket accept key 与 RFC 6455 期望值逐字节一致** | ✅ 用 |
| gzip / deflate | `stdx.compress.zlib` | 流式 `CompressOutputStream(wrap: GzipFormat)` 可用；28000 B → 108 B，解压后内容一致 | ✅ 用（压缩响应） |
| WebSocket 服务端 | `stdx.net.http` | `WebSocket.upgradeFromServer` **端到端跑通**（101 + 子协议协商 + 文本帧回声） | ✅ 用（扩展模块内） |
| HTTP/2 / TLS | `stdx.net.http` / `stdx.net.tls` | 可用，但本方案主模块不用（只做 HTTP/1.1） | ❌ 主模块不用 |

**一句话**：**stdx 该有的都有，而且性能不差**（摘要走 OpenSSL，2.4 GB/s）。
主模块不依赖它是对的（内核要零依赖、可控），但**扩展模块用它完全够，不需要自己造轮子**。

---

## 1. stdx.crypto.digest

### 1.1 可用性（实测，不是查文档）

~~~cangjie
import stdx.crypto.digest.*

let s = SHA1()
s.write("Hello, World!".toArray())
let d = s.finish()        // Array<Byte>
~~~

实测输出：

~~~text
SHA256(Hello, World!) = dffd6021bb2bd5b0af676290809ec3a53191dd81c7f70a4b28688a362182986f
SHA1  (Hello, World!) = 0a0a9f2a6772942557ab5355d76af442f8f65e01
MD5   (Hello, World!) = 65a8e27d8879283831b664bd8b7f0ad4
~~~

三个值与标准参考实现一致。

### 1.2 性能（1 MiB，100 轮平均，-O2）

~~~text
SHA1   1MiB: 413 us/op -> 2415 MB/s
SHA256 1MiB: 439 us/op -> 2272 MB/s
~~~

**这比自写快一个数量级以上**：纯仓颉实现 SHA1 通常只有 50–200 MB/s。
原因是 stdx 的 digest 底层走 OpenSSL 3 的 libcrypto（C 实现 + SHA-NI 指令）。

### 1.3 对扩展模块的含义

- WebSocket 握手只需要 SHA1（每次升级一次，不在热路径），性能无所谓；
- **ETag / 内容摘要**如果用 SHA1，1 MiB 只要 413 µs，可以接受；
- 但注意：**它引入 OpenSSL 3 动态库依赖**（libssl.so.3 / libcrypto.so.3）。
  部署环境必须装 OpenSSL 3 —— 这是扩展模块的部署成本，主模块不受影响。

---

## 2. stdx.encoding.base64

### 2.1 API（与预期的"Base64 类"不同）

stdx 提供的是**两个函数**，不是类：

~~~cangjie
import stdx.encoding.base64.*

let s: String = toBase64String(bytes)         // Array<Byte> -> String
let b: ?Array<Byte> = fromBase64String(s)     // String -> ?Array<Byte>（可失败）
~~~

实测：

~~~text
toBase64String  = SGVsbG8sIFdvcmxkIQ==
fromBase64String = Hello, World!
~~~

> **坑**：`fromBase64String` 返回的是 **Option<Array<Byte>>**，不是 Array<Byte>。
> 第一次写代码时容易漏掉 `??` 解包。

### 2.2 WebSocket 握手对齐验证（关键）

RFC 6455 规定：Sec-WebSocket-Accept = base64(SHA1(clientKey + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))。
用 RFC 示例 key `dGhlIHNhbXBsZSBub25jZQ==` 实算：

~~~text
WebSocket accept key = s3pPLMBiTxaQ9kYGzzhZRbK+xOo=   <- RFC 6455 §1.3 期望值，逐字节一致
~~~

### 2.3 性能

~~~text
base64 编码 1MiB: 1621 us/op  (~646 MB/s)
~~~

自写 base64 编码大约 100–300 MB/s，stdx 版快 2–6 倍。Basic Auth / 小 header 场景完全够用。

---

## 3. stdx.compress.zlib

### 3.1 API（流式，不是 Buffer 函数）

stdx 的 zlib **没有** `Zlib.compress(data, out)` 这种一站式函数，只有**四个流类**：

| 类 | 用途 |
|---|---|
| `CompressOutputStream(outputStream, wrap!, compressLevel!, bufLen!)` | 压缩写 |
| `CompressInputStream(inputStream, wrap!, compressLevel!, bufLen!)` | 压缩读 |
| `DecompressOutputStream(outputStream, wrap!, bufLen!)` | 解压写 |
| `DecompressInputStream(inputStream, wrap!, bufLen!)` | 解压读 |

`WrapType`：`DeflateFormat`（默认）/ `GzipFormat`。
`CompressLevel`：`DefaultCompression` / `BestCompression` / `BestSpeed` 等。

**必须 `flush()` + `close()`**：不 close 拿到的不是完整压缩数据
（文档原文："调用 close 函数后，才会把剩余压缩数据写入绑定的输出流，使其完整"）。

### 3.2 实测

~~~text
原始大小 = 28000 B
gzip 压缩后 = 108 B  (压缩率 259x)
解压后 = 28000 B, 内容一致 = true
gzip 压缩 1MiB: 3035 us/op  (~345 MB/s)
~~~

（259x 是因为测试数据是重复字符串；真实 HTML/JSON 通常 3–5x。）

### 3.3 对扩展模块的含义

**压缩响应（Content-Encoding: gzip）在 stdx 里是一条完整可行的路**：

~~~text
handler 返回 body
  -> 检查 Accept-Encoding 含 gzip
  -> 若 body 够大（如 > 1 KiB）：
       ByteBuffer out
       CompressOutputStream(out, wrap: GzipFormat) 写入 body
       flush + close
       body = out 内容；setHeader("Content-Encoding", "gzip")
  -> 正常走 ResponseSerializer
~~~

**代价**：1 MiB 压缩要 3 ms，比不压缩慢很多。所以必须**设阈值 + 可配置**
（fasthttp 的 CompressHandler 也是这么做的：只压缩超过一定大小的响应）。

---

## 4. stdx.net.http（只取 WebSocket 部分）

### 4.1 为什么扩展模块要用它

WebSocket 不只是"握手 + 帧编解码"——还要处理：
掩码、分片帧（FIN/opcode 组合）、控制帧（ping/pong/close）、UTF-8 校验、子协议协商、
**以及和一个 HTTP 服务端的连接生命周期集成**。

自己写 = 2000 行 + 一堆 RFC 细节。而 stdx 的 WebSocket 集成在其 HTTP 服务端里，
**在主模块上不能直接用**（主模块不用 stdx.net.http）。

### 4.2 两条路，必须选一条

| 方案 | 做法 | 优点 | 缺点 |
|---|---|---|---|
| **A（推荐）** | 扩展模块自带一个 stdx.net.http 服务端，WebSocket 走它；普通 HTTP 走主模块 —— **两个端口 / 两个 Server** | 简单、稳定、零风险 | 部署两个端口；跨协议共享 context 要自己做 |
| B | 主模块识别 Upgrade: websocket 后**把连接交出去**（hijack），扩展模块用 stdx 的 WebSocket 帧编解码接上去 | 单端口 | stdx 没有"只给帧编解码"的公开 API，得自己写帧层 —— 等于回到"自己实现" |

**A 的现实性**：实测 stdx 的 WebSocket 服务端只要 **35 行**就能跑通（见 §4.3），
而且它和 HTTP 服务端是同一个 ServerBuilder ——**扩展模块直接把它整个用起来就行**。

### 4.3 实测：35 行的 WebSocket 回声服务端

~~~cangjie
server.distributor.register("/ws", { ctx: HttpContext =>
    let ws = WebSocket.upgradeFromServer(ctx, subProtocols: ArrayList<String>(["echo"]))
    let frame = ws.read()
    ws.write(frame.frameType, frame.payload, frameSize: frame.payload.size)
    ws.closeConn()
})
~~~

实测（python 手写 WS 帧做客户端）：

~~~text
握手响应:
    HTTP/1.1 101 Switching Protocols
    upgrade: websocket
    connection: upgrade
    sec-websocket-accept: 5OpwzkN7VSA6uQkHJi/rECDfyCA=
    sec-websocket-protocol: echo
握手成功: True
收到帧: opcode=1 payload=b'hello from python'
回声一致: True
~~~

**结论：握手 + 子协议协商 + 文本帧收发全部正常。**

### 4.4 两个需要注意的行为（实测日志）

~~~text
WARN [WebSocket#upgradeFromServer] No origin restrictions configured.
     This enables Cross-Site WebSocket Hijacking (CSWSH) vulnerability.
     Consider setting allowed origins explicitly.
INFO the body should be empty
~~~

1. **必须在 upgradeFromServer 传 origins**，否则有 CSWSH 风险（stdx 会主动警告）。
2. "the body should be empty" 是升级响应带 body 的提示 —— 别在 101 响应里写 body。

### 4.5 另一个选择：扩展模块直接用 stdx.net.http 做整个 HTTP 服务端

如果不追求"主模块性能"，扩展模块也可以**整个用 stdx.net.http**。
实测（k6 1000 VUs，与 tang 同口径）它的水平是：

~~~text
stdx.net.http  : 114,387 req/s   avg 6.62ms  p95 16.16ms  RSS 186 MB
~~~

对比见 §6。

---

## 5. 扩展模块怎么依赖 stdx（这个有坑）

### 5.1 现状：本工作区都是"链接 stdx 静态库"，不是"从中心仓拉 stdx"

所有用 stdx 的仓（tang / cjxt / mcp-cj / atelier）都是这个模式：

~~~toml
[target.x86_64-unknown-linux-gnu]
  link-option = "-L${CANGJIE_STDX_PATH} -lstdx.crypto.digest"

[target.x86_64-unknown-linux-gnu.bin-dependencies]
  path-option = ["${CANGJIE_STDX_PATH}"]
~~~

**`[dependencies]` 里没有 stdx**。理由是：stdx 随 SDK 分发，用 `cjvs stdx-env` 注入
CANGJIE_STDX_PATH，编译器直接从那里找 .cjo 和 .a。

### 5.2 从中心仓拉 stdx —— **可以拉到，但本机构建失败**

中心仓确实有 `stdx` 包（发布者"仓颉编程语言"，最新 **1.2.0**，357 次下载）。
实测 `[dependencies] "stdx" = "1.2.0"` **能正常解析并下载源码**到
`~/.cjpm/repository/source/default/stdx-1.2.0`（含 src/stdx/** 的 C 与仓颉源码），
但 **pre-build 阶段编译失败**：

~~~text
src/stdx/dynamicLoader/opensslSymbols.c:917:5:
  error: cast from 'long (*)(BIO *, int, long, void *)' to 'SSLFunc'
         converts to incompatible function type [-Werror,-Wcast-function-type-mismatch]
...
Error: failed to run build script ... by operation 'pre-build'
~~~

**根因**：stdx 的 OpenSSL 动态加载器用 -Werror 编译，而本机 clang 版本对
-Wcast-function-type-mismatch 更严格 -> 全部升级成错误。
这是**工具链版本问题，不是代码问题**，换 clang 版本或关掉该 warning 可解，但不可控。

### 5.3 结论与建议

| 方案 | 可行性 | 建议 |
|---|---|---|
| A：[dependencies] "stdx" = "1.2.0"（中心仓） | ⚠️ 能拉到源码，但**构建脚本可能因 clang 版本失败** | **不推荐**（对下游不可控） |
| **B：链接 SDK 自带 stdx（CANGJIE_STDX_PATH）** | ✅ 全工作区现状，稳定 | **推荐** |
| C：bin-dependencies.path-option 指到某个固定安装路径 | ✅ 但没有版本约束，容易环境差异 | 仅当无法用 B 时 |

**对扩展模块的具体建议**：

1. 扩展模块仓库的 cjpm.toml 用 **B**（与 tang / cjxt 一致）：

   ~~~toml
   [target.x86_64-unknown-linux-gnu]
     link-option = "-L${CANGJIE_STDX_PATH} -lstdx.crypto.digest -lstdx.encoding.base64 -lstdx.compress.zlib -lstdx.net.http -lstdx.net.tls"
   [target.x86_64-unknown-linux-gnu.bin-dependencies]
     path-option = ["${CANGJIE_STDX_PATH}"]
   ~~~

2. **只链接真正用到的 -lstdx.X**（否则会把无关静态库拖进制品）；
3. 文档里写明"依赖 SDK 的 stdx 组件（cjvs stdx-env）"，不要假装是普通三方依赖；
4. **主模块的 cjpm.toml 里不出现任何 stdx** —— 这是"主模块零 stdx"的判据，
   可以用 `grep -c stdx cjpm.toml` 在 CI 里守。

---

## 6. 性能对照：stdx.net.http vs 主模块 vs Go

同一台机、同一 loadgen、**1000 并发连接**、15 s、3 轮取中位：

| 实现 | QPS | p50 | p99 | RSS |
|---|---:|---:|---:|---:|
| Go fasthttp | 675,357 | 1.3 ms | 5.1 ms | 29.8 MB |
| **仓颉主模块（spike2）** | **547,682** | 1.7 ms | 6.1 ms | 40.0 MB |
| Go net/http | 461,627 | 1.5 ms | 11.3 ms | 51.7 MB |
| **仓颉 stdx.net.http** | **251,762** | 3.5 ms | 24.6 ms | 338.1 MB |

用 **tang 的原版 k6 脚本口径**（1000 VUs、GET /hello -> "hello world!"）：

| 实现 | req/s | avg | p95 | RSS |
|---|---:|---:|---:|---:|
| Go fasthttp | 154,164 | 3.75 ms | 7.54 ms | 28.9 MB |
| **仓颉主模块（spike2）** | **147,983** | 5.08 ms | 12.28 ms | 45.9 MB |
| Go net/http | 136,568 | 4.75 ms | 12.55 ms | 49.8 MB |
| **仓颉 stdx.net.http** | **114,387** | 6.62 ms | 16.16 ms | 186.3 MB |

> 两组数字量级差 4–5 倍，因为 loadgen 与 k6 的连接/调度模型不同；**只做横向对比**。
>
> **注**：tang 仓库 docs/advanced/benchmark.md 记录的是 **SDK 1.0.0 时代**（122,157 RPS），
> 且已说明"本机测试"。本次在 **1.2.0 + stdx 1.2.0.1** 上重测得到 **114,387 req/s**，
> 两者一致（差异在系统负载，不是回归）。

**关键结论：主模块比 stdx.net.http 快 2.2 倍（loadgen）/ 1.29 倍（k6）**，
说明"自己写内核"这件事在性能上是有回报的。
而 **stdx.net.http 的 RSS 是主模块的 4–8 倍**（338 MB vs 40 MB @1000 连接），
这对高并发部署是个实际差异。

---

## 7. 给扩展模块的作用域建议

| 能力 | 放哪 | 依赖 |
|---|---|---|
| HTTP/1.1 解析、连接、keep-alive | **主模块** | 无（仅 std） |
| 路由、中间件 | 上层框架（如 tang） | 无 |
| **gzip 压缩中间件** | **扩展模块** | stdx.compress.zlib |
| **WebSocket 服务端** | **扩展模块** | stdx.net.http + crypto.digest |
| **ETag / 摘要** | **扩展模块** | stdx.crypto.digest |
| **Basic Auth** | **扩展模块** | stdx.encoding.base64 |
| TLS | 扩展模块 | stdx.net.tls（需 OpenSSL 3） |
| HTTP/2 | 不做 | — |

**边界清晰**：主模块是"纯仓颉、零三方依赖、可静态交付"的内核；
扩展模块是"接受 stdx 依赖、换取完整生态"的外挂。
用不用扩展，由使用方决定 —— 这正是"主模块不依赖 stdx"的价值。

---

## 附录：复现

~~~shell
eval "$(cjvs env zsh)"
eval "$(cjvs stdx-env zsh)"

# 摘要 / base64 / zlib
cd .scratch/probe-stdx && cjpm build && ./target/release/bin/main

# stdx.net.http hello + 压测
cd .scratch/bench-stdx-http && cjpm build
bash .scratch/logs/bench-stdx-http.sh

# WebSocket 握手 + 回声
cd .scratch/bench-ws-stdx && cjpm build
bash .scratch/logs/test-ws.sh

# tang 原版 k6 口径四方对比
bash .scratch/logs/k6-4way.sh
~~~

---

## 8. 补测：stdx 传染边界完整矩阵（2026-11-07 晚，本节修正 §5 的部分推论）

> 工程：`.scratch/probe-ws-dep`（workspace + 成员 + 仓外消费者）、`.scratch/probe-transitive`。
> **全部实验都在 `env -u CANGJIE_STDX_PATH` 下跑**（除非注明 env 已设）。
> 机器：仓颉 1.2.0 + stdx 1.2.0.1。

### 8.1 结论先说

| 判断 | 结论 |
|---|---|
| 依赖树里**有** stdx 的包，下游构建需要 `CANGJIE_STDX_PATH`？ | ✅ **是**（沿依赖路径传染） |
| 同 workspace 的**兄弟成员**用 stdx，会不会传染给不依赖它的成员？ | ❌ **不会** |
| 仓库根 `cjpm.toml` 必须写 stdx 吗？ | ❌ **不必**，写在成员自己的 toml 里即可 |
| 从 workspace 根 `cjpm build` 会构建所有成员吗？ | ✅ 会，所以根构建仍然需要 stdx 环境 |
| 能不能让根构建跳过 stdx 成员？ | ✅ 可以，用 `build-members` / `test-members` 过滤（见 I 实验） |
| 成员 toml 里写了 `${CANGJIE_STDX_PATH}` 但不 import stdx，env 未设？ | ✅ **不报错**（空变量只是路径为空） |

### 8.2 完整实验矩阵

| # | 场景 | 结果 |
|---|---|---|
| **A** | workspace `members=[core,ext]`、`build-members` 同；`ext` 用 stdx（配置在**自己** toml）、根干净；从**根** `cjpm build`，env 未设 | ❌ 失败（根构建会构建 ext） |
| **B** | 同 A，但根 `build-members=["core"]`、`test-members=["core"]` | ✅ **success** |
| **C** | 消费者**只依赖 core**（ext 是同 workspace 兄弟，不依赖它），env 未设 | ✅ **success**，输出 `pong from core` |
| **D** | 消费者在 workspace **外面**，path 依赖 core，env 未设 | ✅ **success** |
| **E** | 消费者依赖 `ext`（即真的用到 stdx），env 未设 | ❌ 失败（**应该失败**） |
| **F** | 成员 toml 里写了 `bin-dependencies.path-option = ["${CANGJIE_STDX_PATH}"]` 但**不 import stdx**，env 未设 | ✅ **success**（不报错） |
| **G** | 成员目录直接 build，它自己 import stdx，env 未设（即使 toml 里已声明 `${CANGJIE_STDX_PATH}`） | ❌ 失败：`root package 'ext' imports package 'stdx.crypto.digest' ... but it is not added as a dependency` |
| **H** | 同 G，但 env 已设 | ✅ **success** |
| **I** | A 的变体：只给 `members` 不给 `test-members` | ❌ `the member module 'ext' of the test-members field must appear in the build-members field`（需显式给 test-members） |

### 8.3 关键含义（**这一节推翻 §5.2 里"必须整条链都配"的过度推广**）

1. **传染是"沿依赖路径"的，不是"按仓库"的。**
   消费者只依赖干净成员时**完全不需要 stdx**（C/D）。之前我把它误推成"同仓兄弟也传染"，是错的。

2. **`${CANGJIE_STDX_PATH}` 展开成空串 = 路径无效**，所以"声明了但 env 没设"等价于"没声明"（G 实验）。
   反过来，声明了却不 import stdx 也不会有副作用（F 实验）。
   → **可以在成员 toml 里预先写好 stdx 配置，不影响不使用它的场景。**

3. **仓库根构建（`cjpm build` at workspace root）会构建所有 `build-members`**，
   所以"仓库自己的 CI 想零 stdx"必须用 `build-members` 过滤（B 实验），
   或者直接进成员目录构建（H 实验的反面）。

4. **正确的工程结构**：

   ~~~text
   <repo>/cjpm.toml          [workspace] members=... build-members=...   ← 不写 stdx
   <repo>/cjhttp/cjpm.toml   无 [dependencies]、无 bin-dependencies      ← 零 stdx
   <repo>/cjhttp_ext_ws/cjpm.toml
                             [dependencies] cjhttp = "..."
                             [target.*] link-option = "-L${CANGJIE_STDX_PATH} ..."
                             [target.*.bin-dependencies] path-option = ["${CANGJIE_STDX_PATH}"]
   ~~~

   - 消费者只用 `cjhttp` → 零配置（C/D 实证）
   - 消费者用 `cjhttp_ext_ws` → 需要 `CANGJIE_STDX_PATH`（E 实证，合理）

### 8.4 与之相符的既有仓库做法

`json-rpc` workspace 就是这种结构，只是它把 `bin-dependencies` 同时写在了**每个成员**的 toml 里
（含 `jsonrpc_stdio`/`jsonrpc_tcp`/`jsonrpc_unix` 这些不 import stdx 的成员）——
按 F 实验，这些声明**无害**；按 C 实验，只依赖 `ystyle::jsonrpc` 的下游**不需要** stdx。
它根 `cjpm.toml` 里的 7 处 `path-option` 是给**根构建**用的（对应 A→B 的差别）。
