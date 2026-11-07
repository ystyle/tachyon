package ystyle::tachyon_tests

import ystyle::tachyon.*
import std.unittest.*
import std.unittest.testmacro.*
import std.net.{TcpSocket, TcpServerSocket}
import std.io.*
import std.core.*

/**
 * 流式响应（SetBodyStream）端到端测试。
 * 对应 fasthttp 的 Response.SetBodyStream：size >= 0 定长，size < 0 chunked。
 */
@Test
class StreamTest {
    func readAll(c: TcpSocket): String {
        let buf = Array<Byte>(16384, repeat: 0)
        var total: Int64 = 0
        var guard: Int64 = 0
        while (guard < 50) {
            guard += 1
            let n = try { c.read(buf[total..]) } catch (e: Exception) { 0 }
            if (n <= 0) {
                break
            }
            total += n
        }
        if (total <= 0) {
            return ""
        }
        return String.fromUtf8(buf[0..total])
    }

    @TestCase
    func testStreamFixedLength(): Unit {
        let srv = Server({ ctx: RequestCtx =>
            let bb = ByteBuffer()
            bb.write("streamed-fixed-body".toArray())
            bb.seek(SeekPosition.Begin(0))
            ctx.setBodyStream(bb, 19)
        })
        srv.readTimeout = Duration.second * 5
        let sock = TcpServerSocket(bindAt: 27351)
        sock.reuseAddress = true
        sock.bind()
        spawn { srv.serve(sock) }
        sleep(Duration.millisecond * 200)

        let c = TcpSocket("127.0.0.1", 27351)
        c.connect()
        c.readTimeout = Duration.second * 3
        c.write("GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".toArray())
        let resp = readAll(c)
        c.close()
        srv.shutdown()
        @Expect(resp.contains("Content-Length: 19"), true)
        @Expect(resp.contains("streamed-fixed-body"), true)
    }

    @TestCase
    func testStreamChunked(): Unit {
        let srv = Server({ ctx: RequestCtx =>
            let bb = ByteBuffer()
            bb.write("chunked-body".toArray())
            bb.seek(SeekPosition.Begin(0))
            ctx.setBodyStream(bb, -1)   // -1 -> chunked
        })
        srv.readTimeout = Duration.second * 5
        let sock = TcpServerSocket(bindAt: 27352)
        sock.reuseAddress = true
        sock.bind()
        spawn { srv.serve(sock) }
        sleep(Duration.millisecond * 200)

        let c = TcpSocket("127.0.0.1", 27352)
        c.connect()
        c.readTimeout = Duration.second * 3
        c.write("GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".toArray())
        let resp = readAll(c)
        c.close()
        srv.shutdown()
        @Expect(resp.contains("Transfer-Encoding: chunked"), true)
        @Expect(resp.contains("chunked-body"), true)
        // 结束块
        @Expect(resp.contains("0\r\n\r\n"), true)
    }
}
