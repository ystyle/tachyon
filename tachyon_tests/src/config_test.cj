package ystyle::tachyon_tests

import ystyle::tachyon.*
import std.unittest.*
import std.unittest.testmacro.*
import std.net.{TcpSocket, TcpServerSocket}
import std.core.*

@Test
class ConfigTest {
    /** 起一个 server，跑 body 回调，最后关掉 */
    func withServer(port: UInt16, configure: (Server) -> Unit, body: (UInt16) -> Unit): Unit {
        let srv = Server({ ctx: RequestCtx =>
            ctx.successString("text/plain", "ok")
        })
        srv.readTimeout = Duration.second * 5
        configure(srv)
        let sock = TcpServerSocket(bindAt: port)
        sock.reuseAddress = true
        sock.bind()
        spawn { srv.serve(sock) }
        sleep(Duration.millisecond * 200)
        body(port)
        srv.shutdown()
        sleep(Duration.millisecond * 100)
    }

    func rawReq(port: UInt16, req: String): String {
        let c = TcpSocket("127.0.0.1", port)
        c.connect()
        c.readTimeout = Duration.second * 3
        c.write(req.toArray())
        let buf = Array<Byte>(4096, repeat: 0)
        let n = try { c.read(buf) } catch (e: Exception) { 0 }
        c.close()
        if (n <= 0) {
            return ""
        }
        return String.fromUtf8(buf[0..n])
    }

    @TestCase
    func testGetOnlyRejectsPost(): Unit {
        withServer(27321,
            { s => s.getOnly = true },
            { port =>
                let resp = rawReq(port, "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n")
                @Expect(resp.contains("400"), true)
            })
    }

    @TestCase
    func testGetOnlyAllowsGet(): Unit {
        withServer(27322,
            { s => s.getOnly = true },
            { port =>
                let resp = rawReq(port, "GET / HTTP/1.1\r\nHost: x\r\n\r\n")
                @Expect(resp.contains("200"), true)
            })
    }

    @TestCase
    func testMaxConnsPerIP(): Unit {
        withServer(27323,
            { s => s.maxConnsPerIP = 1 },
            { port =>
                // 第一条 keep-alive 连接占住名额
                let c1 = TcpSocket("127.0.0.1", port)
                c1.connect()
                c1.readTimeout = Duration.second * 3
                c1.write("GET / HTTP/1.1\r\nHost: x\r\n\r\n".toArray())
                let buf = Array<Byte>(4096, repeat: 0)
                let n1 = c1.read(buf)
                @Expect(n1 > 0, true)
                // 第二条应被 429
                let resp2 = rawReq(port, "GET / HTTP/1.1\r\nHost: x\r\n\r\n")
                @Expect(resp2.contains("429"), true)
                c1.close()
            })
    }

    func repeatChar(c: Byte, n: Int64): String {
        return String.fromUtf8(Array<Byte>(n, repeat: c))
    }

    @TestCase
    func testReadBufferSizeAffectsHeaderLimit(): Unit {
        // 把读缓冲设得很小，超长 header 应回 431
        withServer(27324,
            { s => s.readBufferSize = 128 },
            { port =>
                let longHdr = "GET / HTTP/1.1\r\nHost: x\r\nX-Big: " + repeatChar(97, 300) + "\r\n\r\n"
                let resp = rawReq(port, longHdr)
                @Expect(resp.contains("431"), true)
            })
    }
}
