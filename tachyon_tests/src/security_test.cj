package ystyle::tachyon_tests

import ystyle::tachyon.*
import std.unittest.*
import std.unittest.testmacro.*
import std.net.{TcpSocket, TcpServerSocket}
import std.core.*

/**
 * 请求解析的安全用例（RFC 9112 §6）。
 *
 * 这些用例钉住的是"拿不准时宁可拒绝"的行为：走私面一旦放过，
 * 前置代理按 Content-Length、我们按 Transfer-Encoding 解析，两侧看到的请求边界不一致。
 */
@Test
class SecurityTest {
    func withServer(port: UInt16, body: (UInt16) -> Unit): Unit {
        let srv = Server({ ctx: RequestCtx =>
            ctx.successString("text/plain", "ok")
        })
        srv.readTimeout = Duration.second * 5
        let sock = TcpServerSocket(bindAt: port)
        sock.reuseAddress = true
        sock.bind()
        spawn { srv.serve(sock) }
        sleep(Duration.millisecond * 200)
        body(port)
        srv.shutdown()
        sleep(Duration.millisecond * 100)
    }

    func raw(port: UInt16, payload: Array<Byte>): String {
        let c = TcpSocket("127.0.0.1", port)
        c.connect()
        c.readTimeout = Duration.second * 3
        c.write(payload)
        let buf = Array<Byte>(4096, repeat: 0)
        let n = try { c.read(buf) } catch (e: Exception) { 0 }
        c.close()
        if (n <= 0) {
            return ""
        }
        return String.fromUtf8(buf[0..n])
    }

    @TestCase
    func testContentLengthPlusTransferEncodingRejected(): Unit {
        withServer(27371, { port =>
            let req = "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n" +
                "Transfer-Encoding: chunked\r\n\r\n0\r\n\r\n"
            let resp = raw(port, req.toArray())
            // RFC 9112 §6.1：必须 400，而不是"照常响应但关连接"
            @Expect(resp.startsWith("HTTP/1.1 400"), true)
        })
    }

    @TestCase
    func testDuplicateContentLengthRejected(): Unit {
        withServer(27372, { port =>
            let req = "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\nhello"
            let resp = raw(port, req.toArray())
            // 两个不同的 CL 直接拒绝（相同值才允许，见 testDuplicateSameContentLengthAllowed）
            @Expect(resp.startsWith("HTTP/1.1 400"), true)
        })
    }

    @TestCase
    func testMissingHostRejected(): Unit {
        withServer(27373, { port =>
            let resp = raw(port, "GET / HTTP/1.1\r\n\r\n".toArray())
            @Expect(resp.startsWith("HTTP/1.1 400"), true)
        })
    }

    @TestCase
    func testMalformedRequestLineRejected(): Unit {
        withServer(27374, { port =>
            let resp = raw(port, "GARBAGE\r\n\r\n".toArray())
            @Expect(resp.startsWith("HTTP/1.1 400"), true)
        })
    }

    @TestCase
    func testOversizedHeaderRejected(): Unit {
        withServer(27375, { port =>
            let big = Array<Byte>(9000, repeat: 97)   // 'a'
            var req = "GET / HTTP/1.1\r\nHost: x\r\nX-Big: ".toArray()
            let p1 = req
            let out = Array<Byte>(req.size + big.size + 4, repeat: 0)
            var i: Int64 = 0
            while (i < p1.size) { out[i] = p1[i]; i += 1 }
            var j: Int64 = 0
            while (j < big.size) { out[i + j] = big[j]; j += 1 }
            out[i + j] = 13
            out[i + j + 1] = 10
            out[i + j + 2] = 13
            out[i + j + 3] = 10
            let resp = raw(port, out)
            @Expect(resp.startsWith("HTTP/1.1 431"), true)
        })
    }
}
