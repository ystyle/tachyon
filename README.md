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

同机（AMD Ryzen 7 7840HS，8C16T）、同压测器、128 连接、10 s、3 轮中位：

| 实现 | QPS | p50 | p99 | RSS |
|---|---:|---:|---:|---:|
| Go fasthttp | 745,900 | 137 µs | 605 µs | 14.6 MB |
| **tachyon** | **556,800** | 210 µs | 890 µs | 117 MB |
| Go net/http | 412,800 | 189 µs | 1,518 µs | 20.8 MB |
| 仓颉 stdx.net.http | 251,762 | 3.5 ms | 24.6 ms | 338 MB |

即 **达到 fasthttp 的 75%、net/http 的 135%、stdx.net.http 的 2.2 倍**。
（这是 P0–P2 原型，还没做对象池与 buffer 复用；RSS 偏高是因为每连接独立分配。）

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

## 状态

**P0–P2 原型已可运行**（见 `docs/design.md` 的分阶段计划）：

- [x] `Bytes` 零拷贝视图
- [x] 固定大小读写缓冲
- [x] argsKV 式 `HeaderTable`
- [x] `Request` 解析（一遍扫描 + 特殊头分流 + 请求走私防护）
- [x] `URIView` 惰性解析 + RFC 3986 路径规范化
- [x] `ArgsView` 惰性解析 + 百分号解码
- [x] `Response` 序列化（fasthttp 顺序）
- [x] `DateCache`
- [x] `Server` 主循环（keep-alive / 超时 / 优雅关闭）
- [x] chunked transfer-encoding（P3）
- [x] Cookie（请求解析 + Set-Cookie 序列化）（P3）
- [x] 27 个单元测试
- [x] 对象池（per-slot 无锁 + 全局兜底）（P4）
- [x] 每请求分配降到 **192 B**（从 1016 B 优化而来；fasthttp 是 0）
- [ ] 每请求 0 分配（还差 192 B，主要是 read/write 的切片参数）
- [x] 静态文件（P5）：目录索引 / Range / If-Modified-Since / 路径穿越防护
- [x] 并发上限（Semaphore + 503）
- [x] 全部 Server 配置项生效（getOnly / maxConnsPerIP / readBufferSize / writeTimeout / ...）
- [x] 中间件：access log / recovery / requestID / CORS / bodyLimit（Server.use）
- [x] 44 个单元测试

## License

MulanPSL-2.0
