package ystyle::tachyon

import std.collection.ArrayList

/**
 * 脱离真实连接的请求/响应快照。
 *
 * 用途：让 tachyon 的 RequestCtx / handler 链能在**不是 tachyon 自己收包**的场景下复用，
 * 例如把 tang 跑在 stdx.net.http 的 Server 之上（stdx 收包 → 填 DetachedRequest →
 * 跑 tang 的路由与中间件 → 把 snapshotResponse 的结果写回 stdx 的响应）。
 *
 * 这条路是必要的：stdx 的 `HttpContext` 构造器是 internal，外部无法伪造一个，
 * 所以想复用「以 stdx HttpContext 为参数」的 handler，只能反过来跑在 stdx 的 server 上。
 */
public class DetachedRequest {
    /// 方法，如 "GET"
    public var method: String = "GET"
    /// request-target（含 query），如 "/a/b?x=1"
    public var target: String = "/"
    /// Host 头
    public var host: String = ""
    /// 其余请求头（顺序保留）
    public var headers: ArrayList<(String, String)> = ArrayList<(String, String)>()
    /// 请求体
    public var body: Array<Byte> = Array<Byte>(0, repeat: 0)

    public init() {}
}

/// 响应快照（handler 写进 ctx 的结果）
public class DetachedResponse {
    public var statusCode: UInt16 = 200
    /// 用户设置的头（不含 Content-Length / Date / Server 这些默认头）
    public var headers: ArrayList<(String, String)> = ArrayList<(String, String)>()
    public var body: Array<Byte> = Array<Byte>(0, repeat: 0)

    public init() {}
}

/// 用快照构造一个不绑定 socket 的 RequestCtx
public func newDetachedCtx(r: DetachedRequest): RequestCtx {
    let ctx = RequestCtx(4096)
    let req = ctx.req
    req.method = Bytes(r.method.toArray())
    req.isGet = req.method.equals(Bytes("GET".toArray()))
    req.isHead = req.method.equals(Bytes("HEAD".toArray()))
    req.isHTTP11 = true
    req.requestURI = Bytes(r.target.toArray())
    req.uri.reset(req.requestURI)
    if (!r.host.isEmpty()) {
        req.header.host = req.header.copyIn(r.host.toArray(), 0, r.host.size)
    }
    for ((k, v) in r.headers) {
        req.header.add(
            req.header.copyIn(k.toArray(), 0, k.size),
            req.header.copyIn(v.toArray(), 0, v.size)
        )
    }
    if (r.body.size > 0) {
        req.body = Bytes(r.body)
        req.contentLength = r.body.size
    }
    return ctx
}

/// 读回 handler 写进 ctx 的响应
public func snapshotResponse(ctx: RequestCtx): DetachedResponse {
    let out = DetachedResponse()
    out.statusCode = ctx.resp.statusCode
    // 特殊头不在普通头表里，先补上（否则测试/适配器读不到 Content-Type）
    let ht = ctx.resp.header
    if (ht.contentTypeStr.size > 0) {
        out.headers.add(("Content-Type", ht.contentTypeStr))
    } else if (!ht.contentType.isEmpty()) {
        out.headers.add(("Content-Type", ht.contentType.toStr()))
    }
    let n = ht.count()
    var i: Int64 = 0
    while (i < n) {
        out.headers.add((ctx.resp.header.nameAt(i).toStr(), ctx.resp.header.valueAt(i).toStr()))
        i += 1
    }
    if (ctx.resp.bodyStr.size > 0) {
        out.body = ctx.resp.bodyStr.toArray()
    } else {
        out.body = ctx.resp.body.toArray()
    }
    return out
}
