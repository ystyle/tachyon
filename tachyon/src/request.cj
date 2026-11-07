package ystyle::tachyon

/**
 * 请求解析：一次扫描完成"找行尾 / 找冒号 / 校验 key / 记录 key 有无内部空格"，
 * 不做"先 indexOf(换行) 再 indexOf(冒号)"的两遍扫描。
 */
class Request {
    var method: Bytes = Bytes.empty()
    var requestURI: Bytes = Bytes.empty()
    var protocol: Bytes = Bytes.empty()
    var header: HeaderTable
    var uri: URIView = URIView()
    var body: Bytes = Bytes.empty()

    var isHTTP11: Bool = true
    var connectionClose: Bool = false
    var contentLength: Int64 = -2
    var isHead: Bool = false
    var isGet: Bool = false

    init(headerCap: Int64) {
        this.header = HeaderTable(headerCap)
    }

    func reset(): Unit {
        method = Bytes.empty()
        requestURI = Bytes.empty()
        protocol = Bytes.empty()
        header.reset()
        uri.reset(Bytes.empty())
        body = Bytes.empty()
        isHTTP11 = true
        connectionClose = false
        contentLength = -2
        isHead = false
        isGet = false
    }

    func path(): Bytes {
        return uri.path()
    }

    func queryArgs(): ArgsView {
        return uri.queryArgs()
    }

    func headerGetStr(name: String): Bytes {
        return header.getIgnoreCase(Bytes(name.toArray()))
    }

    /**
     * 解析 header block。buf 是整块读缓冲，[pos0, headerEnd) 是 header 部分。
     */
    func parseHeaders(buf: Array<Byte>, pos0: Int64, headerEnd: Int64): Bool {
        var pos = pos0

        // ---- 请求行：METHOD SP TARGET SP VERSION CRLF ----
        var p = pos
        while (p < headerEnd && buf[p] != 32) { p += 1 }
        if (p >= headerEnd) { connectionClose = true; return false }
        method = Bytes(buf, pos, p - pos)

        pos = p + 1
        p = pos
        while (p < headerEnd && buf[p] != 32) { p += 1 }
        if (p >= headerEnd) { connectionClose = true; return false }
        requestURI = Bytes(buf, pos, p - pos)
        uri.reset(requestURI)

        pos = p + 1
        p = pos
        while (p + 1 < headerEnd && !(buf[p] == 13 && buf[p + 1] == 10)) { p += 1 }
        if (p + 1 >= headerEnd) { connectionClose = true; return false }
        protocol = Bytes(buf, pos, p - pos)
        isHTTP11 = protocol.equals(Bytes(strHTTP11))

        pos = p + 2

        // ---- header 行 ----
        var contentLengthSeen = false
        var hostSeen = false
        while (pos + 1 < headerEnd) {
            if (buf[pos] == 13 && buf[pos + 1] == 10) { pos += 2; break }

            var e = pos
            var colonPos: Int64 = -1
            var keyValid = true
            while (e + 1 < headerEnd && !(buf[e] == 13 && buf[e + 1] == 10)) {
                let c = buf[e]
                if (colonPos < 0) {
                    if (c == 58) {
                        colonPos = e
                    } else if (!isValidHeaderFieldByte(c)) {
                        keyValid = false
                    }
                } else if (c == 0) {
                    keyValid = false
                }
                e += 1
            }
            if (e + 1 >= headerEnd) { connectionClose = true; return false }
            if (colonPos < 0 || colonPos == pos || !keyValid) { connectionClose = true; return false }

            var vs = colonPos + 1
            while (vs < e && (buf[vs] == 32 || buf[vs] == 9)) { vs += 1 }
            var ve = e
            while (ve > vs && (buf[ve - 1] == 32 || buf[ve - 1] == 9)) { ve -= 1 }

            let keyView = Bytes(buf, pos, colonPos - pos)
            let valView = Bytes(buf, vs, ve - vs)

            var handled = false
            let lower0 = buf[pos] | 0x20
            if (lower0 == 104) {
                if (keyView.equalsAsciiIgnoreCase(Bytes(hdrHost))) {
                    if (hostSeen) { connectionClose = true; return false }
                    hostSeen = true
                    header.host = header.copyIn(buf, vs, ve)
                    handled = true
                }
            } else if (lower0 == 99) {
                if (keyView.equalsAsciiIgnoreCase(Bytes(hdrContentLength))) {
                    if (contentLengthSeen) { connectionClose = true; return false }
                    contentLengthSeen = true
                    let cl = parseContentLength(buf, vs, ve)
                    if (cl < 0) { connectionClose = true; return false }
                    contentLength = cl
                    header.contentLengthBytes = header.copyIn(buf, vs, ve)
                    handled = true
                } else if (keyView.equalsAsciiIgnoreCase(Bytes(hdrContentType))) {
                    header.contentType = header.copyIn(buf, vs, ve)
                    handled = true
                } else if (keyView.equalsAsciiIgnoreCase(Bytes(hdrConnection))) {
                    header.connection = header.copyIn(buf, vs, ve)
                    if (containsToken(valView, "close")) { connectionClose = true }
                    handled = true
                } else if (keyView.equalsAsciiIgnoreCase(Bytes(hdrCookie))) {
                    header.cookie = header.copyIn(buf, vs, ve)
                    handled = true
                }
            } else if (lower0 == 116) {
                if (keyView.equalsAsciiIgnoreCase(Bytes(hdrTransferEncoding))) {
                    header.transferEncoding = header.copyIn(buf, vs, ve)
                    if (containsToken(valView, "chunked")) { contentLength = -1 }
                    handled = true
                }
            } else if (lower0 == 117) {
                if (keyView.equalsAsciiIgnoreCase(Bytes(hdrUserAgent))) {
                    header.userAgent = header.copyIn(buf, vs, ve)
                    handled = true
                }
            } else if (lower0 == 101) {
                if (keyView.equalsAsciiIgnoreCase(Bytes(hdrExpect))) {
                    header.expect = header.copyIn(buf, vs, ve)
                    handled = true
                }
            }

            if (!handled) {
                let k = header.copyIn(buf, pos, colonPos)
                let v = header.copyIn(buf, vs, ve)
                header.add(k, v)
            }

            pos = e + 2
        }

        // ---- 安全判定（RFC 9112 §6.3）----
        if (contentLength < 0) {
            header.contentLengthBytes = Bytes.empty()
        }
        if (contentLengthSeen && !header.transferEncoding.isEmpty()) {
            connectionClose = true
        }
        if (isHTTP11 && !hostSeen) {
            connectionClose = true
            return false
        }
        if (!isHTTP11) {
            if (!containsToken(header.connection, "keep-alive")) {
                connectionClose = true
            }
        }

        isHead = method.equals(Bytes("HEAD".toArray()))
        isGet = method.equals(Bytes("GET".toArray()))
        return true
    }
}

