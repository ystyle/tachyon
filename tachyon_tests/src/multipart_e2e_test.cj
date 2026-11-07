package ystyle::tachyon_tests

import ystyle::tachyon.*
import std.unittest.*
import std.unittest.testmacro.*
import std.net.{TcpSocket, TcpServerSocket}
import std.core.*

@Test
class MultipartE2ETest {
    @TestCase
    func testMultipartOverWire(): Unit {
        let srv = Server({ ctx: RequestCtx =>
            let f = ctx.multipartForm()
            let title = match (f.field("title")) { case Some(v) => v.toStr(); case None => "(none)" }
            let up = match (f.file("up")) { case Some(p) => p.fileName + ":" + p.data.toStr(); case None => "(nofile)" }
            ctx.successString("text/plain", title + "|" + up)
        })
        srv.readTimeout = Duration.second * 5
        let sock = TcpServerSocket(bindAt: 27361)
        sock.reuseAddress = true
        sock.bind()
        spawn { srv.serve(sock) }
        sleep(Duration.millisecond * 200)

        let boundary = "TESTBOUND"
        let body = "--TESTBOUND\r\n" +
            "Content-Disposition: form-data; name=\"title\"\r\n\r\n" +
            "T\r\n" +
            "--TESTBOUND\r\n" +
            "Content-Disposition: form-data; name=\"up\"; filename=\"f.txt\"\r\n" +
            "Content-Type: text/plain\r\n\r\n" +
            "FC\r\n" +
            "--TESTBOUND--\r\n"
        let req = "POST / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n" +
            "Content-Type: multipart/form-data; boundary=" + boundary + "\r\n" +
            "Content-Length: " + body.size.toString() + "\r\n\r\n" + body

        let c = TcpSocket("127.0.0.1", 27361)
        c.connect()
        c.readTimeout = Duration.second * 3
        c.write(req.toArray())
        let buf = Array<Byte>(8192, repeat: 0)
        let n = try { c.read(buf) } catch (e: Exception) { 0 }
        c.close()
        srv.shutdown()
        let resp = if (n > 0) { String.fromUtf8(buf[0..n]) } else { "" }
        @Expect(resp.contains("T|f.txt:FC"), true)
    }
}
