/**
 * [INPUT]: 依赖显式成本、不可变资源与作用域租约
 * [OUTPUT]: 提供包含保护资源的硬预算缓存与内存压力回收
 * [POS]: NoteReviewCanvas 内部资源容器；不声称限制 CATiledLayer 系统缓存
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 绘制或显示期间持有租约，离开作用域后归还保护；调用者不能把资源另存为无预算强引用。
nonisolated final class NoteReviewCanvasResourceLease<Value: Sendable>: Sendable {
    let value: Value
    private let release: @Sendable () -> Void

    /// 仅由缓存创建，释放回调不捕获租约自身。
    fileprivate init(value: Value, release: @escaping @Sendable () -> Void) {
        self.value = value; self.release = release
    }

    deinit { release() }
}

/// NSLock 仅保护索引和成本，绝不在锁内绘制或等待任务。
/// 调用者只能存入不可变资源；资源本身的线程安全由其类型边界保证。
nonisolated final class NoteReviewCanvasResourceCache<Key: Hashable & Sendable, Value: Sendable>: @unchecked Sendable {
    private struct Entry {
        let value: Value
        let cost: Int
        var access: UInt64
        var leases: Int
    }
    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var used = 0
    private var clock: UInt64 = 0
    let limit: Int
    let countLimit: Int

    /// 预算包含所有未归还租约，不能通过 NSCache 驱逐隐藏正在显示的实际占用。
    init(limit: Int, countLimit: Int = 240) {
        self.limit = max(0, limit); self.countLimit = max(1, countLimit)
    }

    /// 仅为诊断返回轻量统计，不暴露资源集合。
    var statistics: (bytes: Int, count: Int, protectedCount: Int) {
        lock.lock(); defer { lock.unlock() }
        return (used, entries.count, entries.values.filter { $0.leases > 0 }.count)
    }

    /// 在准备完成时接纳资源；无可回收空间时拒绝本次资源，不突破上限或销毁当前可信画面。
    @discardableResult
    func insert(_ value: Value, for key: Key, cost: Int) -> Bool {
        guard cost >= 0, cost <= limit else { return false }
        lock.lock(); defer { lock.unlock() }
        if let existing = entries[key], existing.leases > 0 { return false }
        let oldCost = entries[key]?.cost ?? 0
        let extraEntry = entries[key] == nil ? 1 : 0
        let victims = entries.filter { $0.key != key && $0.value.leases == 0 }
            .sorted { $0.value.access < $1.value.access }
        var requiredBytes = max(0, used - oldCost + cost - limit)
        var requiredCount = max(0, entries.count + extraEntry - countLimit)
        var evictions: [Key] = []
        for victim in victims where requiredBytes > 0 || requiredCount > 0 {
            evictions.append(victim.key)
            requiredBytes -= victim.value.cost
            requiredCount -= 1
        }
        guard requiredBytes <= 0, requiredCount <= 0 else { return false }
        for victim in evictions { if let removed = entries.removeValue(forKey: victim) { used -= removed.cost } }
        if let removed = entries.removeValue(forKey: key) { used -= removed.cost }
        clock &+= 1
        entries[key] = Entry(value: value, cost: cost, access: clock, leases: 0)
        used += cost
        return true
    }

    /// 绘制热路径 O(1) 获取保护，返回后已释放锁；多个后台 Tile 可以同时读取同一不可变资源。
    func lease(for key: Key) -> NoteReviewCanvasResourceLease<Value>? {
        lock.lock()
        guard var entry = entries[key] else { lock.unlock(); return nil }
        clock &+= 1; entry.access = clock; entry.leases += 1
        entries[key] = entry
        lock.unlock()
        return NoteReviewCanvasResourceLease(value: entry.value) { [self] in
            lock.lock(); defer { lock.unlock() }
            guard var retained = entries[key] else { return }
            retained.leases -= 1
            entries[key] = retained
        }
    }

    /// 内存警告只释放无租约条目；当前纸张与正在交接的画面仍计费且不被清空。
    func removeUnprotected() {
        lock.lock(); defer { lock.unlock() }
        let keys = entries.compactMap { $0.value.leases == 0 ? $0.key : nil }
        for key in keys { if let removed = entries.removeValue(forKey: key) { used -= removed.cost } }
    }
}
