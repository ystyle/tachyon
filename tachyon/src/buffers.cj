package ystyle::tachyon

import std.net.TcpSocket

const defaultBufferSize: Int64 = 4096

const cr: Byte = 13
const lf: Byte = 10
const sp: Byte = 32
const colon: Byte = 58
const question: Byte = 63
const ampersand: Byte = 38
const equalsSign: Byte = 61
const percent: Byte = 37
const plusSign: Byte = 43
const slash: Byte = 47
const dot: Byte = 46

/**
 * 固定大小的读缓冲。
 *
 * 关键约束：buf 绝不扩容。扩容会换底层数组，所有指向它的 Bytes 视图立刻失效
 * （Views held by RequestCtx point into this array）。
 */
class BufferedReader {
    var buf: Array<Byte>
    var r: Int64 = 0
    var w: Int64 = 0
    var eof: Bool = false

    init(size: Int64) {
        this.buf = Array<Byte>(size, repeat: 0)
    }

    /** 未消费区间视图（零拷贝） */
    func available(): Bytes {
        return Bytes(buf, r, w - r)
    }

    func buffered(): Int64 {
        return w - r
    }

    /** 未消费区间从 from 起找 CRLFCRLF，返回块结束位置（相对 available 起点），找不到 -1 */
    func findHeaderEnd(): Int64 {
        let n = w
        var i = r
        while (i + 3 < n) {
            if (buf[i] == cr && buf[i + 1] == lf && buf[i + 2] == cr && buf[i + 3] == lf) {
                return i + 4 - r
            }
            i += 1
        }
        return -1
    }

    /** 消费 n 字节 */
    func discard(n: Int64): Unit {
        r += n
        if (r >= w) {
            r = 0
            w = 0
        }
    }

    /** 把未消费数据搬到头部，腾出写空间 */
    func compact(): Unit {
        if (r == 0) {
            return
        }
        let n = w - r
        var i: Int64 = 0
        while (i < n) {
            buf[i] = buf[r + i]
            i += 1
        }
        r = 0
        w = n
    }

    /** 从 socket 读一次，返回到读到的字节数；0 = EOF；-1 = 异常 */
    func fill(conn: TcpSocket): Int64 {
        if (w >= buf.size) {
            compact()
            if (w >= buf.size) {
                return -2
            }
        }
        let n = try {
            conn.read(buf[w..buf.size])
        } catch (e: Exception) {
            -1
        }
        if (n <= 0) {
            eof = true
            return n
        }
        w += n
        return n
    }
}

/**
 * 固定大小的写缓冲。
 *
 * availableSlice() 让 ResponseSerializer 直接往空闲区拼 header，不需要中间 buffer
 * （对应 fasthttp 的 bufio.Writer.AvailableBuffer 优化）。
 */
class BufferedWriter {
    var buf: Array<Byte>
    var n: Int64 = 0

    init(size: Int64) {
        this.buf = Array<Byte>(size, repeat: 0)
    }

    func available(): Int64 {
        return buf.size - n
    }

    /** 尾部空闲区视图，写完要 commit */
    func availableSlice(): Bytes {
        return Bytes(buf, n, buf.size - n)
    }

    /** 提交写入（把写位置前推 k） */
    func commit(k: Int64): Unit {
        n += k
    }

    func write(b: Bytes): Bool {
        let need = b.size()
        if (n + need > buf.size) {
            return false
        }
        b.copyTo(buf, n)
        n += need
        return true
    }

    func writeArray(b: Array<Byte>): Bool {
        if (n + b.size > buf.size) {
            return false
        }
        var i: Int64 = 0
        while (i < b.size) {
            buf[n + i] = b[i]
            i += 1
        }
        n += b.size
        return true
    }

    func writeString(s: String): Bool {
        return writeArray(s.toArray())
    }

    func isFull(): Bool {
        return n >= buf.size
    }

    func reset(): Unit {
        n = 0
    }

    /** 刷到 socket，返回到 true 表示成功 */
    func flush(conn: TcpSocket): Bool {
        if (n == 0) {
            return true
        }
        let ok = try {
            conn.write(buf[0..n])
            true
        } catch (e: Exception) {
            false
        }
        n = 0
        return ok
    }
}

/** CRLF 字符串（避免各处手写 \r\n 字面量出错） */
func crlf(): String {
    return "\r\n"
}
