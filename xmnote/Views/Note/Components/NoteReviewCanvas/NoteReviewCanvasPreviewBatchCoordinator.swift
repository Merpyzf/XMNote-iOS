/**
 * [INPUT]: 接收当前、预测、定位和转场的有界字形准备批次
 * [OUTPUT]: 串行合并在途准备，最后一个消费者离开才取消共享工作
 * [POS]: NoteReviewCanvas 高清准备调度；Repository 并发许可仍由 Session 管理
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

/// 主 actor 管理消费者，独立批次任务不会因原调用者取消而丢弃其他消费者保护中的结果。
@MainActor
final class CanvasOverviewPreviewBatchCoordinator {
    private final class Job {
        let id: UUID
        let cancellation: CanvasOverviewTransitionPreparation
        let task: Task<Void, Error>
        var consumers: Set<UUID> = []

        /// 工作与消费者分别持有身份，单个等待者离开不改变其他等待者的交付资格。
        init(id: UUID, cancellation: CanvasOverviewTransitionPreparation, task: Task<Void, Error>) {
            self.id = id; self.cancellation = cancellation; self.task = task
        }
    }
    private var current: Job?

    /// 上一批完成后调用方重新核对实际缓存，已由其他消费者准备的项不再读取或解析。
    func perform(_ operation: @escaping @MainActor (CanvasOverviewTransitionPreparation) async throws -> Void) async throws {
        try Task.checkCancellation()
        while let existing = current {
            do { try await join(existing) }
            catch { try Task.checkCancellation() }
            try Task.checkCancellation()
        }
        let id = UUID()
        let token = CanvasOverviewTransitionPreparation()
        let task = Task { [weak self] in
            defer { if self?.current?.id == id { self?.current = nil } }
            try Task.checkCancellation()
            try await operation(token)
        }
        let job = Job(id: id, cancellation: token, task: task)
        current = job
        try await join(job)
    }

    /// 取消只撤销本消费者；运行中的系统调用可返回，但无消费者时下一条转换不能开始。
    private func join(_ job: Job) async throws {
        let consumer = UUID()
        job.consumers.insert(consumer)
        try await withTaskCancellationHandler {
            defer { release(consumer, from: job) }
            try Task.checkCancellation()
            try await job.task.value
            try Task.checkCancellation()
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in self?.release(consumer, from: job) }
        }
    }

    /// 准备请求结束后释放保护；共享等待者仍在时不打断字形转换。
    private func release(_ consumer: UUID, from job: Job) {
        guard job.consumers.remove(consumer) != nil, job.consumers.isEmpty else { return }
        job.cancellation.cancel()
        job.task.cancel()
    }

    /// 只在离场或几何失效时撤销整批，旧任务不能继续为新场景读取。
    func cancelAll() {
        current?.cancellation.cancel()
        current?.task.cancel()
        current = nil
    }
}
