package ystyle::tachyon

import std.collection.ArrayList
import std.sync.Mutex

/**
 * 对象池，替代 Go 的 sync.Pool。
 *
 * 仓颉没有 GC 感知的对象池，所以手工做两级：
 *   - per-slot 无锁槽：连接协程启动时领一个 slotId，之后 get/put 都走这个槽，
 *     完全没有锁（同一个 slot 只会被一个连接协程访问）
 *   - 全局兜底：slot 空时从全局队列取，加锁但很少走到
 *
 * slot 数的取法（对齐设计文档 §5.7）：concurrency / 64，碰撞只会退化成加锁路径。
 */
public class ObjectPool<T> where T <: Object {
    let local: Array<ArrayList<T>>
    let globalBuf: ArrayList<T> = ArrayList<T>()
    let lock: Mutex = Mutex()
    let factory: () -> T
    let slotCount: Int64
    let maxPerSlot: Int64

    public init(slotCount: Int64, maxPerSlot: Int64, factory: () -> T) {
        this.slotCount = if (slotCount > 0) { slotCount } else { 1 }
        this.maxPerSlot = if (maxPerSlot > 0) { maxPerSlot } else { 64 }
        this.factory = factory
        this.local = Array<ArrayList<T>>(this.slotCount, { _ => ArrayList<T>() })
    }

    public func get(slotId: Int64): T {
        let s = slotIndex(slotId)
        let list = local[s]
        if (list.size > 0) {
            return list.remove(at: list.size - 1)
        }
        // 全局兜底
        synchronized(lock) {
            if (globalBuf.size > 0) {
                return globalBuf.remove(at: globalBuf.size - 1)
            }
        }
        return factory()
    }

    public func put(slotId: Int64, obj: T): Unit {
        let s = slotIndex(slotId)
        let list = local[s]
        if (list.size < maxPerSlot) {
            list.add(obj)
            return
        }
        synchronized(lock) {
            globalBuf.add(obj)
        }
    }

    /** 槽位分配：连接进来时取一个递增序号，取模到 slot */
    public func slotOf(seq: Int64): Int64 {
        return slotIndex(seq)
    }

    func slotIndex(id: Int64): Int64 {
        let m = id % slotCount
        return if (m < 0) { 0 } else { m }
    }

    public func stats(): (Int64, Int64) {
        var localCount: Int64 = 0
        var i: Int64 = 0
        while (i < slotCount) {
            localCount += local[i].size
            i += 1
        }
        var g: Int64 = 0
        synchronized(lock) { g = globalBuf.size }
        return (localCount, g)
    }
}
