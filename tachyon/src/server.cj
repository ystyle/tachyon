package ystyle::tachyon

import std.net.{TcpServerSocket, TcpSocket}
import std.sync.{SyncCounter, AtomicBool, AtomicInt64, Mutex, Semaphore}
import std.collection.HashMap
import std.time.MonoTime

/**
 * tachyon 服务端。
 *
 * 并发模型：每连接一个协程。
 * 实测依据（见设计文档 §2.2）：仓颉 spawn 是 M:N 协程，20000 条阻塞在 read 上的
 * 连接只占 14 个内核线程、每协程约 13 KB —— 不需要 worker 池，也不需要 event loop。
 *
 * 与 fasthttp 的差异：没有 workerPool，并发上限用 Semaphore 语义（拿不到就 503）。
 */
public class Server {
    let handler: RequestHandler
    let dateCache: DateCache = DateCache()

    // ---- 配置 ----
    public var name: String = "tachyon"
    public var concurrency: Int64 = 16384
    public var readBufferSize: Int64 = 4096
    public var writeBufferSize: Int64 = 8192
    public var readTimeout: ?Duration = None
    public var writeTimeout: ?Duration = None
    public var idleTimeout: ?Duration = None
    public var maxRequestBodySize: Int64 = 4 * 1024 * 1024
    public var maxConnsPerIP: Int64 = 0
    public var disableKeepalive: Bool = false
    public var reduceMemoryUsage: Bool = true
    public var getOnly: Bool = false
    public var noDefaultContentType: Bool = false
    public var noDefaultDate: Bool = false

    // ---- 运行时状态 ----
    var stopping: AtomicBool = AtomicBool(false)
    var openConns: AtomicInt64 = AtomicInt64(0)
    var listener: ?TcpServerSocket = None
    var connIdSeq: AtomicInt64 = AtomicInt64(0)
    let connLock: Mutex = Mutex()

    // 并发连接上限：拿不到名额回 503 并关连接（照搬 fasthttp server.go:2152-2164）。
    // 不排队 —— 排队会把延迟打满，快速失败让客户端有机会重试别的实例。
    var connSem: ?Semaphore = None
    // per-IP 并发连接计数（maxConnsPerIP > 0 时生效）
    let perIPLock: Mutex = Mutex()
    let perIPCounts: HashMap<String, Int64> = HashMap<String, Int64>()

    // 连接级对象池（reader/writer/ctx 都会跨连接复用，避免每连接重新分配）
    // 池在 initLimiter 时按 readBufferSize / writeBufferSize 创建（配置必须在建池前定好）
    var readerPool: ?ObjectPool<BufferedReader> = None
    var writerPool: ?ObjectPool<BufferedWriter> = None
    var ctxPool: ?ObjectPool<RequestCtx> = None

    public init(handler: RequestHandler) {
        this.handler = handler
        this.dateCache.start()
    }

    public func listenAndServe(host: String, port: UInt16): Unit {
        let srv = TcpServerSocket(bindAt: port)
        srv.reuseAddress = true
        srv.backlogSize = 4096
        srv.bind()
        listener = srv
        initLimiter()
        serveInternal(srv)
    }

    public func serve(srv: TcpServerSocket): Unit {
        listener = srv
        initLimiter()
        serveInternal(srv)
    }

    func initLimiter(): Unit {
        if (concurrency > 0) {
            connSem = Some(Semaphore(concurrency))
        }
        // 按配置建池：readBufferSize / writeBufferSize 在这里才真正生效
        let slotCount: Int64 = if (concurrency > 0) { concurrency / 64 + 1 } else { 64 }
        readerPool = Some(ObjectPool<BufferedReader>(slotCount, 32, { => BufferedReader(readBufferSize) }))
        writerPool = Some(ObjectPool<BufferedWriter>(slotCount, 32, { => BufferedWriter(writeBufferSize) }))
        ctxPool = Some(ObjectPool<RequestCtx>(slotCount, 32, { => RequestCtx(4096) }))
    }

