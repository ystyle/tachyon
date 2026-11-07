package ystyle::tachyon_tests

import ystyle::tachyon.*
import std.unittest.*
import std.unittest.testmacro.*
import std.net.{TcpSocket, TcpServerSocket}
import std.core.*

@Test
class PostArgsTest {
    /** 起 server，handler 回显 formValue 的结果 */
    func withEcho(port: UInt16, body: (UInt16) -> Unit): Unit {
        let srv = Server({ ctx: RequestCtx =>
            let a = ctx.formValue("name").toStr()
            let b = ctx.formValue("city").toStr()
            ctx.successString("text/plain", a + "|" + b)
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

    func post(port: UInt16, path: String, ct: String, payload: String): String {
        let c = TcpSocket("127.0.0.1", port)
        c.connect()
        c.readTimeout = Duration.second * 3
        let req = "POST " + path + " HTTP/1.1\r\nHost: x\r\nContent-Type: " + ct +
            "\r\nContent-Length: " + payload.size.toString() + "\r\n\r\n" + payload
        c.write(req.toArray())
        let buf = Array<Byte>(4096, repeat: 0)
        let n = try { c.read(buf) } catch (e: Exception) { 0 }
        c.close()
        if (n <= 0) {
            return ""
        }
        let resp = String.fromUtf8(buf[0..n])
        let i = match (resp.indexOf("\r\n\r\n")) { case Some(v) => v; case None => -1 }
        if (i < 0) {
            return resp
        }
        return resp[i + 4..]
    }

    @TestCase
    func testPostForm(): Unit {
        withEcho(27341, { port =>
            let r = post(port, "/", "application/x-www-form-urlencoded", "name=alice&city=beijing")
            @Expect(r, "alice|beijing")
        })
    }

    @TestCase
    func testPostFormDecode(): Unit {
        withEcho(27342, { port =>
            let r = post(port, "/", "application/x-www-form-urlencoded", "name=a%20b&city=c%2Bd")
            @Expect(r, "a b|c+d")
        })
    }

    @TestCase
    func testQueryBeatsPost(): Unit {
        withEcho(27343, { port =>
            // query 里的 name 优先于 body 里的
            let r = post(port, "/?name=fromquery", "application/x-www-form-urlencoded", "name=frombody&city=x")
            @Expect(r, "fromquery|x")
        })
    }

    @TestCase
    func testNonFormContentType(): Unit {
        withEcho(27344, { port =>
            // 不是表单格式 -> postArgs 为空，但 query 仍可读
            let r = post(port, "/?name=q", "application/json", "{\"name\":\"j\"}")
            @Expect(r, "q|")
        })
    }
}
