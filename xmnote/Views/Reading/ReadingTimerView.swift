import SwiftUI

/**
 * [INPUT]: 依赖 ReadingTimerViewModel 驱动实时计时状态，依赖 ReadingTimerFinishSheet 收集结束确认字段，依赖外层 onReturnFromConflict 回退冲突来源，依赖 XMBookCover/TopBarBackButton/XMSystemAlert 复用系统级组件
 * [OUTPUT]: 对外提供 ReadingTimerView（阅读计时主页面，覆盖开始、暂停、继续、结束、保存与放弃入口）
 * [POS]: Reading 模块阅读计时任务页，由主导航 ReadingRoute.readingSession 与 readingSessionRecord 进入
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 阅读计时主页面，以书籍上下文、封面计时与单一主操作构成核心闭环。
struct ReadingTimerView: View {
    let bookId: Int64
    let recordId: Int64?
    let onReturnFromConflict: (() -> Void)?
    let onAddNote: (Int64) -> Void

    @Environment(RepositoryContainer.self) private var repositories
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel: ReadingTimerViewModel?
    @State private var bootstrapLoadingGate = LoadingGate()
    @State private var shouldPresentStartSheet = false
    @State private var shouldPresentExitConfirmation = false
    @State private var shouldReturnAfterRecoveryDismiss = false

    /// 注入书籍 ID 与记书摘路由回调，避免计时页直接持有外层 NavigationPath。
    init(
        bookId: Int64,
        recordId: Int64? = nil,
        onReturnFromConflict: (() -> Void)? = nil,
        onAddNote: @escaping (Int64) -> Void = { _ in }
    ) {
        self.bookId = bookId
        self.recordId = recordId
        self.onReturnFromConflict = onReturnFromConflict
        self.onAddNote = onAddNote
    }

    var body: some View {
        ZStack {
            Color.surfacePage.ignoresSafeArea()

            if let viewModel {
                ReadingTimerContent(
                    viewModel: viewModel,
                    onMainAction: { handleMainAction(viewModel) },
                    onStop: { Task { await viewModel.stopForSave() } },
                    onAddNote: { onAddNote(bookId) }
                )
            } else if bootstrapLoadingGate.isVisible {
                LoadingStateView("正在准备阅读计时…", style: .card)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                TopBarBackButton {
                    handleBack()
                }
            }
        }
        .navigationPopGuard(
            canPop: !(viewModel?.hasUnfinishedSession ?? false),
            onBlockedAttempt: { shouldPresentExitConfirmation = true }
        )
        .task {
            guard viewModel == nil else { return }
            bootstrapLoadingGate.update(intent: .read)
            let timerViewModel = ReadingTimerViewModel(repository: repositories.readingTimerRepository)
            viewModel = timerViewModel
            bootstrapLoadingGate.update(intent: .none)
            if let recordId {
                await timerViewModel.bootstrap(.record(recordId: recordId, fallbackBookId: bookId))
            } else {
                await timerViewModel.bootstrap(.book(bookId))
            }
        }
        .onChange(of: scenePhase) { _, newValue in
            guard let viewModel else { return }
            switch newValue {
            case .active:
                Task { await viewModel.refreshAfterResume() }
            case .inactive, .background:
                Task { await viewModel.persistBeforeSuspension() }
            @unknown default:
                break
            }
        }
        .onDisappear {
            bootstrapLoadingGate.hideImmediately()
        }
        .sheet(
            isPresented: $shouldPresentStartSheet
        ) {
            if let viewModel {
                ReadingTimerStartSheet { draft in
                    Task {
                        await viewModel.start(countdownSeconds: draft.countdownSeconds)
                    }
                }
            }
        }
        .sheet(
            isPresented: Binding(
                get: { viewModel?.shouldPresentFinishSheet ?? false },
                set: { isPresented in
                    guard let viewModel else { return }
                    viewModel.shouldPresentFinishSheet = isPresented
                }
            )
        ) {
            if let viewModel {
                ReadingTimerFinishSheet(
                    viewModel: viewModel,
                    onSave: { draft in
                        saveFinishDraft(draft, using: viewModel)
                    },
                    onDiscard: {
                        Task {
                            let didDiscard = await viewModel.discardCurrentSession()
                            guard didDiscard else { return }
                            await MainActor.run {
                                dismiss()
                            }
                        }
                    }
                )
            }
        }
        .xmSystemAlert(
            isPresented: Binding(
                get: { viewModel?.shouldPresentRecoveryPrompt ?? false },
                set: { isPresented in
                    guard !isPresented else { return }
                    viewModel?.postponeRecoveryPrompt()
                }
            ),
            descriptor: recoveryDescriptor,
            onDismiss: handleRecoveryPromptDismiss
        )
        .xmSystemAlert(
            isPresented: $shouldPresentExitConfirmation,
            descriptor: exitConfirmationDescriptor
        )
        .xmSystemAlert(
            isPresented: Binding(
                get: { viewModel?.shouldPresentCountdownCompletionAlert ?? false },
                set: { isPresented in
                    guard !isPresented else { return }
                    viewModel?.shouldPresentCountdownCompletionAlert = false
                }
            ),
            descriptor: countdownCompletionDescriptor
        )
    }

    private var recoveryDescriptor: XMSystemAlertDescriptor? {
        guard let viewModel, let session = viewModel.pendingRecoverySession else { return nil }
        return XMSystemAlertDescriptor(
            title: recoveryTitle(for: session),
            message: recoveryMessage(for: session),
            actions: [
                XMSystemAlertAction(title: "继续计时") {
                    viewModel.acceptRecovery()
                },
                XMSystemAlertAction(title: "放弃本次", role: .destructive) {
                    Task {
                        await viewModel.discardCurrentSession()
                    }
                },
                XMSystemAlertAction(title: "返回", role: .cancel) {
                    shouldReturnAfterRecoveryDismiss = true
                    viewModel.clearRecoveryConflictBeforeReturn()
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

    private var exitConfirmationDescriptor: XMSystemAlertDescriptor? {
        guard let viewModel, viewModel.hasUnfinishedSession else { return nil }
        return XMSystemAlertDescriptor(
            title: "本次阅读尚未保存",
            message: "离开前可以保存记录，或放弃这次计时。",
            actions: [
                XMSystemAlertAction(title: "继续阅读", role: .cancel) { },
                XMSystemAlertAction(title: "保存记录") {
                    presentFinishSheet(using: viewModel)
                },
                XMSystemAlertAction(title: "放弃本次", role: .destructive) {
                    Task {
                        let didDiscard = await viewModel.discardCurrentSession()
                        guard didDiscard else { return }
                        await MainActor.run {
                            dismiss()
                        }
                    }
                }
            ]
        )
    }

    private var countdownCompletionDescriptor: XMSystemAlertDescriptor? {
        guard let viewModel, viewModel.isStoppedPendingSave else { return nil }
        return XMSystemAlertDescriptor(
            title: "计时结束",
            message: "本次阅读倒计时已完成，可以保存这段阅读记录。",
            actions: [
                XMSystemAlertAction(title: "保存记录") {
                    viewModel.shouldPresentCountdownCompletionAlert = false
                    viewModel.shouldPresentFinishSheet = true
                }
            ]
        )
    }

    private func handleBack() {
        guard viewModel?.hasUnfinishedSession == true else {
            dismiss()
            return
        }
        shouldPresentExitConfirmation = true
    }

    private func handleRecoveryPromptDismiss() {
        performPendingRecoveryReturn()
    }

    private func performPendingRecoveryReturn() {
        guard shouldReturnAfterRecoveryDismiss else { return }
        shouldReturnAfterRecoveryDismiss = false
        if let onReturnFromConflict {
            onReturnFromConflict()
        } else {
            dismiss()
        }
    }

    private func handleMainAction(_ viewModel: ReadingTimerViewModel) {
        Task {
            if viewModel.canStart {
                shouldPresentStartSheet = true
            } else if viewModel.canPause {
                await viewModel.pause()
            } else if viewModel.canResume {
                await viewModel.resume()
            } else if viewModel.isStoppedPendingSave {
                viewModel.shouldPresentFinishSheet = true
            }
        }
    }

    private func presentFinishSheet(using viewModel: ReadingTimerViewModel) {
        if viewModel.isStoppedPendingSave {
            viewModel.shouldPresentFinishSheet = true
        } else {
            Task { await viewModel.stopForSave() }
        }
    }

    private func saveFinishDraft(_ draft: ReadingTimerFinishDraft, using viewModel: ReadingTimerViewModel) {
        Task {
            await viewModel.saveFinishedRecord(
                position: draft.position,
                insight: draft.insight,
                markReadDone: draft.markReadDone
            )
            guard viewModel.status == .finished else { return }
            dismiss()
        }
    }
}

private extension ReadingTimerViewModel {
    var hasUnfinishedSession: Bool {
        activeSession?.status.isUnfinished == true || pendingRecoverySession != nil
    }
}

/// ReadingTimerContent 负责主计时页面的视觉编排，隔离外层导航、弹窗和生命周期处理。
private struct ReadingTimerContent: View {
    @Bindable var viewModel: ReadingTimerViewModel
    let onMainAction: () -> Void
    let onStop: () -> Void
    let onAddNote: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var book: ReadingTimerBookContext? {
        viewModel.bookContext
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
                    status: viewModel.status,
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
        .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: viewModel.status)
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: viewModel.isWriting)
    }

    private func contentStack(coverSize: CGSize) -> some View {
        VStack(spacing: ReadingTimerLayout.stageControlSpacing) {
            ReadingTimerMinimalStage(
                book: book,
                coverSize: coverSize,
                displayTitle: viewModel.timerDisplayTitle,
                displaySeconds: viewModel.displaySeconds,
                secondaryTimerText: viewModel.secondaryTimerText,
                reduceMotion: reduceMotion
            )
            .padding(.horizontal, Spacing.screenEdge)

            ReadingTimerGlassControlDock(
                mainActionTitle: mainActionTitle,
                mainActionIcon: mainActionIcon,
                isMainActionEnabled: mainActionEnabled && !viewModel.isWriting,
                isWriting: viewModel.isWriting,
                canStop: viewModel.canStop && !viewModel.isWriting,
                isPendingSave: viewModel.isStoppedPendingSave,
                onMainAction: onMainAction,
                onStop: onStop,
                onAddNote: onAddNote
            )
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let errorMessage = viewModel.errorMessage {
            VStack {
                ReadingDashboardInlineBanner(
                    message: errorMessage,
                    actionTitle: "关闭",
                    onAction: { viewModel.errorMessage = nil }
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
        if viewModel.isWriting { return "处理中" }
        if viewModel.isStoppedPendingSave { return "保存记录" }
        if viewModel.canStart { return "开始" }
        if viewModel.canPause { return "暂停" }
        if viewModel.canResume { return "继续" }
        return "开始"
    }

    private var mainActionIcon: String {
        if viewModel.isWriting { return "hourglass" }
        if viewModel.canPause { return "pause.fill" }
        if viewModel.isStoppedPendingSave { return "checkmark" }
        return "play.fill"
    }

    private var mainActionEnabled: Bool {
        viewModel.canStart || viewModel.canPause || viewModel.canResume || viewModel.isStoppedPendingSave
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
