package ystyle::tachyon_tests

import ystyle::tachyon.*
import std.unittest.*
import std.unittest.testmacro.*
import std.collection.ArrayList
import std.core.*

@Test
class MiddlewareTest {
    func makeList(arr: Array<Middleware>): ArrayList<Middleware> {
        let l = ArrayList<Middleware>()
        for (m in arr) {
            l.add(m)
        }
        return l
    }

    func mkCtx(): RequestCtx {
        return RequestCtx(1024)
    }

    @TestCase
    func testComposeOrder(): Unit {
        // 先注册的在外层：a 的"before"先执行、a 的"after"后执行
        // 注意：仓颉里捕获可变局部变量的 lambda 不能当值传递，所以用 ArrayList 装箱（引用类型）
        let order = ArrayList<String>()
        let a: Middleware = { next => { ctx =>
            order.add("a-before"); next(ctx); order.add("a-after") } }
        let b: Middleware = { next => { ctx =>
            order.add("b-before"); next(ctx); order.add("b-after") } }
        let h: RequestHandler = { ctx => order.add("handler") }
        let composed = compose(h, makeList([a, b]))
        composed(mkCtx())
        @Expect(order.size, 5)
        @Expect(order[0], "a-before")
        @Expect(order[1], "b-before")
        @Expect(order[2], "handler")
        @Expect(order[3], "b-after")
        @Expect(order[4], "a-after")
    }

    @TestCase
    func testRecovery(): Unit {
        let h: RequestHandler = { ctx => throw Exception("boom") }
        let composed = compose(h, makeList([recovery()]))
        let ctx = mkCtx()
        composed(ctx)
        @Expect(ctx.statusCode(), UInt16(500))
    }

    @TestCase
    func testBodyLimit(): Unit {
        let ctx = mkCtx()
        ctx.setContentLengthInternal(1000)
        let h: RequestHandler = { c => c.successString("text/plain", "ok") }
        let composed = compose(h, makeList([bodyLimit(100)]))
        composed(ctx)
        @Expect(ctx.statusCode(), UInt16(413))
    }

    @TestCase
    func testRequestIDGenerated(): Unit {
        let ctx = mkCtx()
        let h: RequestHandler = { c => c.successString("text/plain", "ok") }
        compose(h, makeList([requestID()]))(ctx)
        // requestID 写的是**响应**头，不是请求头
        @Expect(ctx.responseHeaderGet("X-Request-ID").isEmpty(), false)
    }

    @TestCase
    func testCorsPreflight(): Unit {
        let ctx = mkCtx()
        // 伪造 OPTIONS 请求 + Origin
        ctx.setMethodInternal("OPTIONS")
        
        // 通过 setHeader 无法设置请求头，这里直接测响应头行为
        let h: RequestHandler = { c => c.successString("text/plain", "ok") }
        compose(h, makeList([cors(Array<String>(), "*", "*")]))(ctx)
        // 没有 Origin 头时不该短路，应正常走 handler
        @Expect(ctx.statusCode(), UInt16(200))
    }
}
