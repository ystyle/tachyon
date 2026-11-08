package std_alloc_baseline

import std.net.{TcpServerSocket, TcpSocket}
import std.runtime.getAllocatedHeapSize

/**
 * 裸 std TcpSocket 的分配基线。
 *
 * 用途：把 tachyon 的分配数字归因到「std 的 socket 层」与「我们自己的 HTTP 层」。
 *
 * 两段：
 *  1) 端到端：32 连接 × 200 请求的完整往返，客户端 + 服务端合计（口径与 ../ 的 alloc bench 一致）
 *  2) 逐调用：单独量 read / write 每次调用的分配，并带空循环 / 普通函数调用作对照
 *
 * 实测（2026-11-08，AMD 7840HS，仓颉 1.2.0）：
 *  端到端 112 B/req；逐调用 write 56 B/call（80 B 与 1024 B 载荷相同）、read 57 B/call，
 *  而空循环与普通函数调用都是 0 B/op。
 *  → 分配在 socket 内部，且是**常数**、与数据量无关；Array 切片本身零分配。
 */
var sink: Int64 = 0

func noop(x: Int64): Int64 {
    return x + 1
}

main(): Int32 {
    perCall()
    endToEnd()
    return 0
}

/// 逐调用归因：read / write 各多少 B/call，与空循环对照
func perCall(): Unit {
    let N: Int64 = 20000

    var i: Int64 = 0
    while (i < 100) {
        sink = sink + 1
        i += 1
    }
    let a0 = getAllocatedHeapSize()
    i = 0
    while (i < N) {
        sink = sink + 1
        i += 1
    }
    let a1 = getAllocatedHeapSize()
    println("空循环（对照）        : " + ((a1 - a0) / N).toString() + " B/op")

    let b0 = getAllocatedHeapSize()
    i = 0
    while (i < N) {
        sink = noop(sink)
        i += 1
    }
    let b1 = getAllocatedHeapSize()
    println("普通函数调用（对照）  : " + ((b1 - b0) / N).toString() + " B/op")

    // 对端：只读不写，供 write 测试
    let sinkPort: UInt16 = 27450
    let sinkSrv = TcpServerSocket(bindAt: sinkPort)
    sinkSrv.reuseAddress = true
    sinkSrv.bind()
    spawn {
        let b = Array<Byte>(65536, repeat: 0)
        while (true) {
            let c = sinkSrv.accept()
            spawn {
                while (true) {
                    let n = try {
                        c.read(b)
                    } catch (e: Exception) {
                        0
                    }
                    if (n <= 0) {
                        break
                    }
                }
            }
        }
    }
    // 对端：不停写，供 read 测试
    let feedPort: UInt16 = 27451
    let feedSrv = TcpServerSocket(bindAt: feedPort)
    feedSrv.reuseAddress = true
    feedSrv.bind()
    let payload = Array<Byte>(1024, repeat: 7)
    spawn {
        while (true) {
            let c = feedSrv.accept()
            spawn {
                while (true) {
                    let ok = try {
                        c.write(payload)
                        true
                    } catch (e: Exception) {
                        false
                    }
                    if (!ok) {
                        break
                    }
                }
            }
        }
    }
    sleep(Duration.millisecond * 400)

    let w1 = TcpSocket("127.0.0.1", sinkPort)
    w1.connect()
    let big = Array<Byte>(1024, repeat: 1)
    i = 0
    while (i < 100) {
        w1.write(big)
        i += 1
    }
    let c0 = getAllocatedHeapSize()
    i = 0
    while (i < N) {
        w1.write(big)
        i += 1
    }
    let c1 = getAllocatedHeapSize()
    println("write(1024 B)         : " + ((c1 - c0) / N).toString() + " B/call")

    let w2 = TcpSocket("127.0.0.1", sinkPort)
    w2.connect()
    let small = Array<Byte>(80, repeat: 2)
    i = 0
    while (i < 100) {
        w2.write(small)
        i += 1
    }
    let d0 = getAllocatedHeapSize()
    i = 0
    while (i < N) {
        w2.write(small)
        i += 1
    }
    let d1 = getAllocatedHeapSize()
    println("write(80 B)           : " + ((d1 - d0) / N).toString() + " B/call")

    // 切片传入：与整数组相同的分配量（说明切片零成本）
    let w3 = TcpSocket("127.0.0.1", sinkPort)
    w3.connect()
    let wide = Array<Byte>(4096, repeat: 3)
    i = 0
    while (i < 100) {
        w3.write(wide[0..1024])
        i += 1
    }
    let e0 = getAllocatedHeapSize()
    i = 0
    while (i < N) {
        w3.write(wide[0..1024])
        i += 1
    }
    let e1 = getAllocatedHeapSize()
    println("write(wide[0..1024])  : " + ((e1 - e0) / N).toString() + " B/call")

    let rc = TcpSocket("127.0.0.1", feedPort)
    rc.connect()
    let rBuf = Array<Byte>(4096, repeat: 0)
    i = 0
    while (i < 100) {
        rc.read(rBuf)
        i += 1
    }
    let f0 = getAllocatedHeapSize()
    i = 0
    while (i < N) {
        rc.read(rBuf)
        i += 1
    }
    let f1 = getAllocatedHeapSize()
    println("read(4096 B)          : " + ((f1 - f0) / N).toString() + " B/call")

    try {
        rc.close()
        w1.close()
        w2.close()
        w3.close()
    } catch (e: Exception) {
        ()
    }
}

/// 端到端：完整往返的每请求分配（客户端 + 服务端合计）
func endToEnd(): Unit {
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
    println("端到端（客户端+服务端）: " + perReq.toString() + " B/req")
    i = 0
    while (i < conns) {
        try {
            clients[i].close()
        } catch (e: Exception) {
            ()
        }
        i += 1
    }
}
