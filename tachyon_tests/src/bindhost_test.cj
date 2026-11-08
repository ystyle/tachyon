package ystyle::tachyon_tests

import ystyle::tachyon.*
import std.unittest.*
import std.unittest.testmacro.*
import std.net.{TcpSocket, IPSocketAddress}
import std.core.*

/**
 * listenAndServe(host, port) 必须真正使用 host。
 *
 * 反例是「参数被忽略、永远绑 0.0.0.0」—— 那样「只听 127.0.0.1」这类用法会静默失效，
 * 等于把服务暴露到所有网卡上。这里通过 listener.localAddress 断言实际绑定地址。
 */
@Test
class BindHostTest {
    @TestCase
    func testListenAndServeBindsGivenHost(): Unit {
        let srv = Server({ ctx: RequestCtx =>
            ctx.successString("text/plain", "bound")
        })
        srv.readTimeout = Duration.second * 5
        spawn { srv.listenAndServe("127.0.0.1", 27341) }
        sleep(Duration.millisecond * 300)

        // 实际绑定地址应是 127.0.0.1，而不是 0.0.0.0
        match (srv.localAddress()) {
            case Some(addr) => @Expect(addr.address.toString(), "127.0.0.1")
            case None => @Fail("listener 未创建")
        }

        // 从本机回环能连上并拿到响应
        let c = TcpSocket("127.0.0.1", 27341)
        c.connect()
        c.readTimeout = Duration.second * 3
        c.write("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n".toArray())
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
        c.close()
        let text = String.fromUtf8(buf[0..total])
        @Expect(text.contains("bound"), true)

        try {
            srv.shutdown()
        } catch (e: Exception) {
            ()
        }
    }
}
