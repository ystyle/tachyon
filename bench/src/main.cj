package tachyon_bench

import ystyle::tachyon.*
import std.runtime.getAllocatedHeapSize
import std.net.{TcpSocket, TcpServerSocket}
import std.time.*
import std.core.*

func benchCase(label: String, port: UInt16, h: RequestHandler): Unit {
    let srv = Server(h)
    srv.readTimeout = Duration.second * 10
    let sock = TcpServerSocket(bindAt: port)
    sock.reuseAddress = true
    sock.bind()
    spawn { srv.serve(sock) }
    sleep(Duration.millisecond * 300)

    let conns: Int64 = 32
    let perConn: Int64 = 200
    let clients = Array<TcpSocket>(conns, { _ => TcpSocket("127.0.0.1", port) })
    var i: Int64 = 0
    while (i < conns) {
        clients[i].connect()
        clients[i].readTimeout = Duration.second * 10
        i += 1
    }
    let req = "GET / HTTP/1.1\r\nHost: x\r\n\r\n".toArray()
    let buf = Array<Byte>(4096, repeat: 0)
    i = 0
    while (i < conns) {
        clients[i].write(req)
        clients[i].read(buf)
        i += 1
    }
    let before = getAllocatedHeapSize()
    var r: Int64 = 0
    while (r < perConn) {
        i = 0
        while (i < conns) {
            clients[i].write(req)
            clients[i].read(buf)
            i += 1
        }
        r += 1
    }
    let after = getAllocatedHeapSize()
    let total = conns * perConn
    println(label + ": " + ((after - before) / total).toString() + " B/req")

    i = 0
    while (i < conns) {
        clients[i].close()
        i += 1
    }
    srv.shutdown()
    sleep(Duration.millisecond * 200)
}

main(): Int32 {
    println("=== handler 粒度归因 ===")
    benchCase("A) 空 handler（不写任何东西）  ", 27420, { ctx => () })
    benchCase("B) 只 setStatusCode(200)         ", 27421, { ctx => ctx.setStatusCode(200) })
    benchCase("C) + setContentType(string)     ", 27422, { ctx =>
        ctx.setStatusCode(200); ctx.setContentType("text/plain")
    })
    benchCase("D) + setBodyString(13B)         ", 27423, { ctx =>
        ctx.setStatusCode(200); ctx.setContentType("text/plain"); ctx.setBodyString("Hello, World!")
    })
    benchCase("E) successString（=D 的封装）    ", 27424, { ctx =>
        ctx.successString("text/plain", "Hello, World!")
    })
    return 0
}