    func serveInternal(srv: TcpServerSocket): Unit {
        while (!stopping.load()) {
            let conn = try {
                srv.accept()
            } catch (e: Exception) {
                // close() 打断 accept 会抛 SocketException —— 这是正常的关闭路径
                break
            }
            // 并发上限：满了立刻回 503 并关连接（照搬 fasthttp 语义，不阻塞 accept）
            var acquired = true
            match (connSem) {
                case Some(sem) =>
                    acquired = sem.tryAcquire()
                case None => ()
            }
            // per-IP 并发上限（fasthttp 的 MaxConnsPerIP 语义：超了回 429）
            let ipKey: String = if (maxConnsPerIP > 0) { ipOf(conn) } else { "" }
            if (maxConnsPerIP > 0) {
                var over = false
                synchronized(perIPLock) {
                    let cur = match (perIPCounts.get(ipKey)) {
                        case Some(v) => v
                        case None => 0
                    }
                    if (cur >= maxConnsPerIP) {
                        over = true
                    } else {
                        perIPCounts[ipKey] = cur + 1
                    }
                }
                if (over) {
                    try {
                        conn.write(("HTTP/1.1 429 Too Many Requests" + crlf() + "Content-Length: 0" + crlf() +
                            "Connection: close" + crlf() + crlf()).toArray())
                    } catch (e: Exception) {}
                    try {
                        conn.close()
                    } catch (e: Exception) {}
                    continue
                }
            }

            if (!acquired) {
                try {
                    conn.write("HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toArray())
                } catch (e: Exception) {}
                try {
                    conn.close()
                } catch (e: Exception) {}
                continue
            }
            openConns.fetchAdd(1)
            let id = UInt64(connIdSeq.fetchAdd(1))
            spawn {
                try {
                    perConnLoop(conn, id)
                } finally {
                    try {
                        conn.close()
                    } catch (e: Exception) {}
                    openConns.fetchSub(1)
                    match (connSem) {
                        case Some(sem) => sem.release()
                        case None => ()
                    }
                    if (maxConnsPerIP > 0 && ipKey.size > 0) {
                        synchronized(perIPLock) {
                            let cur = match (perIPCounts.get(ipKey)) {
                                case Some(v) => v
                                case None => 0
                            }
                            if (cur > 1) {
                                perIPCounts[ipKey] = cur - 1
                            } else {
                                perIPCounts.remove(ipKey)
                            }
                        }
                    }
                }
            }
        }
    }

    func takeReader(slot: Int64): BufferedReader {
        match (readerPool) {
            case Some(p) => return p.get(slot)
            case None => return BufferedReader(readBufferSize)
        }
    }

    func takeWriter(slot: Int64): BufferedWriter {
        match (writerPool) {
            case Some(p) => return p.get(slot)
            case None => return BufferedWriter(writeBufferSize)
        }
    }

    func takeCtx(slot: Int64): RequestCtx {
        match (ctxPool) {
            case Some(p) => return p.get(slot)
            case None => return RequestCtx(4096)
        }
    }

    func giveBackReader(slot: Int64, r: BufferedReader): Unit {
        match (readerPool) {
            case Some(p) => p.put(slot, r)
            case None => ()
        }
    }

    func giveBackWriter(slot: Int64, w: BufferedWriter): Unit {
        match (writerPool) {
            case Some(p) => p.put(slot, w)
            case None => ()
        }
    }

    func giveBackCtx(slot: Int64, c: RequestCtx): Unit {
        match (ctxPool) {
            case Some(p) => p.put(slot, c)
            case None => ()
        }
    }

    public func shutdown(): Unit {
        stopping.store(true)
        match (listener) {
            case Some(s) =>
                try {
                    s.close()
                } catch (e: Exception) {}
            case None => ()
        }
    }

    /** 等所有连接结束，最多等 timeout */
    public func shutdownGracefully(timeout: Duration): Unit {
        shutdown()
        let deadline = MonoTime.now() + timeout
        while (openConns.load() > 0 && MonoTime.now() < deadline) {
            sleep(Duration.millisecond * 10)
        }
    }

    func perConnLoop(conn: TcpSocket, connId: UInt64): Unit {
        let slot = Int64(connId % 64)
        let reader = takeReader(slot)
        let writer = takeWriter(slot)
        let ctx = takeCtx(slot)
        ctx.connID = connId
        ctx.remoteAddr = try {
            conn.remoteAddress
        } catch (e: Exception) {
            None
        }
        ctx.resp.noDefaultContentType = noDefaultContentType
        ctx.resp.noDefaultDate = noDefaultDate

        var alive = true
        while (alive && !stopping.load()) {
            // ---- 1. 找到完整 header block ----
            var headerEnd: Int64 = -1
            while (true) {
                headerEnd = reader.findHeaderEnd()
                if (headerEnd >= 0) {
                    break
                }
                // header 太大
                if (reader.buffered() >= reader.buf.size) {
                    let err = "HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    writer.writeString(err)
                    writer.flush(conn)
                    return
                }
                // 设置读超时
                var to: ?Duration = readTimeout
                if (reader.buffered() == 0 && ctx.connRequestNum > 0) {
                    match (idleTimeout) {
                        case Some(d) => to = d
                        case None => to = readTimeout
                    }
                }
                match (to) {
                    case Some(d) => conn.readTimeout = d
                    case None => conn.readTimeout = None
                }
                let n = reader.fill(conn)
                if (n == -2) {
                    let err = "HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    writer.writeString(err)
                    writer.flush(conn)
                    return
                }
                if (n < 0) {
                    return
                }
                if (n == 0) {
                    // EOF
                    return
                }
            }

            // ---- 2. 解析请求 ----
            let blockStart = reader.r
            let ok = try {
                ctx.req.parseHeaders(reader.buf, blockStart, blockStart + headerEnd)
            } catch (e: Exception) {
                false
            }
            if (!ok) {
                let err = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                writer.writeString(err)
                writer.flush(conn)
                return
            }

            // 消费 header 字节
            reader.discard(headerEnd)

            // getOnly：只服务 GET / HEAD（fasthttp 的 GetOnly 语义）
            if (getOnly && !ctx.req.isGet && !ctx.req.isHead) {
                let err = "HTTP/1.1 400 Bad Request" + crlf() + "Content-Length: 0" + crlf() + "Connection: close" + crlf() + crlf()
                writer.writeString(err)
                writer.flush(conn)
                return
            }

            // ---- 3. 读 body ----
            if (!readBody(conn, reader, ctx)) {
                return
            }

            // ---- 4. handler ----
            ctx.resp.reset()
            try {
                handler(ctx)
            } catch (e: Exception) {
                // 与 fasthttp 的"不吞异常"不同：仓颉协程内未捕获异常只打 stderr 不杀进程，
                // 这里仍然让连接断开，但保证进程继续服务（见设计文档 §7.6）
                ctx.resp.reset()
                ctx.resp.setStatusCode(500)
                ctx.resp.setContentType("text/plain; charset=utf-8")
                ctx.resp.setBodyString("Internal Server Error")
                ctx.resp.connectionClose = true
            }

            // ---- 5. keep-alive 判定（六源或，在 handler 之后）----
            var close = ctx.req.connectionClose || ctx.resp.connectionClose
            if (disableKeepalive) {
                close = true
            }
            if (!ctx.req.isHTTP11) {
                // HTTP/1.0 默认关
                if (!close) {
                    close = true
                }
            }
            if (close) {
                ctx.resp.connectionClose = true
            }

            // ---- 6. 写响应 ----
            match (writeTimeout) {
                case Some(d) => conn.writeTimeout = d
                case None => conn.writeTimeout = None
            }
            ctx.resp.skipBody = ctx.req.isHead
            let written = ctx.resp.serialize(writer, name, dateCache.line(), dateCache.lineLen())
            if (written < 0) {
                // 写缓冲装不下：直接 flush 后回 500（极端情况）
                let err = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                writer.writeString(err)
                writer.flush(conn)
                return
            }
            if (!writer.flush(conn)) {
                return
            }

            if (close) {
                alive = false
            }

            // ---- 7. 复位 ----
            ctx.reset()
        }
        // 连接结束：把对象还给池（reduceMemoryUsage 时缓冲也归零，避免钉住大块内存）
        if (reduceMemoryUsage) {
            reader.r = 0
            reader.w = 0
            writer.reset()
        }
        giveBackReader(slot, reader)
        giveBackWriter(slot, writer)
        giveBackCtx(slot, ctx)
    }

    /** 读 body；成功返回 true，失败返回 false（连接应关闭） */
    func readBody(conn: TcpSocket, reader: BufferedReader, ctx: RequestCtx): Bool {
        let cl = ctx.req.contentLength
        if (cl == 0 || cl == -2) {
            ctx.req.body = Bytes.empty()
            return true
        }
        if (cl > maxRequestBodySize) {
            let err = "HTTP/1.1 413 Payload Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            try {
                conn.write(err.toArray())
            } catch (e: Exception) {}
            return false
        }
        if (cl == -1) {
            // chunked transfer-encoding（RFC 9112 §7.1）
            let out = Array<Byte>(maxRequestBodySize, repeat: 0)
            let cr = ChunkedReader()
            let n = try {
                cr.readBody(conn, reader, out, maxRequestBodySize)
            } catch (e: Exception) {
                -1
            }
            if (n < 0) {
                let err = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                try {
                    conn.write(err.toArray())
                } catch (e: Exception) {}
                return false
            }
            ctx.req.body = Bytes(out, 0, n)
            return true
        }

        // 定长：先把缓冲里已有的拷出来，再继续读
        let buf = Array<Byte>(cl, repeat: 0)
        var got: Int64 = 0
        let avail = reader.buffered()
        if (avail > 0) {
            let take = if (avail < cl) { avail } else { cl }
            let view = reader.available()
            var i: Int64 = 0
            while (i < take) {
                buf[i] = view[i]
                i += 1
            }
            got = take
            reader.discard(take)
        }
        while (got < cl) {
            let n = try {
                conn.read(buf[got..cl])
            } catch (e: Exception) {
                -1
            }
            if (n <= 0) {
                return false
            }
            got += n
        }
        ctx.req.body = Bytes(buf)
        return true
    }
}
/** 取连接的远端 IP（不含端口），用于 per-IP 计数 */
func ipOf(conn: TcpSocket): String {
    try {
        let addr = conn.remoteAddress
        let s = addr.toString()
        // "127.0.0.1:54321" -> "127.0.0.1"
        let i = match (s.lastIndexOf(":")) {
            case Some(v) => v
            case None => -1
        }
        if (i > 0) {
            return s[0..i]
        }
        return s
    } catch (e: Exception) {
        return ""
    }
}
