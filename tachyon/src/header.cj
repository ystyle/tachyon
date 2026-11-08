package ystyle::tachyon

import std.collection.ArrayList

/**
 * HTTP 头表，照搬 fasthttp 的 argsKV 模型：names/values 两个平行数组，
 * 每个元素是指向 hdrBuf 的 Bytes 视图。
 *
 * 为什么不做"单 slab + 偏移"：fasthttp 实测每个 key/value 是独立切片，
 * 复用靠"底层数组跨请求保留 + 截断重填"。平行数组 + 截断是最直接的等价物。
 *
 * 视图指向 per-connection 的 hdrBuf（而不是读缓冲），因为读缓冲会被下一次
 * read 覆盖，而 handler 里可能要求 header 值活过整个请求。
 */
class HeaderTable {
    var names: ArrayList<Bytes> = ArrayList<Bytes>()
    var values: ArrayList<Bytes> = ArrayList<Bytes>()
    var hdrBuf: Array<Byte>
    var hdrLen: Int64 = 0

    // ---- 特殊头：走专用字段，不进表（查 Host/Content-Length 是 O(1)）----
    var host: Bytes = Bytes.empty()
    var userAgent: Bytes = Bytes.empty()
    var contentType: Bytes = Bytes.empty()
    var connection: Bytes = Bytes.empty()
    var transferEncoding: Bytes = Bytes.empty()
    var cookie: Bytes = Bytes.empty()
    var expect: Bytes = Bytes.empty()
    var contentLengthBytes: Bytes = Bytes.empty()
    // 显式设置的 Content-Type 用 String 存（避免每请求 toArray 分配）
    var contentTypeStr: String = ""

    init(capacity: Int64) {
        this.hdrBuf = Array<Byte>(capacity, repeat: 0)
    }

    func reset(): Unit {
        names.clear()
        values.clear()
        hdrLen = 0
        host = Bytes.empty()
        userAgent = Bytes.empty()
        contentType = Bytes.empty()
        connection = Bytes.empty()
        transferEncoding = Bytes.empty()
        cookie = Bytes.empty()
        expect = Bytes.empty()
        contentLengthBytes = Bytes.empty()
        contentTypeStr = ""
    }

    /**
     * 从源视图复制一段字节到 hdrBuf，返回指向副本的视图。
     * 复制是必须的：读缓冲会被下一次 read 覆盖。
     */
    func copyIn(src: Array<Byte>, from: Int64, to: Int64): Bytes {
        return copyIn(Bytes(src), from, to)
    }

    func copyIn(src: Bytes, from: Int64, to: Int64): Bytes {
        let n = to - from
        if (hdrLen + n > hdrBuf.size) {
            // 极端情况（超大 header）：放弃复制，直接返回源视图。
            // 这会带来"handler 返回后视图失效"的语义，但比抛异常好。
            return src.slice(from, to)
        }
        var i: Int64 = 0
        while (i < n) {
            hdrBuf[hdrLen + i] = src[from + i]
            i += 1
        }
        let v = Bytes(hdrBuf, hdrLen, n)
        hdrLen += n
        return v
    }

    func add(name: Bytes, value: Bytes): Unit {
        names.add(name)
        values.add(value)
    }

    /** 按名字精确查找（大小写敏感，要求调用方传入正确大小写） */
    func get(name: Bytes): Bytes {
        var i: Int64 = 0
        let n = names.size
        while (i < n) {
            if (names[i].equals(name)) {
                return values[i]
            }
            i += 1
        }
        return Bytes.empty()
    }

    /** 按名字大小写无关查找 */
    func getIgnoreCase(name: Bytes): Bytes {
        var i: Int64 = 0
        let n = names.size
        while (i < n) {
            if (names[i].equalsAsciiIgnoreCase(name)) {
                return values[i]
            }
            i += 1
        }
        return Bytes.empty()
    }

    func count(): Int64 {
        return names.size
    }

    func nameAt(i: Int64): Bytes {
        return names[i]
    }

    func valueAt(i: Int64): Bytes {
        return values[i]
    }
}

/** 预置的常量名字，避免每次比较时构造新数组 */
let hdrHost: Array<Byte> = "Host".toArray()
let hdrContentLength: Array<Byte> = "Content-Length".toArray()
let hdrContentType: Array<Byte> = "Content-Type".toArray()
let hdrUserAgent: Array<Byte> = "User-Agent".toArray()
let hdrTransferEncoding: Array<Byte> = "Transfer-Encoding".toArray()
let hdrConnection: Array<Byte> = "Connection".toArray()
let hdrCookie: Array<Byte> = "Cookie".toArray()
let hdrExpect: Array<Byte> = "Expect".toArray()
let hdrServer: Array<Byte> = "Server".toArray()
let hdrDate: Array<Byte> = "Date".toArray()
let hdrSetCookie: Array<Byte> = "Set-Cookie".toArray()
let valueClose: Array<Byte> = "close".toArray()
let valueKeepAlive: Array<Byte> = "keep-alive".toArray()
let valueChunked: Array<Byte> = "chunked".toArray()
let valueChunkedLower: Array<Byte> = "chunked".toArray()
let strHTTP11: Array<Byte> = "HTTP/1.1".toArray()
let strHTTP10: Array<Byte> = "HTTP/1.0".toArray()
let strCRLF: Array<Byte> = "\r\n".toArray()
let strHeaderEnd: Array<Byte> = "\r\n\r\n".toArray()
