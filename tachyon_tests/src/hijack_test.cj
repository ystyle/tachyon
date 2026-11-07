package ystyle::tachyon_tests

import ystyle::tachyon.*
import std.unittest.*
import std.unittest.testmacro.*
import std.net.{TcpSocket, TcpServerSocket}
import std.core.*

/**
 * Hijack 端到端测试：handler 拿过连接后自己写响应，服务端不再插手。
 * 这是第三方实现 WebSocket / CONNECT 的唯一途径（对应 fasthttp 的 ctx.Hijack）。
 */
@Test
class HijackTest {
    @TestCase
    func testHijackTakesOverConnection(): Unit {
        let srv = Server({ ctx: RequestCtx =>
            ctx.hijack({ hc: HijackedConn =>
                // 直接写一条非 HTTP 的原始响应，服务端不应该再补任何东西
                hc.socket.write("RAW-HIJACKED-OK".toArray())
                hc.socket.close()
            })
        })
        srv.readTimeout = Duration.second * 5
        let sock = TcpServerSocket(bindAt: 27331)
        sock.reuseAddress = true
        sock.bind()
        spawn { srv.serve(sock) }
        sleep(Duration.millisecond * 200)

        let c = TcpSocket("127.0.0.1", 27331)
        c.connect()
        c.readTimeout = Duration.second * 3
        c.write("GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n\r\n".toArray())
        let buf = Array<Byte>(4096, repeat: 0)
        var total: Int64 = 0
        var guard: Int64 = 0
        while (guard < 10) {
            guard += 1
            let n = try { c.read(buf[total..]) } catch (e: Exception) { 0 }
            if (n <= 0) {
                break
            }
            total += n
        }
        c.close()
        srv.shutdown()
        let resp = if (total > 0) { String.fromUtf8(buf[0..total]) } else { "" }
        // 必须是原始内容，不能有 HTTP/1.1 200 之类的服务端自动响应
        @Expect(resp, "RAW-HIJACKED-OK")
    }
}