/** header 字段名字节是否合法（RFC 9110 tchar） */
func isValidHeaderFieldByte(c: Byte): Bool {
    if (c >= 48 && c <= 57) { return true }
    if (c >= 65 && c <= 90) { return true }
    if (c >= 97 && c <= 122) { return true }
    if (c == 33 || c == 35 || c == 36 || c == 37 || c == 38 || c == 39) { return true }
    if (c == 42 || c == 43 || c == 45 || c == 46) { return true }
    if (c == 94 || c == 95 || c == 96 || c == 124 || c == 126) { return true }
    return false
}

/** 解析十进制 Content-Length，失败返回 -1 */
func parseContentLength(buf: Array<Byte>, from: Int64, to: Int64): Int64 {
    if (to <= from) { return -1 }
    var v: Int64 = 0
    var i = from
    while (i < to) {
        let c = buf[i]
        if (c < 48 || c > 57) { return -1 }
        v = v * 10 + (Int64(c) - 48)
        if (v > 1000000000000) { return -1 }
        i += 1
    }
    return v
}

/** 逗号分隔 token 列表是否含某个 token（大小写无关） */
func containsToken(v: Bytes, token: String): Bool {
    let t = token.toArray()
    let n = v.size()
    var i: Int64 = 0
    while (i < n) {
        while (i < n && (v[i] == 44 || v[i] == 32 || v[i] == 9)) { i += 1 }
        let start = i
        while (i < n && v[i] != 44) { i += 1 }
        var end = i
        while (end > start && (v[end - 1] == 32 || v[end - 1] == 9)) { end -= 1 }
        if (end - start == t.size) {
            var j: Int64 = 0
            var ok = true
            while (j < t.size) {
                if ((v[start + j] | 0x20) != (t[j] | 0x20)) { ok = false; break }
                j += 1
            }
            if (ok) { return true }
        }
    }
    return false
}
