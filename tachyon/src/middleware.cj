package ystyle::tachyon

import std.time.MonoTime
import std.core.*
import std.collection.ArrayList

/**
 * 中间件。
 *
 * 与 fasthttp 的设计差异：fasthttp 没有内置的中间件概念（用 Handler 包装函数手写），
 * 这里提供显式的 Middleware 类型 + Use() 组合，因为 tang 这类框架需要它。
 * 组合顺序：use(a); use(b) -> a(b(handler))，即先注册的在外层。
 */
public type Middleware = (RequestHandler) -> RequestHandler

/** 把一串中间件应用到 handler 上（左到右，先注册的先执行） */
public func compose(handler: RequestHandler, mws: ArrayList<Middleware>): RequestHandler {
    var h = handler
    var i = mws.size - 1
    while (i >= 0) {
        h = mws[i](h)
        i -= 1
    }
    return h
}

// ============ 内置中间件（全部零依赖，不碰 stdx） ============

/**
 * Access log。
 *
 * 输出格式（对齐 fasthttp 的 accesslog 中间件）：
 *   <ip> - - [<date>] "<method> <path> <proto>" <status> <bytes> <duration>
 *
 * 注意：这里用 println 直接写 stdout。生产环境应替换成自己的 logger。
 */
public func accessLog(): Middleware {
    return { next: RequestHandler =>
        { ctx: RequestCtx =>
            let t0 = MonoTime.now()
            next(ctx)
            let dur = MonoTime.now() - t0
            let ip = match (ctx.remoteAddr) {
                case Some(a) => a.toString()
                case None => "-"
            }
            let line = ip + " \"" + ctx.method().toStr() + " " + ctx.path().toStr() + " " + ctx.req.protocol.toStr() +
                "\" " + ctx.statusCode().toString() + " " + ctx.responseBodyLen().toString() + " " + dur.toString()
            println(line)
        }
    }
}

/**
 * Recovery：捕获 handler 抛出的异常，转成 500。
 *
 * ⚠️ 与 fasthttp 的默认行为**相反**：fasthttp 默认不 recover（panic 会崩掉整个服务）。
 * 这里做成显式中间件，用不用由使用者决定。默认不装。
 */
public func recovery(): Middleware {
    return { next: RequestHandler =>
        { ctx: RequestCtx =>
            try {
                next(ctx)
            } catch (e: Exception) {
                ctx.resp.reset()
                ctx.setStatusCode(500)
                ctx.setContentType("text/plain; charset=utf-8")
                ctx.setBodyString("Internal Server Error")
                ctx.setConnectionClose()
            }
        }
    }
}

/** 给每个响应加一个请求 ID（优先沿用客户端传的 X-Request-ID） */
public func requestID(): Middleware {
    return { next: RequestHandler =>
        { ctx: RequestCtx =>
            let existing = ctx.headerGet("X-Request-ID")
            if (!existing.isEmpty()) {
                ctx.setHeader("X-Request-ID", existing.toStr())
            } else {
                ctx.setHeader("X-Request-ID", nextRequestID())
            }
            next(ctx)
        }
    }
}

var reqIdSeq: Int64 = 0

func nextRequestID(): String {
    reqIdSeq += 1
    return "tcy-" + reqIdSeq.toString()
}

/**
 * CORS。
 *
 * allowOrigins 为空表示 "*"（允许所有来源）。生产环境应显式列出。
 */
public func cors(allowOrigins: Array<String>, allowMethods: String, allowHeaders: String): Middleware {
    let originList = allowOrigins
    return { next: RequestHandler =>
        { ctx: RequestCtx =>
            let origin = ctx.headerGet("Origin")
            var allow = ""
            if (originList.size == 0) {
                allow = "*"
            } else {
                let o = origin.toStr()
                var i: Int64 = 0
                while (i < originList.size) {
                    if (originList[i] == o) {
                        allow = o
                        break
                    }
                    i += 1
                }
            }
            if (allow.size > 0) {
                ctx.setHeader("Access-Control-Allow-Origin", allow)
                ctx.setHeader("Access-Control-Allow-Methods", allowMethods)
                ctx.setHeader("Access-Control-Allow-Headers", allowHeaders)
                ctx.setHeader("Access-Control-Max-Age", "86400")
            }
            // 预检请求直接回 204
            if (ctx.isOptions() && !origin.isEmpty()) {
                ctx.setStatusCode(204)
                return
            }
            next(ctx)
        }
    }
}

/** 简单的 body 大小限制（超过返回 413） */
public func bodyLimit(maxBytes: Int64): Middleware {
    return { next: RequestHandler =>
        { ctx: RequestCtx =>
            if (ctx.req.contentLength > maxBytes) {
                ctx.setStatusCode(413)
                ctx.setContentType("text/plain; charset=utf-8")
                ctx.setBodyString("Payload Too Large")
                ctx.setConnectionClose()
                return
            }
            next(ctx)
        }
    }
}
