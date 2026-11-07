package ystyle::tachyon_tests

import ystyle::tachyon.*
import std.unittest.*
import std.unittest.testmacro.*
import std.net.{TcpSocket, TcpServerSocket}
import std.sync.SyncCounter
import std.time.MonoTime
import std.core.*

/**
 * chunked 端到端测试：起真实 server，用原始 socket 发 chunked 请求。
 * 覆盖"CRLF 消费"这个曾经出错的地方。
 */
@Test
class ChunkedE2ETest {
    @TestCase
    func testChunkedBody(): Unit {
        let srv = Server({ ctx: RequestCtx =>
            let b = ctx.body()
            ctx.successString("text/plain", b.toStr())
        })
        srv.readTimeout = Duration.second * 5
        let port: UInt16 = 27311
        let sock = TcpServerSocket(bindAt: port)
        sock.reuseAddress = true
        sock.bind()
        spawn {
            srv.serve(sock)
        }
        sleep(Duration.millisecond * 200)

        let c = TcpSocket("127.0.0.1", port)
        c.connect()
        c.readTimeout = Duration.second * 5
        let req = "POST /e HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"
        c.write(req.toArray())
        let buf = Array<Byte>(4096, repeat: 0)
        let n = c.read(buf)
        let resp = String.fromUtf8(buf[0..n])
        c.close()
        srv.shutdown()

        // 响应必须含 200 且 body 是 "hello world"
        @Expect(resp.contains("200 OK"), true)
        @Expect(resp.contains("hello world"), true)
    }
}
