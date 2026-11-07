package ystyle::tachyon

import std.collection.ArrayList
import std.io.InputStream

/**
 * multipart/form-data 解析（RFC 7578）。
 *
 * 支持：
 *   - 普通字段（不带 filename 的 part）
 *   - 文件字段（带 filename 的 part，内容在内存里）
 *   - boundary 从 Content-Type 里提取
 *
 * 不做：
 *   - 流式解析（整个 body 必须先读进内存 —— 与 fasthttp 默认行为一致）
 *   - nested multipart/mixed
 *   - 文件落盘（SaveMultipartFile 那种，需要用户自己写）
 *
 * 内存代价：body 已经是内存里的 Bytes，part 内容用视图指向它，**不额外拷贝**。
 */
public class MultipartForm {
    var fields: ArrayList<MultipartPart> = ArrayList<MultipartPart>()

    public func field(name: String): ?Bytes {
        var i: Int64 = 0
        while (i < fields.size) {
            let p = fields[i]
            if (p.name == name && !p.isFile) {
                return Some(p.data)
            }
            i += 1
        }
        return None
    }

    public func file(name: String): ?MultipartPart {
        var i: Int64 = 0
        while (i < fields.size) {
            let p = fields[i]
            if (p.name == name && p.isFile) {
                return Some(p)
            }
            i += 1
        }
        return None
    }

    public func count(): Int64 {
        return fields.size
    }

    public func partAt(i: Int64): MultipartPart {
        return fields[i]
    }
}

/** 一个 multipart part */
public class MultipartPart {
    public var name: String = ""
    public var fileName: String = ""
    public var contentType: String = ""
    public var data: Bytes = Bytes.empty()
    public var isFile: Bool = false
}

/**
 * 从 Content-Type 里提取 boundary。
 * 形如 "multipart/form-data; boundary=----WebKitFormBoundaryXXX"
 */
public func extractBoundary(contentType: Bytes): ?String {
    let ct = contentType.toStr()
    if (!ct.startsWith("multipart/form-data")) {
        return None
    }
    let marker = "boundary="
    let idx = match (ct.indexOf(marker)) {
        case Some(i) => i
        case None => return None
    }
    var start = idx + marker.size
    if (start >= ct.size) {
        return None
    }
    // boundary 可能被双引号包裹
    if (ct[start] == 34) {
        start += 1
        var endQ = start
        while (endQ < ct.size && ct[endQ] != 34) {
            endQ += 1
        }
        if (endQ >= ct.size) {
            return None
        }
        return Some(ct[start..endQ])
    }
    var end = start
    while (end < ct.size && ct[end] != 59 && ct[end] != 32) {
        end += 1
    }
    if (end == start) {
        return None
    }
    return Some(ct[start..end])
}

/**
 * 解析 multipart body。
 *
 * 分隔符是 "\r\n--<boundary>"，第一段前面没有 CRLF，
 * 所以实际做法是：在 body 前拼一个 CRLF，然后按 "\r\n--<boundary>" 切。
 * 结尾是 "\r\n--<boundary>--"。
 */
public func parseMultipart(body: Bytes, boundary: String): MultipartForm {
    let form = MultipartForm()
    if (body.isEmpty() || boundary.size == 0) {
        return form
    }
    // 构造分隔符字节：CRLF + "--" + boundary
    let delimStr = crlf() + "--" + boundary
    let delim = delimStr.toArray()

    // 在 body 前面补一个虚拟 CRLF，让第一段也能用同样的分隔符切
    let padded = Array<Byte>(body.size() + 2, repeat: 0)
    padded[0] = 13
    padded[1] = 10
    var i: Int64 = 0
    while (i < body.size()) {
        padded[i + 2] = body[i]
        i += 1
    }
    let paddedView = Bytes(padded)

    // 逐个找分隔符位置
    var positions: ArrayList<Int64> = ArrayList<Int64>()
    var searchFrom: Int64 = 0
    while (true) {
        let p = paddedView.indexOfSeq(delim, searchFrom)
        if (p < 0) {
            break
        }
        positions.add(p)
        searchFrom = p + delim.size
    }
    if (positions.size < 1) {
        return form
    }

    var k: Int64 = 0
    while (k < positions.size) {
        let segStart = positions[k] + delim.size
        // 这一段是 "--" 就说明结束了
        if (segStart + 1 < padded.size && padded[segStart] == 45 && padded[segStart + 1] == 45) {
            break
        }
        var segEnd = padded.size
        if (k + 1 < positions.size) {
            segEnd = positions[k + 1]
        }
        // part 内容：从 segStart（跳过 CRLF）到 segEnd
        var ps = segStart
        if (ps + 1 < padded.size && padded[ps] == 13 && padded[ps + 1] == 10) {
            ps += 2
        }
        if (ps < segEnd) {
            let part = parsePart(Bytes(padded, ps, segEnd - ps))
            form.fields.add(part)
        }
        k += 1
    }
    return form
}

/** 解析单个 part：[headers] CRLFCRLF [data] */
func parsePart(seg: Bytes): MultipartPart {
    let part = MultipartPart()
    // 找 header/body 分界 CRLFCRLF
    let sep = [13u8, 10u8, 13u8, 10u8]
    let idx = seg.indexOfSeq(sep, 0)
    if (idx < 0) {
        // 没有 header，整段都是 data
        part.data = seg
        return part
    }
    let headerBlock = seg.slice(0, idx)
    part.data = seg.slice(idx + 4, seg.size())

    // 逐行解析 header
    var lineStart: Int64 = 0
    let hn = headerBlock.size()
    while (lineStart < hn) {
        var lineEnd = headerBlock.indexOf(13, lineStart)
        if (lineEnd < 0) {
            lineEnd = hn
        }
        let line = headerBlock.slice(lineStart, lineEnd)
        // "Content-Disposition: form-data; name=\"x\"; filename=\"y\""
        if (line.startsWith("Content-Disposition".toArray())) {
            part.name = extractAttr(line.toStr(), "name")
            let fn = extractAttr(line.toStr(), "filename")
            if (fn.size > 0) {
                part.fileName = fn
                part.isFile = true
            }
        } else if (line.startsWith("Content-Type".toArray())) {
            let s = line.toStr()
            let i = match (s.indexOf(":")) { case Some(v) => v; case None => -1 }
            if (i >= 0) {
                part.contentType = s[i + 1..].trimAscii()
            }
        }
        lineStart = lineEnd + 2
    }
    return part
}

/** 从 "Content-Disposition: ...; name=\"value\"" 里取属性值 */
func extractAttr(s: String, attr: String): String {
    let key = attr + "=" + "\""
    let i = match (s.indexOf(key)) {
        case Some(v) => v
        case None => return ""
    }
    let start = i + key.size
    var end = start
    while (end < s.size && s[end] != 34) {
        end += 1
    }
    if (end >= s.size) {
        return ""
    }
    return s[start..end]
}