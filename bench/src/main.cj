package tachyon_bench

import ystyle::tachyon.*
import std.runtime.*
import std.net.{TcpSocket, TcpServerSocket}
import std.time.*
import std.core.*

/**
 * 每请求分配测量。
 *
 * 用 getAllocatedHeapSize 前后差值除以请求数 = 每请求字节数。
 * 对应 fasthttp 的 allocation_test.go（AllocsPerRun = 0）。
 */
main(): Int32 {
    let port: UInt16 = 27314
    let srv = Server({ ctx: RequestCtx =>
        ctx.successString("text/plain", "Hello, World!")
    })
    srv.readTimeout = Duration.second * 10
    let sock = TcpServerSocket(bindAt: port)
    sock.reuseAddress = true
    sock.bind()
    spawn { srv.serve(sock) }
    sleep(Duration.millisecond * 300)

    let conns: Int64 = 64
    let perConn: Int64 = 200
    let clients: Array<TcpSocket> = Array<TcpSocket>(conns, { _ => TcpSocket("127.0.0.1", port) })
    var i: Int64 = 0
    while (i < conns) {
        clients[i].connect()
        clients[i].readTimeout = Duration.second * 10
        i += 1
    }
    let req: Array<Byte> = "GET / HTTP/1.1\r\nHost: x\r\n\r\n".toArray()
    let buf: Array<Byte> = Array<Byte>(4096, repeat: 0)

    // warmup
    i = 0
    while (i < conns) {
        clients[i].write(req)
        clients[i].read(buf)
        i += 1
    }

    let before = getAllocatedHeapSize()
    let t0 = MonoTime.now()
    var r: Int64 = 0
    while (r < perConn) {
        i = 0
        while (i < conns) {
            clients[i].write(req)
            let n = clients[i].read(buf)
            if (n <= 0) {
                println("read failed")
                return 1
            }
            i += 1
        }
        r += 1
    }
    let t1 = MonoTime.now()
    let after = getAllocatedHeapSize()

    let total = conns * perConn
    let bytes = after - before
    println("requests      = " + total.toString())
    println("elapsed       = " + (t1 - t0).toString())
    println("allocated     = " + bytes.toString() + " B")
    println("per request   = " + (bytes / total).toString() + " B")
    println("per request < 1 B  = " + (bytes < total).toString())
    println("qps           = " + (total * 1000000000 / ((t1 - t0).toNanoseconds() + 1)).toString())

    i = 0
    while (i < conns) {
        clients[i].close()
        i += 1
    }
    srv.shutdown()
    return 0
}
