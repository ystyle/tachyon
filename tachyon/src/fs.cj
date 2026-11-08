package ystyle::tachyon

import std.fs.*
import std.time.*
import std.io.*
import std.core.*
import std.collection.ArrayList

/**
 * 静态文件处理器。
 *
 * 支持：
 *   - 目录索引（默认 index.html）
 *   - Range 请求（单区间，RFC 9110 §14）
 *   - If-Modified-Since / Last-Modified（304）
 *   - 路径穿越防护（规范化后必须仍在 root 下）
 *
 * 不做：ETag（需要摘要算法，主模块零 stdx）、sendfile（std.net 拿不到 fd）。
 */
public class FileServer {
    var root: String
    var indexNames: ArrayList<String> = ArrayList<String>()
    var allowRange: Bool = true
    var maxAgeSeconds: Int64 = 0

    public init(root: String) {
        this.root = root
        indexNames.add("index.html")
        indexNames.add("index.htm")
        this.root = normalizeRoot(root)
    }

    func normalizeRoot(r: String): String {
        var s = r
        while (s.size > 1 && s.endsWith("/")) {
            s = s[0..s.size - 1]
        }
        return s
    }

    /** 追加目录索引文件名 */
    public func addIndexName(name: String): Unit {
        var i: Int64 = 0
        while (i < indexNames.size) {
            if (indexNames[i] == name) {
                return
            }
            i += 1
        }
        indexNames.add(name)
    }

    /** 是否支持 Range 请求 */
    public func setAllowRange(allow: Bool): Unit {
        allowRange = allow
    }

    /** Cache-Control 的 max-age（秒），<=0 表示不输出 */
    public func setMaxAge(seconds: Int64): Unit {
        maxAgeSeconds = seconds
    }

    /** 挂载到指定前缀下（如 "/static"），会自动剥离前缀再拼文件路径 */
    public func serve(ctx: RequestCtx, mountPrefix: String): Unit {
        let rawPath = ctx.path().toStr()
        if (!rawPath.startsWith(mountPrefix)) {
            ctx.error("Not Found", 404)
            return
        }
        let rest = rawPath[mountPrefix.size..]
        handlerWithPath(ctx, if (rest.size == 0) { "/" } else { rest })
    }

    /** 直接按 ctx.path() 当文件路径（挂载点就是 root 时用） */
    public func handler(ctx: RequestCtx): Unit {
        handlerWithPath(ctx, ctx.path().toStr())
    }

