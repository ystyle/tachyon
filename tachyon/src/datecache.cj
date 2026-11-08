package ystyle::tachyon

import std.sync.{AtomicReference, AtomicBool}
import std.time.{DateTime, Month, DayOfWeek}
import std.core.*

/**
 * Date 头的缓存行（不可变快照）。
 *
 * 仓颉 DateTime.now() 只要 20 ns，但格式化要 1227 ns（实测），
 * 所以每秒刷一次 + 序列化时 memcpy 仍然值得（约 1.2 us/请求 的收益）。
 *
 * ⚠️ 读路径必须**无锁**：早先版本用 Mutex 保护 len，每次请求都要 synchronized，
 * 在 16 线程上是全局串行点。现在刷新时构造不可变快照、原子换引用，
 * 读侧只做一次 AtomicReference.load()。
 */
class DateSnapshot {
    let bytes: Array<Byte>

    init(b: Array<Byte>) {
        bytes = b
    }
}

let emptyDateSnapshot: DateSnapshot = DateSnapshot(Array<Byte>(0, repeat: 0))

class DateCache {
    var current: AtomicReference<DateSnapshot> = AtomicReference<DateSnapshot>(emptyDateSnapshot)
    var running: AtomicBool = AtomicBool(true)

    func start(): Unit {
        refresh()
        spawn {
            while (running.load()) {
                sleep(Duration.second)
                refresh()
            }
        }
    }

    func stop(): Unit {
        running.store(false)
    }

    func refresh(): Unit {
        // 每秒一次，分配一个新快照完全无所谓；换来读路径彻底无锁
        current.store(DateSnapshot(buildDateLine()))
    }

    /** 当前缓存行（不可变，长度就是数组长度；含行尾 CRLF） */
    func line(): Array<Byte> {
        return current.load().bytes
    }
}

func pad2(v: Int64): String {
    if (v < 10) {
        return "0" + v.toString()
    }
    return v.toString()
}

let monthNames: Array<String> = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
]
let weekDayNames: Array<String> = [
    "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"
]

func monthNum(m: Month): Int64 {
    match (m) {
        case January => return 1
        case February => return 2
        case March => return 3
        case April => return 4
        case May => return 5
        case June => return 6
        case July => return 7
        case August => return 8
        case September => return 9
        case October => return 10
        case November => return 11
        case December => return 12
        case _ => return 1
    }
}

func weekDayNum(d: DayOfWeek): Int64 {
    match (d) {
        case Sunday => return 0
        case Monday => return 1
        case Tuesday => return 2
        case Wednesday => return 3
        case Thursday => return 4
        case Friday => return 5
        case Saturday => return 6
        case _ => return 0
    }
}

/** 生成 "Date: Sat, 07 Nov 2026 20:56:38 GMT
" */
func buildDateLine(): Array<Byte> {
    let now = DateTime.now()
    let mon = monthNum(now.month)
    let wd = weekDayNum(now.dayOfWeek)
    let s = "Date: " + weekDayNames[wd] + ", " + pad2(now.dayOfMonth) + " " +
            monthNames[mon - 1] + " " + now.year.toString() + " " +
            pad2(now.hour) + ":" + pad2(now.minute) + ":" + pad2(now.second) + " GMT\r\n"
    return s.toArray()
}

/** 秒级 unix 时间戳 -> "Sat, 07 Nov 2026 20:56:38 GMT"（不含 "Date: " 前缀） */
public func formatHTTPDate(unixSec: Int64): String {
    // 直接按 unix 秒手工算年月日时（civil_from_days 算法，纯整数、无分配）。
    // 不用 DateTime：它的构造需要 TimeZone，而 UTC 常量在 std.time 里不可直接引用。
    var days = unixSec / 86400
    var secsOfDay = unixSec % 86400
    if (secsOfDay < 0) {
        secsOfDay += 86400
        days -= 1
    }
    let (y, m, d) = civilFromDays(days)
    let hh = secsOfDay / 3600
    let mm = (secsOfDay % 3600) / 60
    let ss = secsOfDay % 60
    // 1970-01-01 是周四（weekday 4）
    var wd = ((days % 7) + 7) % 7
    wd = (wd + 4) % 7
    return weekDayNames[wd] + ", " + pad2(d) + " " + monthNames[m - 1] + " " + y.toString() + " " +
        pad2(hh) + ":" + pad2(mm) + ":" + pad2(ss) + " GMT"
}

/** Howard Hinnant 的 civil_from_days（days since 1970-01-01 -> (y, m, d)） */
func civilFromDays(days0: Int64): (Int64, Int64, Int64) {
    var z = days0 + 719468
    let era = (if (z >= 0) { z } else { z - 146096 }) / 146097
    let doe = z - era * 146097
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
    let y = yoe + era * 400
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let d = doy - (153 * mp + 2) / 5 + 1
    let m = if (mp < 10) { mp + 3 } else { mp - 9 }
    let yy = if (m <= 2) { y + 1 } else { y }
    return (yy, m, d)
}

/** 解析 IMF-fixdate："Sat, 07 Nov 2026 20:56:38 GMT"。失败返回 -1 */
public func parseHTTPDate(v: Bytes): Int64 {
    let s = v.toStr().trimAscii()
    // 最短满足 "Sat, 07 Nov 2026 20:56:38 GMT" = 29
    if (s.size < 29) {
        return -1
    }
    let comma = match (s.indexOf(",")) { case Some(i) => i; case None => return -1 }
    if (comma != 3) {
        return -1
    }
    // "Sat, 07 Nov 2026 20:56:38 GMT"
    let rest = s[5..]
    let p = rest.split(" ")
    if (p.size < 4) {
        return -1
    }
    let day = parseIntOr(p[0], -1)
    let month = monthIdx(p[1])
    let year = parseIntOr(p[2], -1)
    let t = splitTime(p[3])
    if (day < 0 || month <= 0 || year < 0) {
        return -1
    }
    return daysFromCivil(year, month, day) * 86400 + t[0] * 3600 + t[1] * 60 + t[2]
}

/** (y, m, d) -> days since 1970-01-01 */
func daysFromCivil(y0: Int64, m: Int64, d: Int64): Int64 {
    let y = if (m <= 2) { y0 - 1 } else { y0 }
    let era = (if (y >= 0) { y } else { y - 399 }) / 400
    let yoe = y - era * 400
    let mp = if (m > 2) { m - 3 } else { m + 9 }
    let doy = (153 * mp + 2) / 5 + d - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146097 + doe - 719468
}

func parseIntOr(s: String, dflt: Int64): Int64 {
    var v: Int64 = 0
    if (s.size == 0) {
        return dflt
    }
    for (c in s.toArray()) {
        if (c < 48 || c > 57) {
            return dflt
        }
        v = v * 10 + (Int64(c) - 48)
    }
    return v
}

func monthIdx(name: String): Int64 {
    var i: Int64 = 0
    while (i < 12) {
        if (monthNames[i] == name) {
            return i + 1
        }
        i += 1
    }
    return -1
}

func splitTime(s: String): Array<Int64> {
    let parts = s.split(":")
    var r: Array<Int64> = [0, 0, 0]
    if (parts.size >= 3) {
        r[0] = parseIntOr(parts[0], 0)
        r[1] = parseIntOr(parts[1], 0)
        r[2] = parseIntOr(parts[2], 0)
    }
    return r
}