/**
 * [INPUT]: 接收准备流水线各工作单元的开始与结束，不接收书摘身份或正文
 * [OUTPUT]: 以独立 signpost 区分队列等待、读取、解析、排版、恢复和栅格耗时
 * [POS]: NoteReviewCanvas 页面私有性能证据入口，仅观测，不参与准备状态决策
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import os

/// Signpost 可以跨准备线程配对，计时不改变工作队列、缓存或用户反馈时机。
nonisolated enum CanvasOverviewPreparationMetrics {
    static let signposter = OSSignposter(subsystem: "com.wangke.xmnote", category: "CanvasPreparation")

    /// 同步单元独占所属线程；作用域结束包含提前返回，且不记录个人内容。
    static func measure<T>(_ name: StaticString, _ operation: () throws -> T) rethrows -> T {
        let interval = signposter.beginInterval(name)
        defer { signposter.endInterval(name, interval) }
        return try operation()
    }
}
