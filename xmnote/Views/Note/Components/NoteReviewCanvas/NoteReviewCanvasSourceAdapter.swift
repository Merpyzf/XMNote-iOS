/**
 * [INPUT]: 依赖 Session 注入的布局源读取闭包及当前请求的有序身份
 * [OUTPUT]: 提供可取消、有背压、明确缺失身份的有序轻量批次
 * [POS]: NoteReviewCanvas 数据适配边界；不持有 Repository 或另一份业务会话
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import os

/// 每批只保留本批源与缺失身份；消费完成后调用方应释放原始 HTML。
nonisolated struct NoteReviewCanvasSourceBatch: Sendable {
    let sources: [NoteReviewOverviewLayoutSource]
    let missingIDs: Set<Int64>
    let completedCount: Int
    let isLast: Bool
}

/// 主 actor 负责仓储交接；昂贵转换由 consumer 异步移到准备队列，等待构成背压。
@MainActor
struct NoteReviewCanvasSourceAdapter {
    typealias Reader = ([Int64], TaskPriority) async throws -> [NoteReviewOverviewLayoutSource]
    private let read: Reader

    /// 仅注入 Session 的受调度读取，禁止适配器另建 Repository 会话。
    init(read: @escaping Reader) { self.read = read }

    /// 上一批已转换并释放后才开始下一批；退出和过时代次通过外层任务取消传播。
    func consume(ids: [Int64], priority: TaskPriority = .utility,
                 consumer: (NoteReviewCanvasSourceBatch) async throws -> Void) async throws {
        try Task.checkCancellation()
        var seen = Set<Int64>()
        let unique = ids.filter { seen.insert($0).inserted }
        if unique.isEmpty {
            try await consumer(NoteReviewCanvasSourceBatch(sources: [], missingIDs: [], completedCount: 0, isLast: true))
            try Task.checkCancellation()
            return
        }
        for start in stride(from: 0, to: unique.count, by: 128) {
            try Task.checkCancellation()
            let end = min(unique.count, start + 128)
            let requested = Array(unique[start..<end])
            let interval = CanvasOverviewPreparationMetrics.signposter.beginInterval("Read layout batch")
            let returned: [NoteReviewOverviewLayoutSource]
            do {
                returned = try await read(requested, priority)
                CanvasOverviewPreparationMetrics.signposter.endInterval("Read layout batch", interval)
            } catch {
                CanvasOverviewPreparationMetrics.signposter.endInterval("Read layout batch", interval)
                throw error
            }
            try Task.checkCancellation()
            let allowed = Set(requested)
            var byID: [Int64: NoteReviewOverviewLayoutSource] = [:]
            for source in returned where allowed.contains(source.noteID) { byID[source.noteID] = source }
            let ordered = requested.compactMap { byID[$0] }
            let missing = allowed.subtracting(byID.keys)
            try await consumer(NoteReviewCanvasSourceBatch(sources: ordered, missingIDs: missing,
                completedCount: end, isLast: end == unique.count))
            try Task.checkCancellation()
        }
    }
}
