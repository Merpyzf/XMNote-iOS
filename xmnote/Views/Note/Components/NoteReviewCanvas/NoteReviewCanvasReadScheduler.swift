/**
 * [INPUT]: 依赖 Session 提交的可取消仓储读取与优先级
 * [OUTPUT]: 提供统一双并发读取许可，覆盖清单、布局源和完整书摘
 * [POS]: NoteReviewCanvas 页面专用调度协作者；只由 Session 拥有
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 主 actor 串行维护许可；等待不阻塞线程，取消中的系统调用仍计入并发直到返回。
@MainActor
final class NoteReviewCanvasReadScheduler {
    private struct Waiter {
        let id: UUID
        let priority: TaskPriority
        let continuation: CheckedContinuation<Void, Error>
    }

    private let limit: Int
    private var waiting: [Waiter] = []
    private var isDisposed = false
    private(set) var activeCount = 0
    private(set) var maximumObservedCount = 0
    var waitingCount: Int { waiting.count }

    /// 生产固定双并发，测试可用单许可确定取消与优先级次序。
    init(limit: Int = 2) {
        self.limit = max(1, min(2, limit))
    }

    /// 在当前任务内执行，不另建逃逸查询任务；等待或完成后取消均不交付结果。
    func perform<T>(priority: TaskPriority = .userInitiated,
                    operation: () async throws -> T) async throws -> T {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await acquire(id: id, priority: priority)
        } onCancel: { [self] in
            Task { @MainActor [self] in cancelWaiting(id: id) }
        }
        defer { release() }
        try Task.checkCancellation()
        guard !isDisposed else { throw CancellationError() }
        let result = try await operation()
        try Task.checkCancellation()
        guard !isDisposed else { throw CancellationError() }
        return result
    }

    /// 永久关闭后唤醒全部等待者；正在读取者返回时释放许可但不能提交结果。
    func dispose() {
        isDisposed = true
        let cancelled = waiting
        waiting.removeAll()
        for waiter in cancelled { waiter.continuation.resume(throwing: CancellationError()) }
    }

    /// 主 actor 内原子占用或排队，取消不能在检查与登记之间穿插。
    private func acquire(id: UUID, priority: TaskPriority) async throws {
        try Task.checkCancellation()
        guard !isDisposed else { throw CancellationError() }
        if activeCount < limit {
            activeCount += 1
            maximumObservedCount = max(maximumObservedCount, activeCount)
            return
        }
        try await withCheckedThrowingContinuation { continuation in
            waiting.append(Waiter(id: id, priority: priority, continuation: continuation))
        }
    }

    /// 同优先级 FIFO，高优先级目标首屏先获得下一个空闲许可。
    private func release() {
        activeCount -= 1
        guard !isDisposed, !waiting.isEmpty else { return }
        var next = 0
        for index in waiting.indices where waiting[index].priority.rawValue > waiting[next].priority.rawValue {
            next = index
        }
        let waiter = waiting.remove(at: next)
        activeCount += 1
        waiter.continuation.resume()
    }

    /// 只取消指定等待项；已经进入系统调用的许可不提前归还。
    private func cancelWaiting(id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
