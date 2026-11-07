package ystyle::tachyon

/**
 * URI 视图。惰性解析：只有调用 path()/query()/args() 时才真正解析，
 * 解析结果缓存在字段里（照搬 fasthttp 的 parsedURI 布尔位）。
 */
public class URIView {
    var raw: Bytes = Bytes.empty()
    var parsed: Bool = false
    var parseErr: Bool = false

    var pathView: Bytes = Bytes.empty()
    var queryView: Bytes = Bytes.empty()
    var pathBuf: Array<Byte> = Array<Byte>(1024, repeat: 0)

    var argsParsed: Bool = false
    var args: ArgsView = ArgsView()

    public func reset(raw: Bytes): Unit {
        this.raw = raw
        parsed = false
        parseErr = false
        pathView = Bytes.empty()
        queryView = Bytes.empty()
        argsParsed = false
        args.reset()
    }

    /** 解析 path 与 query。失败返回 false（调用方应回 400） */
    public func parse(): Bool {
        if (parsed) {
            return !parseErr
        }
        parsed = true
        let s = raw
        let n = s.size()
        if (n == 0) {
            parseErr = true
            return false
        }

        // 找 '?' 与 '#'
        var q: Int64 = -1
        var h: Int64 = -1
        var i: Int64 = 0
        while (i < n) {
            let c = s[i]
            if (c == question && q < 0) {
                q = i
            } else if (c == 35) { // '#'
                h = i
                break
            }
            i += 1
        }

        // path 段 = [0, min(q,h,n))
        var pathEnd = n
        if (q >= 0 && q < pathEnd) {
            pathEnd = q
        }
        if (h >= 0 && h < pathEnd) {
            pathEnd = h
        }
        // query 段 = (q, min(h,n))
        if (q >= 0 && q + 1 <= n) {
            var qEnd = n
            if (h > q) {
                qEnd = h
            }
            queryView = s.slice(q + 1, qEnd)
        }

        // 路径规范化
        let rawPath = s.slice(0, pathEnd)
        pathView = normalizePath(rawPath, pathBuf)
        return true
    }

    public func path(): Bytes {
        if (!parse()) {
            return Bytes.empty()
        }
        return pathView
    }

    public func query(): Bytes {
        if (!parse()) {
            return Bytes.empty()
        }
        return queryView
    }

    public func queryArgs(): ArgsView {
        if (!parse()) {
            return args
        }
        if (!argsParsed) {
            argsParsed = true
            args.parse(queryView)
        }
        return args
    }
}

/**
 * 路径规范化，顺序必须照抄 fasthttp（顺序有安全含义）：
 *   1. "/" -> 直接返回
 *   2. 补前导斜杠
 *   3. 百分号解码（'+' 不动，path 里 '+' 是字面量）
 *   4. 去重复斜杠
 *   5. 没有 '.' 就返回（快路径）
 *   6. 去 "." / ".."（RFC 3986 §5.2.4）
 *
 * "先解码再处理 dot-segment"不可颠倒，否则 %2e%2e 会被当普通字符放过去（目录穿越）。
 */
public func normalizePath(src: Bytes, out: Array<Byte>): Bytes {
    let n = src.size()
    if (n == 0) {
        out[0] = slash
        return Bytes(out, 0, 1)
    }
    if (n == 1 && src[0] == slash) {
        out[0] = slash
        return Bytes(out, 0, 1)
    }

    var w: Int64 = 0
    var i: Int64 = 0

    // 2. 补前导斜杠
    if (src[0] != slash) {
        out[w] = slash
        w += 1
    }

    // 3 + 4. 百分号解码 + 去重复斜杠，一趟做完
    var lastWasSlash = w > 0 && out[w - 1] == slash
    while (i < n) {
        let c = src[i]
        if (c == percent && i + 2 < n) {
            let hi = hexVal(src[i + 1])
            let lo = hexVal(src[i + 2])
            if (hi >= 0 && lo >= 0) {
                let b = UInt8(hi * 16 + lo)
                if (b == slash && lastWasSlash) {
                    i += 3
                    continue
                }
                out[w] = b
                lastWasSlash = (b == slash)
                w += 1
                i += 3
                continue
            }
            // 非法转义：原样保留 '%'
        }
        if (c == slash && lastWasSlash) {
            i += 1
            continue
        }
        out[w] = c
        lastWasSlash = (c == slash)
        w += 1
        i += 1
    }
    let decoded = Bytes(out, 0, w)

    // 5. 快路径：没有 '.' 就不用处理 dot-segment
    var hasDot = false
    var k: Int64 = 0
    while (k < w) {
        if (out[k] == dot) {
            hasDot = true
            break
        }
        k += 1
    }
    if (!hasDot) {
        return decoded
    }

    // 6. 去 "." / ".."
    return removeDotSegments(decoded, out)
}

public func hexVal(c: Byte): Int64 {
    if (c >= 48 && c <= 57) {
        return Int64(c) - 48
    }
    let l = c | 0x20
    if (l >= 97 && l <= 102) {
        return Int64(l) - 87
    }
    return -1
}

/**
 * RFC 3986 §5.2.4 的 dot-segment 移除，单遍原地重写（fasthttp 也是 O(n)）。
 * 输入输出可共用同一块 buffer（从前往后写，读位置永远 >= 写位置）。
 */
public func removeDotSegments(src: Bytes, out: Array<Byte>): Bytes {
    var w: Int64 = 0
    var i: Int64 = 0
    let n = src.size()

    // 输出保证以 '/' 开头
    out[w] = slash
    w += 1

    while (i < n) {
        // 跳过斜杠
        if (src[i] == slash) {
            i += 1
            continue
        }
        // 读一段 segment [segStart, segEnd)
        let segStart = i
        while (i < n && src[i] != slash) {
            i += 1
        }
        let segEnd = i
        let segLen = segEnd - segStart

        if (segLen == 1 && src[segStart] == dot) {
            continue   // "." 直接跳过
        }
        if (segLen == 2 && src[segStart] == dot && src[segStart + 1] == dot) {
            // ".." 回退一层：先把末尾斜杠去掉，再退到上一个斜杠
            if (w > 1 && out[w - 1] == slash) {
                w -= 1
            }
            while (w > 1 && out[w - 1] != slash) {
                w -= 1
            }
            if (w > 1 && out[w - 1] == slash) {
                w -= 1
            }
            continue
        }

        // 普通 segment：先补斜杠（根之后的第一段不加）
        if (w > 0 && out[w - 1] != slash) {
            out[w] = slash
            w += 1
        }
        var j: Int64 = segStart
        while (j < segEnd) {
            out[w] = src[j]
            w += 1
            j += 1
        }
        // 读到的源在这里还有后续（有斜杠），补一个斜杠
        if (i < n) {
            out[w] = slash
            w += 1
        }
    }

    if (w == 0) {
        out[0] = slash
        return Bytes(out, 0, 1)
    }
    // 注意：保留结尾斜杠（/a/b/ 仍是 /a/b/）。
    // 这是 fasthttp normalizePath 的行为（uri.go:745）—— 结尾斜杠在 HTTP 语义里
    // 是有意义的（目录 vs 资源），规范化不能抹掉它。
    return Bytes(out, 0, w)
}
