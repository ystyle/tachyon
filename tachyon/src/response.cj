package ystyle::tachyon

import std.io.InputStream

/**
 * 响应。序列化顺序照抄 fasthttp（顺序是协议 + 兼容性要求）：
 *   状态行 -> Server -> Date -> Content-Type -> Content-Length -> 用户头 -> Set-Cookie -> Connection
 */
class Response {
    var statusCode: UInt16 = 200
    var header: HeaderTable
    var body: Bytes = Bytes.empty()
    // 直接持有 String（不 toArray），序列化时逐字节写；避免每请求一次 Array 分配
    var bodyStr: String = ""

    // 流式 body：size >= 0 定长，size < 0 chunked
    var bodyStream: ?InputStream = None
    var bodyStreamSize: Int64 = 0
    var bodyStreamChunked: Bool = false
    // 热路径用 bool 判断（Option 的 match 在每请求上都有开销）
    var hasStream: Bool = false

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
        bodyStr = ""
        bodyStream = None
        bodyStreamSize = 0
        bodyStreamChunked = false
        hasStream = false
        skipBody = false
        connectionClose = false
    }

    func setBody(b: Bytes): Unit {
        body = b
    }

    func setBodyString(s: String): Unit {
        body = Bytes.empty()
        bodyStr = s
        bodyStream = None
    }

    /**
     * 流式 body。size >= 0 已知长度（定长发送）；size < 0 未知（chunked）。
     * 对应 fasthttp 的 Response.SetBodyStream。
     */
    func setBodyStream(stream: InputStream, size: Int64): Unit {
        body = Bytes.empty()
        bodyStr = ""
        bodyStream = Some(stream)
        bodyStreamSize = size
        bodyStreamChunked = size < 0
        hasStream = true
    }

    func isStreaming(): Bool {
        return hasStream
    }

    func bodyLength(): Int64 {
        if (hasStream) {
            return if (bodyStreamSize >= 0) { bodyStreamSize } else { 0 }
        }
        if (bodyStr.size > 0) {
            return bodyStr.size
        }
        return body.size()
    }

    func setStatusCode(code: UInt16): Unit {
        statusCode = code
    }

    func setContentType(ct: String): Unit {
        // 存 String 而不是 Bytes(ct.toArray())：每请求省一次 Array 分配
        header.contentTypeStr = ct
        header.contentType = Bytes.empty()
    }

    /** 序列化到写缓冲。返回实际写入的字节数，-1 表示缓冲装不下 */
    func serialize(w: BufferedWriter, serverName: String, dateBuf: Array<Byte>, dateLen: Int64): Int64 {
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

        // 3. Date（缓存行，直接按有效长度 memcpy）
        if (!noDefaultDate && dateLen > 0) {
            var di: Int64 = 0
            while (di < dateLen) {
                dst[p] = dateBuf[di]
                p += 1
                di += 1
            }
        }

        let skipBodyHere = skipBody || mustSkipBody(statusCode)
        let bodyLen: Int64 = if (skipBodyHere) { 0 } else { bodyLength() }

        // 4. Content-Type（仅当有 body 或显式设置）
        if (header.contentTypeStr.size > 0) {
            p = appendString(dst, p, "Content-Type: ")
            p = appendString(dst, p, header.contentTypeStr)
            p = appendCRLF(dst, p)
        } else if (!header.contentType.isEmpty()) {
            p = appendString(dst, p, "Content-Type: ")
            p = appendBytes(dst, p, header.contentType)
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
            if (bodyStr.size > 0) {
                // 逐字节写 String，避免 toArray 分配
                for (b in bodyStr) {
                    dst[p] = b
                    p += 1
                }
            } else {
                p = body.copyTo(dst, p)
            }
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

func appendString(dst: Array<Byte>, p0: Int64, s: String): Int64 {
    // 直接遍历 String 的 UTF-8 字节（迭代 String 拿到的就是 UInt8），
    // 避免 s.toArray() 的每请求分配
    var p = p0
    for (b in s) {
        dst[p] = b
        p += 1
    }
    return p
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

/** 写小写十六进制（chunk-size 用） */
func appendHexInt(dst: Array<Byte>, p0: Int64, v0: Int64): Int64 {
    var p = p0
    if (v0 == 0) {
        dst[p] = 48
        return p + 1
    }
    var v = v0
    let tmp = Array<Byte>(20, repeat: 0)
    var n: Int64 = 0
    while (v > 0) {
        let d = v % 16
        tmp[n] = if (d < 10) { UInt8(d + 48) } else { UInt8(d - 10 + 97) }
        n += 1
        v = v / 16
    }
    while (n > 0) {
        n -= 1
        dst[p] = tmp[n]
        p += 1
    }
    return p
}
