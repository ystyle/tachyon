package ystyle::tachyon

import std.net.{SocketAddress, TcpSocket}
import std.io.InputStream
import std.collection.HashMap

/**
 * 请求上下文。每连接复用一个实例（reset 只截断不释放）。
 *
 * 与 fasthttp 一致：handler 返回后 ctx 会被复用，**不要把 ctx 或它的字节视图
 * 存到 handler 之外**。
 */
public class RequestCtx {
    var req: Request
    var resp: Response
    var remoteAddr: ?SocketAddress = None
    var connID: UInt64 = 0
    var connRequestNum: UInt64 = 0
    var readDeadline: ?Duration = None
    var writeDeadline: ?Duration = None
    var userValues: ?HashMap<String, Object> = None
    var hijackHandler: ?HijackHandler = None
    var postArgsParsed: Bool = false
    var postArgsView: ArgsView = ArgsView()
    var multipartParsed: Bool = false
    var multipartView: MultipartForm = MultipartForm()

    public init(headerCap: Int64) {
        req = Request(headerCap)
        resp = Response(headerCap)
    }

    internal func reset(): Unit {
        req.reset()
        resp.reset()
        connRequestNum += 1
        readDeadline = None
        writeDeadline = None
        hijackHandler = None
        postArgsParsed = false
        postArgsView.reset()
        multipartParsed = false
        multipartView.reset()
        match (userValues) {
            case Some(m) => m.clear()
            case None => ()
        }
    }

    /** 仅供测试/中间件构造请求头（生产代码不应调用） */
    public func setRequestHeaderInternal(name: String, value: String): Unit {
        req.header.add(
            req.header.copyIn(name.toArray(), 0, name.toArray().size),
            req.header.copyIn(value.toArray(), 0, value.toArray().size)
        )
    }

    /** 仅供测试：设置 content-length */
    public func setContentLengthInternal(n: Int64): Unit {
        req.contentLength = n
    }

    /** 仅供测试：设置方法 */
    public func setMethodInternal(m: String): Unit {
        req.method = Bytes(m.toArray())
        req.isGet = req.method.equals(Bytes("GET".toArray()))
        req.isHead = req.method.equals(Bytes("HEAD".toArray()))
    }

    // ---- 请求侧（只读视图）----
    public func method(): Bytes { return req.method }
    public func requestURI(): Bytes { return req.requestURI }
    public func path(): Bytes { return req.path() }
    public func queryArgs(): ArgsView { return req.queryArgs() }

    /**
     * POST 表单参数（application/x-www-form-urlencoded）。
     *
     * 惰性解析 body；Content-Type 不是表单格式时返回空。多部分表单（multipart）
     * 不支持 —— 那需要 stdx 或自己实现 boundary 解析，属于扩展范畴。
     */
    public func postArgs(): ArgsView {
        if (!postArgsParsed) {
            postArgsParsed = true
            let ct = req.header.contentType
            if (!ct.isEmpty() && ct.startsWith("application/x-www-form-urlencoded".toArray())) {
                postArgsView.parse(req.body)
            }
        }
        return postArgsView
    }

    /**
     * multipart/form-data 表单（惰性解析，对应 fasthttp 的 ctx.MultipartForm()）。
     * Content-Type 不是 multipart 时返回空表单。
     */
    public func multipartForm(): MultipartForm {
        if (!multipartParsed) {
            multipartParsed = true
            match (extractBoundary(req.header.contentType)) {
                case Some(b) =>
                    multipartView = parseMultipart(req.body, b)
                case None => ()
            }
        }
        return multipartView
    }

    /** 表单value（QueryArgs 优先于 PostArgs，对齐 fasthttp 的 FormValue 语义） */
    public func formValue(key: String): Bytes {
        let qv = queryArgs().get(key)
        if (!qv.isEmpty()) {
            return qv
        }
        return postArgs().get(key)
    }
    /** 远端地址（无连接信息时返回 None）。对应 fasthttp 的 RemoteAddr()。 */
    public func remoteAddress(): ?SocketAddress { return remoteAddr }

    public func host(): Bytes { return req.header.host }
    public func userAgent(): Bytes { return req.header.userAgent }
    public func body(): Bytes { return req.body }
    public func isTLS(): Bool { return false }
    public func isHTTP11(): Bool { return req.isHTTP11 }

    public func headerGet(name: String): Bytes {
        return req.headerGetStr(name)
    }

    /** 请求 Cookie（惰性解析 "Cookie: a=1; b=2"） */
    public func cookie(name: String): Bytes {
        let c = CookieView()
        c.reset(req.header.cookie)
        return c.get(name)
    }

    /** 追加一条 Set-Cookie */
    public func setCookie(b: SetCookieBuilder): Unit {
        addHeader("Set-Cookie", b.toString())
    }

    public func isGet(): Bool { return req.isGet }
    public func isHead(): Bool { return req.isHead }
    public func isPost(): Bool { return req.method.equals(Bytes("POST".toArray())) }
    public func isPut(): Bool { return req.method.equals(Bytes("PUT".toArray())) }
    public func isDelete(): Bool { return req.method.equals(Bytes("DELETE".toArray())) }
    public func isOptions(): Bool { return req.method.equals(Bytes("OPTIONS".toArray())) }

    // ---- 响应侧 ----
    public func setStatusCode(code: UInt16): Unit {
        resp.setStatusCode(code)
    }

    public func statusCode(): UInt16 {
        return resp.statusCode
    }

