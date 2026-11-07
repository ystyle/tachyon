package ystyle::tachyon

import std.collection.ArrayList

/**
 * 请求 Cookie 视图。惰性解析 "Cookie: a=1; b=2"。
 */
public class CookieView {
    var raw: Bytes = Bytes.empty()
    var parsed: Bool = false
    var names: ArrayList<Bytes> = ArrayList<Bytes>()
    var values: ArrayList<Bytes> = ArrayList<Bytes>()

    public func reset(raw: Bytes): Unit {
        this.raw = raw
        parsed = false
        names.clear()
        values.clear()
    }

    public func parse(): Unit {
        if (parsed || raw.isEmpty()) {
            return
        }
        parsed = true
        let n = raw.size()
        var pos: Int64 = 0
        while (pos < n) {
            // 跳过 ';' 与空白
            while (pos < n && (raw[pos] == 59 || raw[pos] == 32 || raw[pos] == 9)) {
                pos += 1
            }
            if (pos >= n) {
                break
            }
            // 找这一对的 ';'
            var end = pos
            while (end < n && raw[end] != 59) {
                end += 1
            }
            // 去尾部空白
            var e = end
            while (e > pos && (raw[e - 1] == 32 || raw[e - 1] == 9)) {
                e -= 1
            }
            // 找 '='
            var eq: Int64 = -1
            var i = pos
            while (i < e) {
                if (raw[i] == 61) {
                    eq = i
                    break
                }
                i += 1
            }
            if (eq > pos) {
                var vs = eq + 1
                if (vs < e && raw[vs] == 34) {   // 去掉包裹的双引号
                    vs += 1
                    if (e > vs && raw[e - 1] == 34) {
                        e -= 1
                    }
                }
                names.add(raw.slice(pos, eq))
                values.add(raw.slice(vs, e))
            }
            pos = end + 1
        }
    }

    public func get(name: String): Bytes {
        parse()
        let nb = name.toArray()
        var i: Int64 = 0
        let cnt = names.size
        while (i < cnt) {
            if (names[i].equals(Bytes(nb))) {
                return values[i]
            }
            i += 1
        }
        return Bytes.empty()
    }

    public func count(): Int64 {
        parse()
        return names.size
    }

    public func nameAt(i: Int64): Bytes {
        parse()
        return names[i]
    }

    public func valueAt(i: Int64): Bytes {
        parse()
        return values[i]
    }
}

/**
 * 响应 Set-Cookie 构建器。
 * 序列化顺序照搬 fasthttp cookie.go:290。
 */
public class SetCookieBuilder {
    var name: String = ""
    var value: String = ""
    var path: String = ""
    var domain: String = ""
    var maxAge: Int64 = 0
    var httpOnly: Bool = false
    var secure: Bool = false
    var sameSite: String = ""   // "Lax" / "Strict" / "None"

    public init(name: String, value: String) {
        this.name = name
        this.value = value
    }

    public func setPath(p: String): SetCookieBuilder { path = p; return this }
    public func setDomain(d: String): SetCookieBuilder { domain = d; return this }
    public func setMaxAge(s: Int64): SetCookieBuilder { maxAge = s; return this }
    public func setHttpOnly(): SetCookieBuilder { httpOnly = true; return this }
    public func setSecure(): SetCookieBuilder { secure = true; return this }
    public func setSameSite(s: String): SetCookieBuilder { sameSite = s; return this }

    public func toString(): String {
        var sb = StringBuilder()
        sb.append(name)
        sb.append("=")
        sb.append(value)
        if (maxAge > 0) {
            sb.append("; max-age=")
            sb.append(maxAge.toString())
        } else if (maxAge < 0) {
            sb.append("; max-age=0")   // 立即删除的约定
        }
        if (domain.size > 0) {
            sb.append("; domain=")
            sb.append(domain)
        }
        if (path.size > 0) {
            sb.append("; path=")
            sb.append(path)
        }
        if (httpOnly) {
            sb.append("; HttpOnly")
        }
        if (secure) {
            sb.append("; secure")
        }
        if (sameSite.size > 0) {
            sb.append("; SameSite=")
            sb.append(sameSite)
        }
        return sb.toString()
    }
}
