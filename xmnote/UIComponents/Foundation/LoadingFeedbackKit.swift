/**
 * [INPUT]: 依赖 SwiftUI 动画与并发语义，依赖 DesignTokens 设计节奏约束页面加载反馈
 * [OUTPUT]: 对外提供 LoadingIntent、LoadingPolicy、LoadingGate、LoadPhase 与 LoadPhaseHost
 * [POS]: UIComponents/Foundation 的加载反馈基础设施，统一“延迟显示 + 最短驻留 + 阶段承载”模式
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 页面加载意图：读加载允许延迟，写操作必须即时反馈。
enum LoadingIntent {
    case none
    case read
    case write
}

/// 加载可视化策略：控制延迟显示、最短驻留和显隐动画。
struct LoadingPolicy {
    let delay: Duration
    let minimumVisible: Duration
    let showAnimation: Animation
    let hideAnimation: Animation

    static let readDefault = LoadingPolicy(
        delay: .milliseconds(150),
        minimumVisible: .milliseconds(200),
        showAnimation: .smooth(duration: 0.16),
        hideAnimation: .smooth(duration: 0.16)
    )

    static let writeImmediate = LoadingPolicy(
        delay: .zero,
        minimumVisible: .zero,
        showAnimation: .smooth(duration: 0.12),
        hideAnimation: .smooth(duration: 0.12)
    )

    static func `default`(for intent: LoadingIntent) -> LoadingPolicy {
        switch intent {
        case .none, .read:
            return .readDefault
        case .write:
            return .writeImmediate
        }
    }
}

/// 统一管理加载显隐门闩，避免页面手写延迟与闪烁控制逻辑。
@MainActor
@Observable
final class LoadingGate {
    private let clock = ContinuousClock()
    private var transitionTask: Task<Void, Never>?
    private var visibleAt: ContinuousClock.Instant?
    private var shownMinimumVisible: Duration = .zero
    private var shownHideAnimation: Animation = .smooth(duration: 0.16)

    private(set) var intent: LoadingIntent = .none
    private(set) var isVisible = false

    /// 根据意图更新加载可视化状态。读加载默认延迟显示，写加载即时反馈。
    func update(intent: LoadingIntent, policy: LoadingPolicy? = nil) {
        self.intent = intent
        transitionTask?.cancel()
        transitionTask = nil

        let resolved = policy ?? LoadingPolicy.default(for: intent)

        switch intent {
        case .none:
            hideIfNeeded()
        case .read, .write:
            showIfNeeded(using: resolved)
        }
    }

    /// 立即清空可视状态，常用于页面离场时的任务收口。
    func hideImmediately() {
        transitionTask?.cancel()
        transitionTask = nil
        intent = .none

        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            isVisible = false
        }
        visibleAt = nil
        shownMinimumVisible = .zero
    }

    private func showIfNeeded(using policy: LoadingPolicy) {
        guard !isVisible else { return }
        let delay = policy.delay
        if delay > .zero {
            transitionTask = Task {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                guard intent != .none else { return }
                present(using: policy)
            }
            return
        }
        present(using: policy)
    }

    private func present(using policy: LoadingPolicy) {
        guard !isVisible else { return }
        shownMinimumVisible = policy.minimumVisible
        shownHideAnimation = policy.hideAnimation
        visibleAt = clock.now
        withAnimation(policy.showAnimation) {
            isVisible = true
        }
    }

    private func hideIfNeeded() {
        guard isVisible else { return }
        let hideAnimation = shownHideAnimation
        let minimumVisible = shownMinimumVisible

        guard let visibleAt else {
            withAnimation(hideAnimation) {
                isVisible = false
            }
            self.visibleAt = nil
            return
        }

        let elapsed = visibleAt.duration(to: clock.now)
        guard elapsed < minimumVisible else {
            withAnimation(hideAnimation) {
                isVisible = false
            }
            self.visibleAt = nil
            return
        }

        let remaining = minimumVisible - elapsed
        transitionTask = Task {
            try? await Task.sleep(for: remaining)
            guard !Task.isCancelled else { return }
            guard intent == .none else { return }
            withAnimation(hideAnimation) {
                isVisible = false
            }
            self.visibleAt = nil
        }
    }
}

/// 统一视图阶段状态：支持静默占位、加载、内容、空态、错误态。
enum LoadPhase: Equatable {
    case placeholder
    case loading
    case content
    case empty(message: String)
    case error(message: String)
}

/// 通用阶段宿主：由业务侧提供各阶段渲染内容，避免页面重复 switch。
struct LoadPhaseHost<
    Content: View,
    Placeholder: View,
    Loading: View,
    Empty: View,
    Failure: View
>: View {
    let phase: LoadPhase
    let content: () -> Content
    let placeholder: () -> Placeholder
    let loading: () -> Loading
    let empty: (String) -> Empty
    let failure: (String) -> Failure

    init(
        phase: LoadPhase,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder,
        @ViewBuilder loading: @escaping () -> Loading,
        @ViewBuilder empty: @escaping (String) -> Empty,
        @ViewBuilder failure: @escaping (String) -> Failure
    ) {
        self.phase = phase
        self.content = content
        self.placeholder = placeholder
        self.loading = loading
        self.empty = empty
        self.failure = failure
    }

    var body: some View {
        Group {
            switch phase {
            case .placeholder:
                placeholder()
            case .loading:
                loading()
            case .content:
                content()
            case .empty(let message):
                empty(message)
            case .error(let message):
                failure(message)
            }
        }
    }
}
