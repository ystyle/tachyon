package ystyle::tachyon

import std.collection.ArrayList

/**
 * Query / Post 参数视图。惰性解析，解析结果缓存在 keys/vals 里。
 *
 * 扫描用一张 256 字节查表把"是不是分隔符"变成一次查表（照搬 fasthttp 的
 * argsScanTable），一遍扫完记下所有分隔位置，解码只对"含 % 或 +"的片段做。
 */
public class ArgsView {
    var raw: Bytes = Bytes.empty()
    var parsed: Bool = false
    var keys: ArrayList<Bytes> = ArrayList<Bytes>()
    var vals: ArrayList<Bytes> = ArrayList<Bytes>()
    var noValue: ArrayList<Bool> = ArrayList<Bool>()
    var buf: Array<Byte> = Array<Byte>(1024, repeat: 0)
    var bufLen: Int64 = 0

    public func reset(): Unit {
        raw = Bytes.empty()
        parsed = false
        keys.clear()
        vals.clear()
        noValue.clear()
        bufLen = 0
    }

    public func parse(raw: Bytes): Unit {
        this.raw = raw
        if (parsed) {
            return
        }
        parsed = true
        if (raw.isEmpty()) {
            return
        }

        let n = raw.size()
        var pos: Int64 = 0
        while (pos < n) {
            // 找这一对的结束位置 '&'
            var end = pos
            while (end < n && raw[end] != ampersand) {
                end += 1
            }
            // 在 [pos, end) 里找 '='
            var eq: Int64 = -1
            var i = pos
            while (i < end) {
                if (raw[i] == equalsSign) {
                    eq = i
                    break
                }
                i += 1
            }
            if (eq < 0) {
                // 无值 key（"?flag"）
                let k = decodeArg(raw.slice(pos, end), true)
                keys.add(k)
                vals.add(Bytes.empty())
                noValue.add(true)
            } else {
                let k = decodeArg(raw.slice(pos, eq), true)
                let v = decodeArg(raw.slice(eq + 1, end), true)
                keys.add(k)
                vals.add(v)
                noValue.add(false)
            }
            pos = end + 1
        }
    }

    /** 解码百分号与 '+'（argDecodePlus=true 表示 '+' -> 空格，query 语义） */
    func decodeArg(src: Bytes, plusAsSpace: Bool): Bytes {
        let n = src.size()
        // 快路径：没有 '%' 也没有 '+' 就不用解码，直接返回原视图
        var needDecode = false
        var i: Int64 = 0
        while (i < n) {
            let c = src[i]
            if (c == percent || (plusAsSpace && c == plusSign)) {
                needDecode = true
                break
            }
            i += 1
        }
        if (!needDecode) {
            return src
        }
        if (bufLen + n > buf.size) {
            return src
        }
        let start = bufLen
        var w = bufLen
        var k: Int64 = 0
        while (k < n) {
            let c = src[k]
            if (plusAsSpace && c == plusSign) {
                buf[w] = sp
                w += 1
                k += 1
                continue
            }
            if (c == percent && k + 2 < n) {
                let hi = hexVal(src[k + 1])
                let lo = hexVal(src[k + 2])
                if (hi >= 0 && lo >= 0) {
                    buf[w] = UInt8(hi * 16 + lo)
                    w += 1
                    k += 3
                    continue
                }
            }
            buf[w] = c
            w += 1
            k += 1
        }
        bufLen = w
        return Bytes(buf, start, w - start)
    }

    public func get(key: String): Bytes {
        let kb = key.toArray()
        var i: Int64 = 0
        let n = keys.size
        while (i < n) {
            if (keys[i].equals(Bytes(kb))) {
                return vals[i]
            }
            i += 1
        }
        return Bytes.empty()
    }

    public func get(key: Bytes): Bytes {
        var i: Int64 = 0
        let n = keys.size
        while (i < n) {
            if (keys[i].equals(key)) {
                return vals[i]
            }
            i += 1
        }
        return Bytes.empty()
    }

    public func has(key: String): Bool {
        let kb = key.toArray()
        var i: Int64 = 0
        let n = keys.size
        while (i < n) {
            if (keys[i].equals(Bytes(kb))) {
                return true
            }
            i += 1
        }
        return false
    }

    public func count(): Int64 {
        return keys.size
    }

    public func keyAt(i: Int64): Bytes {
        return keys[i]
    }

    public func valueAt(i: Int64): Bytes {
        return vals[i]
    }
}
