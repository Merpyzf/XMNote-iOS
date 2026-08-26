/**
 * [INPUT]: 依赖 NoteReviewViewModel 的候选页准备/提交与一级操作状态、NoteReviewPagingDeck，以及页面注入的卡片内容、AI 助手与业务动作闭包
 * [OUTPUT]: 对外提供 NoteReviewLoadingShell、NoteReviewRefreshDeckHost、紧凑低强调的四项卡片操作栏、随机换组 latest-wins 协调器与可测动效规格
 * [POS]: Note/Components 的回顾卡组与卡片操作宿主，以稳定 live deck 和预挂载新组完成连续替换，不作为跨模块组件
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 随机换组的有限状态，确保任一时刻最多只有一个在途意图和一个待处理意图。
nonisolated enum NoteReviewRefreshPhase: Equatable, Sendable {
    case idle
    case loading
    case replacing
    case settling
}

/// 状态机向 View 发出的下一步操作；所有意图均以递增 ID 标识，过期回调会被忽略。
nonisolated enum NoteReviewRefreshCoordinatorAction: Equatable, Sendable {
    case none
    case start(Int)
    case mountReplacement(Int)
    case settle(Int)
    case finish(shouldAnnounce: Bool)
}

/// 管理“换一组”最新意图优先级的纯值协调器，不持有 Task 或 SwiftUI 状态，便于单元测试验证连续点击。
nonisolated struct NoteReviewRefreshCoordinator: Sendable {
    private(set) var phase: NoteReviewRefreshPhase = .idle
    private var nextIntentID = 0
    private var activeIntentID: Int?
    private var pendingIntentID: Int?

    /// 记录一次点击；空闲时立即启动，其他阶段仅覆盖单个 pending 意图，避免形成无限队列。
    mutating func request() -> NoteReviewRefreshCoordinatorAction {
        nextIntentID &+= 1
        let intentID = nextIntentID
        guard phase == .idle else {
            pendingIntentID = intentID
            return .none
        }
        activeIntentID = intentID
        phase = .loading
        return .start(intentID)
    }

    /// 判断回调是否仍属于当前在途意图，供 View 丢弃取消、设置变化或旧查询的响应。
    func isActive(_ intentID: Int) -> Bool {
        activeIntentID == intentID
    }

    /// 在候选页到达后决定直接提交或进入双 snapshot 交接；直接提交前优先启动已合并的最新 intent。
    mutating func preparationCompleted(
        for intentID: Int,
        requiresReplacement: Bool,
        shouldAnnounceOnFinish: Bool
    ) -> NoteReviewRefreshCoordinatorAction {
        guard phase == .loading, activeIntentID == intentID else { return .none }
        if pendingIntentID != nil {
            return startPendingOrFinish(shouldAnnounce: false)
        }
        if requiresReplacement {
            phase = .replacing
            return .mountReplacement(intentID)
        }
        return startPendingOrFinish(shouldAnnounce: shouldAnnounceOnFinish)
    }

    /// 在候选查询失败或取消后收束状态；若存在 pending，则只启动最后一次点击且不发布旧失败。
    mutating func preparationFailed(for intentID: Int) -> NoteReviewRefreshCoordinatorAction {
        guard phase == .loading, activeIntentID == intentID else { return .none }
        return startPendingOrFinish(shouldAnnounce: false)
    }

    /// 交接的 290ms 视觉阶段结束后进入 settling，要求 View 先无动画提交 live deck，再清理两个 snapshot。
    mutating func replacementAnimationCompleted(for intentID: Int) -> NoteReviewRefreshCoordinatorAction {
        guard phase == .replacing, activeIntentID == intentID else { return .none }
        phase = .settling
        return .settle(intentID)
    }

    /// live deck 已经无动画接管后启动合并的最新请求，或回到 idle。
    mutating func settlingCompleted(for intentID: Int) -> NoteReviewRefreshCoordinatorAction {
        guard phase == .settling, activeIntentID == intentID else { return .none }
        return startPendingOrFinish(shouldAnnounce: true)
    }

    /// 页面消失、设置变化或 generation 失效时清空全部意图；ID 继续递增，避免旧 Task 重新获得有效身份。
    mutating func cancel() {
        phase = .idle
        activeIntentID = nil
        pendingIntentID = nil
    }

    /// 只有卡组确有可感知变化且至少两张时才值得执行整组空间交接。
    static func requiresReplacement(oldIDs: [Int64], newIDs: [Int64]) -> Bool {
        oldIDs.count > 1 && newIDs.count > 1 && oldIDs != newIDs
    }

    /// 消费唯一 pending 或按调用阶段收口，布尔值只描述最终落定组是否需要播报。
    private mutating func startPendingOrFinish(
        shouldAnnounce: Bool
    ) -> NoteReviewRefreshCoordinatorAction {
        if let pendingIntentID {
            self.pendingIntentID = nil
            activeIntentID = pendingIntentID
            phase = .loading
            return .start(pendingIntentID)
        }
        activeIntentID = nil
        phase = .idle
        return .finish(shouldAnnounce: shouldAnnounce)
    }
}

/// 一组静态卡组 snapshot 在交接某一阶段使用的几何状态。
nonisolated struct NoteReviewRefreshDeckTransform: Equatable, Sendable {
    let offsetX: CGFloat
    let offsetY: CGFloat
    let scale: CGFloat
    let rotationDegrees: Double
    let opacity: Double
}

/// 刷新按钮查询反馈的纯值策略，所有刷新模式统一延迟 150ms 显示并至少驻留 200ms。
nonisolated enum NoteReviewRefreshProgressPolicy {
    static let delay: Duration = .milliseconds(150)
    static let minimumVisibleDuration: Duration = .milliseconds(200)
}

/// 保障临时新组和提交后的 live deck 至少经历一轮渲染的时序，避免状态写入被 SwiftUI 合并后跳帧。
nonisolated enum NoteReviewRefreshRenderPolicy {
    static let mountDelay: Duration = .milliseconds(16)
    static let handoffDelay: Duration = .milliseconds(16)
}

/// 回顾首轮读取的同构壳层，复用生产卡组与操作栏几何，避免启动阶段出现无关列表骨架。
struct NoteReviewLoadingShell: View {
    let isLoadingIndicatorVisible: Bool

    @State private var selection: Int? = 0

    private static let placeholderItems = (0..<3).map(NoteReviewLoadingItem.init)

    /// 创建静止壳层；加载提示默认隐藏，超过读取阈值后只在固定位置叠加紧凑指示。
    init(isLoadingIndicatorVisible: Bool = false) {
        self.isLoadingIndicatorVisible = isLoadingIndicatorVisible
    }

    var body: some View {
        ZStack {
            semanticStructure
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .transaction { transaction in
                    transaction.disablesAnimations = true
                }

            if isLoadingIndicatorVisible {
                LoadingStateView(style: .inline)
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                    .accessibilityLabel("正在加载回顾")
            }
        }
    }

    private var semanticStructure: some View {
        VStack(spacing: NoteReviewBottomLayout.actionRowSpacing) {
            NoteReviewPagingDeck(
                items: Self.placeholderItems,
                selection: $selection,
                hasMoreItems: false,
                configuration: deckConfiguration
            ) { _, _ in
                NoteReviewLoadingCard()
                    .padding(.horizontal, reviewLayoutSpec.cardHorizontalPadding)
                    .padding(.bottom, Spacing.cozy)
            } emptyContent: {
                Color.clear
            }
            .frame(maxWidth: reviewLayoutSpec.maxDeckWidth, maxHeight: .infinity)
            .padding(.top, NoteReviewBottomLayout.deckTopPadding)
            .padding(.bottom, NoteReviewBottomLayout.deckBottomPadding)

            NoteReviewPrimaryActionBar(
                item: nil,
                configuredDestinations: [],
                refreshTitle: "换一组",
                isRefreshing: false,
                isRefreshDisabled: true,
                areContentActionsDisabled: true,
                isSending: false,
                isTagActionInFlight: false,
                isTagProgressVisible: false,
                isAIActionInFlight: false,
                isAIProgressVisible: false,
                onSend: { _, _ in },
                onRequestSendConfiguration: {},
                onEditTags: { _ in },
                onExplain: { _ in },
                onAutoTag: { _ in },
                onRefresh: {}
            )
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.bottom, NoteReviewBottomLayout.actionRowBottomPadding)
        }
    }

    private var reviewLayoutSpec: NoteReviewPagingLayoutSpec {
        var layoutSpec = NoteReviewPagingLayoutSpec.iOSReviewDefault
        layoutSpec.cardInsets.bottom = Spacing.cozy
        return layoutSpec
    }

    private var deckConfiguration: NoteReviewPagingDeckConfiguration {
        var configuration = NoteReviewPagingDeckConfiguration.iOSReviewDefault
        configuration.cardInsets = reviewLayoutSpec.cardInsets
        configuration.isSwipeEnabled = false
        configuration.isTapEnabled = false
        return configuration
    }
}

/// 壳层分页项只提供稳定身份，不携带伪造的书摘内容。
private struct NoteReviewLoadingItem: Identifiable {
    let id: Int
}

/// 待数据卡片只表达正文、想法和来源的占位层级，颜色与装饰保持低对比且静止。
private struct NoteReviewLoadingCard: View {
    @Environment(\.noteReviewPagingCardContentVisibility) private var cardContentVisibility

    var body: some View {
        VStack(spacing: Spacing.none) {
            VStack(alignment: .leading, spacing: NoteReviewCardLayout.bodySectionSpacing) {
                bodyLines
                ideaPlaceholder
                Spacer(minLength: Spacing.none)
            }
            .padding(.horizontal, NoteReviewCardLayout.horizontalPadding)
            .padding(.top, NoteReviewCardLayout.topPadding)
            .padding(.bottom, NoteReviewCardLayout.bodyBottomPadding)
            .opacity(cardContentVisibility.bodyOpacity)

            footerPlaceholder
                .padding(.horizontal, NoteReviewCardLayout.horizontalPadding)
                .padding(.bottom, NoteReviewCardLayout.bottomPadding)
                .opacity(cardContentVisibility.footerOpacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.surfaceCard)
        .compositingGroup()
        .clipShape(cardShape)
        .overlay {
            cardShape
                .stroke(
                    Color.surfaceBorderSubtle.opacity(NoteReviewLoadingMetrics.borderOpacity),
                    lineWidth: NoteReviewCardLayout.borderWidth
                )
        }
        .shadow(
            color: Color.black.opacity(NoteReviewCardLayout.shadowOpacity),
            radius: NoteReviewCardLayout.shadowRadius,
            x: 0,
            y: NoteReviewCardLayout.shadowYOffset
        )
    }

    private var bodyLines: some View {
        VStack(alignment: .leading, spacing: NoteReviewLoadingMetrics.bodyLineSpacing) {
            placeholderLine(widthFraction: 0.96)
            placeholderLine(widthFraction: 0.88)
            placeholderLine(widthFraction: 0.93)
            placeholderLine(widthFraction: 0.64)
        }
    }

    private var ideaPlaceholder: some View {
        VStack(alignment: .leading, spacing: NoteReviewLoadingMetrics.ideaLineSpacing) {
            placeholderLine(widthFraction: 0.84, height: NoteReviewLoadingMetrics.ideaLineHeight)
            placeholderLine(widthFraction: 0.58, height: NoteReviewLoadingMetrics.ideaLineHeight)
        }
        .padding(.horizontal, NoteReviewCardLayout.ideaHorizontalPadding)
        .padding(.vertical, NoteReviewCardLayout.ideaVerticalPadding)
        .background(
            Color.textPrimary.opacity(NoteReviewLoadingMetrics.ideaSurfaceOpacity),
            in: RoundedRectangle(
                cornerRadius: NoteReviewCardLayout.ideaCornerRadius,
                style: .continuous
            )
        )
    }

    private var footerPlaceholder: some View {
        HStack(spacing: NoteReviewCardLayout.footerContentSpacing) {
            RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                .fill(Color.textPrimary.opacity(NoteReviewLoadingMetrics.coverOpacity))
                .frame(
                    width: NoteReviewCardLayout.footerCoverWidth,
                    height: NoteReviewLoadingMetrics.footerCoverHeight
                )

            VStack(alignment: .leading, spacing: NoteReviewCardLayout.footerTextSpacing) {
                placeholderLine(widthFraction: 0.52, height: NoteReviewLoadingMetrics.footerTitleHeight)
                placeholderLine(widthFraction: 0.34, height: NoteReviewLoadingMetrics.footerAuthorHeight)
            }

            Spacer(minLength: Spacing.none)
        }
        .padding(.top, NoteReviewCardLayout.footerTopPadding)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.surfaceBorderSubtle.opacity(NoteReviewLoadingMetrics.dividerOpacity))
                .frame(height: CardStyle.borderWidth)
        }
    }

    private func placeholderLine(widthFraction: CGFloat, height: CGFloat = NoteReviewLoadingMetrics.bodyLineHeight) -> some View {
        GeometryReader { proxy in
            Capsule()
                .fill(Color.textSecondary.opacity(NoteReviewLoadingMetrics.lineOpacity))
                .frame(width: proxy.size.width * widthFraction, height: height)
        }
        .frame(height: height)
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: NoteReviewCardLayout.cornerRadius, style: .continuous)
    }
}

private enum NoteReviewLoadingMetrics {
    static let bodyLineHeight: CGFloat = 9
    static let ideaLineHeight: CGFloat = 7
    static let footerTitleHeight: CGFloat = 8
    static let footerAuthorHeight: CGFloat = 6
    static let footerCoverHeight: CGFloat = 52
    static let bodyLineSpacing = Spacing.cozy
    static let ideaLineSpacing = Spacing.half
    static let lineOpacity = 0.12
    static let ideaSurfaceOpacity = 0.035
    static let coverOpacity = 0.065
    static let borderOpacity = 0.38
    static let dividerOpacity = 0.42
}

/// 对交接曲线的纯值描述，既能被 SwiftUI 映射为 Animation，也能精确地在单元测试中验证。
nonisolated enum NoteReviewRefreshMotionCurve: Equatable, Sendable {
    case smooth
    case snappy(extraBounce: Double)
    case easeInOut
}

/// 单个 snapshot 的起始状态与时序。
nonisolated struct NoteReviewRefreshMotionStage: Equatable, Sendable {
    let transform: NoteReviewRefreshDeckTransform
    let duration: TimeInterval
    let delay: TimeInterval
    let curve: NoteReviewRefreshMotionCurve

    var durationMilliseconds: Int64 {
        Int64((duration * 1_000).rounded())
    }

    var delayMilliseconds: Int64 {
        Int64((delay * 1_000).rounded())
    }

    var delayValue: Duration {
        .milliseconds(delayMilliseconds)
    }
}

/// “换一组”双 snapshot 交接的唯一动效规格；Reduce Motion 改为连续的 opacity 交接。
nonisolated struct NoteReviewRefreshMotionSpec: Equatable, Sendable {
    let outgoing: NoteReviewRefreshMotionStage
    let incoming: NoteReviewRefreshMotionStage

    static let standard = NoteReviewRefreshMotionSpec(
        outgoing: NoteReviewRefreshMotionStage(
            transform: .init(offsetX: -18, offsetY: -6, scale: 0.988, rotationDegrees: -0.25, opacity: 0),
            duration: 0.18,
            delay: 0,
            curve: .smooth
        ),
        incoming: NoteReviewRefreshMotionStage(
            transform: .init(offsetX: 12, offsetY: 7, scale: 0.978, rotationDegrees: 0.15, opacity: 0),
            duration: 0.24,
            delay: 0.05,
            curve: .snappy(extraBounce: 0)
        )
    )

    static let reduceMotion = NoteReviewRefreshMotionSpec(
        outgoing: NoteReviewRefreshMotionStage(
            transform: .init(offsetX: 0, offsetY: 0, scale: 1, rotationDegrees: 0, opacity: 0),
            duration: 0.1,
            delay: 0,
            curve: .easeInOut
        ),
        incoming: NoteReviewRefreshMotionStage(
            transform: .init(offsetX: 0, offsetY: 0, scale: 1, rotationDegrees: 0, opacity: 0),
            duration: 0.14,
            delay: 0.1,
            curve: .easeInOut
        )
    )

    /// 从旧组开始退场到新组落定的完整编排时长。
    var totalDuration: TimeInterval {
        let totalMilliseconds = max(
            outgoing.durationMilliseconds,
            incoming.delayMilliseconds + incoming.durationMilliseconds
        )
        return TimeInterval(totalMilliseconds) / 1_000
    }

    /// 供页面 Task 与测试共同使用的最终完成时刻，避免手工时长与规格漂移。
    var completionDuration: TimeInterval {
        totalDuration
    }

    /// 仅将曲线和持续时间映射为 Animation；阶段 delay 由外层编排 Task 唯一负责。
    func animation(for stage: NoteReviewRefreshMotionStage) -> Animation {
        let animation: Animation
        switch stage.curve {
        case .smooth:
            animation = .smooth(duration: stage.duration)
        case .snappy(let extraBounce):
            animation = .snappy(duration: stage.duration, extraBounce: extraBounce)
        case .easeInOut:
            animation = .easeInOut(duration: stage.duration)
        }
        return animation
    }
}

/// 页面私有卡组宿主：随机模式让稳定 live deck 退场并由预挂载新组接替；顺序模式继续即时刷新。
struct NoteReviewRefreshDeckHost<CardContent: View>: View {
    private struct DeckSnapshot {
        let intentID: Int
        let items: [NoteReviewCardItem]
    }

    @Bindable var viewModel: NoteReviewViewModel
    let isTagActionInFlight: Bool
    let isTagProgressVisible: Bool
    let isAIActionInFlight: Bool
    let isAIProgressVisible: Bool
    let onCardTapped: (NoteReviewCardItem) -> Void
    let onSend: (NoteReviewCardItem, ExternalAppDestination) -> Void
    let onRequestSendConfiguration: () -> Void
    let onEditTags: (NoteReviewCardItem) -> Void
    let onExplain: (NoteReviewCardItem) -> Void
    let onAutoTag: (NoteReviewCardItem) -> Void
    @ViewBuilder let cardContent: (NoteReviewCardItem) -> CardContent

    private let progressClock = ContinuousClock()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var coordinator = NoteReviewRefreshCoordinator()
    @State private var liveDeckRevision = 0
    @State private var incomingSnapshot: DeckSnapshot?
    @State private var incomingSelection: Int64?
    @State private var hasOutgoingDeparted = false
    @State private var hasIncomingArrived = false
    @State private var isShowingQueryProgress = false
    @State private var isOrderedRefreshing = false
    @State private var progressGeneration = 0
    @State private var progressShownAt: ContinuousClock.Instant?
    @State private var queryProgressTask: Task<Void, Never>?
    @State private var refreshTask: Task<Void, Never>?
    @State private var replacementTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: NoteReviewBottomLayout.actionRowSpacing) {
            deck

            NoteReviewPrimaryActionBar(
                item: viewModel.currentItem,
                configuredDestinations: configuredDestinations,
                refreshTitle: viewModel.settings.sortRule == .random ? "换一组" : "刷新",
                isRefreshing: isShowingQueryProgress,
                isRefreshDisabled: isRefreshButtonDisabled,
                areContentActionsDisabled: areContentActionsDisabled,
                isSending: viewModel.externalAppSendAction != nil,
                isTagActionInFlight: isTagActionInFlight,
                isTagProgressVisible: isTagProgressVisible,
                isAIActionInFlight: isAIActionInFlight,
                isAIProgressVisible: isAIProgressVisible,
                onSend: onSend,
                onRequestSendConfiguration: onRequestSendConfiguration,
                onEditTags: onEditTags,
                onExplain: onExplain,
                onAutoTag: onAutoTag,
                onRefresh: requestRefresh
            )
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.bottom, NoteReviewBottomLayout.actionRowBottomPadding)
        }
        .onChange(of: viewModel.settings) { _, _ in
            cancelRefreshWork()
        }
        .onDisappear {
            cancelRefreshWork()
        }
    }

    @ViewBuilder
    private var deck: some View {
        ZStack {
            if let incomingSnapshot {
                frozenDeck(snapshot: incomingSnapshot, selection: $incomingSelection)
                    .compositingGroup()
                    .refreshDeckState(
                        hasArrived: hasIncomingArrived,
                        stage: motion.incoming
                    )
                    .id(incomingSnapshot.intentID)
                    .zIndex(0)
            }

            liveDeck
                .id(liveDeckRevision)
                .compositingGroup()
                .refreshDeckState(
                    hasArrived: !hasOutgoingDeparted,
                    stage: motion.outgoing
                )
                .allowsHitTesting(incomingSnapshot == nil)
                .accessibilityHidden(incomingSnapshot != nil)
                .zIndex(1)
        }
        .frame(maxWidth: reviewLayoutSpec.maxDeckWidth, maxHeight: .infinity)
        .padding(.top, NoteReviewBottomLayout.deckTopPadding)
        .padding(.bottom, NoteReviewBottomLayout.deckBottomPadding)
        .animation(.smooth(duration: reduceMotion ? 0.01 : 0.22), value: viewModel.settings.palette)
    }

    private var liveDeck: some View {
        NoteReviewPagingDeck(
            items: viewModel.items,
            selection: $viewModel.selectedItemID,
            hasMoreItems: viewModel.hasMoreItems,
            configuration: deckConfiguration,
            onCardAppeared: { item, index in
                viewModel.handleCardAppeared(item, index: index)
            },
            onNeedsMoreItems: {
                Task { await viewModel.loadMoreIfNeeded() }
            },
            onTap: { item, _ in
                onCardTapped(item)
            }
        ) { item, _ in
            cardContent(item)
        } emptyContent: {
            Color.clear
        }
    }

    /// 用独立 selection binding 渲染无交互 snapshot，避免旧组与 live/new deck 共享分页状态。
    private func frozenDeck(
        snapshot: DeckSnapshot,
        selection: Binding<Int64?>
    ) -> some View {
        NoteReviewPagingDeck(
            items: snapshot.items,
            selection: selection,
            hasMoreItems: false,
            configuration: staticDeckConfiguration
        ) { item, _ in
            cardContent(item)
        } emptyContent: {
            Color.clear
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var reviewLayoutSpec: NoteReviewPagingLayoutSpec {
        var layoutSpec = NoteReviewPagingLayoutSpec.iOSReviewDefault
        layoutSpec.cardInsets.bottom = Spacing.cozy
        return layoutSpec
    }

    private var deckConfiguration: NoteReviewPagingDeckConfiguration {
        var configuration = NoteReviewPagingDeckConfiguration.iOSReviewDefault
        configuration.cardInsets = reviewLayoutSpec.cardInsets
        return configuration
    }

    private var staticDeckConfiguration: NoteReviewPagingDeckConfiguration {
        var configuration = deckConfiguration
        configuration.isSwipeEnabled = false
        configuration.isTapEnabled = false
        return configuration
    }

    private var motion: NoteReviewRefreshMotionSpec {
        reduceMotion ? .reduceMotion : .standard
    }

    private var isRefreshButtonDisabled: Bool {
        viewModel.isInitialLoading
            || (viewModel.settings.sortRule == .ordered && isOrderedRefreshing)
    }

    private var areContentActionsDisabled: Bool {
        viewModel.currentItem == nil
            || viewModel.isInitialLoading
            || viewModel.isRefreshing
            || coordinator.phase != .idle
            || incomingSnapshot != nil
            || isOrderedRefreshing
    }

    private var configuredDestinations: [ExternalAppDestination] {
        ExternalAppDestination.allCases.filter(viewModel.isExternalAppDestinationConfigured)
    }

    /// 接收刷新点击；顺序模式维持即时提交，随机模式只让协调器启动或合并最新意图，所有 Task 在主线程检查取消与 intent 身份。
    private func requestRefresh() {
        guard !viewModel.isInitialLoading else { return }
        guard viewModel.settings.sortRule == .random else {
            startOrderedRefresh()
            return
        }
        perform(coordinator.request())
    }

    /// 顺序刷新保持即时数据提交，但用同一 150/200ms 反馈策略包裹真实查询；Task 在主线程更新按钮状态，取消后不再恢复过期反馈。
    private func startOrderedRefresh() {
        guard !isOrderedRefreshing else { return }
        isOrderedRefreshing = true
        let progressID = beginProgressFeedback()
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            await viewModel.refresh()
            guard await finishProgressFeedback(for: progressID) else { return }
            isOrderedRefreshing = false
        }
    }

    /// 启动候选页查询与 150ms 延迟的固定 icon-slot 进度指示；Task 继承主线程，页面取消或 generation 失效后不再变更 snapshot。
    private func startPreparation(intentID: Int) {
        let progressID = beginProgressFeedback()
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            let result = await viewModel.prepareRefresh()
            guard !Task.isCancelled, coordinator.isActive(intentID) else { return }
            guard await finishProgressFeedback(for: progressID) else { return }
            guard coordinator.isActive(intentID) else { return }
            handlePreparation(result, intentID: intentID)
        }
    }

    /// 为当前查询建立唯一反馈 generation；延迟任务继承主线程，只为仍有效的查询记录 ContinuousClock 显示时刻。
    private func beginProgressFeedback() -> Int {
        progressGeneration &+= 1
        let generation = progressGeneration
        queryProgressTask?.cancel()
        isShowingQueryProgress = false
        progressShownAt = nil
        queryProgressTask = Task { @MainActor in
            try? await Task.sleep(for: NoteReviewRefreshProgressPolicy.delay)
            guard !Task.isCancelled, progressGeneration == generation else { return }
            progressShownAt = progressClock.now
            isShowingQueryProgress = true
        }
        return generation
    }

    /// 查询结束后等待 mini progress 满足 200ms 最短驻留；等待期间旧卡保持不动，取消或 generation 变化会终止后续处理。
    private func finishProgressFeedback(for generation: Int) async -> Bool {
        queryProgressTask?.cancel()
        if let progressShownAt, isShowingQueryProgress {
            do {
                try await progressClock.sleep(
                    until: progressShownAt.advanced(
                        by: NoteReviewRefreshProgressPolicy.minimumVisibleDuration
                    )
                )
            } catch {
                return false
            }
        }
        guard !Task.isCancelled, progressGeneration == generation else { return false }
        isShowingQueryProgress = false
        progressShownAt = nil
        return true
    }

    /// 根据候选查询结果提交、进入交接或合并 pending；只有仍是最后一个意图的失败会进入 ViewModel 的既有 Toast 通道。
    private func handlePreparation(_ result: NoteReviewPrepareRefreshResult, intentID: Int) {
        switch result {
        case .prepared(let prepared):
            let oldIDs = viewModel.items.map(\.id)
            let newIDs = prepared.items.map(\.id)
            let requiresReplacement = NoteReviewRefreshCoordinator.requiresReplacement(
                oldIDs: oldIDs,
                newIDs: newIDs
            )
            let action = coordinator.preparationCompleted(
                for: intentID,
                requiresReplacement: requiresReplacement,
                shouldAnnounceOnFinish: oldIDs != newIDs
            )
            switch action {
            case .mountReplacement:
                mountReplacement(with: prepared, intentID: intentID)
            case .start:
                viewModel.cancelPreparedRefresh()
                perform(action)
            case .finish:
                if commitWithoutAnimation(prepared) {
                    perform(action)
                } else {
                    coordinator.cancel()
                }
            case .none, .settle:
                break
            }
        case .failed(let message):
            let action = coordinator.preparationFailed(for: intentID)
            guard action != .none else { return }
            viewModel.cancelPreparedRefresh()
            if action == .finish(shouldAnnounce: false) {
                viewModel.publishPreparedRefreshError(message)
            }
            perform(action)
        case .cancelled:
            let action = coordinator.preparationFailed(for: intentID)
            guard action != .none else { return }
            viewModel.cancelPreparedRefresh()
            perform(action)
        }
    }

    /// 先在 live deck 后方挂载不可交互的新组并等待一帧；避免挂载和退场写入被合并，确保旧组从当前画面连续离场。
    private func mountReplacement(with prepared: NoteReviewPreparedRefresh, intentID: Int) {
        let nextSelection = prepared.items.first?.id
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            incomingSnapshot = DeckSnapshot(intentID: intentID, items: prepared.items)
            incomingSelection = nextSelection
            hasOutgoingDeparted = false
            hasIncomingArrived = false
        }

        replacementTask?.cancel()
        let replacementMotion = motion
        replacementTask = Task { @MainActor in
            try? await Task.sleep(for: NoteReviewRefreshRenderPolicy.mountDelay)
            guard !Task.isCancelled,
                  coordinator.phase == .replacing,
                  coordinator.isActive(intentID)
            else { return }

            withAnimation(replacementMotion.animation(for: replacementMotion.outgoing)) {
                hasOutgoingDeparted = true
            }
            try? await Task.sleep(for: replacementMotion.incoming.delayValue)
            guard !Task.isCancelled, coordinator.phase == .replacing, coordinator.isActive(intentID) else { return }
            withAnimation(
                replacementMotion.animation(for: replacementMotion.incoming),
                completionCriteria: .logicallyComplete
            ) {
                hasIncomingArrived = true
            } completion: {
                guard coordinator.phase == .replacing,
                      coordinator.isActive(intentID)
                else { return }
                finishReplacement(prepared, intentID: intentID)
            }
        }
    }

    /// 新组落定后先在遮罩下提交 live deck，再保留一帧完成无缝接管；仅最终落定且未被 pending 合并的组会播报一次。
    private func finishReplacement(_ prepared: NoteReviewPreparedRefresh, intentID: Int) {
        guard coordinator.replacementAnimationCompleted(for: intentID) == .settle(intentID) else { return }
        guard commitPreparedRefreshKeepingTransition(prepared) else {
            coordinator.cancel()
            clearTransitionVisualsWithoutAnimation()
            return
        }

        replacementTask = Task { @MainActor in
            try? await Task.sleep(for: NoteReviewRefreshRenderPolicy.handoffDelay)
            guard !Task.isCancelled,
                  coordinator.phase == .settling,
                  coordinator.isActive(intentID)
            else { return }

            clearTransitionVisualsWithoutAnimation()
            perform(coordinator.settlingCompleted(for: intentID))
        }
    }

    /// 无空间交接时在同一禁用动画事务内提交并清理临时状态。
    private func commitWithoutAnimation(_ prepared: NoteReviewPreparedRefresh) -> Bool {
        var didCommit = false
        let previousIDs = viewModel.items.map(\.id)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            didCommit = viewModel.commitPreparedRefresh(prepared)
            if didCommit, previousIDs != viewModel.items.map(\.id) {
                liveDeckRevision &+= 1
            }
            incomingSnapshot = nil
            incomingSelection = nil
            hasOutgoingDeparted = false
            hasIncomingArrived = false
        }
        return didCommit
    }

    /// 在新组仍覆盖前景时更新底层 live deck，使其获得一轮布局与分页状态同步时间。
    private func commitPreparedRefreshKeepingTransition(
        _ prepared: NoteReviewPreparedRefresh
    ) -> Bool {
        var didCommit = false
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            didCommit = viewModel.commitPreparedRefresh(prepared)
            if didCommit {
                liveDeckRevision &+= 1
            }
        }
        return didCommit
    }

    /// 以禁用动画事务清理替换图层；调用后 live deck 恢复命中测试与无障碍焦点。
    private func clearTransitionVisualsWithoutAnimation() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            incomingSnapshot = nil
            incomingSelection = nil
            hasOutgoingDeparted = false
            hasIncomingArrived = false
        }
    }

    /// 执行状态机操作；`.finish` 是唯一允许发布最终换组无障碍播报的路径，合并请求不会获得中间播报。
    private func perform(_ action: NoteReviewRefreshCoordinatorAction) {
        switch action {
        case .none:
            break
        case .start(let intentID):
            startPreparation(intentID: intentID)
        case .mountReplacement, .settle:
            break
        case .finish(let shouldAnnounce):
            if shouldAnnounce, viewModel.settings.sortRule == .random {
                AccessibilityNotification.Announcement("已换一组，共 \(viewModel.items.count) 张书摘").post()
            }
        }
    }

    /// 页面消失或设置变化会取消所有延迟和交接任务，并推进 ViewModel generation，防止旧候选页恢复到新范围。
    private func cancelRefreshWork() {
        queryProgressTask?.cancel()
        refreshTask?.cancel()
        replacementTask?.cancel()
        queryProgressTask = nil
        refreshTask = nil
        replacementTask = nil
        progressGeneration &+= 1
        isShowingQueryProgress = false
        isOrderedRefreshing = false
        progressShownAt = nil
        coordinator.cancel()
        viewModel.cancelPreparedRefresh()
        clearTransitionVisualsWithoutAnimation()
    }
}

private extension View {
    /// 将 snapshot 在初始/落定状态之间切换，所有几何属性作用于整组 deck。
    func refreshDeckState(
        hasArrived: Bool,
        stage: NoteReviewRefreshMotionStage
    ) -> some View {
        offset(
            x: hasArrived ? 0 : stage.transform.offsetX,
            y: hasArrived ? 0 : stage.transform.offsetY
        )
        .scaleEffect(hasArrived ? 1 : stage.transform.scale)
        .rotationEffect(.degrees(hasArrived ? 0 : stage.transform.rotationDegrees))
        .opacity(hasArrived ? 1 : stage.transform.opacity)
    }
}

private enum NoteReviewBottomLayout {
    static let deckTopPadding = Spacing.base
    static let deckBottomPadding = Spacing.none
    static let actionRowSpacing = Spacing.cozy
    static let actionRowBottomPadding = Spacing.section + Spacing.cozy
    static let actionRowMinHeight: CGFloat = 44
}

/// 操作栏按整组选择横排或上下排列，避免单项独立折行造成视觉节奏混杂。
private enum NoteReviewPrimaryActionLayout {
    case inline
    case stacked

    var actionSpacing: CGFloat {
        switch self {
        case .inline:
            NoteReviewPrimaryActionMetrics.inlineActionSpacing
        case .stacked:
            Spacing.none
        }
    }

    var rowAlignment: VerticalAlignment {
        switch self {
        case .inline:
            .center
        case .stacked:
            .top
        }
    }

    var controlMaxWidth: CGFloat? {
        switch self {
        case .inline:
            nil
        case .stacked:
            .infinity
        }
    }
}

/// 与既有“换一组”同层级的四项一级操作栏；只编排入口，不持有发送、标签或 AI 业务状态。
private struct NoteReviewPrimaryActionBar: View {
    let item: NoteReviewCardItem?
    let configuredDestinations: [ExternalAppDestination]
    let refreshTitle: String
    let isRefreshing: Bool
    let isRefreshDisabled: Bool
    let areContentActionsDisabled: Bool
    let isSending: Bool
    let isTagActionInFlight: Bool
    let isTagProgressVisible: Bool
    let isAIActionInFlight: Bool
    let isAIProgressVisible: Bool
    let onSend: (NoteReviewCardItem, ExternalAppDestination) -> Void
    let onRequestSendConfiguration: () -> Void
    let onEditTags: (NoteReviewCardItem) -> Void
    let onExplain: (NoteReviewCardItem) -> Void
    let onAutoTag: (NoteReviewCardItem) -> Void
    let onRefresh: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrowRotationDegrees = 0.0

    var body: some View {
        ViewThatFits(in: .horizontal) {
            actionRow(layout: .inline)
                .fixedSize(horizontal: true, vertical: false)

            actionRow(layout: .stacked)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("回顾卡片操作")
    }

    private func actionRow(layout: NoteReviewPrimaryActionLayout) -> some View {
        HStack(alignment: layout.rowAlignment, spacing: layout.actionSpacing) {
            sendControl(layout: layout)

            actionButton(
                title: "标签",
                systemImage: "tag",
                showsProgress: isTagProgressVisible,
                isDisabled: contentActionDisabled || isTagActionInFlight,
                layout: layout,
                accessibilityLabel: "设置当前书摘标签",
                accessibilityHint: "打开标签编辑"
            ) {
                guard let item else { return }
                onEditTags(item)
            }

            aiAssistantControl(layout: layout)

            actionButton(
                title: refreshTitle,
                systemImage: "arrow.clockwise",
                showsProgress: isRefreshing,
                isDisabled: isRefreshDisabled,
                rotationDegrees: reduceMotion ? 0 : arrowRotationDegrees,
                layout: layout,
                accessibilityLabel: refreshTitle == "换一组" ? "换一组书摘" : "刷新回顾",
                accessibilityHint: "重新加载当前范围内的书摘卡片",
                action: performRefresh
            )
        }
    }

    private var contentActionDisabled: Bool {
        item == nil || areContentActionsDisabled
    }

    private var sendActionDisabled: Bool {
        contentActionDisabled || isSending
    }

    private var aiActionDisabled: Bool {
        contentActionDisabled || isAIActionInFlight
    }

    @ViewBuilder
    private func sendControl(layout: NoteReviewPrimaryActionLayout) -> some View {
        if configuredDestinations.count > 1 {
            Menu {
                ForEach(configuredDestinations) { destination in
                    Button {
                        guard let item else { return }
                        onSend(item, destination)
                    } label: {
                        Label(
                            destination.noteReviewMenuTitle,
                            systemImage: destination.noteReviewMenuSystemImage
                        )
                    }
                    .disabled(isSending)
                }
            } label: {
                NoteReviewPrimaryActionLabel(
                    title: "发送",
                    systemImage: "paperplane",
                    showsProgress: isSending,
                    isDisabled: sendActionDisabled,
                    layout: layout
                )
            }
            .menuIndicator(.hidden)
            .buttonStyle(NoteReviewPrimaryActionButtonStyle(isEnabled: !sendActionDisabled))
            .disabled(sendActionDisabled)
            .accessibilityLabel("发送当前书摘")
            .accessibilityHint("选择一个已配置的发送目标")
            .frame(maxWidth: layout.controlMaxWidth)
        } else {
            actionButton(
                title: "发送",
                systemImage: "paperplane",
                showsProgress: isSending,
                isDisabled: sendActionDisabled,
                layout: layout,
                accessibilityLabel: "发送当前书摘",
                accessibilityHint: configuredDestinations.isEmpty
                    ? "前往关联应用设置"
                    : "发送到 \(configuredDestinations[0].noteReviewMenuTitle)"
            ) {
                guard let item else { return }
                if let destination = configuredDestinations.first {
                    onSend(item, destination)
                } else {
                    onRequestSendConfiguration()
                }
            }
        }
    }

    /// 使用系统菜单承载两项 AI 能力，入口保持与同层普通操作一致的中性色和 44pt 命中范围。
    private func aiAssistantControl(layout: NoteReviewPrimaryActionLayout) -> some View {
        Menu {
            Button {
                guard let item else { return }
                onExplain(item)
            } label: {
                Label("AI 释义", systemImage: "sparkles")
            }

            Button {
                guard let item else { return }
                onAutoTag(item)
            } label: {
                Label("AI 标签", systemImage: "tag")
            }
        } label: {
            NoteReviewPrimaryActionLabel(
                title: "AI 助手",
                systemImage: "sparkles",
                showsProgress: isAIProgressVisible,
                isDisabled: aiActionDisabled,
                layout: layout
            )
        }
        .menuIndicator(.hidden)
        .buttonStyle(NoteReviewPrimaryActionButtonStyle(isEnabled: !aiActionDisabled))
        .disabled(aiActionDisabled)
        .accessibilityLabel("AI 助手")
        .accessibilityHint("打开 AI 释义和 AI 标签菜单")
        .frame(maxWidth: layout.controlMaxWidth)
    }

    private func actionButton(
        title: String,
        systemImage: String,
        showsProgress: Bool,
        isDisabled: Bool,
        rotationDegrees: Double = 0,
        layout: NoteReviewPrimaryActionLayout,
        accessibilityLabel: String,
        accessibilityHint: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            NoteReviewPrimaryActionLabel(
                title: title,
                systemImage: systemImage,
                showsProgress: showsProgress,
                isDisabled: isDisabled,
                rotationDegrees: rotationDegrees,
                layout: layout
            )
        }
        .buttonStyle(NoteReviewPrimaryActionButtonStyle(isEnabled: !isDisabled))
        .disabled(isDisabled)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
        .frame(maxWidth: layout.controlMaxWidth)
    }

    private func performRefresh() {
        if !reduceMotion {
            withAnimation(.snappy(duration: 0.18, extraBounce: 0)) {
                arrowRotationDegrees += 120
            }
        }
        onRefresh()
    }
}

/// 按操作栏选定的统一形态排列图标与文案，并保持 44pt 点击区域和稳定加载图标槽。
private struct NoteReviewPrimaryActionLabel: View {
    let title: String
    let systemImage: String
    let showsProgress: Bool
    let isDisabled: Bool
    var rotationDegrees = 0.0
    let layout: NoteReviewPrimaryActionLayout

    @ScaledMetric(relativeTo: .caption) private var iconSlot: CGFloat = 16

    var body: some View {
        Group {
            switch layout {
            case .inline:
                HStack(spacing: Spacing.half) {
                    icon
                    inlineTitleLabel
                }
            case .stacked:
                VStack(spacing: Spacing.tiny) {
                    icon
                    stackedTitleLabel
                }
            }
        }
        .foregroundStyle(
            Color.textSecondary.opacity(
                isDisabled
                    ? NoteReviewPrimaryActionMetrics.disabledOpacity
                    : NoteReviewPrimaryActionMetrics.enabledOpacity
            )
        )
        .frame(
            minWidth: NoteReviewBottomLayout.actionRowMinHeight,
            maxWidth: layout.controlMaxWidth,
            minHeight: NoteReviewBottomLayout.actionRowMinHeight
        )
        .contentShape(Rectangle())
    }

    private var icon: some View {
        ZStack {
            Image(systemName: systemImage)
                .font(AppTypography.captionMedium)
                .rotationEffect(.degrees(rotationDegrees))
                .opacity(showsProgress ? 0 : 1)
                .accessibilityHidden(true)

            ProgressView()
                .controlSize(.mini)
                .tint(Color.textSecondary.opacity(NoteReviewPrimaryActionMetrics.progressOpacity))
                .opacity(showsProgress ? 1 : 0)
                .accessibilityHidden(true)
        }
        .frame(width: iconSlot, height: iconSlot)
    }

    private var inlineTitleLabel: some View {
        Text(title)
            .font(AppTypography.captionMedium)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var stackedTitleLabel: some View {
        Text(title)
            .font(AppTypography.captionMedium)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct NoteReviewPrimaryActionButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isEnabled: Bool

    /// 保留既有 0.96 按压反馈，并在 Reduce Motion 下移除缩放动画。
    func makeBody(configuration: Configuration) -> some View {
        let isPressed = isEnabled && configuration.isPressed

        configuration.label
            .background {
                if isPressed {
                    Capsule()
                        .fill(Color.controlFillSecondary.opacity(NoteReviewPrimaryActionMetrics.pressedFillOpacity))
                        .padding(.horizontal, -Spacing.half)
                        .padding(.vertical, Spacing.tiny)
                        .accessibilityHidden(true)
                }
            }
            .scaleEffect(!reduceMotion && isPressed ? NoteReviewPrimaryActionMetrics.pressedScale : 1)
            .animation(reduceMotion ? nil : .snappy(duration: NoteReviewPrimaryActionMetrics.pressAnimationDuration), value: configuration.isPressed)
    }
}

private enum NoteReviewPrimaryActionMetrics {
    static let inlineActionSpacing = Spacing.base
    static let enabledOpacity = 0.94
    static let disabledOpacity = 0.36
    static let progressOpacity = 0.68
    static let pressedFillOpacity = 0.10
    static let pressedScale = 0.96
    static let pressAnimationDuration = 0.12
}