    func handlerWithPath(ctx: RequestCtx, p0: String): Unit {
        // 只服务 GET / HEAD
        if (!ctx.isGet() && !ctx.isHead()) {
            ctx.error("Method Not Allowed", 405)
            return
        }

        let p = p0
        if (p.isEmpty()) {
            ctx.error("Bad Request", 400)
            return
        }

        // 路径穿越防护：规范化后的 path 已经是干净的（uri.normalizePath 做了 dot-segment），
        // 但还要确保不含 ".." 残片
        if (p.contains("..")) {
            ctx.error("Forbidden", 403)
            return
        }

        // 拼绝对路径：root 已去掉尾部斜杠，p 以 "/" 开头，直接拼
        var full = root + (if (p.startsWith("/")) { p } else { "/" + p })
        // 去掉重复斜杠（root + "/" + "/" 会变成双斜杠）
        if (p == "/") {
            full = root
        }

        var info = statOf(full)
        if (info.exists && info.isDir) {
            // 目录：尝试 index 文件
            var found = false
            var i: Int64 = 0
            while (i < indexNames.size) {
                let cand = (if (full.endsWith("/")) { full + indexNames[i] } else { full + "/" + indexNames[i] })
                let ci = statOf(cand)
                if (ci.exists && !ci.isDir) {
                    full = cand
                    info = ci
                    found = true
                    break
                }
                i += 1
            }
            if (!found) {
                ctx.error("Not Found", 404)
                return
            }
        } else if (!info.exists) {
            // 尝试目录索引
            var found = false
            var i: Int64 = 0
            while (i < indexNames.size) {
                let cand = (if (full.endsWith("/")) { full + indexNames[i] } else { full + "/" + indexNames[i] })
                let ci = statOf(cand)
                if (ci.exists) {
                    full = cand
                    info = ci
                    found = true
                    break
                }
                i += 1
            }
            if (!found) {
                ctx.error("Not Found", 404)
                return
            }
        }

        // If-Modified-Since
        let ims = ctx.headerGet("If-Modified-Since")
        if (!ims.isEmpty() && info.mtimeSec > 0) {
            let since = parseHTTPDate(ims)
            if (since > 0 && info.mtimeSec <= since) {
                ctx.setStatusCode(304)
                ctx.setHeader("Last-Modified", formatHTTPDate(info.mtimeSec))
                return
            }
        }

        ctx.setHeader("Last-Modified", formatHTTPDate(info.mtimeSec))
        ctx.setContentType(contentTypeOf(full))
        if (maxAgeSeconds > 0) {
            ctx.setHeader("Cache-Control", "max-age=" + maxAgeSeconds.toString())
        }

        // Range
        let rangeHdr = ctx.headerGet("Range")
        if (allowRange && !rangeHdr.isEmpty()) {
            let r = parseRange(rangeHdr, info.size)
            match (r) {
                case Some(rr) =>
                    if (rr.start > rr.end || rr.end >= info.size) {
                        ctx.setStatusCode(416)
                        ctx.setHeader("Content-Range", "bytes */" + info.size.toString())
                        ctx.setBodyString("")
                        return
                    }
                    let data = readFileRange(full, rr.start, rr.end - rr.start + 1)
                    match (data) {
                        case Some(d) =>
                            ctx.setStatusCode(206)
                            ctx.setHeader(
                                "Content-Range",
                                "bytes " + rr.start.toString() + "-" + rr.end.toString() + "/" + info.size.toString()
                            )
                            ctx.setBody(Bytes(d))
                        case None =>
                            ctx.error("Internal Server Error", 500)
                    }
                    return
                case None => ()
            }
        }

        // 整个文件
        let data = readFile(full)
        match (data) {
            case Some(d) =>
                ctx.setStatusCode(200)
                ctx.setBody(Bytes(d))
            case None =>
                ctx.error("Internal Server Error", 500)
        }
    }
}

class FileStat {
    var exists: Bool = false
    var isDir: Bool = false
    var size: Int64 = 0
    var mtimeSec: Int64 = 0
}

func statOf(p: String): FileStat {
    let st = FileStat()
    // 先判目录：能列出来就是目录
    try {
        let _ = Directory.readFrom(Path(p))
        st.exists = true
        st.isDir = true
        st.size = 0
        st.mtimeSec = 0
        return st
    } catch (e: Exception) {}
    // 再按文件打开
    try {
        let f = File(Path(p), OpenMode.Read)
        let info = f.info
        f.close()
        st.exists = true
        st.isDir = false
        st.size = info.size
        st.mtimeSec = dateTimeToUnixSec(info.lastModificationTime)
    } catch (e: Exception) {
        st.exists = false
    }
    return st
}

public class RangeSpec {
    public var start: Int64
    public var end: Int64
    public init(s: Int64, e: Int64) {
        start = s
        end = e
    }
}

