package ystyle::tachyon

import std.net.TcpSocket

/**
 * chunked transfer-encoding 读取（RFC 9112 §7.1）。
 *
 * 格式：
 *   chunk-size [ chunk-ext ] CRLF
 *   chunk-data CRLF
 *   ...
 *   0 [ chunk-ext ] CRLF
 *   trailer-section CRLF
 *
 * chunk-size 是**十六进制**，chunk-ext（';' 之后）直接忽略。
 */
public class ChunkedReader {
    var total: Int64 = 0
    var finished: Bool = false

    /**
     * 把 body 读进 out（调用方预分配 maxSize），返回读到的字节数。
     * 返回 -1 表示格式错误或超限。
     */
    func readBody(conn: TcpSocket, reader: BufferedReader, out: Array<Byte>, maxSize: Int64): Int64 {
        var written: Int64 = 0
        while (!finished) {
            // ---- 读 chunk-size 行 ----
            let lineLen = readLine(conn, reader)
            if (lineLen < 0) {
                return -1
            }
            let line = reader.available().slice(0, lineLen)
            let size = parseChunkSize(line)
            if (size < 0) {
                return -1
            }
            // readLine 返回的是行长度（不含 CRLF），必须把 CRLF 一起消费掉
            reader.discard(lineLen + 2)

            if (size == 0) {
                // ---- trailer：读到空行为止 ----
                while (true) {
                    let tl = readLine(conn, reader)
                    if (tl < 0) {
                        return -1
                    }
                    if (tl == 0) {
                        reader.discard(2)   // 空行本身的 CRLF
                        break
                    }
                    reader.discard(tl + 2)  // trailer 行 + 它的 CRLF
                }
                finished = true
                break
            }

            if (written + size > maxSize) {
                return -1
            }

            // ---- 读 chunk-data ----
            var got: Int64 = 0
            while (got < size) {
                if (reader.buffered() == 0) {
                    let n = reader.fill(conn)
                    if (n <= 0) {
                        return -1
                    }
                }
                let avail = reader.buffered()
                let take = if (avail < size - got) { avail } else { size - got }
                let view = reader.available()
                var i: Int64 = 0
                while (i < take) {
                    out[written + got + i] = view[i]
                    i += 1
                }
                reader.discard(take)
                got += take
            }
            written += size

            // ---- chunk 后面必须跟 CRLF ----
            while (reader.buffered() < 2) {
                let n = reader.fill(conn)
                if (n <= 0) {
                    return -1
                }
            }
            let tail = reader.available()
            if (tail[0] != 13 || tail[1] != 10) {
                return -1
            }
            reader.discard(2)
            total += size
        }
        return written
    }

    /** 读一行（到 CRLF，不含 CRLF），返回行长度（已把行留在 reader 里）。-1=错误 */
    func readLine(conn: TcpSocket, reader: BufferedReader): Int64 {
        // 行最长 256 字节（chunk-size + ext）
        var scanned: Int64 = 0
        var guard: Int64 = 0
        while (guard < 1024) {
            guard += 1
            let avail = reader.buffered()
            let view = reader.available()
            var i = scanned
            while (i + 1 < avail) {
                if (view[i] == 13 && view[i + 1] == 10) {
                    return i
                }
                i += 1
            }
            scanned = avail
            if (avail >= 256) {
                return -1
            }
            let n = reader.fill(conn)
            if (n <= 0) {
                return -1
            }
        }
        return -1
    }

    /**
     * parse 十六进制 chunk-size，遇到 ';'（chunk-ext）就停。
     * 失败返回 -1。
     */
    public func parseChunkSize(line: Bytes): Int64 {
        if (line.isEmpty()) {
            return -1
        }
        var v: Int64 = 0
        var any = false
        var i: Int64 = 0
        while (i < line.size()) {
            let c = line[i]
            if (c == 59) {   // ';' chunk-ext 开始
                break
            }
            let d = hexVal(c)
            if (d < 0) {
                if (c == 32 || c == 9) {   // 允许尾部空白
                    i += 1
                    continue
                }
                return -1
            }
            any = true
            v = v * 16 + d
            if (v > 1000000000) {
                return -1
            }
            i += 1
        }
        if (!any) {
            return -1
        }
        return v
    }
}
