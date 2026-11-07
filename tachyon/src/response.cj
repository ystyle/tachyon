package ystyle::tachyon

/**
 * 响应。序列化顺序照抄 fasthttp（顺序是协议 + 兼容性要求）：
 *   状态行 -> Server -> Date -> Content-Type -> Content-Length -> 用户头 -> Set-Cookie -> Connection
 */
class Response {
    var statusCode: UInt16 = 200
    var header: HeaderTable
    var body: Bytes = Bytes.empty()

    // 自动头的开关
    var noDefaultContentType: Bool = false
    var noDefaultDate: Bool = false
    var skipBody: Bool = false
    var connectionClose: Bool = false

    init(headerCap: Int64) {
        this.header = HeaderTable(headerCap)
    }

    func reset(): Unit {
        statusCode = 200
        header.reset()
        body = Bytes.empty()
        skipBody = false
        connectionClose = false
    }

    func setBody(b: Bytes): Unit {
        body = b
    }

    func setBodyString(s: String): Unit {
        body = Bytes(s.toArray())
    }

    func setStatusCode(code: UInt16): Unit {
        statusCode = code
    }

    func setContentType(ct: String): Unit {
        header.contentType = Bytes(ct.toArray())
    }

    /** 序列化到写缓冲。返回实际写入的字节数，-1 表示缓冲装不下 */
    func serialize(w: BufferedWriter, serverName: String, dateLine: Array<Byte>): Int64 {
        w.reset()
        let dst = w.buf
        var p: Int64 = 0
        let cap = dst.size

        // 1. 状态行 "HTTP/1.1 " + code + " " + text + CRLF
        p = appendString(dst, p, "HTTP/1.1 ")
        p = appendUInt16(dst, p, statusCode)
        let text = statusText(statusCode)
        if (text.size > 0) {
            p = appendByte(dst, p, 32)
            p = appendString(dst, p, text)
        }
        p = appendCRLF(dst, p)

        // 2. Server
        if (serverName.size > 0) {
            p = appendString(dst, p, "Server: ")
            p = appendString(dst, p, serverName)
            p = appendCRLF(dst, p)
        }

        // 3. Date（缓存行，直接 memcpy）
        if (!noDefaultDate && dateLine.size > 0) {
            p = appendArray(dst, p, dateLine)
        }

        let skipBodyHere = skipBody || mustSkipBody(statusCode)
        let bodyLen: Int64 = if (skipBodyHere) { 0 } else { body.size() }

        // 4. Content-Type（仅当有 body 或显式设置）
        let ct = header.contentType
        if (!ct.isEmpty()) {
            p = appendString(dst, p, "Content-Type: ")
            p = appendBytes(dst, p, ct)
            p = appendCRLF(dst, p)
        } else if (!noDefaultContentType && bodyLen != 0) {
            p = appendString(dst, p, "Content-Type: text/plain; charset=utf-8\r\n")
        }

        // 5. Content-Length（1xx/204 禁发；304 允许）
        if (!mustSkipContentLengthOnWire(statusCode)) {
            p = appendString(dst, p, "Content-Length: ")
            p = appendInt64(dst, p, bodyLen)
            p = appendCRLF(dst, p)
        }

        // 6. 用户头
        var i: Int64 = 0
        let n = header.count()
        while (i < n) {
            p = appendBytes(dst, p, header.nameAt(i))
            p = appendString(dst, p, ": ")
            p = appendBytes(dst, p, header.valueAt(i))
            p = appendCRLF(dst, p)
            i += 1
        }

        // 7. Connection: close
        if (connectionClose) {
            p = appendString(dst, p, "Connection: close\r\n")
        }

        // 空行
        p = appendCRLF(dst, p)
        if (p > cap) { return -1 }

        // body 跟在 header 后面（同一块缓冲，一次 write）
        if (bodyLen > 0) {
            if (p + bodyLen > cap) {
                return -1
            }
            p = body.copyTo(dst, p)
        }
        w.commit(p)
        return p
    }
}

func appendByte(dst: Array<Byte>, p: Int64, b: Byte): Int64 {
    dst[p] = b
    return p + 1
}

func appendCRLF(dst: Array<Byte>, p: Int64): Int64 {
    dst[p] = 13
    dst[p + 1] = 10
    return p + 2
}

func appendString(dst: Array<Byte>, p: Int64, s: String): Int64 {
    let a = s.toArray()
    return appendArray(dst, p, a)
}

func appendArray(dst: Array<Byte>, p0: Int64, a: Array<Byte>): Int64 {
    var p = p0
    var i: Int64 = 0
    while (i < a.size) {
        dst[p] = a[i]
        p += 1
        i += 1
    }
    return p
}

func appendBytes(dst: Array<Byte>, p0: Int64, b: Bytes): Int64 {
    return b.copyTo(dst, p0)
}

func appendUInt16(dst: Array<Byte>, p0: Int64, v: UInt16): Int64 {
    return appendInt64(dst, p0, Int64(v))
}

func appendInt64(dst: Array<Byte>, p0: Int64, v0: Int64): Int64 {
    var p = p0
    if (v0 == 0) {
        dst[p] = 48
        return p + 1
    }
    var v = v0
    if (v < 0) {
        dst[p] = 45
        p += 1
        v = -v
    }
    // 最多 20 位
    var tmp: Array<Byte> = Array<Byte>(20, repeat: 0)
    var n: Int64 = 0
    while (v > 0) {
        tmp[n] = UInt8(v % 10 + 48)
        n += 1
        v = v / 10
    }
    while (n > 0) {
        n -= 1
        dst[p] = tmp[n]
        p += 1
    }
    return p
}
