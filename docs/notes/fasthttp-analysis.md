# fasthttp 服务端实现剖析（Go → 仓颉移植依据）

> 源码：/home/ystyle/Projects/Cangjie/.scratch/ref/fasthttp，master，commit 000816e
> （perf: speed up path normalization, query parsing, header setters and Client.Do (#2513)）。
> 工作副本是 **shallow clone**（.git/shallow 只有这一个 commit），所以本文不做跨版本考古，
> 只对当前快照下结论。所有 file:line 均指该快照。
>
> "实测"结论都来自本机真跑出来的探针，记录见附录 A。
> **凡是我没跑过、只靠读代码推出来的，正文里会写"（读码推断）"。**

---

## 目录

- [1. 请求生命周期全链路](#1-请求生命周期全链路)
- [2. 零分配技巧清单](#2-零分配技巧清单)
- [3. Header 存储细节](#3-header-存储细节)
- [4. URI 与 Args](#4-uri-与-args)
- [5. Cookie](#5-cookie)
- [6. 连接管理](#6-连接管理)
- [7. 并发模型（含 workerpool 到底干什么）](#7-并发模型含-workerpool-到底干什么)
- [8. 错误处理](#8-错误处理)
- [9. 与 net/http 的关键差异](#9-与-nethttp-的关键差异)
- [10. 对仓颉移植的结论](#10-对仓颉移植的结论)
- [附录 A：实测记录](#附录-a实测记录)
- [附录 B：file:line 索引](#附录-bfileline-索引)

---

## 1. 请求生命周期全链路

### 1.1 一张图：从 accept 到 close

~~~text
ListenAndServe(addr)                      server.go:1899  → net.Listen("tcp4", addr) 后 Serve
└─ Serve(ln net.Listener)                 server.go:2109
   ├─ 建 workerPool{WorkerFunc: s.serveConn, MaxWorkersCount: Concurrency}   server.go:2124
   ├─ wp.Start()                          server.go:2133 → workerpool.go:49
   ├─ s.open.Add(1)                       server.go:2140（"正在 accept"也算一个 open）
   └─ for {
        acceptConn(s, ln, ...)            server.go:2256
          ├─ ln.Accept()                  server.go:2259
          └─ MaxConnsPerIP>0 → wrapPerIPConn  server.go:2286 → peripconn.go:66
        s.setState(c, StateNew)           server.go:2149
        s.open.Add(1)                     server.go:2150
        wp.Serve(c)                       server.go:2152 → workerpool.go:148
          └─ getCh()                      workerpool.go:171（复用空闲 worker 或新建）
             └─ ch.ch <- c
                └─ workerFunc(ch) 调 WorkerFunc = s.serveConn   workerpool.go:225
                   └─ serveConn(c)        server.go:2484
                      └─ serveConnCounted(c, true)  server.go:2488
      }

serveConnCounted(c, countConcurrency)     server.go:2488
├─ defer serveConnCleanup                    server.go:2489
├─ getNextProto(c)                          server.go:2493（TLS ALPN 分派；纯 HTTP 返回 ""）
├─ connTime := time.Now()                   server.go:2515
├─ idleConns[c] 记账（5 秒后算 idle）        server.go:2518~2536
├─ ctx := s.acquireCtx(c)                   server.go:2550 → 3276（sync.Pool）
└─ for {                                    server.go:2565
     connRequestNum++                        server.go:2566

     ── ① 等第一个字节（deadline 在这里设） ──
     if connRequestNum == 1 { SetReadDeadline(now+ReadTimeout) }      server.go:2570
     else                   { SetReadDeadline(now+idleTimeout()) }    server.go:2577
     br = acquireReader(ctx)                  server.go:2588 → 3240
     br.Peek(1)                              server.go:2595  ← 阻塞点
       （ReduceMemoryUsage 时改走 acquireByteReader）  server.go:2606 → 3206

     ── ② 读 Header ──
     ctx.Request.Header.Read(br)              server.go:2648
       └─ Header.readLoop(br, true)           header.go:2890
          └─ tryRead(r, n)                   header.go:2906
             └─ parse(buf)                   header.go:3347
                ├─ parseFirstLine            header.go:3535（方法/URI/协议）
                └─ parseHeaders              header.go:3783（特殊头分流 + 校验）
     ⚠ pipelining 优化：上个响应的 bw 里还有未 flush 的数据时，
      先 readLoop(br,false) 试一次，不够再 Flush 再阻塞读。  server.go:2650~2658

     ── ③ 解析 URI（失败 → 400 并断链） ──
     ctx.Request.parseURI()                   server.go:2688 → http.go:1220 → uri.go:299
       err → s.writeErrorResponse(...)        server.go:2689 → 3508

     ── ④ 读 body（有长度上限） ──
     ctx.Request.readLimitBody(br, maxRequestBodySize, GetOnly, preParseMultipart)  server.go:2699
       └─ http.go:1618 → ContinueReadBody      http.go:1678 → ReadBody  http.go:1733
     （StreamRequestBody 时走 readBodyStream   server.go:2697 → http.go:1636）

     ── ⑤ 错误收口 ──
     io.EOF 当正常关；ErrNothingRead 且非首请求当 keep-alive 空闲超时；
     net.ErrClosed 当自己关的；其余 writeErrorResponse + break   server.go:2711~2736

     ── ⑥ Expect: 100-continue ──
     MayContinue()                            server.go:2740 → http.go:1666
       ExpectHandler / ContinueHandler 否决 → 417 + close   server.go:2742~2760
       否则写死常量 "HTTP/1.1 100 Continue\r\n\r\n"           server.go:2770（strings.go:32）
       然后 ContinueReadBody                   server.go:2787

     ── ⑦ 记录请求上下文，调 handler ──
     connectionClose = req.Header.ConnectionClose()    server.go:2806
     isHTTP11 = req.Header.IsHTTP11()                  server.go:2810
     ctx.connID / connRequestNum / ctx.time            server.go:2816~2831
     s.Handler(ctx)                                    server.go:2841   ← 用户代码
       （TimeoutHandler 包装时 handler 在另一 goroutine 跑，见 server.go:520）

     ── ⑧ 结算响应 ──
     HEAD → Response.SkipBody = true          server.go:2875
     Hijack 取走 handler                       server.go:2879
     WriteTimeout → SetWriteDeadline            server.go:2884~2901
     connectionClose |= Response 要求关 | 未读完的流 | CloseOnShutdown   server.go:2905~2908
     connectionClose |= DisableKeepalive | MaxRequestsPerConn 到顶      server.go:2912
     connectionClose → Response.Header.SetConnectionClose()             server.go:2928
     否则 HTTP/1.0 → 补 Connection: keep-alive                          server.go:2933
     HTTP/1.0 → Response.Header.noHTTP11 = true（响应不许用 chunked）    server.go:2938
     writeResponse(ctx, bw)                   server.go:2949 → 3192 → http.go:2550
     flush 条件（有下个请求在 pipeline 里就不 flush）                    server.go:2964
     清理 handler 留下的 deadline 残留          server.go:3022~3045

     ── ⑨ 复位，下一轮 ──
     setState(StateIdle)                      server.go:3052
     ctx.Request.Reset() / ctx.Response.Reset()  server.go:3055~3056（缓冲归还池）
     if s.stop.Load() == 1 { break }           server.go:3063   ← Shutdown
   }

关闭：br/bw 还池、ctx 还池、idleConns 清理   server.go:3068~3092
      真正的 c.Close() 在 ServeConn / workerFunc（谁拥有谁关）
~~~

### 1.2 逐段拆解

**① accept 循环不做业务**。`Serve` 只做三件事：收连接、记账（`s.open`）、丢给 workerPool
（`server.go:2152`）。`wp.Serve` 返回 false（worker 已满）时直接回 503 并关连接
（`server.go:2152-2164`），**不阻塞 accept**。

**② 每连接一次 ctx 分配**。`acquireCtx` 从 `sync.Pool` 取（`server.go:3276`），首次才
`new(RequestCtx)`。一个 `RequestCtx` 里内嵌了 `Request` 和 `Response`（`server.go:649-689`），
所以"每连接一次分配"包含全部 header/body 结构。

**③ 读 body 时机**。默认在 handler 之前读完（`readLimitBody`，`server.go:2699`）。
`StreamRequestBody=true` 时改走 `readBodyStream`（`server.go:2697`），handler 边读边处理，
但**服务端负责把 handler 没读完的 body 抽干**，否则下一个请求会被错位解析
（`server.go:2975-2981`，超过 `maxUnreadStreamBodySize=256KB`（`server.go:2468`）就直接断链）。

**④ handler 之后才决定 keep-alive**。关键顺序：`connectionClose` 在 handler 返回**之后**
才综合判定（`server.go:2905-2913`），所以 handler 里调 `ctx.SetConnectionClose()` 有效，
且响应头是 `writeResponse` 时现生成的，不需要提前占位。

**⑤ 响应写完才 flush**。`writeResponse`（`server.go:3192`）只是 `ctx.Response.write(ctx.c, w)`
（`http.go:2550`），数据落到 `bufio.Writer` 里；是否 flush 由 pipeline 状态决定
（`server.go:2964-2971`）。**没有 pipeline 才 flush**，这是为 TechEmpower 16 请求流水线
特调的（源码注释直说 "this is a big of an ugly optimization"，`server.go:2959-2963`）。

### 1.3 实测响应样本

最小 GET（`GET / HTTP/1.1` + `Host: h`，handler 只 `SetBodyString("ok")`）：

~~~text
HTTP/1.1 200 OK
Server: fasthttp
Date: Sat, 07 Nov 2026 12:32:40 GMT
Content-Type: text/plain; charset=utf-8
Content-Length: 2

ok
~~~

handler 什么都不设（空 body）：

~~~text
HTTP/1.1 200 OK / Server: fasthttp / Date: ... / Content-Length: 0
（没有 Content-Type！）
~~~

注意：**`Content-Type` 只在"有 body"时补默认值**，条件在 `header.go:3143`：
`len(h.contentType) > 0 || (h.ContentLength() != 0 && !h.mustSkipBody())`。
所以空 body 响应没有 Content-Type。这一点很容易在移植时写成"永远补"。

---

## 2. 零分配技巧清单

### 2.1 总表

| # | 技巧 | Go 靠什么 | 换语言还成不成立 |
|---|---|---|---|
| 1 | 每连接一大 buffer，池化复用 | `sync.Pool` 复用 `*bufio.Reader/Writer`，尺寸 = `ReadBufferSize/WriteBufferSize`（默认 4096） | **半成立**：池要自己写（无 GC 池），buffer 本身语言无关 |
| 2 | Header 不解析成 map/string | `[]argsKV`，key/value 是**各自独立的 []byte**，按需 `append(x[:0], ...)` 复用 | **成立**（仓颉 `ArrayList` + 切片别名也能做，见 §10） |
| 3 | Request/Response 每连接只分配一次 | ctx 池 + `Reset()` 只截断切片不还内存 | **成立**，但"池"要手写 |
| 4 | Args/URI 惰性解析 | `parsedURI`/`parsedPostArgs`/`parsedQueryArgs` 布尔位，不调用就不解析 | **完全成立**（纯算法） |
| 5 | `[]byte` ↔ `string` 零拷贝 | `unsafe.String` / `unsafe.Slice`（`b2s.go:7`、`s2b.go:6`） | **仓颉做不到**，见 §10.3 |
| 6 | 少用反射/接口 | handler 是 `func(*RequestCtx)` 而非 interface（`server.go:143`） | **完全成立** |
| 7 | Date 头缓存 | 后台 goroutine 每秒刷一次，存 `atomic.Pointer[[]byte]` | **完全成立**（`std.sync` 有 AtomicReference） |
| 8 | 直接往 bufio 的**空闲区**拼 header | `w.AvailableBuffer()` + `AppendBytes`（`header.go:3045`） | **要自己写 buffered writer** |
| 9 | header+body 一次 writev | `net.Buffers`（`http.go:2594`） | **做不到**，见 §10.3 |
| 10 | body 缓冲池 | `bytebufferpool`（第三方），`requestBodyPool`/`responseBodyPool`（`http.go:589-592`） | 同 #1 |
| 11 | SWAR 8 字节并行扫字节 | `encoding/binary` 读 uint64 + 位运算（`swar.go:18-60`） | **成立**，但有代价（§10.2） |
| 12 | 常量字节切片预置 | `strings.go:25-60` 一堆 `[]byte(...)` 包级变量 | **成立** |
| 13 | 状态码文本表 | `status.go` 的 `statusMessages` | **成立** |
| 14 | `noCopy` 结构体 | 空方法集骗 `go vet`（`nocopy.go:8`） | **不适用** |

**实测**：`ServeConn` 端到端 `testing.AllocsPerRun = 0.0`（`allocation_test.go:10` 的用例，
我自己跑也是 0.0，附录 A-1）。

### 2.2 逐条：Go 靠什么 / 换语言还成不成立

#### (1) buffer 复用 —— 注意：**它其实用了 bufio**

任务描述里说"bufio 替换"，但**当前快照恰恰是用 bufio 的**：
`acquireReader` → `bufio.NewReaderSize(ctx.c, n)`（`server.go:3240-3252`），
`acquireWriter` → `bufio.NewWriterSize`（`server.go:3258-3270`）。
省分配靠的是 **`sync.Pool` 复用这两个对象**（`readerPool`/`writerPool`，`server.go:163-166`），
不是"绕过 bufio 直接 syscall"。

真正的"绕过"在 `ReduceMemoryUsage=true` 时：`acquireByteReader`（`server.go:3206`）先
**把 ctx 还池**、然后**直接对 `c.Read` 读 1 个字节**（`server.go:3218`），拿到首字节后才重新取 ctx、
把首字节塞进 `firstByteReader`（`server.go:1088-1110`）再包一层 bufio。目的写在注释里：
"Make GC happy, so it could garbage collect ctx while we wait for the next request"（`server.go:3213`）。
即**空闲 keep-alive 连接不占 ctx、不占 buffer**。

> 实测：5000 条 keep-alive 连接，`ReduceMemoryUsage=false` 每连接堆增 ≈ 11597 B；
> `=true` 时堆增量测不出（buffer 全还池了）。见附录 A-8。

#### (2) Header 不做 map

`type header struct { h []argsKV; ... }`（`header.go:21-47`），
`type argsKV struct { key, value []byte; noValue bool }`（`args.go:52-56`）。

要点（**这是移植时最容易做错的地方**）：

- **不是**"所有 key/value 塞进一块大 buffer、彼此用偏移量引用"。实测每个 key/value 是
  **独立的切片**，各有自己的 cap：`key="Host" cap=4 value cap=8`、`key="B" cap=8`……
  （附录 A-4）。共享的只有 `h` 这个 `[]argsKV` 数组本身（`allocArg` 复用，`args.go:509-521`）。
- 解析时 key/value 是**从 bufio 缓冲里 append 复制出来的**，不是指向读缓冲。
  实测：解析后把 bufio 内部缓冲全改成 `'Q'`，`Host()` 仍是 `"example.com"`（附录 A-5）。
  这也解释了为什么 header 大也不怕 bufio 被下次读覆盖。
- 特殊头**不进 `h`**，各占一个字段：`host/userAgent/contentType/method/requestURI/protocol`
  （`RequestHeader`，`header.go:103-121`）、`contentType/contentEncoding/server/statusMessage`
  （`ResponseHeader`，`header.go:76-95`）、`contentLengthBytes`、`cookies`、`trailerH`。
- `bufK`/`bufV` 是"查表/写表时的临时 key/value 缓冲"（`header.go:26-27`），
  用来给 `Peek("x") string→[]byte` 做零分配转换，**不是存储**。

**换语言后**：纯数据结构设计，**成立**。仓颉里用 `ArrayList<(Array<Byte>, Array<Byte>)>`
或两个平行数组都行；关键是要能"原地截断复用"。仓颉 `ArrayList` 的 `clear()`/`reserve()` 可以，
切片别名也验证过（附录 A-9）。

#### (3) Request/Response 每连接复用

`ctx := s.acquireCtx(c)` 一次（`server.go:2550`），循环末尾
`ctx.Request.Reset(); ctx.Response.Reset()`（`server.go:3055-3056`）。

`Reset` 的语义是"**截断但保留底层容量**"：`h.h = h.h[:0]`（`header.go:1479-1503`）；
body 缓冲特殊处理——`!KeepBodyBuffer` 时把 `*bytebufferpool.ByteBuffer` **还池**
（`http.go:1503-1513`、`http.go:1542-1555`），否则 body 会越滚越大。

**换语言后**：`Reset` 语义成立；"还池"要有自己的 free list。

#### (4) 惰性解析

三个布尔位，各自带缓存：

| 对象 | 布尔位 | 位置 |
|---|---|---|
| URI | `parsedURI` / `uriParseErr` | `http.go:65-67`，`parseURI` `http.go:1220-1229` |
| POST args | `parsedPostArgs` | `http.go:1236-1246` |
| URI query args | `parsedQueryArgs` | `uri.go:1070-1076` |

注意 `parsedURI` 会缓存 **error**（`uriParseErr`），失败也记下来。

另外还有"**host 备忘录**"：`URI.parse` 里如果 `host` 与上次的 `hostRaw` 相同
（keep-alive 常见情况），直接复用 `hostParsed`，跳过 `parseHost` 校验
（`uri.go:305-315`，存储 `uri.go:60-63`，上限 `maxMemoizedHostLen=256` 见 `uri.go:285`）。

"origin-form 根路径 + 同 Host"还有个全走快路径的分支（`uri.go:307-315`），
这是 keep-alive 流量的稳态。

**换语言后**：**完全成立**，纯状态机。

#### (5) `[]byte` ↔ `string` 零拷贝 —— 仓颉做不到

~~~go
// b2s.go:7
func b2s(b []byte) string { return unsafe.String(unsafe.SliceData(b), len(b)) }
// s2b.go:6
func s2b(s string) []byte { return unsafe.Slice(unsafe.StringData(s), len(s)) }
~~~

用途：所有 `Peek(key string) []byte` 内部转 key（`header.go:2439-2456`）、
`args.go` 里所有字符串比较。

**代价必须说清楚**：这是**真 unsafe**——返回的 string/[]byte 与原对象共享内存，
调用方写它就会破坏原对象（`s2b` 尤其危险，Go 的 string 常量可能在只读段）。
这也是 Readme 里专门有 "zero-allocation helpers" 章节的原因（`README.md:482-512`）。

**仓颉**：`String` 不可变，标准库**没有**把 `Array<Byte>` reinterpret 成 `String` 的 API；
能查到的只有 `acquireArrayRawData<T>(Array<T>): CPointerHandle<T> where T <: CType`
（`libs_std/core_core_package_funcs_func_acquireArrayRawData_T_Array_T_where_T_CType_1`），
文档明确写"获取和释放之间仅可包含简单的 foreign C 函数调用，不构造仓颉对象"。
所以**只能全程用 `Array<Byte>`，最后一次性 `String.fromUtf8`**（实测 1MB ≈ 0.87ms，附录 A-10）。

#### (6) 少反射少接口

handler 是 `type RequestHandler func(ctx *RequestCtx)`（`server.go:143`），
不是 `interface{ ServeHTTP(...) }`。整个热路径没有 `reflect`、没有 map 查找
（`peek` 里的 `switch string(key)` 是**编译期字符串比较**，`header.go:2496-2556`）。

**仓颉**：函数类型/闭包都有，成立。

#### (7) Date 头缓存 —— 注意 `coarsetime.go` 已废弃

~~~go
// coarsetime.go:11
// Deprecated: This is slower than calling time.Now() directly.
func CoarseTimeNow() time.Time { return time.Now().Truncate(time.Second) }
~~~

真正的缓存在 `header.go:3001-3035`：

~~~text
updateServerDate()          header.go:3001   // 只跑一次（sync.Once），起一个 goroutine
  └─ for { time.Sleep(time.Second); refreshServerDate() }
refreshServerDate()         header.go:3017   // 格式化 + 存 atomic.Pointer[[]byte] + 存 Unix 秒
serverDateLineFor(now)      header.go:3025   // "Date: <RFC1123>\r\n"
coarseSecond()              header.go:3032   // 供 LazyRequestTime 用
~~~

序列化时直接 `dst = append(dst, *serverDateLine.Load()...)`（`header.go:3132-3135`），
**零格式化、零分配**。实测间隔 1.1s 的两次请求 Date 行随之变化（附录 A-11）。

**仓颉**：后台线程 + `AtomicReference<Array<Byte>>`（`std.sync` 有），**成立**。

#### (8) 直接写进 bufio 的空闲区

~~~go
// header.go:3045
func (h *ResponseHeader) serialize(w *bufio.Writer) []byte {
	if w.Available() < cap(h.bufV) { return h.Header() }   // 装不下 → 用自有缓冲
	buf := h.AppendBytes(w.AvailableBuffer())              // 直接拼在 writer 的空闲区
	if cap(buf) != w.Available() { h.bufV = buf }          // 溢出过就记下尺寸
	return buf
}
~~~

`RequestHeader.Write` 同样（`header.go:3210-3219`）。这样**绝大多数响应头完全不经过中间 buffer**。

**仓颉**：需要自己实现 buffered writer 并暴露"空闲区"（`Array<Byte>` 的尾部区间）。
因为切片别名成立（附录 A-9），**技术上可行**，但要手写。

#### (9) header+body 一次 writev

`http.go:2550-2592`：如果 `len(header)+bodyLen > w.Size()`（writer 装不下），
走 `writeVectored`（`http.go:2594`），用 `net.Buffers` 一次 writev。
但 `vectorWriter`（`http.go:2613`）**只对 `*net.TCPConn`/`*net.UnixConn` 生效**，
TLS 连接走不了。`Response` 里 `vec [2][]byte` 是**内联数组**（`http.go:144`），
所以组装这对切片本身不分配。

**仓颉**：没有 `writev` 的等价 API（`std.net` 的 TcpSocket 只有 read/write）。**做不到**。

#### (10) body 缓冲池

`requestBodyPool`/`responseBodyPool` 是两个 `bytebufferpool.Pool`（`http.go:589-592`），
`bodyBuffer()` 惰性取（`http.go:575-587`）。可配置上限 `SetBodySizePoolLimit`（`http.go:28`），
超过上限的 body 直接还给 GC 而不是池（`http.go:944-976` 的 `ReleaseBody`）。

#### (11) SWAR 8 字节并行扫字节

`swar.go` 整个文件：`loadWord`（`swar.go:18`，`binary.LittleEndian.Uint64`）、
`anyByteIsCTL`（`swar.go:48`，一次判 8 个字节是不是控制字符）、
`lowercaseWord`（`swar.go:60`，一次把 8 个字节全小写）、`anyByteEqual`（`swar.go:40`）。

调用点：`scanValueLine`（`headerscanner.go:359-394`，找 header value 的行尾 + 校验合法性）、
`skipCleanWords`（`header.go:953-959`）、`stringContainsCTLByte`（`uri.go:1080-1093`）。

**仓颉**：位运算都在，但 `UInt64` 要从 `Array<Byte>` 拼出来。见 §10.2(c)。

#### (12)(13)(14) 杂项

- 常量字节切片：`strings.go:25-60`，全部包级 `[]byte(...)` —— `HTTP/1.1`、`\r\n\r\n` 等。
  移植时**必须在启动时一次性构造**，别每次比较时 `toArray()`。
- 状态码文本：`status.go:170-177` 的 `statusMessages` map（这个是 map，但只在格式化用）。
- `noCopy`：`nocopy.go:8-12`，纯粹给 `go vet` 看的，移植无意义。

---

## 3. Header 存储细节

### 3.1 字节布局：不是一块 slab

~~~text
header struct (header.go:21)
├── h        []argsKV         ← 普通头，按"到达顺序"（parsed）或"首次出现顺序"（set）
├── trailerH []argsKV         ← trailer 段
├── cookies  []argsKV         ← Cookie（请求）/ Set-Cookie（响应），从 h 里搬出来
├── bufK, bufV []byte         ← 查找/设置时的临时缓冲（非存储）
├── contentLengthBytes []byte ← Content-Length 的原文
├── contentType, protocol []byte
├── mulHeader [][]byte, trailer [][]byte
├── contentLength int         ← -2=identity, -1=chunked, >=0 定长
├── terminatorSearched int    ← 增量找 \r\n\r\n 的水位（header.go:60-68）
└── 一组 bool：disableNormalizing / noHTTP11 / connectionClose / ...

argsKV (args.go:52) { key []byte; value []byte; noValue bool }
~~~

**每个 key/value 是独立切片**（实测 cap 各不相同，附录 A-4）。所以"一块 byte 切片原地存放"
只在**概念上**成立——真正的复用是"每个 key/value 的底层数组跨请求保留，`[:0]` 截断后重填"。

> **移植提醒**：如果照字面理解成"单 slab + 偏移"，会得到和 fasthttp 不同的扩容行为：
> 单 slab 需要 `bufK`/`bufV` 那种"搬家"逻辑（`header.go:4079-4094` 的 `initHeaderKV`），
> 复杂度反而更高。**建议按 argsKV 模型移植**。

### 3.2 解析：单遍 scanner + SWAR

`headerscanner.go` 是重写过的（commit 就是这个方向）。核心：

~~~text
headerScanner.next()                      headerscanner.go:41
├─ 首次调用：拒绝以空格/tab 开头的头（headerscanner.go:47-50）
├─ 一行内同时完成：找冒号、校验 key 字节、记录"key 里有内部空格"
│    headerscanner.go:90-118
├─ scanValueLine(b[i:])                  headerscanner.go:359  ← 8 字节一跳找行尾+校验
├─ 折叠（续行）：nextFolded               headerscanner.go:190
│    └─ 只在整块到齐时做（blockComplete），因为折叠是**原地改写 b**
│    └─ secureRaw 先把要覆盖的原字节存进 rawHeaders   headerscanner.go:297-311
├─ 空行/块结束判定：blockComplete          headerscanner.go:157（CRLFCRLF 只搜一次，记水位）
└─ 出错时 failLine 模拟"逐行读"的同一套报错文案  headerscanner.go:171-187
~~~

`rawHeaders`（`RequestHeader.rawHeaders`，`header.go:112-114`）只在**有折叠**时才保存原始字节
（`parse` 里 `if n > 2` 分支，`header.go:3357-3363`），供 `VisitAllInOrder` 用
（`header.go:1788-1806`，会**重新解析** rawHeaders）。

`parseHeaders` 的分流（`header.go:3783-3952`）—— 按 `key[0] | 0x20` 一个 switch：

| 头 | 处理 | 位置 |
|---|---|---|
| `Host` | 存字段；**重复即错** | header.go:3855-3866 |
| `User-Agent` | 存字段 | header.go:3868-3872 |
| `Content-Type` | 存字段 | header.go:3874-3877 |
| `Content-Length` | `parseContentLength`；**重复即 ErrDuplicateContentLength** | header.go:3815-3830 |
| `Connection` | 含 `close` 就置 `connectionClose=true`；含别的值才留在 `h` 里 | header.go:3885-3898 |
| `Transfer-Encoding` | 只认 `identity`/`chunked`；chunked → `contentLength=-1`；其它值报错 | header.go:3900-3915 |
| `Trailer` | `addParsedTrailers`，禁头列表 `isBadTrailer` | header.go:3916-3921 / 3427-3476 |
| 其余 | `appendArgNormalized`（**边复制边规范化**） | header.go:3924 |

尾部还有三条**安全判定**（`header.go:3930-3952`）：
1. `contentLength < 0` 时清掉 `contentLengthBytes`；
2. **CL 与 TE 同时出现 → `connectionClose=true`**（防请求走私，RFC 9112 §6.3）；
3. HTTP/1.0 且没有 `Connection: keep-alive` → 关连接。

实测 G/G2（附录 A-31）：重复 CL → 400；CL+TE 同时 → 200 但 `Connection: close`。

### 3.3 大小写规范化（零分配）

两条路径：

**解析时**：`appendArgNormalized`（`args.go:472-494`）在 `append` 复制的同时做
`toUpperTable`/`toLowerTable`（`bytesconv_table.go:7` 是一张 256 字节表，预生成），
**不碰源字节**。所以读缓冲可以原样复用。
带空格的 key 不规范化（`disableNormalizing := h.disableNormalizing || s.keyHasSpace`，
`header.go:3809`）。

**查表/设置时**：`normalizeHeaderKey`（`header.go:4102-4116`）**原地**改写传入的切片
（这个切片一定是自己的 `bufK`），`normalizeHeaderKeyValidated`（`header.go:4118-4136`）是核心循环：

~~~go
upper := true
for i, c := range b {
	if upper { c = toUpperTable[c] } else { c = toLowerTable[c] }
	upper = c == '-'        // 连字符后一个大写
	b[i] = c
}
~~~

**禁用**：`Server.DisableHeaderNamesNormalizing`（`server.go:457`）→
`ctx.Request.Header.DisableNormalizing()`（`server.go:2636-2639`）。
实测：开着时 `x-MiXeD-Case` 原样输出到响应（附录 A-12）。

### 3.4 Peek / Has / 多值语义

**`Peek`**（`header.go:2439` / `2470`）：string 版先 `getHeaderKeyBytes`（复制进 `bufK` + 规范化），
然后 `peek(key)`。`peek` **不是**查表，是一个 `switch string(key)` 把特殊头分流
（`header.go:2496-2556` 响应 / `2523-2553` 请求），**前提是你传的 key 已经是规范形式**；
普通头落到 `peekSections`（`header.go:725-733`）：先扫 `h`（**返回第一个匹配**），再扫 `trailerH`。

- `Peek` 返回的是**内部切片**，不拷贝，但"有效期到 handler 返回"
  （注释到处写 "The returned value is valid until ... your request handler returning"）。
- `PeekCanonical`（`header.go:2461`/`2492`）：**不规范化**，要求调用方自己传规范形式，
  省掉一次复制。这是给热路径准备的逃生门。

**`Has`**：`*RequestHeader`/`*ResponseHeader` **没有** `Has(key)`！
我用 `go doc` 确认过（附录 A-13），只有 `HasAcceptEncoding`/`HasAcceptEncodingBytes`
（`header.go:1299`/`1310`）。判断"有没有这个头"的惯用法是 `len(h.Peek(k)) > 0`。
`Args` 倒是有 `Has`/`HasBytes`（`args.go:310`/`315`）——但注意它判断的是**key 存在**，
无值 key（`?flag`）也返回 true。实测：`Has("flag")=true, Peek("flag")=""`（附录 A-14）。

> **移植时别自作多情加 `Header.Has`**——加了会和 `len(Peek)>0` 的语义冲突
> （值为空字符串的头 `Has` 为 true 但 `Peek` 为空）。

**多值**：`PeekAll`（`header.go:2559`/`2616`）→ `peekAll`（`2564`/`2621`），
结果是复用 `h.mulHeader` 这个 `[][]byte`。特殊头（`Set-Cookie`/`Cookie`）在这里被**拼成一条**。

**`VisitAll` 的顺序不是到达顺序**（实测，附录 A-15）：先输出特殊头
（Host → Content-Length → Content-Type → User-Agent → Trailer → Cookie → Connection），
再按 `h.h` 顺序（`header.go:1764-1787`）。要到达顺序必须用 `VisitAllInOrder`（重解析 rawHeaders）。

**Set vs Add**（实测附录 A-16）：
- `Set` → `setArg` 遇到同名 key **原地覆盖**（`args.go:455-464`）；
- `Add` → `appendArg` 无条件追加（`args.go:496-507`）；
- 混用时 `Set` 只改**第一个**匹配，后面的 `Add` 值留在原地。
  实测 `Set X-C=9` 覆盖了第一个 `1`，第二个 `2` 还在 → `Peek="9"`，`VisitAll` 出两条。

### 3.5 Content-Length / Transfer-Encoding / chunked

`contentLength` 三态：`-2`=identity（没有 CL 也没有 chunked）、`-1`=chunked、`>=0`=定长。
字段在 `header.go:34`，语义注释在 `ContentLength()`（`header.go:256-265`）。
读请求时初始化为 `-2`（`header.go:3784`）。

- `SetContentLength`（响应，`header.go:288-303`）：先 `mustSkipContentLength()` 拦掉
  1xx/204/304（`header.go:305-317`）；`>=0` 写字节 + 删掉 `Transfer-Encoding`；
  `-1` 写 `Transfer-Encoding: chunked`。
- `SetContentLength`（请求，`header.go:339-351`）：同样的三态。
- **序列化时的差异**：`mustSkipContentLengthOnWire`（`header.go:331-336`）比
  `mustSkipContentLength` **窄**——304 允许带 Content-Length（描述对应 200 的 body），
  只有 `<200` 和 `204` 才禁止。这个区别写在 `header.go:3154-3165` 的注释里。
  实测：204 响应**完全没有 Content-Length**（即使 handler 设了）（附录 A-17）。

**chunked 请求**：`readBodyChunked`（`http.go:3370-3396`），
`parseChunkSize`（`http.go:3402`）支持 chunk extension（`;ext` 会被跳过）。
**chunked 响应**：只有当 `SetBodyStream(..., -1)` 且长度未知时才用
（`http.go:2562-2575`），`writeBufferedBodyChunked` 写块，然后 `writeTrailer`
（`header.go:3077`）。实测（附录 A-30）：

~~~text
Transfer-Encoding: chunked\r\n\r\nd\r\nstreamed-data\r\n0\r\n\r\n
~~~

**普通响应永远不用 chunked**：`Response.write` 里无条件 `resp.Header.SetContentLength(bodyLen)`
（`http.go:2559-2561`），因为 body 已经在内存里了。

**HTTP/1.0 特殊处理**：`noHTTP11=true` 时响应禁用 chunked（`server.go:2938`），
因为 1.0 客户端不认 chunked。

### 3.6 序列化：写进 bufio 的空闲区

`ResponseHeader.AppendBytes`（`header.go:3121-3207`）的顺序是**固定**的（实测 `header.go:3143` 是 Content-Type 的门槛、`3202` 是 Connection: close、`3207` 是函数结束）：

1. 状态行（`formatStatusLine`，`status.go:176`）
2. `Server`（有就用，没有就用缓存的 `serverDefaultLine`）
3. `Date`（缓存，见 §2 (7)）
4. `Content-Type`（条件：显式设了，或"有 body"）
5. `Content-Encoding`
6. `Content-Length`（受 `mustSkipContentLengthOnWire` 约束）
7. `h.h` 遍历（跳过 `Date`、1xx/204 时跳过 `Transfer-Encoding`）
8. `Trailer`
9. `Set-Cookie`（每个一条）
10. `Connection: close`（如果 `connectionClose` 且 `h.h` 里没有）

**关键**：`Server`/`Date`/`Content-Type`/`Content-Length` 这些"自动头"在 `h.h` 里
**根本没有实体**，是序列化时现拼的。所以 `Del("Content-Length")` 要单独处理
（`header.go:1828` 的 `ResponseHeader.del` / `1867` 的 `RequestHeader.del` 有一堆 case）。

---

## 4. URI 与 Args

### 4.1 惰性解析

见 §2 (4)。`Server` 在调 handler **之前**会主动 `parseURI()`（`server.go:2688`），
这样 URI 解析失败能在 handler 之前回 400。但 query args 仍然是惰性的：
`ctx.QueryArgs()`（`server.go:1203`）→ `URI.QueryArgs()`（`uri.go:1065`）→ `parseQueryArgs`（`uri.go:1070`）。

### 4.2 URI.parse 的解析算法

`uri.go:299-412`。分解：

1. **Host 备忘录快路径**（`uri.go:305-315`）：`uri == "/" && host == u.hostRaw` → 全复用。
2. **CTL 字节检查**（`uri.go:317-319`）：`stringContainsCTLByte`（`uri.go:1080`）→ `ErrorInvalidURI`。
3. **判断 origin-form**（`uri.go:321-330`）：`uri[0]=='/' && uri[1]!='/'` 且**只有一个前导斜杠**；
   否则如果 host 为空或 URI 里有 `://`，走 `splitHostURI`（`uri.go:1031`）剥 scheme+host。
   实测：`GET http://example.com/x/y?q=1` + `Host: other` → host 变成 `example.com`
   （URI 里的优先）（附录 A-18）。
4. **userinfo**（`uri.go:337-357`）：最后一个 `@`，`validUserinfo` 校验，有 `%` 才解码。
5. **host**（`uri.go:359-374`）：`parseHost`（`uri.go:480`，处理 IPv6 `[...]`、`%25` zone、
   `validOptionalPort`）然后**强制小写** `lowercaseBytes`。
6. **path / query / hash 切分**（`uri.go:376-411`）：找 `?` 和 `#`，注意
   "query 在 fragment 里就忽略"（`uri.go:380-383`）。

### 4.3 路径规范化 / 百分号解码

`normalizePath`（`uri.go:745-770`）：

~~~text
1. src == "/" → 直接返回 "/"
2. addLeadingSlash
3. decodeArgAppendNoPlus     ← 百分号解码（'%' 解码，'+' 不动，因为 path 里 '+' 是字面量）
4. removeSegments("//")      ← 去掉重复斜杠
5. 没有 '.' 就直接返回（快速路径）
6. removeDotSegments         ← 去掉 "." / ".."
~~~

`removeSegments`（`uri.go:699-721`）和 `removeParentSegments`（`uri.go:724-743`）是
**单遍原地重写**算法，注释里明确写了原因：老实现是 O(n²)（`uri.go:695-698`）。

`removeDotSegments`（`uri.go:772-818`）按 RFC 3986 §5.2.4 的四种情况处理，
末尾的 `/.` 只删点不删斜杠、末尾 `/foo/..` 退到上一个斜杠。

实测：`/a//b/../c/./d%41` → `/a/c/dA`（附录 A-19）。
注意 `%41` 解码成 `A`——**解码先于 dot-segment 处理**，所以 `%2e%2e` 也会被当成 `..`。

**是否改写原 buffer**：**不改**。`pathOriginal` 存原文，`path` 是**独立的 []byte**，
`normalizePath(u.path, u.pathOriginal)` 写进 `u.path`。

### 4.4 Args 扫描器

`ParseBytes`（`args.go:110-127`）→ `argsScanner.next`（`args.go:559-610`）：

~~~go
for i, c := range s.b {
	t := argsScanTable[c]     // 256 字节查表：'%'/'+' → '%', '=' → '=', '&' → default
	if t == 0 { continue }    // 绝大多数字节直接跳过（既不是分隔符也不是转义）
	switch t {
	case '%': if esc < 0 { esc = i - k }   // 只记第一个转义的位置
	case '=': ...
	default:  // '&'
	}
}
~~~

**性能要点**：用一张 256 字节的 `argsScanTable` 把"是不是分隔符/转义"变成一次查表；
解码函数拿到的 `esc` 是"第一个 `%`/`+` 的相对位置"，避免二次扫描
（`decodeArgAppendAt`，`args.go:632-665`）。

**解码语义**：
- query args：`+` → 空格，`%XX` → 字节，非法转义**原样保留** `%`（`args.go:653-657`）。
- path / userinfo / cookie：`+` **不转空格**（`decodeArgAppendNoPlus`，`args.go:672-702`）。

**无值 key**：`?flag` 会存成 `noValue=true`，`QueryString()` 输出时不带 `=`
（`args.go:167` 的 `AppendBytes`，`args.go:172` 检查 `kv.noValue`）。

---

## 5. Cookie

`Cookie` 结构（`cookie.go:34-58`）：`expire time.Time / key,value,domain,path []byte /
bufK,bufV []byte / maxAge int / sameSite / httpOnly / secure / partitioned`。

**序列化** `AppendBytes`（`cookie.go:290-352`），顺序固定：

~~~text
key=value
[; max-age=N]        或 [; expires=<RFC1123>]     ← 二者互斥，maxAge 优先
[; domain=X]
[; path=Y]
[; HttpOnly]
[; secure]
[; SameSite=Lax|Strict|None]  或 [; SameSite]（DefaultMode，只输出键名）
[; Partitioned]
~~~

实测：`"k=v; max-age=60; domain=e.com; path=/; HttpOnly; secure; SameSite=None; Partitioned"`
（附录 A-20）。

**要点**：
- `maxAge < 0` 时输出 `max-age=0`（`cookie.go:299-306`），这是"立即删除"的约定。
- `expire` 走 `AppendHTTPDate`（`bytesconv.go:116`），复用同一个 `bufV`。
- 大小写**不统一**：`max-age`/`domain`/`path` 小写，`HttpOnly`/`secure`/`SameSite`/`Partitioned`
  混合。跟着常量表抄就行。
- **请求里的 Cookie 头会被搬出 `h`**：`collectCookies`（`header.go:3955-3975`）把
  所有 `Cookie` 头解析进 `h.cookies` 并从 `h.h` 里删掉，`cookiesCollected` 标记防重入。
  `Peek("Cookie")` 在收集后是**现拼的**（`header.go:2541-2545`）。
- **响应里的 Set-Cookie 单独存**：`h.cookies`，`kv.key` 是 cookie name（`getCookieKey` 提取），
  `kv.value` 是整条 Set-Cookie 值。所以 `SetCookie` 不会覆盖前一条。
- `ParseBytes`（`cookie.go:395`）**宽容**：属性解析失败只忽略该属性，不整条失败（RFC 6265 §5.2）。

---

## 6. 连接管理

### 6.1 keep-alive 判定

**请求侧**（决定服务端是否愿意保持）—— `server.go:2905-2913`，六个来源取或：

~~~go
connectionClose = connectionClose                                  // 来自 2806：Request.Header.ConnectionClose()
               || ctx.Response.Header.ConnectionClose()            // handler 设了 close
               || (reqStream != nil && reqStream.failed)           // 流式 body 失败
               || (s.CloseOnShutdown && s.stop.Load() == 1)        // 正在 Shutdown
if hijackHandler == nil {
	connectionClose = connectionClose ||
		s.DisableKeepalive ||                                  // 全局关
		(s.MaxRequestsPerConn > 0 && connRequestNum >= uint64(s.MaxRequestsPerConn))
}
~~~

**请求头 `Connection: close` 的解析**在 `parseHeaders` 里就做了（`header.go:3885-3898`）：
含 `close` → `connectionClose=true`；**如果还含别的值**（如 `close, foo`），
原值也留在 `h` 里（为了不丢信息）；只有**纯 `close`** 才从 `h` 里删掉。

HTTP/1.0：没有 `Connection: keep-alive` 就关（`header.go:3947-3952`）；
要 keep-alive 时响应里补 `Connection: keep-alive`（`server.go:2933`）——
HTTP/1.1 不需要补，因为是默认。

**响应侧**：`AppendBytes` 末尾如果 `connectionClose` 且 `h.h` 里没有 Connection 头，
补 `Connection: close`（`header.go:3202-3204`）。实测 MaxRequestsPerConn=1 /
DisableKeepalive / handler 里 SetConnectionClose 三种情况都正确带上了（附录 A-21）。

### 6.2 pipelining

fasthttp **天然支持 pipelining**（同一连接连续多个请求），因为读循环就是
"读一个、处理一个、写一个"。没有 head-of-line 阻塞的特殊处理，但有两个优化：

1. **读下一个 header 前先试一次不等待**：如果 `bw` 里有未 flush 的响应，
   用 `readLoop(br, false)`（`waitForMore=false`）试着解析，`ErrNeedMore` 才 flush 再阻塞读
   （`server.go:2650-2658`）。这样"响应等着 flush、请求等着被读"不会互锁。
2. **有 pipeline 就不 flush**：`server.go:2964-2971`——`br.Buffered() != 0` 说明已经
   有下一个请求在缓冲里，把响应攒着一起发。源码注释自己承认这是为 bench 特调的行为。

实测：一次写入两个请求，一次 `Read` 拿回 270 字节、含 2 个 `HTTP/1.1 200`（附录 A-7）。

**没有请求队列上限**，也不做 pipeline 深度控制——完全靠 TCP 背压。

### 6.3 超时族

| 字段 | 位置 | 语义 |
|---|---|---|
| `ReadTimeout` | `server.go:302` | 读**整个请求**（含 body）。新连接从 accept 起算；keep-alive 从**读到第一个字节**起算（`server.go:2570`、`2627-2637`） |
| `WriteTimeout` | `server.go:309` | 写响应；在 handler **返回后**才设（`server.go:2884`），写完清掉 |
| `IdleTimeout` | `server.go:314` | keep-alive 空闲；为 0 时**回落到 ReadTimeout**（`idleTimeout()`，`server.go:2470-2475`） |
| `MaxRequestBodySize` | `server.go:351` | 默认 `DefaultMaxRequestBodySize=4MB`（`server.go:2462`）；**<=0 也取默认值，不是无限制** |
| `MaxConnsPerIP` | `server.go:320` | 每 IP 并发连接数，超出回 429 |
| `MaxRequestsPerConn` | `server.go:328` | 每连接请求数上限，到顶在最后一个响应加 `Connection: close` |
| `Concurrency` | `server.go:280` | 并发连接总数，默认 `256*1024`（`server.go:2104`） |
| `HeaderReceived` | `server.go:190` | 读到 header 后回调，可**逐请求覆盖** ReadTimeout/WriteTimeout/MaxRequestBodySize（`server.go:2662-2685`） |

**实测超时行为**（附录 A-23）：

| 场景 | 结果 |
|---|---|
| `ReadTimeout=300ms`，连上不发数据 | 300ms 后收到 `408 Request Timeout` + `Connection: close` + "Request timeout" |
| `IdleTimeout=300ms`，keep-alive 后不发 | 300ms 后 `read` 返回 `EOF`（**不发任何响应**，直接关） |
| `Concurrency=1`，第二个连接 | `503 Service Unavailable` |
| `MaxConnsPerIP=1`，第二个连接 | `429 Too Many Requests` |

**注意**：Idle 超时**不发响应**（因为还没开始解析，不知道是哪个请求），
这和第 2 个请求"一个字节都没读到"的分支有关（`server.go:2717-2729` 的 `ErrNothingRead` 处理）。

**ctx 里的逃生门**：`RequestCtx.SetReadDeadline/SetWriteDeadline`（`server.go:950/968`）
让 handler 自己改 deadline，但循环会在下一轮把 handler 设过的 deadline 清掉
（`server.go:3022-3045`）。

### 6.4 并发与配额

三层，都在不同位置拦：

1. **accept 层**：`MaxConnsPerIP`（`acceptConn`，`server.go:2286-2296`）→ 超了回 429 并关。
   计数器是 `perIPConnCounter`（`peripconn.go:15-37`），key 是 **16 字节 IPv4-mapped**
   （`peripconn.go:13`），所以 `::ffff:1.2.3.4` 和 `1.2.3.4` 算同一个客户端。
   `perIPConn.Close` 里注销（`peripconn.go:81-88`），有 `atomic.Bool` 防重复注销。
2. **workerPool 层**：`Concurrency` 就是 `MaxWorkersCount`（`server.go:2124-2126`）。
   `wp.Serve` 拿不到 worker → 回 503（`server.go:2152-2164`）。
3. **ServeConn 层**（手动调用时）：`tryAcquireConcurrency`（`server.go:2390-2397`）用
   `atomic.Uint32` 计数，超了 `ErrConcurrencyLimit`。

**注意 `TimeoutHandler` 有第四层**：`getConcurrencyCh()`（`server.go:2445`）是个
容量 = Concurrency 的 channel，用来给"超时 handler"限流（`server.go:520-552`），
拿不到名额直接 429。

### 6.5 优雅关闭

`Shutdown()` → `ShutdownWithContext(context.Background())`（`server.go:2187-2206`）。

~~~text
s.stop.Store(1)                           → 各 serveConn 循环看到后 break（server.go:3063）
closeListenersLocked()                    → ln.Close()，Serve 返回 io.EOF
close(*s.done)                            → ctx.Done() 从此可读（server.go:3358-3364）
循环 { closeIdleConns(); if open==0 { return } ; sleep 100ms }   server.go:2229-2245
~~~

`closeIdleConns`（`server.go:3533-3546`）扫 `s.idleConns` map，把**已经空闲超过 5 秒**的
连接直接 `c.Close()`（idle 时间戳在 `server.go:2531-2535` 用 `connTime.Add(5s)`）。

**关键限制**（文档注释自己说的，`server.go:2195-2198`）：
> Shutdown does not close keepalive connections so it's recommended to set
> ReadTimeout and IdleTimeout to something else than 0.

即**空闲连接如果不设超时，Shutdown 会一直等**。配合 `CloseOnShutdown`（`server.go:490`）
可以在最后一个响应里加 `Connection: close` 促使客户端断开。

`ctx.Done()` 的实现很省：**不为每个请求建 channel**，只在 Shutdown 时关一个全局 channel
（`server.go:3352-3364`，注释直说 "creating a new channel for every request is just too expensive"）。

### 6.6 Hijack

`ctx.Hijack(handler)`（`server.go:805`）只是记下 handler，循环末尾
（`server.go:2987-3012`）：
1. flush 并释放 `bw`；
2. `c.SetDeadline(zeroTime)` 清掉所有 deadline；
3. `go hijackConnHandler(ctx, hjr, c, s, handler)` 起新 goroutine；
4. 返回 `errHijacked`（`server.go:2386`）让 ServeConn **不关连接**。

`hijackConnHandler`（`server.go:3102-3125`）：默认（`KeepHijackedConns=false`）
handler 返回后**替它关连接**并释放 ctx。`KeepHijackedConns=true` 才交给调用方。
`HijackSetNoResponse(true)` 可以跳过响应（`server.go:814`）。

---

## 7. 并发模型（含 workerpool 到底干什么）

### 7.1 每连接一 goroutine 的代价

Go 的 goroutine 栈从 2KB 起、按需增长，`go func(){}` 实测 **235ns/次**
（附录 A-24），10K 个阻塞 goroutine ≈ 605B/个（堆）。

fasthttp 的取舍：**连接数 = goroutine 数**，靠 `Concurrency` 硬顶（默认 256K，
`server.go:2104`）。`ReduceMemoryUsage` 进一步把"空闲连接"的内存压到只剩 goroutine 栈。

### 7.2 workerpool 到底干什么 —— **它是服务端的**

任务描述里写"它主要是客户端 Dial 用的，要说清楚"。**这个说法不对，必须纠正**：

~~~go
// server.go:2124-2133
wp := &workerPool{
	WorkerFunc:            s.serveConn,     // ← 就是服务端的连接处理函数
	MaxWorkersCount:       maxWorkersCount,
	...
}
wp.Start()
~~~

`grep -rn 'workerPool{' --include='*.go' .` 的结果：**只有 `server.go:2124` 一处**（外加两个测试）
（附录 A-25）。整个仓库里 `workerPool` 只被**服务端 `Serve`** 使用。

它解决的是 **"每连接一 goroutine" 的爆量问题**：

- **不是**线程池（不限制并发处理数）——并发数由 `MaxWorkersCount` 限制，
  但那同时就是 `Server.Concurrency`（`server.go:2132`）。
- **是"连接 → worker"的分发器**：worker 处理完一个连接**不退出**，回到 `wp.ready` 队列
  等下一条连接（`workerpool.go:216-252`）。这样连接量大时不用反复建 goroutine。
- FILO 复用（源码原文 "in FILO order, i.e. the most recently stopped worker will serve the next
  incoming connection. Such a scheme keeps CPU caches hot (in theory)"，`workerpool.go:12-16`），
  用二分查找清理空闲太久的 worker（`workerpool.go:113-135`）。
- `workerChanCap` 按 `GOMAXPROCS` 决定阻塞/非阻塞 channel（`workerpool.go:157-169`）。

**真正"主要给客户端用"的是** `HostClient` 的连接池：`conns []*clientConn` /
`connsCount` / `connsWait`（`client.go:1031-1033`），配 `MaxConns` 限制，
`serveWaiterLocked`/`dialConnFor` 那一套（`client.go:1894`、`2067`）。**两套东西完全不同**。

> **移植建议**：workerPool 的语义 = "有界 worker 复用 + 空闲淘汰"。
> 仓颉的 `spawn` 实测是**协程**（M:N 绿线程，2 万条阻塞连接只占 20 个内核线程，见 §10.2(a)），
> 所以每连接一协程在内存上是可行的；这个池的移植价值主要在"有界并发 + 空闲淘汰"的语义，
> 而不是省线程栈。

### 7.3 MaxRequestsPerConn

`server.go:2912`：`connRequestNum >= MaxRequestsPerConn` → 关连接。
实现在主循环里，**不在 workerPool 里**。到顶时最后一个响应带 `Connection: close`
（`server.go:2928`）。实测 2 个请求后关（附录 A-21）。

---

## 8. 错误处理

### 8.1 解析失败怎么回 400

`writeErrorResponse`（`server.go:3508-3529`）：

~~~go
errorHandler := defaultErrorHandler
if s.ErrorHandler != nil { errorHandler = s.ErrorHandler }
errorHandler(ctx, err)                 // 默认实现见 3498
if serverName != "" { ctx.Response.Header.SetServer(serverName) }
ctx.SetConnectionClose()               // ← 一律关连接
if bw == nil { bw = acquireWriter(ctx) }
writeResponse(ctx, bw)
ctx.Response.Reset()
bw.Flush()
~~~

`defaultErrorHandler`（`server.go:3498-3506`）三种映射：

| 错误类型 | 状态码 | body |
|---|---|---|
| `*ErrSmallBuffer`（header 超 `ReadBufferSize`） | **431** | "Too big request header" |
| `*net.OpError` 且 `Timeout()` | **408** | "Request timeout" |
| 其它 | **400** | "Error when parsing request" |

实测三类都对上了（附录 A-26）。**注意 400 响应一律带 `Connection: close`**。

**在哪几个点回错误**（`writeErrorResponse` 的 3 个调用点）：
`server.go:2689`（URI 解析失败）、`server.go:2733`（header/body 读失败）、
`server.go:2798`（100-continue 后读 body 失败）。

### 8.2 什么时候直接关连接（不回响应）

`server.go:2711-2736`：

~~~go
if err == io.EOF { err = nil }                                  // 对端正常关，静默
else if nr, ok := err.(ErrNothingRead); ok {
	if connRequestNum > 1 { err = nil }                          // keep-alive 空闲超时，静默关
	else { err = nr.error }                                      // 首请求超时 → 408
}
if errors.Is(err, net.ErrClosed) { err = nil }                   // Shutdown 关的，静默
if err != nil { bw = s.writeErrorResponse(...) }
break
~~~

另外 `rejectConn`（`server.go:2315-2328`）走的是**快速路径 `writeFastError`**
（`server.go:3475-3496`），手写状态行 + 头，**不经过 ctx**（因为这时还没有 ctx）。
而且**对 TLS 连接不发响应**——注释说握手可能还没完成，写响应会卡住 accept 循环。

### 8.3 panic 恢复 —— **fasthttp 不恢复**

`Server.Handler` 的文档注释（`server.go:173-175`）：

> Take into account that no `panic` recovery is done by `fasthttp` (thus any `panic`
> will take down the entire server). Instead the user should use `recover` to handle
> these situations.

**实测证实**：handler 里 `panic("boom")` 直接冒到 `serveConnCounted` 的调用栈，
整个进程崩溃（附录 A-27 的栈）。`grep 'recover()'` 全仓库只有 2 处非测试：
`http.go:2681`（`writeBodyStream` 里保护 body stream 写入）和 `fs_test.go:959`。

> **移植时这是必须"照搬"的行为**：**不要**在 handler 外层加 catch 然后继续。
> 但仓颉没 panic，等价物是 `throw`/`catch` —— 建议**默认不 catch**，
> 只在 `writeBodyStream` 那种"用户回调"处 catch（对应 `http.go:2677-2686`）。

---

## 9. 与 net/http 的关键差异

| 维度 | fasthttp | net/http | 位置 |
|---|---|---|---|
| Handler 签名 | `func(*RequestCtx)`，返回值即响应 | `interface{ ServeHTTP(ResponseWriter, *Request) }` | `server.go:143` |
| 请求对象所有权 | **只有一个**，handler 返回后就被复用，**不能存指针** | 每个请求一个 `*Request`，可逃逸 | 文档到处写 |
| Header 类型 | map-less 的 `[]argsKV`，key 会被规范化 | `map[string][]string`，key 规范化成 Canonical | `header.go:21` |
| HTTP/2 | **完全不支持** | 支持 | `doc.go` 特性列表无 h2 |
| Hijack | `ctx.Hijack(func(net.Conn))`，**必须**用它做 Upgrade | `Hijacker` 接口 + `bufio.ReadWriter` | `server.go:805` |
| panic | **不恢复** | 恢复并打日志 | `server.go:173` |
| Context | `RequestCtx` 实现 `context.Context`，但 `Done()` 只在 Shutdown 时触发 | 每请求一个可取消 ctx | `server.go:3352` |
| Content-Length | `contentLength int` 三态（-2/-1/>=0），**自动管理** | `ContentLength int64` + `TransferEncoding` | `header.go:34` |
| 响应头自动补 | Server / Date / Content-Type / Content-Length 都是**序列化时现拼** | 也是自动，但 `Header` map 里有实体 | `header.go:3121` |
| 请求 body | 默认 handler 前读完 | 流式 | `server.go:2699` |
| 超时 | 连接级 deadline（`SetReadDeadline`） | `http.TimeoutHandler` 等 | `server.go:2570` |
| 错误响应 | 可被 `ErrorHandler` 完全接管 | 固定 400 | `server.go:187` |
| 协程模型 | 每连接一个 goroutine + workerPool | 每连接一个 goroutine | `workerpool.go` |

**"不支持 hijack 的具体行为"** —— 任务里这句话我得澄清：fasthttp **支持** hijack
（`ctx.Hijack`），但和 net/http 的 `Hijacker` **语义不同**：
- net/http 给你 `bufio.ReadWriter`，你自己管读写；
- fasthttp 给你 `io.Reader`（包了 bufio，保留已缓冲字节）+ 已 flush 完的连接
  （`server.go:2988-3010`），并且**默认在 handler 返回后替你关连接**
  （`KeepHijackedConns=false`，`server.go:3117-3122`）。

**HTTP/2 的实际行为**（实测，附录 A-28）：客户端发 `PRI * HTTP/2.0` + `SM`，
fasthttp 把 `PRI` 当方法、`*` 当 URI，`validateRequestURI`（`header.go:3611-3636`）判定
"`*` 只允许 OPTIONS" → **400 + close**。不会 hang，也不会误判成正常请求。

---

## 10. 对仓颉移植的结论

先给结论表，再展开。

| 技巧 | 仓颉可行性 | 依据 |
|---|---|---|
| argsKV 式 Header 存储 | 可做 | `ArrayList` + `Array<Byte>` 切片别名（附录 A-9） |
| 惰性解析（URI/Args） | 无成本 | 纯状态位 |
| 每连接复用一个 ctx | 可做 | 手写对象池 |
| Date 头缓存 | 可做 | `std.sync` 的 `AtomicReference` |
| SWAR 8 字节扫描 | 有代价 | 要能从 `Array<Byte>` 高效取 `UInt64` |
| 写进 buffer 空闲区 | 要自己写 | 无现成 `AvailableBuffer` 等价物 |
| 每连接一 goroutine | 可做（仓颉是协程 M:N） | `spawn` ≈ 1µs/个，但 2 万协程只占 20 内核线程（附录 A-29 + Lead 实测） |
| `sync.Pool` 式复用 | 手写 free list | 无 GC 池 |
| `[]byte`↔`string` 零拷贝 | **做不到** | 无 unsafe reinterpret API |
| writev 一次发 header+body | **做不到** | `std.net` 只有 `write` |

### 10.1 语言无关、可照搬

这几条**没有任何 Go 特有依赖**，可以 1:1 移植：

1. **主循环结构**（`server.go:2565-3065`）：读头 → 解析 URI → 读 body → handler → 写响应 →
   算 keep-alive → 复位。这是 HTTP/1.1 的形态，不是语言特性。
2. **状态机式的超时设置点**（`server.go:2570-2583`、`2624-2631`、`2884-2901`）。
3. **keep-alive 六源或运算**（`server.go:2905-2913`）。
4. **错误映射表**（`server.go:3498-3506`）：431/408/400。
5. **惰性解析的三个布尔位**（`http.go:65-67` 等）。
6. **路径规范化算法**（`uri.go:745-818`）：RFC 3986，纯字节操作。
7. **Args 扫描器**（`args.go:559-606`）：256 字节查表 + 单遍。
8. **Header 规范化循环**（`header.go:4118-4136`）：`upper := c == '-'`。
9. **Cookie 序列化顺序**（`cookie.go:290-352`）。
10. **Content-Length 三态语义**（-2/-1/>=0）以及"响应永远不用 chunked（除非流式）"。
11. **Date 头缓存策略**（`header.go:3001-3035`）。
12. **解析失败一律 `Connection: close`** 的免疫策略。

### 10.2 可做但有代价

**(a) 连接并发模型 —— 最大的坑**

Go：`go func` 235ns，10K 阻塞 goroutine 605B/个。
仓颉：`spawn` 实测 **~1µs/个**（附录 A-29，2 万次 spawn+get = 20ms）。

**但 `spawn` 是协程（M:N 绿线程），不是 1:1 OS 线程** —— 这一条是本报告最重要的更正，
Lead 亲自实测（§10.2 附实测）：

~~~text
=== baseline ===                      Threads: 5
=== 20000 个存活并阻塞的协程 ===        Threads: 20      VmRSS: 260 MB
=== 20000 条阻塞在 read() 的真实连接 ===  Threads: 14      VmRSS: 363 MB
~~~

20000 个同时存活、且**阻塞在内核 read() 上的连接**，进程只有 14–20 个内核线程。
说明仓颉运行时在阻塞式 socket 调用上做了**栈切换/异步化**（polyfill goroutine 语义），
协程模型与 Go 同构。**因此"每连接一协程"完全可行，不需要 event loop，
也不需要 epoll 抽象。** 万级连接的内存代价（≈18 KB/连接）才是要算的账。

**结论**：
- 每连接一个 `spawn`（协程）+ 有界 worker 池：可行，就是 fasthttp 的同构移植；
- 唯一要处理的是**内存**：20000 连接 ≈ 363 MB（≈18 KB/连接），比 Go 的 ≈0.6 KB + 24 KB buffer 略高，
  但可以通过"空闲连接还缓冲"（对应 fasthttp 的 `ReduceMemoryUsage`）压下来。

**(b) 对象池**

Go 的 `sync.Pool` 会随 GC 自动清理、无锁快路径。仓颉没有等价物。
手写 free list 需要锁（或用 `std.sync` 的 `Mutex`），每次借还要 lock/unlock。
**代价**：热路径上多一次锁竞争。缓解办法：**每 worker 一个无锁本地池**（因为 worker 独占 ctx）。

**(c) SWAR**

`swar.go` 全部算法（`anyByteIsCTL`/`lowercaseWord`）都是纯位运算，**可以直接翻译**。
问题只在于"从 `Array<Byte>` 的第 i 个位置读 8 字节拼成 `UInt64`"：
- 安全写法：8 次索引 + 移位（实测 `Array<Byte>` 2M 次随机写 34.5ms，索引不慢，附录 A-10）；
- 快写法：`unsafe { acquireArrayRawData(arr) }` + `CPointer<UInt8>` 读，
  但**文档警告**"获取和释放之间仅可包含简单的 foreign C 函数调用"，
  不能在这中间构造仓颉对象（`acquireArrayRawData` 文档原文）。
  → **每次调用都要 acquire/release，开销可能抵消收益**。

**建议**：先用手写 8 次索引版，profile 后再决定要不要 unsafe。

**(d) 写进 writer 空闲区**

需要自己实现 `BufferedWriter`，暴露 `availableBuffer(): Array<Byte>`（尾部区间）。
因为仓颉切片别名成立（附录 A-9），**技术上完全可行**，
但有个坑：`ArrayList` 扩容会**换底层数组**，所以必须用**固定大小的 `Array<Byte>`** 做 buffer，
自己维护读写下标。

### 10.3 做不到

**(a) `[]byte` ↔ `string` 零拷贝 —— 明确做不到**

Go 靠 `unsafe.String`/`unsafe.Slice`（`b2s.go:7`、`s2b.go:6`）。
仓颉：
- `String` 不可变，标准库**没有** `Array<Byte>` → `String` 的零拷贝视图；
- 唯一相关的 unsafe API 是 `acquireArrayRawData<T>(Array<T>): CPointerHandle<T>`
  （要求 `T <: CType`），拿到的是 `CPointer`，**不是 `String`**；
- `String.fromUtf8(Array<UInt8>)` 会**产生新对象**（还做 UTF-8 校验），
  实测 1MB 转换 ≈ 0.87ms（附录 A-10 的 D 项：200 次 1MB = 174ms）。

**后果**：所有 API 面只能用 `Array<Byte>` 或自定义 `Bytes` 包装类型。
对外如果要 `String`，就得**付一次拷贝**。**这是移植后最大的性能落差，不要粉饰。**

> 缓解：定义 `struct Bytes { raw: Array<Byte>; start: Int64; len: Int64 }` 做零拷贝视图，
> 内部全用它，只在"真的要当字符串用"时转换。

**(b) writev**

`std.net.TcpSocket` 的 API 我查过（`class TcpSocket` 文档），只有
`read(Array<Byte>)` / `write(Array<Byte>)`，**没有 writev**。
fasthttp 的 `net.Buffers`（`http.go:2594`）**无法等价实现**。

**后果**：header+body 要么拼成一块（多一次 memcpy），要么分两次 `write`（多一个 TCP 包）。
前者通常更好（body 大时 memcpy 比多包便宜）。

**(c) `net.Buffers` 的零分配 vec**

`Response` 里 `vec [2][]byte` 内联（`http.go:144`）配合 `net.Buffers`，
这在仓颉里也没有对应物——但这条影响很小，因为 (b) 已经做不到。

### 10.4 移植优先级建议

如果目标是"复刻一个 fasthttp 风格的 HTTP/1.1 服务端"：

1. **先做对**（语言无关部分）：主循环、Header argsKV 模型、URI/Args 惰性解析、
   Content-Length 三态、keep-alive 判定、错误映射、Date 缓存。
   **这一层能做到和 fasthttp 同构，且性能特征相近。**
2. **再做"有代价"的**：worker 池 + 有界并发（必须比 Go 小很多）、
   手写 BufferedWriter（支持写空闲区）、对象池（per-worker 避免锁）。
3. **接受落差**：字符串 API 会有一次拷贝；header+body 会有一次 memcpy；没有 writev。
4. **不要碰**：unsafe 指针别名（仓颉的 unsafe 限制太多，得不偿失）。

---

## 附录 A：实测记录

> 全部在本机跑：Go 1.27.3（/usr/bin/go）、仓颉 1.2.0（cjnative）。
> Go 探针在 `.scratch/go-probe/main*/main.go`，仓颉探针在 `.scratch/cj-probe/`。
> 输出原文见各小节。

**A-1 零分配（端到端）**
~~~text
$ go test -run TestAllocationServeConn -count=1 -v
--- PASS: TestAllocationServeConn (0.00s)
（用例在 allocation_test.go:10；我自己的探针复现：ServeConn AllocsPerRun = 0.0）
~~~

**A-2 Header 解析 / URI / Args 分配**
~~~text
BenchmarkHeaderRead-16         7310469   162.0 ns/op   0 B/op   0 allocs/op
BenchmarkHeaderReadWithPeek-16 4742323   249.6 ns/op   0 B/op   0 allocs/op
BenchmarkURIParse-16          12144775    92.45 ns/op  0 B/op   0 allocs/op
BenchmarkArgsParse-16         26860647    44.40 ns/op  0 B/op   0 allocs/op
（HeaderRead 首次对象会分配 ~10 次，是 bufio+切片初始容量；复用后 0）
~~~

**A-3 复用 header 对象反复解析**
~~~text
C. 复用 header 对象反复解析 AllocsPerRun=0.0
D. 每次新建 header+bufio AllocsPerRun=10.0（含 bufio/Reader 本身分配）
~~~

**A-4 header 不是单 slab，是 per-KV 切片**
~~~text
   key="Host" cap(key)=4 cap(value)=8
   key="A"    cap(key)=8 cap(value)=8
   key="B"    cap(key)=8 cap(value)=8
   key="C"    cap(key)=8 cap(value)=8
   rawHeaders: len=32 cap=32
   2nd key="Xyz-Longer-Key" cap(key)=16 cap(value)=16
~~~

**A-5 header 是拷贝出来的，不是指向读缓冲**
~~~text
A. 解析后 br.Buffered()=0（整块被 discard 消费掉）
B. Peek 切片长度=54
C. 篡改读缓冲后 Host="example.com" X-Probe="hello"
   rawHeaders="Host: example.com\r\nX-Probe: hello\r\n\r\n"
~~~

**A-6 每次请求后 header 容量复用**
~~~text
B. Reset 后 RawHeaders 长度=0；重新解析后 cap=48 长度=37
   重新解析后 cap(rawHeaders)=48 len=37 内容="Host: example.com\r\nX-Probe: hello\r\n\r\n"
~~~

**A-7 pipelining**
~~~text
== pipelining 一次读取的响应字节数: 270
== 响应中出现 "HTTP/1.1 200" 次数: 2
"HTTP/1.1 200 OK\r\nServer: fasthttp\r\nDate: ...\r\nContent-Length: 1\r\n\r\nR
 HTTP/1.1 200 OK\r\nServer: fasthttp\r\nDate: ..."
~~~

**A-8 每连接内存**
~~~text
ReduceMemoryUsage=false  实际连接=5000  堆增量=56628 KB  每连接≈11597 B
ReduceMemoryUsage=true   实际连接=5000  堆增量=0 KB      每连接≈0 B
（=true 时 buffer 全还池，所以堆测不出来——这正说明它省内存）
~~~

**A-9 仓颉 `Array<Byte>` 切片是别名（零拷贝视图）**
~~~text
slice before: a=[1, 2, 3, 4, 5] s=[2, 3, 4]
slice after  s[0]=99: a=[1, 99, 3, 4, 5] s=[99, 3, 4]
inclusive slice: b=[1, 77, 3, 4, 5] t=[77, 3, 4]
ArrayList.toArray: list[0]=1 arr[0]=55        ← toArray 是拷贝
A. Array 赋值共享底层? a[0]=99 b[0]=99        ← 数组赋值也是别名（引用语义）
E. 大数组切片是否别名: src[500]=42 view[0]=42
~~~
**结论**：`Array<T>[range]` 是**别名视图**，可以做 Header 的 key/value 视图；
`ArrayList.toArray()` 是**拷贝**；`var b = a` 也是引用（不是深拷贝）。

**A-10 仓颉字节容器性能**
~~~text
A. Array<Byte> 200万次写: 34ms550us308ns
B. ArrayList<Byte> 200万次写: 35ms564us304ns        ← 几乎一样，可以用 ArrayList
C. 200 次 String(1MB).toArray(): 69ms555us916ns     ← 0.35ms/次
D. 200 次 String.fromUtf8(1MB): 174ms646us973ns     ← 0.87ms/次（含 UTF-8 校验）
E. ArrayList 默认 capacity=16，追加 10 万个耗时 1ms765us789ns，capacity=118342
F. toArray 后改数组是否影响 ArrayList: list[0]=1 arr[0]=9   ← 不影响，确实是拷贝
   reserve(4096) 后 capacity=4096
~~~

**A-11 Date 头每秒刷新**
~~~text
第一个 Date 行: Date: Sat, 07 Nov 2026 12:25:16 GMT
1.1s 后 Date 行: Date: Sat, 07 Nov 2026 12:25:17 GMT
~~~

**A-12 DisableHeaderNamesNormalizing**
~~~text
3. DisableHeaderNamesNormalizing 响应:
"HTTP/1.1 200 OK\r\n...\r\nx-MiXeD-Case: 1\r\n\r\nok"
4. Peek 大小写不敏感（请求头 X-My-Header）:
   peek-lower=v1 peek-upper=v1
~~~

**A-13 `*Header` 没有 `Has(key)`**
~~~text
$ go doc github.com/valyala/fasthttp.RequestHeader | grep -i has
func (h *RequestHeader) HasAcceptEncoding(acceptEncoding string) bool
func (h *RequestHeader) HasAcceptEncodingBytes(acceptEncoding []byte) bool
（没有 Has(key)；判断"有没有"用 len(Peek) > 0）
~~~

**A-14 Args 的 Has / 无值 key**
~~~text
5. 无值 key: Has(flag)=true Peek(flag)="" Has(x)=true
4. Args 重复 key: a="1" b="2" len=3 PeekMulti=[[49] [51]]
   Set 后 a="99" len=3
~~~

**A-15 VisitAll 顺序 vs 到达顺序**
~~~text
E. VisitAll 顺序：Host=h | Z-Last=1 | A-First=2
   VisitAllInOrder 顺序：Z-Last=1 | Host=h | A-First=2
~~~

**A-16 Set / Add 语义**
~~~text
Add 两次: rows=[Content-Type=... X-C=1 X-C=2] Peek="1" PeekAll=[[49] [50]]
再 Set 一次: rows=[Content-Type=... X-C=9 X-C=2] Peek="9" PeekAll=[[57] [50]]
（Set 只覆盖第一个匹配，后面的 Add 值留着）
1. Set X-A=1 / Add X-A=2 / Add X-A=3 / Set X-A=9
   → Peek="9" PeekAll=[[57] [50] [51]]，VisitAll 出三条
~~~

**A-17 204 / 304 的 Content-Length**
~~~text
1. 204 响应（handler 里设了 CL=100 + 100 字节 body）:
"HTTP/1.1 204 No Content\r\nServer: fasthttp\r\nDate: ...\r\n\r\n"   ← CL 和 body 都没了
2. 304 响应:
"HTTP/1.1 304 Not Modified\r\nServer: fasthttp\r\nDate: ...\r\n\r\n"
~~~

**A-18 absolute-form URI**
~~~text
"orig=[http://example.com/x/y?q=1] norm=[/x/y] qs=[q=1] host=[example.com]"
（请求头是 Host: other，但 URI 里的 host 优先）
~~~

**A-19 路径规范化 + 百分号解码**
~~~text
"orig=[/a//b/../c/./d%41?x=1&y=2] norm=[/a/c/dA] qs=[x=1&y=2] host=[h]"
~~~

**A-20 Cookie 序列化**
~~~text
Set-Cookie: sid=abc; path=/; HttpOnly; SameSite=Lax
k=v; max-age=3600; secure          （ParseBytes 后重序列化）
7. Cookie 序列化: "k=v; max-age=60; domain=e.com; path=/; HttpOnly; secure; SameSite=None; Partitioned"
~~~

**A-21 keep-alive 三种关闭**
~~~text
4. MaxRequestsPerConn=1 响应头:
HTTP/1.1 200 OK / Server: fasthttp / Date: ... / Content-Length: 2 / Connection: close
5. handler 内 SetConnectionClose 后: ... Connection: close
6. DisableKeepalive: ... Connection: close
（MaxRequestsPerConn=2 时：响应数=2，含 Connection: close=true）
~~~

**A-22 请求/响应细节**
~~~text
A. Connection: close（请求带）→ 响应带 Connection: close
B. HTTP/1.0 无 keep-alive  → 响应带 Connection: close
C. HTTP/1.0 + keep-alive   → 响应带 Connection: keep-alive
F. HEAD 请求 → 有 Content-Length: 4，但 body 不发送
N. POST 无 CL 无 TE → 服务端按 len=0 处理，连接保持
P. Expect: 100-continue → 先 "HTTP/1.1 100 Continue\r\n\r\n" 再 200
~~~

**A-23 超时与配额**
~~~text
G. ReadTimeout=300ms，连上不发数据：耗时 300ms
   "HTTP/1.1 408 Request Timeout ... Connection: close ... Request timeout"
H. IdleTimeout=300ms keep-alive：第一个响应正常，空闲后读到 err=EOF（不发响应）
E. Concurrency=1 第二条连接："HTTP/1.1 503 Service Unavailable\r\n"
F. MaxConnsPerIP=1 第二条连接："HTTP/1.1 429 Too Many Requests\r\n"
~~~

**A-24 Go 协程代价**
~~~text
A. Go: 20 万次 go+Wait = 47.02243ms (avg 235ns)
B. Go: 1 万个阻塞 goroutine 堆占用 ≈ 5912 KB (每个≈605 B)
~~~

**A-25 workerPool 只有服务端用**
~~~text
$ grep -rn 'workerPool{' --include='*.go' .
server.go:2124:	wp := &workerPool{
workerpool_test.go:39 / :84        （测试）
对照：客户端连接池是 HostClient.conns（client.go:1031-1033）
~~~

**A-26 三种错误响应**
~~~text
坏 header:    "HTTP/1.1 400 Bad Request ... Connection: close ... Error when parsing request"
超大 header:  "HTTP/1.1 431 Request Header Fields Too Large ... Too big request header"
读超时:       "HTTP/1.1 408 Request Timeout ... Request timeout"
自定义 ErrorHandler 可完全替换 body（实测成功）
~~~

**A-27 handler panic 不恢复**
~~~text
panic: boom
goroutine 11 [running]:
main.main.func2.2(...)
	.../main.go:48 +0x25
github.com/valyala/fasthttp.(*Server).serveConnCounted(...)
	.../ref/fasthttp/server.go:2841 +0x13d4
（server.go:2841 就是 s.Handler(ctx)）
~~~

**A-28 HTTP/2 preface**
~~~text
=== K. HTTP/2 preface (=PRI * HTTP/2.0) ===
"HTTP/1.1 400 Bad Request ... Connection: close ... Error when parsing request"
stderr: invalid request uri "*" in "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
~~~

**A-29 仓颉 spawn 代价 + TCP 服务端可行性**
~~~text
A. Cangjie: spawn+get 2万次 = 19ms957us298ns (avg 997ns)
B. Cangjie: 500 并发线程 = 2ms284us191ns
（对比 Go: 235ns / 次 —— 仓颉慢约 4 倍；但两者都是协程，见 §10.2(a) 的线程数实测）

仓颉 TCP echo 服务端验证（能跑通）：
B. bind port = 42365
C. echo bytes = 11 body = hello world
D. default readTimeout = None
~~~

**A-30 chunked 请求 / 流式响应**
~~~text
D. chunked 请求 "5\r\nhello\r\n0\r\n\r\n" → 响应 "Content-Length: 5\r\n\r\nhello"（已解码）
E. SetBodyStream(..., -1) → "Transfer-Encoding: chunked\r\n\r\nd\r\nstreamed-data\r\n0\r\n\r\n"
~~~

**A-31 CL+TE 走私防护**
~~~text
G. 重复 Content-Length → 400
G2. CL + TE 同时存在 → 200 但 Connection: close（响应正常，连接关掉）
8. Transfer-Encoding: gzip → 400（不支持）
9. 非法方法 "GE T" → 400
10. GetOnly + POST → 400
~~~

**A-32 MaxRequestBodySize 超限**
~~~text
MaxRequestBodySize=4，CL=10 → "HTTP/1.1 400 Bad Request ... Error when parsing request"
stderr: fasthttp: body size exceeds the given limit
~~~

**A-33 空 body GET 的响应头**
~~~text
T. "HTTP/1.1 200 OK\r\nServer: fasthttp\r\nDate: ...\r\nContent-Length: 0\r\n\r\n"
（注意：没有 Content-Type）
~~~

**A-34 与仓颉标准库 API 的核验**
~~~text
- std.net.TcpServerSocket：有 accept() / accept(timeout!) / bind() / localAddress
- std.net.TcpSocket：有 readTimeout/writeTimeout/noDelay/keepAlive/connect/read/write，
  没有 writev
- std.sync：有 AtomicInt64/AtomicReference/AtomicBool/Mutex/Barrier/spawn/Future
- std.core：acquireArrayRawData<T>(Array<T>): CPointerHandle<T> where T <: CType
  （unsafe，两份文档都强调"之间仅可包含简单的 foreign C 函数调用"）
- 没找到：epoll/selector、writev、Array<Byte> -> String 零拷贝视图
~~~

---

## 附录 B：file:line 索引

### server.go
| 内容 | 行 |
|---|---|
| `type Server struct` | 157 |
| `Handler`（含"不 recover panic"注释） | 173-176 |
| `ErrorHandler` | 187 |
| `Concurrency` / `ReadBufferSize` / `WriteBufferSize` | 280 / 289 / 294 |
| `ReadTimeout` / `WriteTimeout` / `IdleTimeout` | 302 / 309 / 314 |
| `MaxConnsPerIP` / `MaxRequestsPerConn` | 320 / 328 |
| `MaxRequestBodySize` | 351 |
| `DisableKeepalive` / `ReduceMemoryUsage` / `GetOnly` | 376 / 393 / 413 |
| `DisableHeaderNamesNormalizing` / `CloseOnShutdown` / `StreamRequestBody` | 457 / 490 / 499 |
| `TimeoutWithCodeHandler` | 520 |
| `type RequestCtx struct` | 649 |
| `EarlyHints` | 713 |
| `Hijack` / `HijackSetNoResponse` | 805 / 814 |
| `SetReadDeadline` / `SetWriteDeadline` | 950 / 968 |
| `RequestCtx.reset` | 985 |
| `type RequestHandler` / `ServeHandler` / `HijackHandler` | 143 / 146 / 771 |
| `NextProto` / `getNextProto` | 1861 / 1871 |
| `ListenAndServe` | 1899 |
| `DefaultConcurrency = 256*1024` | 2104 |
| `Serve` | 2109 |
| `wp := &workerPool` | 2124 |
| `wp.Serve(c)` | 2152 |
| `Shutdown` / `ShutdownWithContext` | 2187 / 2205 |
| `acceptConn` | 2256 |
| `wrapPerIPConn` | 2290 |
| `rejectConn` | 2315 |
| `ServeConn` | 2358 |
| `tryAcquireConcurrency` | 2390 |
| `getConcurrencyCh` | 2445 |
| `DefaultMaxRequestBodySize = 4MB` | 2462 |
| `maxUnreadStreamBodySize = 256KB` | 2468 |
| `idleTimeout` | 2470 |
| `serveConn` / `serveConnCounted` | 2484 / 2488 |
| 主循环 `for {` | 2565 |
| 首请求 ReadTimeout | 2570 |
| keep-alive IdleTimeout | 2577 |
| `br = acquireReader` | 2588 |
| `br.Peek(1)` | 2595 |
| `acquireByteReader` | 2606 |
| `readLoop(br, false)` + flush | 2650 / 2652 |
| `parseURI` + 错误响应 | 2688 / 2689 |
| `readBodyStream` / `readLimitBody` | 2697 / 2699 |
| 错误收口块 | 2711-2736 |
| `MayContinue` | 2740 |
| `strResponseContinue` 写入 + flush | 2770 / 2774 |
| `ContinueReadBody` | 2787 |
| `connectionClose = req.Header...` | 2806 |
| `isHTTP11 = ...` | 2810 |
| `s.Handler(ctx)` | 2841 |
| `ctx.IsHead()` → SkipBody | 2875 |
| WriteTimeout | 2884 |
| connectionClose 六源或 | 2905-2913 |
| `SetConnectionClose` | 2928 |
| HTTP/1.0 keep-alive | 2933 |
| `noHTTP11 = true` | 2938 |
| `writeResponse` | 2949 |
| flush 条件 | 2964 |
| 流式 body 抽干 | 2975-2981 |
| hijack 收尾 | 2987-3012 |
| `releaseRequestStream` | 3018 |
| handler deadline 清理 | 3022-3045 |
| `setState(StateIdle)` | 3052 |
| `Request.Reset/Response.Reset` | 3055-3056 |
| `s.stop.Load() == 1` | 3063 |
| `setState` | 3096 |
| `hijackConnHandler` | 3102 |
| `writeResponse` | 3192 |
| `acquireByteReader` | 3206 |
| `acquireReader` / `releaseReader` | 3240 / 3254 |
| `acquireWriter` / `releaseWriter` | 3258 / 3272 |
| `acquireCtx` | 3276 |
| `RequestCtx.Done` | 3358 |
| `releaseCtx` | 3430 |
| `getServerNameLine` / `getServerName` | 3447 / 3465 |
| `writeFastError` | 3475 |
| `defaultErrorHandler` | 3498 |
| `writeErrorResponse` | 3508 |
| `closeIdleConns` | 3533 |

### header.go / headerscanner.go / swar.go
| 内容 | 行 |
|---|---|
| `type header struct` | 21 |
| `blockTerminated` | 60 |
| `type ResponseHeader` / `type RequestHeader` | 76 / 103 |
| `ConnectionClose` / `SetConnectionClose` | 196 / 201 |
| `mustSkipContentLength` / `mustSkipContentLengthOnWire` | 305 / 331 |
| `SetContentLength`（响应/请求） | 288 / 339 |
| `ignoreBody` | 3343 |
| `RequestHeader.Reset` / `resetSkipNormalize` | 1472 / 1479 |
| `All`（请求头顺序） | 1764-1787 |
| `AllInOrder`（重解析 rawHeaders） | 1788-1806 |
| `setSpecialHeader`（响应/请求） | 1899 / 1999 |
| `setNonSpecial` | 1970 |
| `Set`（响应/请求） | 2138 / 2370 |
| `SetCanonical`（响应/请求） | 2194 / 2426 |
| `Peek`（响应/请求） | 2439 / 2470 |
| `peek`（响应/请求） | 2496 / 2523 |
| `peekSections` | 725 |
| `PeekAll` / `peekAll` | 2559 / 2564 |
| `RequestHeader.Read` / `readLoop` / `tryRead` | 2883 / 2890 / 2906 |
| `validate`（HTTP/1.1 必须有 Host） | 2968 |
| `updateServerDate` / `refreshServerDate` / `serverDateLineFor` / `coarseSecond` | 3001 / 3017 / 3025 / 3032 |
| `ResponseHeader.serialize`（写 bufio 空闲区） | 3045 |
| `writeTrailer` | 3077 |
| `ResponseHeader.AppendBytes` | 3121 |
| `RequestHeader.Write` | 3210 |
| `RequestHeader.AppendBytes` | 3270 |
| `RequestHeader.parse` | 3347 |
| `parseFirstLine` | 3535 |
| `validateRequestURI` | 3611 |
| `parseHeaders` | 3783 |
| `collectCookies` | 3955 |
| `nextLine` | 4067 |
| `initHeaderKV` | 4079 |
| `getHeaderKeyBytes` | 4096 |
| `normalizeHeaderKey` / `normalizeHeaderKeyValidated` | 4102 / 4118 |
| `mustPeekBuffered` / `mustDiscard` | 4259 / 4267 |
| `skipCleanWords` / `validHeaderFieldByte` | 953 / 962 |
| headerScanner.next | headerscanner.go:41 |
| blockComplete | headerscanner.go:157 |
| nextFolded | headerscanner.go:190 |
| secureRaw | headerscanner.go:297 |
| scanValueLine（SWAR） | headerscanner.go:359 |
| scanHeaderKey | headerscanner.go:402 |
| loadWord / anyByteIsCTL / lowercaseWord | swar.go:18 / 48 / 60 |

### http.go / args.go / uri.go / cookie.go / workerpool.go / 其它
| 内容 | 行 |
|---|---|
| `type Request struct` / `type Response struct` | http.go:39 / 127 |
| `vec [2][]byte`（writev 内联） | http.go:144 |
| `parsedURI/parsedPostArgs/uriParseErr` | http.go:65-67 |
| `SetBodySizePoolLimit` | http.go:28 |
| `bodyBuffer`（响应/请求） | http.go:575 / 583 |
| `requestBodyPool` / `responseBodyPool` | http.go:589-592 |
| `parseURI` / `parsePostArgs` | http.go:1220 / 1236 |
| `Request.Reset` / `Response.Reset` | http.go:1503 / 1542 |
| `readLimitBody` | http.go:1618 |
| `readBodyStream` | http.go:1636 |
| `MayContinue` | http.go:1666 |
| `ContinueReadBody` | http.go:1678 |
| `ReadBody` | http.go:1733 |
| `mustSkipBody` | http.go:1929 |
| `Response.write` | http.go:2550 |
| `writeVectored` | http.go:2594 |
| `vectorWriter` | http.go:2613 |
| `writeBodyStream`（recover） | http.go:2677 |
| `readBody` / `readBodyWithStreaming` / `readBodyIdentity` | http.go:3262 / 3271 / 3298 |
| `appendBodyFixedSize` | http.go:3332 |
| `readBodyChunked` / `parseChunkSize` | http.go:3370 / 3402 |
| `type Args struct` / `type argsKV struct` | args.go:45 / 52 |
| `ParseBytes` | args.go:110 |
| `Has` / `Peek` / `PeekMulti` | args.go:310 / 281 / 294 |
| `delAllArgs` / `setArgBytes` | args.go:433 / 445 |
| `appendArgNormalized` | args.go:472 |
| `allocArg` | args.go:509 |
| `peekArgBytes` | args.go:535 |
| `argsScanner.next` | args.go:559 |
| `decodeArgAppendAt` / `decodeArgAppendNoPlus` | args.go:632 / 672 |
| `type URI struct` | uri.go:42 |
| `maxMemoizedHostLen = 256` | uri.go:285 |
| `URI.parse` | uri.go:299 |
| `parseHost` | uri.go:480 |
| `removeSegments` / `removeParentSegments` | uri.go:699 / 724 |
| `normalizePath` / `removeDotSegments` | uri.go:745 / 772 |
| `RequestURI` / `requestURIBytes` | uri.go:820 / 827 |
| `splitHostURI` | uri.go:1031 |
| `QueryArgs` / `parseQueryArgs`（惰性） | uri.go:1065 / 1070 |
| `stringContainsCTLByte` | uri.go:1080 |
| `type Cookie struct` | cookie.go:34 |
| `AppendBytes` | cookie.go:290 |
| `ParseBytes` | cookie.go:395 |
| `cookieScanner` | cookie.go:597 |
| `type workerPool` | workerpool.go:17 |
| `Start` / `Stop` | workerpool.go:49 / 74 |
| `clean`（二分找 LRU） | workerpool.go:102 |
| `Serve` / `getCh` / `release` | workerpool.go:148 / 171 / 204 |
| `workerFunc` | workerpool.go:216 |
| `workerChanCap` | workerpool.go:157 |
| `CoarseTimeNow`（已废弃） | coarsetime.go:11 |
| `b2s` / `s2b` | b2s.go:7 / s2b.go:6 |
| `noCopy` | nocopy.go:8 |
| `strResponseContinue` | strings.go:32 |
| `formatStatusLine` | status.go:176 |
| `perIPConnCounter` / `perIPConn.Close` | peripconn.go:15 / 81 |
| `type RequestCtx` / `Done` / `reset` | server.go:649 / 3358 / 985 |