/** 解析 "bytes=start-end" / "bytes=start-" / "bytes=-suffix" */
public func parseRange(h: Bytes, fileSize: Int64): ?RangeSpec {
    let s = h.toStr().trimAscii()
    if (!s.startsWith("bytes=")) {
        return None
    }
    let spec = s["bytes=".size..]
    let dash = match (spec.indexOf("-")) { case Some(i) => i; case None => -1 }
    if (dash < 0) {
        return None
    }
    let a = spec[0..dash].trimAscii()
    let b = spec[dash + 1..].trimAscii()
    var start: Int64 = 0
    var end: Int64 = 0
    if (a.size == 0) {
        // bytes=-N : 最后 N 个字节
        let n = parseI64(b)
        if (n <= 0) {
            return None
        }
        start = if (n >= fileSize) { 0 } else { fileSize - n }
        end = fileSize - 1
    } else {
        start = parseI64(a)
        if (b.size == 0) {
            end = fileSize - 1
        } else {
            end = parseI64(b)
        }
    }
    if (start < 0 || end < 0) {
        return None
    }
    return Some(RangeSpec(start, end))
}

func parseI64(s: String): Int64 {
    var v: Int64 = 0
    if (s.size == 0) {
        return -1
    }
    for (c in s.toArray()) {
        if (c < 48 || c > 57) {
            return -1
        }
        v = v * 10 + (Int64(c) - 48)
        if (v > 100000000000) {
            return -1
        }
    }
    return v
}

func readFile(p: String): ?Array<Byte> {
    try {
        return Some(File.readFrom(Path(p)))
    } catch (e: Exception) {
        return None
    }
}

func readFileRange(p: String, start: Int64, count: Int64): ?Array<Byte> {
    var f: ?File = None
    try {
        f = Some(File(Path(p), OpenMode.Read))
        match (f) {
            case Some(file) =>
                file.seek(SeekPosition.Begin(start))
                let buf = Array<Byte>(count, repeat: 0)
                var got: Int64 = 0
                while (got < count) {
                    let n = file.read(buf[got..count])
                    if (n <= 0) {
                        break
                    }
                    got += n
                }
                file.close()
                return Some(buf[0..got])
            case None => return None
        }
    } catch (e: Exception) {
        match (f) {
            case Some(file) => try { file.close() } catch (e2: Exception) {}
            case None => ()
        }
        return None
    }
}

func contentTypeOf(p: String): String {
    let lower = p.toAsciiLower()
    if (lower.endsWith(".html") || lower.endsWith(".htm")) { return "text/html; charset=utf-8" }
    if (lower.endsWith(".css")) { return "text/css; charset=utf-8" }
    if (lower.endsWith(".js")) { return "application/javascript; charset=utf-8" }
    if (lower.endsWith(".json")) { return "application/json; charset=utf-8" }
    if (lower.endsWith(".txt")) { return "text/plain; charset=utf-8" }
    if (lower.endsWith(".svg")) { return "image/svg+xml" }
    if (lower.endsWith(".png")) { return "image/png" }
    if (lower.endsWith(".jpg") || lower.endsWith(".jpeg")) { return "image/jpeg" }
    if (lower.endsWith(".gif")) { return "image/gif" }
    if (lower.endsWith(".webp")) { return "image/webp" }
    if (lower.endsWith(".ico")) { return "image/x-icon" }
    if (lower.endsWith(".pdf")) { return "application/pdf" }
    if (lower.endsWith(".wasm")) { return "application/wasm" }
    if (lower.endsWith(".woff2")) { return "font/woff2" }
    return "application/octet-stream"
}

/** DateTime -> unix 秒。std.time 没有直接的 toUnixTimeSeconds，用"当前时刻 - 时间差"换算。 */
func dateTimeToUnixSec(dt: DateTime): Int64 {
    let now = DateTime.now()
    let age = now - dt
    let nowSec = currentUnixSec()
    return nowSec - age.toSeconds()
}

/** 当前 unix 秒（用 MonoTime 不行，MonoTime 是单调时钟；用 DateTime.now 的字段手算） */
func currentUnixSec(): Int64 {
    let dt = DateTime.now()
    return daysFromCivil(dt.year, monthNum(dt.month), dt.dayOfMonth) * 86400 +
        dt.hour * 3600 + dt.minute * 60 + dt.second
}