    /** 遍历所有请求头（含特殊头），回调返回 false 提前终止 */
    public func visitHeaders(f: (Bytes, Bytes) -> Bool): Unit {
        // 特殊头先访问（与 fasthttp 的 VisitAll 顺序一致）
        if (!req.header.host.isEmpty()) {
            if (!f(Bytes("Host".toArray()), req.header.host)) { return }
        }
        if (!req.header.contentLengthBytes.isEmpty()) {
            if (!f(Bytes("Content-Length".toArray()), req.header.contentLengthBytes)) { return }
        }
        if (!req.header.contentType.isEmpty()) {
            if (!f(Bytes("Content-Type".toArray()), req.header.contentType)) { return }
        }
        if (!req.header.userAgent.isEmpty()) {
            if (!f(Bytes("User-Agent".toArray()), req.header.userAgent)) { return }
        }
        if (!req.header.connection.isEmpty()) {
            if (!f(Bytes("Connection".toArray()), req.header.connection)) { return }
        }
        // 普通头按到达顺序
        var i: Int64 = 0
        let n = req.header.count()
        while (i < n) {
            if (!f(req.header.nameAt(i), req.header.valueAt(i))) {
                return
            }
            i += 1
        }
    }

    /** 读取响应头（中间件/测试用） */
    public func responseHeaderGet(name: String): Bytes {
        return resp.header.getIgnoreCase(Bytes(name.toArray()))
    }

    /** 响应 body 的字节数（access log 等中间件用） */
    public func responseBodyLen(): Int64 {
        return resp.bodyLength()
    }

    public func setContentType(ct: String): Unit {
        resp.setContentType(ct)
    }

    public func setHeader(name: String, value: String): Unit {
        // 支持覆盖：先找同名，找到就替换
        let nb = Bytes(name.toArray())
        var i: Int64 = 0
        let n = resp.header.count()
        while (i < n) {
            if (resp.header.nameAt(i).equalsAsciiIgnoreCase(nb)) {
                resp.header.values[i] = resp.header.copyIn(value.toArray(), 0, value.toArray().size)
                return
            }
            i += 1
        }
        resp.header.add(
            resp.header.copyIn(name.toArray(), 0, name.toArray().size),
            resp.header.copyIn(value.toArray(), 0, value.toArray().size)
        )
    }

    public func addHeader(name: String, value: String): Unit {
        resp.header.add(
            resp.header.copyIn(name.toArray(), 0, name.toArray().size),
            resp.header.copyIn(value.toArray(), 0, value.toArray().size)
        )
    }

    public func setBody(b: Bytes): Unit {
        resp.setBody(b)
    }

    public func setBodyString(s: String): Unit {
        resp.setBodyString(s)
    }

    public func setBodyArray(a: Array<Byte>): Unit {
        resp.setBody(Bytes(a))
    }

    /**
     * 对应 fasthttp 的 SetBodyStream。
     */
    public func setBodyStream(stream: InputStream, size: Int64): Unit {
        resp.setBodyStream(stream, size)
    }

    public func setConnectionClose(): Unit {
        resp.connectionClose = true
        req.connectionClose = true
    }

    public func success(contentType: String, b: Bytes): Unit {
        setStatusCode(200)
        setContentType(contentType)
        setBody(b)
    }

    public func successString(contentType: String, s: String): Unit {
        setStatusCode(200)
        setContentType(contentType)
        setBodyString(s)
    }

    public func error(msg: String, code: UInt16): Unit {
        setStatusCode(code)
        setContentType("text/plain; charset=utf-8")
        setBodyString(msg)
    }

    public func redirect(uri: String, code: UInt16): Unit {
        setStatusCode(code)
        setHeader("Location", uri)
    }

    /**
     * 劫持连接。调用后服务端**不再**为本次请求发送响应，连接交给你。
     *
     * 与 fasthttp 一致：handler 返回后连接由你负责关闭。
     */
    public func hijack(h: HijackHandler): Unit {
        hijackHandler = h
    }

    // ---- 逃生门 ----
    public func setReadDeadline(d: ?Duration): Unit { readDeadline = d }
    public func setWriteDeadline(d: ?Duration): Unit { writeDeadline = d }

    // ---- 用户数据 ----
    public func setUserValue(key: String, v: Object): Unit {
        match (userValues) {
            case Some(m) => m[key] = v
            case None =>
                let m = HashMap<String, Object>()
                m[key] = v
                userValues = m
        }
    }

    public func userValue(key: String): ?Object {
        match (userValues) {
            case Some(m) => return m.get(key)
            case None => return None
        }
    }
}

/** 劫持后的连接处理函数。返回后服务端不再接管这条连接。 */
public type HijackHandler = (HijackedConn) -> Unit

/**
 * 被劫持的连接。
 *
 * 与 fasthttp 的 ctx.Hijack(func(net.Conn)) 对应：拿到连接后由使用者自己读写，
 * 服务端不再发送响应、不再处理这个连接上的后续请求。
 *
 * 用途：协议升级（WebSocket 握手后自管帧层）、CONNECT 隧道、特殊协议。
 */
public class HijackedConn {
    public let socket: TcpSocket
    /** 已经读进缓冲但还没被消费的字节（劫持前客户端可能已经多发了数据） */
    public let pendingBytes: Bytes

    init(socket: TcpSocket, pendingBytes: Bytes) {
        this.socket = socket
        this.pendingBytes = pendingBytes
    }
}

public type RequestHandler = (RequestCtx) -> Unit