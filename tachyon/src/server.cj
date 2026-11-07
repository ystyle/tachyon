package ystyle::tachyon

import std.net.{TcpServerSocket, TcpSocket}
import std.sync.{SyncCounter, AtomicBool, AtomicInt64, Mutex}
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
        serveInternal(srv)
    }

    public func serve(srv: TcpServerSocket): Unit {
        listener = srv
        serveInternal(srv)
    }

    func serveInternal(srv: TcpServerSocket): Unit {
        while (!stopping.load()) {
            let conn = try {
                srv.accept()
            } catch (e: Exception) {
                // close() 打断 accept 会抛 SocketException —— 这是正常的关闭路径
                break
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
                }
            }
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
        let reader = BufferedReader(readBufferSize)
        let writer = BufferedWriter(writeBufferSize)
        let ctx = RequestCtx(4096)
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
            ctx.resp.skipBody = ctx.req.isHead
            let written = ctx.resp.serialize(writer, name, dateCache.line())
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
            // chunked：先不支持，按 400 处理（P3 再实现）
            let err = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            try {
                conn.write(err.toArray())
            } catch (e: Exception) {}
            return false
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
