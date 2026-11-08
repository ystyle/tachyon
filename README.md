# tachyon

**A fasthttp-style zero-allocation HTTP/1.1 server for Cangjie.**
Design ported from Go's [`valyala/fasthttp`](https://github.com/valyala/fasthttp). **Std-only, no stdx, no HTTP/2.**

> [`ystyle::tachyon`](https://pkg.cangjie-lang.cn) · MulanPSL-2.0

---

## 为什么是 tachyon

| | tachyon | Go fasthttp | stdx.net.http |
|---|---|---|---|
| 依赖 | **仅 `std.*`** | Go 标准库 + 3 个三方包 | stdx（+ OpenSSL 3） |
| 协议 | HTTP/1.1 | HTTP/1.1 | HTTP/1.1 + HTTP/2 + WS |
| 设计取向 | 零分配内核 | 零分配内核 | 通用 HTTP 栈 |
| Handler | `(RequestCtx) -> Unit` | `func(*RequestCtx)` | `HttpRequestHandler` 接口 |
| 每请求分配 | **目标 0–1 次** | 0 次 | 未针对性优化 |

**下游零配置**：只依赖 `ystyle::tachyon` 不需要 `${CANGJIE_STDX_PATH}`，也不需要任何三方依赖。

## 快速开始

```toml
[dependencies]
  "ystyle::tachyon" = "0.1.0"

[package]
  cjc-version = "1.2.0"
  compile-option = "-O2 -Woff unused"   # ⚠️ -O2 是必须的，见下
```

```cangjie
import ystyle::tachyon.*

main() {
    let srv = Server({ ctx: RequestCtx =>
        ctx.successString("text/plain", "Hello, World!")
    })
    srv.listenAndServe("0.0.0.0", 8080)
}
```

### ⚠️ 必须开 `-O2`

同一个逐字节扫描循环，不开 `-O2` 是 **75 MB/s**，开了是 **4189 MB/s**（55 倍差距）。
cjpm **默认不开 `-O2`** —— 不写这条，性能设计全部作废。

## 性能

同机（AMD Ryzen 7 7840HS，8C16T）、同压测器、128 长连接、10 s。**两边都是最小 handler**
（只回 `200 + "Hello, World!"`），交替多轮取中位：

| 实现 | QPS | **服务端 CPU/请求** | 稳态 RSS |
|---|---:|---:|---:|
| Go fasthttp | 745,900 | — | 14.6 MB |
| **tachyon** | **562,832 – 595,426** | **12.0 – 12.6 µs** | **31 MB** |
| Go net/http | 412,800 | — | 20.8 MB |
| 仓颉 stdx.net.http | 332,148 – 339,861 | 24.6 – 25.3 µs | 291 – 296 MB |

即 **约 2.0 倍的每请求 CPU 优势、9.5 倍的稳态内存优势**。
压测器与被测服务同机，绝对 QPS 只能同机对比；**CPU/请求**才是跨环境有意义的指标。

> 为什么能比 stdx 快、以及这次对比**没有**证明什么，见
> [`docs/why-faster-than-stdx.md`](docs/why-faster-than-stdx.md)（含源码级对比与复现命令）。

> 加 3 个中间件（requestID + bodyLimit + cors）约损失 **9.6%** QPS，
> 那是每请求多三轮闭包调用 + 三处 header 读写的真实代价，不是退化。

## 设计要点

1. **`Bytes` 零拷贝视图**：`Array<Byte>` 切片是别名（实测 27 ns/次），
   内部全程用 `Bytes{ buf, start, len }`，不构造 `String`。
   `String.fromUtf8` 带 UTF-8 校验（1 MiB ≈ 544 µs），热路径禁用。

2. **每连接一协程**：仓颉 `spawn` 是 **M:N 协程**，不是 OS 线程。
   实测 20000 条阻塞在 `read()` 上的连接只占 **14 个内核线程**，每协程约 **13 KB**。
   → 不需要 worker 池，不需要 event loop。

3. **argsKV 式 header**：`names`/`values` 双平行数组 + `hdrBuf` 拷贝 + 截断复用。
   特殊头（Host/Content-Length/Connection/...）走专用字段，查表 O(1)。

4. **写缓冲空闲区**：`BufferedWriter.availableSlice()` 让 header 直接拼进写缓冲，
   header + body 一次 `write` 发出。

## 不做的事（与 fasthttp 一致）

- **HTTP/2**：fasthttp 至今不支持（README FAQ 原话 "HTTP/2.0 support is in progress"）。
  需要 h2 的场景在**前面挂 LB**（nginx/Caddy/Traefik/云 LB）终结 TLS + h2，后端走 HTTP/1.1。
- **TLS**：需要 `stdx.net.tls`（OpenSSL 3），由 LB 或独立扩展承担。
- **WebSocket / gzip / 摘要**：在独立的扩展包里，主模块零 stdx。

## 状态（按设计文档的阶段）

| 阶段 | 内容 | 状态 |
|---|---|---|
| P0 | `Bytes` / `Buffers` / 扫描原语 / `-O2` 工程骨架 | ✅ |
| P1 | `HeaderTable` + `RequestParser` | ✅（验收标准里的「每请求 0 分配」不可达，见下节） |
| P2 | `ResponseSerializer` + perConnLoop（keep-alive / 超时） | ✅ 56–59 万 QPS（验收 ≥ 40 万） |
| P3 | body（定长 + chunked）/ `ArgsView` / URI 规范化 / Cookie | ✅ 含 CL/TE 走私、`%2e%2e` 等安全用例 |
| P4 | `ObjectPool` / `reduceMemoryUsage` / `maxConnsPerIP` / 优雅关闭 | ✅ 56–59 万 QPS（验收 ≥ 55 万） |
| P5 | 静态文件 / 错误页 / 中间件 | ✅ |

### 细项

- [x] `Bytes` 零拷贝视图
- [x] 固定大小读写缓冲
- [x] argsKV 式 `HeaderTable`
- [x] `Request` 解析（一遍扫描 + 特殊头分流 + 请求走私防护）
- [x] `URIView` 惰性解析 + RFC 3986 路径规范化
- [x] `ArgsView` 惰性解析 + 百分号解码
- [x] `Response` 序列化（fasthttp 顺序）
- [x] `DateCache`
- [x] `Server` 主循环（keep-alive / 超时 / 优雅关闭）
- [x] chunked transfer-encoding
- [x] Cookie（请求解析 + Set-Cookie 序列化）
- [x] 对象池（per-slot 无锁 + 全局兜底）
- [x] 每请求分配约 **48 B**（自身开销；全流程 160 B/req，其中裸 std socket 已占约 112 B）
- [ ] ~~每请求 0 分配~~ —— **在现有 std 上不可达**，见下节「分配实测」
- [x] 静态文件：目录索引 / Range / If-Modified-Since / 路径穿越防护
- [x] 错误页：`Server.errorHandler`（fasthttp `ErrorHandler` 的等价物，返回 true 表示已自行写出）
- [x] 并发上限（Semaphore + 503）
- [x] 全部 Server 配置项生效（getOnly / maxConnsPerIP / readBufferSize / writeTimeout / ...）
- [x] 中间件：access log / recovery / requestID / CORS / bodyLimit（Server.use）
- [x] Hijack（ctx.hijack，把连接交给使用者 —— 第三方实现 WS / CONNECT 的途径）
- [x] SetBodyStream 流式响应（定长 / chunked）
- [x] MultipartForm（multipart/form-data 解析，含文件字段）
- [x] 脱离连接的上下文（`DetachedRequest` / `newDetachedCtx` / `snapshotResponse`）
- [x] **63 个单元测试**

## 分配实测（2026-11-08）

两个口径，都出自 `bench/std-alloc-baseline`（`getAllocatedHeapSize` 差值 / 次数）：

### 逐调用（单看 socket 的 read / write）

| 操作 | 每次分配 |
|---|---:|
| 空循环（对照） | 0 B |
| 普通函数调用（对照） | 0 B |
| `write(1024 B)` | **56 B** |
| `write(80 B)` | **56 B** |
| `write(wide[0..1024])`（切片传入） | **56 B** |
| `read(4096 B)` | **56 B** |

### 端到端

| 被测 | 每请求分配 |
|---|---:|
| 裸 `std.net.TcpSocket`（accept → read → write 固定响应） | **112 B** |
| tachyon 全流程（HTTP 解析 + 响应序列化 + socket 读写） | **160 B** |

→ tachyon 自身的 HTTP 层开销约 **48 B/req**，其余是 socket 的固定成本。

### 结论：为什么「0 分配」做不到

1. **分配在 socket 里，而且是常数**：`read`/`write` 每次调用固定约 56 B，**与载荷大小无关**
   （80 B 与 1024 B 一样），不像"按数据量复制"，更像每次调用建了个临时对象。
2. **不是 API 形状问题**：`Array<Byte>` 的切片（`a[i..j]`）是零拷贝视图，**切片传入与整数组传入
   分配量完全相同**（都是 56 B/call，对照的空循环是 0）。所以「没有 offset/count 重载」并不构成障碍。
3. 因此 tachyon 的硬下限是「每请求 1 读 + 1 写」的固定成本；要再往下，只能靠 std 把
   `TcpSocket.read/write` 的内部分配去掉。

已向上游提交：[Cangjie/UsersForum#3578](https://atomgit.com/Cangjie/UsersForum/issues/3578)。
（对照：Go 的 `net.Conn.Write` 零分配，fasthttp 才能在 128 长连接上做到 745,900 QPS。）

### 复现

`cd bench/std-alloc-baseline && cjpm run` —— 逐调用归因 + 端到端两个口径一次跑完；
tachyon 侧按 handler 粒度拆分用 `cd bench && cjpm run`。

## License

MulanPSL-2.0