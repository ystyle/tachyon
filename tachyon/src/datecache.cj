package ystyle::tachyon

import std.sync.{AtomicReference, Mutex, AtomicBool}
import std.time.{DateTime, Month, DayOfWeek}
import std.core.*

/**
 * Date 头的缓存行。
 *
 * 仓颉 DateTime.now() 只要 20 ns，但格式化要 1227 ns（实测），
 * 所以每秒刷一次 + 序列化时 memcpy 仍然值得（约 1.2 us/请求 的收益）。
 */
class DateCache {
    var buf: Array<Byte> = Array<Byte>(64, repeat: 0)
    var len: Int64 = 0
    let lock: Mutex = Mutex()
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
        let line = buildDateLine()
        synchronized(lock) {
            if (line.size > buf.size) {
                buf = Array<Byte>(line.size, repeat: 0)
            }
            var i: Int64 = 0
            while (i < line.size) {
                buf[i] = line[i]
                i += 1
            }
            len = line.size
        }
    }

    /** 返回当前缓存行的视图（只含有效字节；array 是固定 64 字节，必须裁剪） */
    func line(): Array<Byte> {
        synchronized(lock) { return buf[0..len] }
    }

    func lineLen(): Int64 {
        synchronized(lock) { return len }
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
