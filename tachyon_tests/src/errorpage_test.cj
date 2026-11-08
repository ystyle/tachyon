package ystyle::tachyon_tests

import ystyle::tachyon.*
import std.unittest.*
import std.unittest.testmacro.*
import std.net.{TcpSocket, TcpServerSocket}
import std.core.*

/**
 * 自定义错误页（Server.errorHandler，对应 fasthttp 的 ErrorHandler）。
 *
 * 默认错误响应是「状态码 + text/plain 一行说明」；业务侧通常要 JSON 错误体或
 * 统一错误页，所以需要一个「交给你写、你说了算」的钩子。
 */
@Test
class ErrorPageTest {
    func rawGet(port: UInt16, path: String): String {
        let c = TcpSocket("127.0.0.1", port)
        c.connect()
        c.readTimeout = Duration.second * 3
        c.write(("GET " + path + " HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n").toArray())
        let buf = Array<Byte>(4096, repeat: 0)
        var total: Int64 = 0
        var guard: Int64 = 0
        while (guard < 10) {
            guard += 1
            let n = try {
                c.read(buf[total..])
            } catch (e: Exception) {
                0
            }
            if (n <= 0) {
                break
            }
            total += n
        }
        try {
            c.close()
        } catch (e: Exception) {
            ()
        }
        if (total <= 0) {
            return ""
        }
        return String.fromUtf8(buf[0..total])
    }

    @TestCase
    func testCustomErrorPage(): Unit {
        let port: UInt16 = 27361
        let srv = Server({ ctx: RequestCtx =>
            if (ctx.path().toStr() == "/boom") {
                ctx.error("upstream exploded", 500)
            } else if (ctx.path().toStr() == "/api/x") {
                ctx.error("no such api", 404)
            } else {
                ctx.successString("text/plain", "ok")
            }
        })
        // 业务侧把错误响应改成 JSON
        srv.errorHandler = Some({ ctx: RequestCtx, msg: String, code: UInt16 =>
            ctx.setStatusCode(code)
            ctx.setContentType("application/json")
            ctx.setBodyString("{\"error\":\"" + msg + "\",\"status\":" + code.toString() + "}")
            true
        })
        let sock = TcpServerSocket(bindAt: port)
        sock.reuseAddress = true
        sock.bind()
        spawn { srv.serve(sock) }
        sleep(Duration.millisecond * 300)

        let resp = rawGet(port, "/boom")
        @Expect(resp.startsWith("HTTP/1.1 500"), true)
        @Expect(resp.contains("application/json"), true)
        @Expect(resp.contains("{\"error\":\"upstream exploded\",\"status\":500}"), true)

        let resp2 = rawGet(port, "/api/x")
        @Expect(resp2.startsWith("HTTP/1.1 404"), true)
        @Expect(resp2.contains("{\"error\":\"no such api\",\"status\":404}"), true)

        // 正常响应不受影响
        let ok = rawGet(port, "/hi")
        @Expect(ok.startsWith("HTTP/1.1 200"), true)
        @Expect(ok.contains("ok"), true)

        try {
            srv.shutdown()
        } catch (e: Exception) {
            ()
        }
        try {
            sock.close()
        } catch (e: Exception) {
            ()
        }
    }

    @TestCase
    func testHandlerDeclinesFallsBackToDefault(): Unit {
        let port: UInt16 = 27362
        let srv = Server({ ctx: RequestCtx => ctx.error("teapot", 418) })
        // 只处理 5xx，其余交回默认实现
        srv.errorHandler = Some({ ctx: RequestCtx, msg: String, code: UInt16 =>
            if (code >= 500) {
                ctx.setStatusCode(code)
                ctx.setBodyString("custom: " + msg)
                true
            } else {
                false
            }
        })
        let sock = TcpServerSocket(bindAt: port)
        sock.reuseAddress = true
        sock.bind()
        spawn { srv.serve(sock) }
        sleep(Duration.millisecond * 300)

        let resp = rawGet(port, "/x")
        @Expect(resp.startsWith("HTTP/1.1 418"), true)
        @Expect(resp.contains("teapot"), true)
        @Expect(resp.contains("text/plain"), true)

        try {
            srv.shutdown()
        } catch (e: Exception) {
            ()
        }
        try {
            sock.close()
        } catch (e: Exception) {
            ()
        }
    }
}
