package std_alloc_baseline

import std.net.{TcpServerSocket, TcpSocket}
import std.runtime.getAllocatedHeapSize

/**
 * 裸 std TcpSocket 的每请求分配基线。
 *
 * 用途：给 tachyon 的分配数字做归因 —— 全流程 160 B/req 里有多少是 std socket 自己的。
 * 口径与 ../（alloc bench）一致：32 连接 × 200 请求，
 * getAllocatedHeapSize 差值 / 请求数，客户端与服务端合计。
 *
 * 实测（2026-11-08，AMD 7840HS）：112 B/req。
 * 结论：std 的 socket read/write 本身就在分配，所以「每请求 0 分配」在现有 std 上不可达。
 */
main(): Int32 {
    let port: UInt16 = 27430
    let sock = TcpServerSocket(bindAt: port)
    sock.reuseAddress = true
    sock.bind()
    let resp = "HTTP/1.1 200 OK\r\nContent-Length: 13\r\n\r\nHello, World!".toArray()

    spawn {
        let serverBuf = Array<Byte>(4096, repeat: 0)
        while (true) {
            let conn = sock.accept()
            spawn {
                while (true) {
                    let n = try {
                        conn.read(serverBuf)
                    } catch (e: Exception) {
                        0
                    }
                    if (n <= 0) {
                        break
                    }
                    try {
                        conn.write(resp)
                    } catch (e: Exception) {
                        break
                    }
                }
                try {
                    conn.close()
                } catch (e: Exception) {
                    ()
                }
            }
        }
    }
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
    let perReq = (after - before) / (conns * perConn)
    println("裸 std TcpSocket: " + perReq.toString() + " B/req（客户端+服务端合计）")
    println("对照：tachyon 全流程 160 B/req，故其自身 HTTP 层约 " + (160 - perReq).toString() + " B/req")
    return 0
}
