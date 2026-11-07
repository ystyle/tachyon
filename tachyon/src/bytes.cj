package ystyle::tachyon

/** 共享的零长视图，避免每次 Bytes.empty() 分配 */
let EMPTY_BYTES: Bytes = Bytes(Array<Byte>(0, repeat: 0), 0, 0)

/**
 * 零拷贝字节视图。
 *
 * 这里刻意不使用 String：仓颉的 String.fromUtf8 会做完整 UTF-8 校验
 * （实测 1 MiB ≈ 544 µs），放在 HTTP 解析热路径上无法接受。
 *
 * Bytes 是 struct，按值传递不分配；buf 与底层 Array 共享存储（切片是别名，实测 27 ns/次）。
 */
public struct Bytes {
    let buf: Array<Byte>
    let start: Int64
    let len: Int64

    /** 整块视图 */
    public init(buf: Array<Byte>) {
        this.buf = buf
        this.start = 0
        this.len = buf.size
    }

    /** 切片视图，不拷贝 */
    public init(buf: Array<Byte>, start: Int64, len: Int64) {
        this.buf = buf
        this.start = start
        this.len = len
    }

    public static func empty(): Bytes {
        return EMPTY_BYTES
    }

    public func size(): Int64 {
        return len
    }

    public func isEmpty(): Bool {
        return len == 0
    }

    public operator func [](i: Int64): Byte {
        return buf[start + i]
    }

    /** 子视图，零拷贝 */
    public func slice(from: Int64, to: Int64): Bytes {
        return Bytes(buf, start + from, to - from)
    }

    public func sliceFrom(from: Int64): Bytes {
        return Bytes(buf, start + from, len - from)
    }

    public func sliceTo(to: Int64): Bytes {
        return Bytes(buf, start, to)
    }

    /** 唯一的拷贝出口：转 String（会做 UTF-8 校验） */
    public func toStr(): String {
        return String.fromUtf8(buf[start..start + len])
    }

    /** 转成独立的 Array<Byte>（拷贝） */
    public func toArray(): Array<Byte> {
        return buf[start..start + len]
    }

    public func toArrayUnsafe(): Array<Byte> {
        return buf[start..start + len]
    }

    /** ASCII 大小写无关比较（对方是 Bytes） */
    public func equalsAsciiIgnoreCase(other: Bytes): Bool {
        if (len != other.len) {
            return false
        }
        var i: Int64 = 0
        while (i < len) {
            let a = buf[start + i] | 0x20
            let b = other.buf[other.start + i] | 0x20
            if (a != b) {
                return false
            }
            i += 1
        }
        return true
    }

    /** ASCII 大小写无关比较（对方是 String） */
    public func equalsAsciiIgnoreCase(s: String): Bool {
        let arr = s.toArray()
        if (len != arr.size) {
            return false
        }
        var i: Int64 = 0
        while (i < len) {
            let a = buf[start + i] | 0x20
            let b = arr[i] | 0x20
            if (a != b) {
                return false
            }
            i += 1
        }
        return true
    }

    /** 精确比较 */
    public func equals(other: Bytes): Bool {
        if (len != other.len) {
            return false
        }
        var i: Int64 = 0
        while (i < len) {
            if (buf[start + i] != other.buf[other.start + i]) {
                return false
            }
            i += 1
        }
        return true
    }

    public func equals(s: String): Bool {
        let arr = s.toArray()
        if (len != arr.size) {
            return false
        }
        var i: Int64 = 0
        while (i < len) {
            if (buf[start + i] != arr[i]) {
                return false
            }
            i += 1
        }
        return true
    }

    /** 从 from 开始找第一个字节 b，找不到返回 -1 */
    public func indexOf(b: Byte, from: Int64): Int64 {
        var i = from
        while (i < len) {
            if (buf[start + i] == b) {
                return i
            }
            i += 1
        }
        return -1
    }

    /** 从 from 开始找字节序列 seq，找不到返回 -1 */
    public func indexOfSeq(seq: Array<Byte>, from: Int64): Int64 {
        let m = seq.size
        if (m == 0) {
            return from
        }
        if (m > len) {
            return -1
        }
        var i = from
        let last = len - m
        while (i <= last) {
            var j: Int64 = 0
            while (j < m && buf[start + i + j] == seq[j]) {
                j += 1
            }
            if (j == m) {
                return i
            }
            i += 1
        }
        return -1
    }

    /** 是否以 prefix 开头 */
    public func startsWith(prefix: Array<Byte>): Bool {
        if (prefix.size > len) {
            return false
        }
        var i: Int64 = 0
        while (i < prefix.size) {
            if (buf[start + i] != prefix[i]) {
                return false
            }
            i += 1
        }
        return true
    }

    /** 写入到 dst 的指定位置，返回新的写位置 */
    public func copyTo(dst: Array<Byte>, dstPos: Int64): Int64 {
        var i: Int64 = 0
        var p = dstPos
        while (i < len) {
            dst[p] = buf[start + i]
            p += 1
            i += 1
        }
        return p
    }
}
