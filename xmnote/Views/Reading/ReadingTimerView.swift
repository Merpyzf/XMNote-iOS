import SwiftUI

/**
 * [INPUT]: 依赖环境注入的 ReadingTimerCoordinator 投影应用级计时状态，依赖 ReadingTimerFinishSheet 收集结束确认字段，依赖外层 onRequestDismiss 统一处理收起与后续导航，并依赖 XMBookCover/XMSystemAlert 复用系统级组件
 * [OUTPUT]: 对外提供 ReadingTimerView 与 ReadingTimerDismissReason（全局阅读计时完整控制页及类型化关闭结果）
 * [POS]: Reading 模块阅读计时模态控制页，只编排计时交互并将关闭原因交还呈现宿主，不拥有全局呈现生命周期
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 描述计时页结束当前模态任务的业务原因，供呈现宿主决定退场与后续导航。
enum ReadingTimerDismissReason: Equatable {
    case minimize
    case completed
    case discarded
    case conflict
    case openNote(bookId: Int64)
}

/// 阅读计时主页面，以书籍上下文、封面计时与单一主操作构成核心闭环。
struct ReadingTimerView: View {
    let bookId: Int64
    let recordId: Int64?
    let onRequestDismiss: (ReadingTimerDismissReason) -> Void

    @Environment(ReadingTimerCoordinator.self) private var coordinator
    @Environment(ReadingTimerSettingsStore.self) private var timerSettings
    @State private var shouldPresentStartSheet = false
    @State private var shouldReturnAfterRecoveryDismiss = false
    @State private var pendingFinishDismissReason: ReadingTimerDismissReason?

    /// 注入计时目标与单一关闭回调，避免计时页持有呈现状态或外层 NavigationPath。
    init(
        bookId: Int64,
        recordId: Int64? = nil,
        onRequestDismiss: @escaping (ReadingTimerDismissReason) -> Void
    ) {
        self.bookId = bookId
        self.recordId = recordId
        self.onRequestDismiss = onRequestDismiss
    }

    var body: some View {
        ZStack {
            Color.surfacePage.ignoresSafeArea()

            if coordinator.bookContext != nil || coordinator.activeSession != nil {
                ReadingTimerContent(
                    coordinator: coordinator,
                    onMainAction: { handleMainAction(coordinator) },
                    onStop: { Task { @MainActor in await coordinator.stopForSave() } },
                    onAddNote: { onRequestDismiss(.openNote(bookId: bookId)) }
                )
            } else if coordinator.isLoading {
                LoadingStateView("正在准备阅读计时…", style: .card)
            } else if let errorMessage = coordinator.errorMessage {
                ReadingTimerUnavailableState(message: errorMessage)
            }
        }
        .accessibilityIdentifier("reading.timer.\(bookId)")
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .task(id: bootstrapIdentity) {
            if let recordId {
                await coordinator.bootstrap(.record(recordId: recordId, fallbackBookId: bookId))
            } else {
                await coordinator.bootstrap(.book(bookId))
            }
        }
        .sheet(
            isPresented: $shouldPresentStartSheet
        ) {
            ReadingTimerStartSheet { draft in
                Task { @MainActor in
                    await coordinator.start(bookId: bookId, countdownSeconds: draft.countdownSeconds)
                }
            }
        }
        .sheet(
            isPresented: Binding(
                get: { coordinator.shouldPresentFinishSheet },
                set: { isPresented in
                    coordinator.shouldPresentFinishSheet = isPresented
                }
            ),
            onDismiss: completePendingFinishDismissal
        ) {
            ReadingTimerFinishSheet(
                coordinator: coordinator,
                onSave: { draft in
                    saveFinishDraft(draft, using: coordinator)
                },
                onDiscard: {
                    Task { @MainActor in
                        let didDiscard = await coordinator.discardCurrentSession()
                        guard didDiscard else { return }
                        pendingFinishDismissReason = .discarded
                        coordinator.shouldPresentFinishSheet = false
                    }
                },
                onContinue: {
                    Task { @MainActor in
                        await coordinator.resumeStoppedForContinue()
                    }
                }
            )
        }
        .xmSystemAlert(
            isPresented: Binding(
                get: { coordinator.shouldPresentRecoveryPrompt },
                set: { isPresented in
                    guard !isPresented else { return }
                    coordinator.postponeRecoveryPrompt()
                }
            ),
            descriptor: recoveryDescriptor,
            onDismiss: handleRecoveryPromptDismiss
        )
        .xmSystemAlert(
            isPresented: Binding(
                get: { coordinator.shouldPresentCountdownCompletionAlert },
                set: { isPresented in
                    guard !isPresented else { return }
                    coordinator.shouldPresentCountdownCompletionAlert = false
                }
            ),
            descriptor: countdownCompletionDescriptor
        )
    }

    private var bootstrapIdentity: String {
        if let recordId {
            return "record-\(recordId)-book-\(bookId)"
        }
        return "book-\(bookId)"
    }

    private var recoveryDescriptor: XMSystemAlertDescriptor? {
        guard let session = coordinator.pendingRecoverySession else { return nil }
        return XMSystemAlertDescriptor(
            title: recoveryTitle(for: session),
            message: recoveryMessage(for: session),
            actions: [
                XMSystemAlertAction(title: "查看计时") {
                    coordinator.acceptRecovery()
                },
                XMSystemAlertAction(title: "取消", role: .cancel) {
                    shouldReturnAfterRecoveryDismiss = true
                    coordinator.clearRecoveryConflictBeforeReturn()
                    Task { @MainActor in
                        await Task.yield()
                        performPendingRecoveryReturn()
                    }
                }
            ]
        )
    }

    private func recoveryTitle(for session: ReadingTimerSession) -> String {
        session.status == .stoppedPendingSave ? "有阅读计时待保存" : "已有阅读计时进行中"
    }

    private func recoveryMessage(for session: ReadingTimerSession) -> String {
        let elapsed = recoveryElapsedSeconds(for: session, at: Date())
        return "《\(session.book.name)》\(recoveryStatusText(for: session))，已记录 \(ReadDurationFormatter.format(seconds: elapsed))。请先处理这段计时。"
    }

    private func recoveryStatusText(for session: ReadingTimerSession) -> String {
        switch session.status {
        case .running:
            return "正在计时"
        case .paused:
            return "已暂停"
        case .stoppedPendingSave:
            return "待保存"
        case .finished:
            return "已结束"
        }
    }

    private func recoveryElapsedSeconds(for session: ReadingTimerSession, at date: Date) -> Int64 {
        guard session.status == .running else {
            return session.elapsedSeconds
        }
        let anchor = session.interruptTime ?? session.updatedDate ?? session.startTime ?? date
        let delta = max(0, Int64(date.timeIntervalSince(anchor)))
        return session.elapsedSeconds + delta
    }

    private var countdownCompletionDescriptor: XMSystemAlertDescriptor? {
        guard coordinator.isStoppedPendingSave else { return nil }
        return XMSystemAlertDescriptor(
            title: "计时结束",
            message: "本次阅读倒计时已完成，可以保存这段阅读记录。",
            actions: [
                XMSystemAlertAction(title: "保存记录") {
                    coordinator.shouldPresentCountdownCompletionAlert = false
                    coordinator.shouldPresentFinishSheet = true
                }
            ]
        )
    }

    private func handleRecoveryPromptDismiss() {
        performPendingRecoveryReturn()
    }

    private func performPendingRecoveryReturn() {
        guard shouldReturnAfterRecoveryDismiss else { return }
        shouldReturnAfterRecoveryDismiss = false
        onRequestDismiss(.conflict)
    }

    /// 按当前状态分派开始、暂停、继续或保存；Task 继承 MainActor，由 Coordinator 串行处理并忽略失效状态。
    private func handleMainAction(_ coordinator: ReadingTimerCoordinator) {
        Task { @MainActor in
            if coordinator.canStart {
                switch timerSettings.preference {
                case .askEveryTime:
                    shouldPresentStartSheet = true
                case .countUp:
                    await coordinator.start(bookId: bookId, countdownSeconds: 0)
                case .countdown(let seconds):
                    await coordinator.start(bookId: bookId, countdownSeconds: seconds)
                }
            } else if coordinator.canPause {
                await coordinator.pause()
            } else if coordinator.canResume {
                await coordinator.resume()
            } else if coordinator.isStoppedPendingSave {
                coordinator.shouldPresentFinishSheet = true
            }
        }
    }

    /// 在 MainActor 发起保存，只有 Coordinator 确认进入 finished 后才请求宿主关闭，失败时保留当前 Sheet 重试。
    private func saveFinishDraft(_ draft: ReadingTimerFinishDraft, using coordinator: ReadingTimerCoordinator) {
        Task { @MainActor in
            await coordinator.saveFinishedRecord(
                targetBookId: draft.targetBookId,
                startAt: draft.startAt,
                endAt: draft.endAt,
                didEditTimeRange: draft.didEditTimeRange,
                position: draft.position,
                insight: draft.insight,
                markReadDone: draft.markReadDone
            )
            guard coordinator.status == .finished else { return }
            pendingFinishDismissReason = .completed
            coordinator.shouldPresentFinishSheet = false
        }
    }

    /// 等待结束确认 Sheet 完全退场后再关闭外层页面，避免嵌套模态与系统 Zoom 竞争。
    private func completePendingFinishDismissal() {
        guard let reason = pendingFinishDismissReason else { return }
        pendingFinishDismissReason = nil
        onRequestDismiss(reason)
    }
}

/// 在深链记录与兜底书籍均不可用时提供可感知反馈，并保留顶部收起出口。
private struct ReadingTimerUnavailableState: View {
    let message: String

    var body: some View {
        VStack(spacing: Spacing.base) {
            Image(systemName: "clock.badge.exclamationmark")
                .font(.title)
                .foregroundStyle(Color.textSecondary)
                .accessibilityHidden(true)

            Text("无法打开阅读计时")
                .font(AppTypography.title3Semibold)
                .foregroundStyle(Color.textPrimary)

            Text(message)
                .font(AppTypography.body)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, Spacing.screenEdge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// ReadingTimerContent 负责主计时页面的视觉编排，隔离外层导航、弹窗和生命周期处理。
private struct ReadingTimerContent: View {
    @Bindable var coordinator: ReadingTimerCoordinator
    let onMainAction: () -> Void
    let onStop: () -> Void
    let onAddNote: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var book: ReadingTimerBookContext? {
        coordinator.bookContext
    }

    var body: some View {
        GeometryReader { proxy in
            let bottomSafeArea = proxy.safeAreaInsets.bottom
            let coverSize = ReadingTimerLayout.coverSize(
                availableWidth: proxy.size.width,
                availableHeight: proxy.size.height
            )

            ZStack(alignment: .top) {
                ReadingTimerMinimalBackground(
                    book: book,
                    status: coordinator.status,
                    reduceMotion: reduceMotion
                )

                ViewThatFits(in: .vertical) {
                    contentStack(coverSize: coverSize)
                        .padding(.top, ReadingTimerLayout.contentTopPadding)
                        .padding(.bottom, ReadingTimerLayout.contentBottomPadding(bottomSafeArea: bottomSafeArea))
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .center)

                    ScrollView {
                        contentStack(coverSize: ReadingTimerLayout.compactCoverSize(from: coverSize))
                            .padding(.top, Spacing.section)
                            .padding(.bottom, ReadingTimerLayout.contentBottomPadding(bottomSafeArea: bottomSafeArea))
                            .frame(maxWidth: .infinity)
                    }
                    .scrollIndicators(.hidden)
                    .scrollBounceBehavior(.basedOnSize)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                errorBanner
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: coordinator.status)
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: coordinator.isWriting)
    }

    private func contentStack(coverSize: CGSize) -> some View {
        VStack(spacing: ReadingTimerLayout.stageControlSpacing) {
            ReadingTimerMinimalStage(
                book: book,
                coverSize: coverSize,
                displayTitle: coordinator.timerDisplayTitle,
                displaySeconds: coordinator.displaySeconds,
                secondaryTimerText: coordinator.secondaryTimerText,
                reduceMotion: reduceMotion
            )
            .padding(.horizontal, Spacing.screenEdge)

            ReadingTimerGlassControlDock(
                mainActionTitle: mainActionTitle,
                mainActionIcon: mainActionIcon,
                isMainActionEnabled: mainActionEnabled && !coordinator.isWriting,
                isWriting: coordinator.isWriting,
                canStop: coordinator.canStop && !coordinator.isWriting,
                isPendingSave: coordinator.isStoppedPendingSave,
                onMainAction: onMainAction,
                onStop: onStop,
                onAddNote: onAddNote
            )
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let errorMessage = coordinator.errorMessage {
            VStack {
                ReadingDashboardInlineBanner(
                    message: errorMessage,
                    actionTitle: "关闭",
                    onAction: { coordinator.errorMessage = nil }
                )
                .padding(.horizontal, Spacing.screenEdge)
                .padding(.top, Spacing.base)
                .transition(.opacity.combined(with: .move(edge: .top)))

                Spacer(minLength: Spacing.none)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var mainActionTitle: String {
        if coordinator.isWriting { return "处理中" }
        if coordinator.isStoppedPendingSave { return "保存记录" }
        if coordinator.canStart { return "开始" }
        if coordinator.canPause { return "暂停" }
        if coordinator.canResume { return "继续" }
        return "开始"
    }

    private var mainActionIcon: String {
        if coordinator.isWriting { return "hourglass" }
        if coordinator.canPause { return "pause.fill" }
        if coordinator.isStoppedPendingSave { return "checkmark" }
        return "play.fill"
    }

    private var mainActionEnabled: Bool {
        coordinator.canStart || coordinator.canPause || coordinator.canResume || coordinator.isStoppedPendingSave
    }
}

/// 集中管理极简计时页的封面、书名与玻璃控制区几何。
private enum ReadingTimerLayout {
    static let controlHorizontalPadding: CGFloat = Spacing.screenEdge
    static let controlSpacing: CGFloat = Spacing.double
    static let primaryControlSize: CGFloat = 56
    static let secondaryControlSize: CGFloat = 52
    static let contentTopPadding: CGFloat = Spacing.double
    static let stageControlSpacing: CGFloat = Spacing.double
    static let coverMetadataSpacing: CGFloat = Spacing.base
    static let metadataTimerSpacing: CGFloat = Spacing.double
    static let titleSpacing: CGFloat = Spacing.half
    static let compactCoverWidthRatio: CGFloat = 0.90
    static let coverCornerRadii = RectangleCornerRadii(
        topLeading: CornerRadius.inlayHairline,
        bottomLeading: CornerRadius.inlayHairline,
        bottomTrailing: CornerRadius.blockLarge,
        topTrailing: CornerRadius.blockLarge
    )
    static func contentBottomPadding(bottomSafeArea: CGFloat) -> CGFloat {
        max(bottomSafeArea, Spacing.base) + Spacing.section * 2
    }

    static func coverSize(availableWidth: CGFloat, availableHeight: CGFloat) -> CGSize {
        let widthBound = max(0, availableWidth - Spacing.screenEdge * 2)
        let referenceWidth = availableWidth * 0.40
        let heightBoundWidth = max(0, availableHeight * 0.25 * XMBookCover.aspectRatio)
        let adaptiveWidth = min(referenceWidth, widthBound, heightBoundWidth)
        let clampedWidth = min(max(adaptiveWidth, 144), 168)
        return XMBookCover.size(width: clampedWidth)
    }

    static func compactCoverSize(from coverSize: CGSize) -> CGSize {
        let compactWidth = min(max(coverSize.width * compactCoverWidthRatio, 132), 150)
        return XMBookCover.size(width: compactWidth)
    }
}

/// 用当前封面延展出低干扰背景，保持沉浸感但不抢前景封面和标题。
private struct ReadingTimerMinimalBackground: View {
    let book: ReadingTimerBookContext?
    let status: ReadingTimerRecordStatus?
    let reduceMotion: Bool

    private var hasCoverArtwork: Bool {
        guard let coverURL = book?.coverURL.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !coverURL.isEmpty
    }

    var body: some View {
        ZStack {
            Color.surfacePage

            if let book, hasCoverArtwork, !reduceMotion {
                XMBookCover.fixedHeight(
                    780,
                    urlString: book.coverURL,
                    cornerRadius: CornerRadius.containerXL,
                    placeholderIconSize: .hidden,
                    priority: .low,
                    surfaceStyle: .spine
                )
                .scaleEffect(2.2)
                .saturation(0.22)
                .blur(radius: 58, opaque: true)
                .opacity(coverOpacity)
                .offset(y: -Spacing.section * 2)
                .allowsHitTesting(false)
            }

            LinearGradient(
                colors: [
                    Color.surfacePage.opacity(0.86),
                    Color.surfaceCard.opacity(status == .running ? 0.58 : 0.64),
                    Color.surfacePage.opacity(0.96)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            LinearGradient(
                colors: [
                    Color.clear,
                    Color.textPrimary.opacity(status == .running ? 0.035 : 0.02)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }

    private var coverOpacity: Double {
        switch status {
        case .running:
            return 0.20
        case .paused, .stoppedPendingSave:
            return 0.14
        case .finished:
            return 0.16
        case nil:
            return 0.12
        }
    }
}

/// 把封面与单行书名作为页面唯一内容焦点，弱化工具属性。
private struct ReadingTimerMinimalStage: View {
    let book: ReadingTimerBookContext?
    let coverSize: CGSize
    let displayTitle: String
    let displaySeconds: Int64
    let secondaryTimerText: String?
    let reduceMotion: Bool

    var body: some View {
        VStack(spacing: ReadingTimerLayout.metadataTimerSpacing) {
            VStack(spacing: ReadingTimerLayout.coverMetadataSpacing) {
                lastReadPositionText
                cover
                bookTitleText
            }

            ReadingTimerElapsedBlock(
                title: displayTitle,
                seconds: displaySeconds,
                secondaryText: secondaryTimerText,
                reduceMotion: reduceMotion
            )
        }
        .frame(maxWidth: .infinity)
        .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.98)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(bookTitle)，\(displayTitle) \(ReadingTimerDisplayFormatter.digital(seconds: displaySeconds))")
    }

    private var cover: some View {
        XMBookCover.fixedSize(
            width: coverSize.width,
            height: coverSize.height,
            urlString: book?.coverURL ?? "",
            cornerRadii: ReadingTimerLayout.coverCornerRadii,
            border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth),
            surfaceStyle: .spine
        )
        .shadow(
            color: Color.bookCoverDropShadow.opacity(reduceMotion ? 0.18 : 0.24),
            radius: reduceMotion ? 8 : 14,
            x: 0,
            y: reduceMotion ? 3 : 8
        )
    }

    private var bookTitleText: some View {
        VStack(spacing: ReadingTimerLayout.titleSpacing) {
            Text(bookTitle)
                .font(AppTypography.bodyMedium)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.82)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            if let authorText {
                Text(authorText)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.86)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private var lastReadPositionText: some View {
        if let text = lastReadPosition {
            Text(text)
                .font(AppTypography.captionMedium)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.86)
                .multilineTextAlignment(.center)
                .transition(.opacity)
        }
    }

    private var authorText: String? {
        guard let author = book?.author.trimmingCharacters(in: .whitespacesAndNewlines),
              !author.isEmpty else {
            return nil
        }
        return author
    }

    private var lastReadPosition: String? {
        guard let book, book.readPosition > 0 else { return nil }
        let positionText = ReadingTimerDisplayFormatter.position(book.readPosition)
        guard let formatted = NotePositionUnitFormatter.footerText(
            position: positionText,
            unit: book.currentPositionUnit
        ) else {
            return nil
        }
        return "上次阅读：\(formatted)"
    }

    private var bookTitle: String {
        guard let title = book?.name.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return "未选择书籍"
        }
        return title
    }
}

/// 独立展示当前阅读时长，让主数据脱离封面并成为页面第一阅读层级。
private struct ReadingTimerElapsedBlock: View {
    let title: String
    let seconds: Int64
    let secondaryText: String?
    let reduceMotion: Bool

    var body: some View {
        VStack(spacing: Spacing.tiny) {
            Text(title)
                .font(AppTypography.captionMedium)
                .foregroundStyle(Color.textSecondary)

            Text(ReadingTimerDisplayFormatter.digital(seconds: seconds))
                .font(AppTypography.brandDisplay(size: 56, relativeTo: .largeTitle))
                .monospacedDigit()
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.58)
                .frame(maxWidth: .infinity)
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: seconds)
                .transaction { transaction in
                    if reduceMotion {
                        transaction.animation = nil
                    }
                }

            if let secondaryText {
                Text(secondaryText)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.86)
                    .transition(.opacity)
                }
            }
        }
}

/// 作为内容流最后一层的轻量控制组，保留主动作、停止与记书摘入口。
private struct ReadingTimerGlassControlDock: View {
    let mainActionTitle: String
    let mainActionIcon: String
    let isMainActionEnabled: Bool
    let isWriting: Bool
    let canStop: Bool
    let isPendingSave: Bool
    let onMainAction: () -> Void
    let onStop: () -> Void
    let onAddNote: () -> Void

    var body: some View {
        glassControls
        .frame(maxWidth: .infinity)
        .padding(.horizontal, ReadingTimerLayout.controlHorizontalPadding)
        .animation(.snappy(duration: 0.18), value: mainActionTitle)
        .animation(.snappy(duration: 0.18), value: isWriting)
        .animation(.smooth(duration: 0.28), value: isPendingSave)
    }

    @ViewBuilder
    private var glassControls: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: ReadingTimerLayout.controlSpacing) {
                controls
            }
        } else {
            controls
        }
    }

    private var controls: some View {
        HStack(alignment: .center, spacing: ReadingTimerLayout.controlSpacing) {
            ReadingTimerGlassIconButton(
                title: "记书摘",
                systemImage: "square.and.pencil",
                isEnabled: !isWriting,
                size: ReadingTimerLayout.secondaryControlSize,
                tint: Color.textSecondary,
                action: onAddNote
            )

            ReadingTimerGlassIconButton(
                title: mainActionTitle,
                systemImage: mainActionIcon,
                isEnabled: isMainActionEnabled,
                isWriting: isWriting,
                size: ReadingTimerLayout.primaryControlSize,
                tint: primaryTint,
                action: onMainAction
            )

            ReadingTimerGlassIconButton(
                title: "停止",
                systemImage: "stop.fill",
                isEnabled: canStop && !isPendingSave,
                size: ReadingTimerLayout.secondaryControlSize,
                tint: Color.textSecondary,
                action: onStop
            )
            .opacity(isPendingSave ? 0 : 1)
            .allowsHitTesting(!isPendingSave)
            .accessibilityHidden(isPendingSave)
        }
        .frame(maxWidth: .infinity)
    }

    private var primaryTint: Color {
        Color.textPrimary
    }
}

/// 圆形玻璃图标按钮，控制视觉重量但保留不小于 44pt 的触控热区。
private struct ReadingTimerGlassIconButton: View {
    let title: String
    let systemImage: String
    let isEnabled: Bool
    var isWriting = false
    let size: CGFloat
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if isWriting {
                    LoadingStateView(style: .inline)
                        .controlSize(.small)
                        .tint(tint)
                } else {
                    Image(systemName: systemImage)
                        .font(AppTypography.headlineSemibold)
                }
            }
            .foregroundStyle(isEnabled ? tint : Color.textHint)
            .frame(width: size, height: size)
            .contentShape(Circle())
            .glassControlBackground(isEnabled: isEnabled, tint: tint, shape: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(title)
    }
}

private extension View {
    /// 为计时控制按钮附加 iOS 26 玻璃效果，并在不可用系统上降级为系统材质。
    @ViewBuilder
    func glassControlBackground<S: Shape>(isEnabled: Bool, tint: Color, shape: S) -> some View {
        if #available(iOS 26.0, *) {
            if isEnabled {
                self.glassEffect(.regular.interactive(), in: shape)
            } else {
                self
                    .opacity(0.58)
                    .glassEffect(.regular, in: shape)
            }
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .overlay {
                    shape
                        .stroke(
                            tint.opacity(isEnabled ? 0.26 : 0.12),
                            lineWidth: CardStyle.borderWidth
                        )
                }
        }
    }
}

private enum ReadingTimerDisplayFormatter {
    static func digital(seconds: Int64) -> String {
        let clamped = max(0, seconds)
        let hours = clamped / 3600
        let minutes = (clamped % 3600) / 60
        let secs = clamped % 60
        return String(format: "%02lld:%02lld:%02lld", hours, minutes, secs)
    }

    static func position(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int64(value))
        }
        return String(format: "%.1f", value)
    }
}
