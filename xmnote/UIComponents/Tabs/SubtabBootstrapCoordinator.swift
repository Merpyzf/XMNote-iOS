/**
 * [INPUT]: 依赖 Foundation 并发能力，接收二级页选择标识与异步启动任务
 * [OUTPUT]: 对外提供 SubtabBootstrapCoordinator（通用二级页启动协调器）
 * [POS]: UIComponents/Tabs 的容器级启动基础设施，负责二级页 warmup 去重与优先级调度
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 容器级二级页启动协调器，保证同一个分段的首开任务只调度一次。
@MainActor
final class SubtabBootstrapCoordinator<Selection: Hashable> {
    enum Phase: Equatable {
        case idle
        case warming
        case ready
    }

    private var phases: [Selection: Phase] = [:]
    private var tasks: [Selection: Task<Void, Never>] = [:]

    deinit {
        tasks.values.forEach { $0.cancel() }
    }

    /// 返回指定分段的当前启动阶段，供容器判断是否需要触发首开任务。
    func phase(for selection: Selection) -> Phase {
        phases[selection] ?? .idle
    }

    /// 为指定分段启动一次 warmup；同一个分段已 warming/ready 时忽略后续重复调度。
    func warm(
        _ selection: Selection,
        priority: TaskPriority = .utility,
        operation: @escaping @MainActor @Sendable () async -> Void
    ) {
        guard phase(for: selection) == .idle else { return }

        phases[selection] = .warming
        let task = Task(priority: priority) { @MainActor [weak self] in
            await operation()
            guard let self else { return }
            self.tasks[selection] = nil
            self.phases[selection] = .ready
        }
        tasks[selection] = task
    }
}
