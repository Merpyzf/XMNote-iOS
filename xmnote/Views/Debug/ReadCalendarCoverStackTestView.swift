#if DEBUG
import SwiftUI

/**
 * [INPUT]: 依赖 ReadCalendarCoverStackTestViewModel 提供场景与可编辑参数，依赖 ReadCalendarCoverFanStack / ReadCalendarMonthGrid 组件渲染预览，依赖 RepositoryContainer 提供 Book 表封面数据
 * [OUTPUT]: 对外提供 ReadCalendarCoverStackTestView（阅读日历封面堆叠测试页）
 * [POS]: Debug 测试页，集中验证封面扇形堆叠在组件级与网格级的视觉表现
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

struct ReadCalendarCoverStackTestView: View {
    @State private var viewModel = ReadCalendarCoverStackTestViewModel()

    var body: some View {
        ReadCalendarCoverStackTestContentView(viewModel: viewModel)
    }
}

private struct ReadCalendarCoverStackTestContentView: View {
    @Bindable var viewModel: ReadCalendarCoverStackTestViewModel
    @State private var isConfigSheetPresented = false
    @State private var fullscreenPayload: ReadCalendarCoverStackFullscreenPayload?
    @State private var sharedTransitionPhase: ReadCalendarCoverSharedTransitionPhase = .idle
    @Environment(RepositoryContainer.self) private var repositories
    @Namespace private var coverTransitionNamespace

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.double) {
                componentPreviewSection
                gridPreviewSection
                metricsSection
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
            .safeAreaPadding(.bottom)
        }
        .background(Color.windowBackground)
        .navigationTitle("封面堆叠测试")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isConfigSheetPresented = true
                } label: {
                    Label("配置", systemImage: "slider.horizontal.3")
                        .labelStyle(.titleAndIcon)
                }
                .accessibilityLabel("打开封面堆叠配置")
            }
        }
        .sheet(isPresented: $isConfigSheetPresented) {
            ReadCalendarCoverStackConfigSheet(viewModel: viewModel)
                .presentationDetents([.fraction(0.55), .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.regularMaterial)
                .presentationBackgroundInteraction(.enabled)
                .presentationContentInteraction(.scrolls)
        }
        .onChange(of: clampedInput) { _, _ in
            viewModel.clampEditableValues()
        }
        .task {
            await viewModel.loadBookCoversIfNeeded(using: repositories.bookRepository)
        }
        .overlay {
            if let fullscreenPayload {
                ReadCalendarCoverStackTestFullscreenOverlay(
                    payload: fullscreenPayload,
                    coverTransitionNamespace: coverTransitionNamespace,
                    isSharedTransitionActive: isSharedTransitionActive,
                    style: viewModel.fanStyle,
                    isAnimated: viewModel.isAnimated,
                    onClose: closeFullscreenOverlay
                )
                .zIndex(30)
                .transition(.opacity)
            }
        }
    }

    private var clampedInput: ClampInput {
        ClampInput(
            targetDayIndex: viewModel.targetDayIndex,
            bookCount: viewModel.bookCount,
            maxVisibleCount: viewModel.maxVisibleCount,
            collapsedVisibleCount: viewModel.collapsedVisibleCount,
            coverWidth: viewModel.coverWidth,
            coverHeight: viewModel.coverHeight,
            secondaryRotation: viewModel.secondaryRotation,
            tertiaryRotation: viewModel.tertiaryRotation,
            secondaryOffsetXRatio: viewModel.secondaryOffsetXRatio,
            tertiaryOffsetXRatio: viewModel.tertiaryOffsetXRatio,
            secondaryOffsetYRatio: viewModel.secondaryOffsetYRatio,
            tertiaryOffsetYRatio: viewModel.tertiaryOffsetYRatio,
            shadowOpacity: viewModel.shadowOpacity,
            shadowRadius: viewModel.shadowRadius,
            shadowX: viewModel.shadowX,
            shadowY: viewModel.shadowY
        )
    }

    var isSharedTransitionActive: Bool {
        switch sharedTransitionPhase {
        case .opening, .closing:
            return true
        case .idle, .opened:
            return false
        }
    }
}

private struct ClampInput: Equatable {
    let targetDayIndex: Int
    let bookCount: Int
    let maxVisibleCount: Int
    let collapsedVisibleCount: Int
    let coverWidth: CGFloat
    let coverHeight: CGFloat
    let secondaryRotation: Double
    let tertiaryRotation: Double
    let secondaryOffsetXRatio: CGFloat
    let tertiaryOffsetXRatio: CGFloat
    let secondaryOffsetYRatio: CGFloat
    let tertiaryOffsetYRatio: CGFloat
    let shadowOpacity: CGFloat
    let shadowRadius: CGFloat
    let shadowX: CGFloat
    let shadowY: CGFloat
}

private extension ReadCalendarCoverStackTestContentView {
    var componentPreviewSection: some View {
        let enlargedSize = CGSize(
            width: max(42, viewModel.coverSize.width * 3),
            height: max(60, viewModel.coverSize.height * 3)
        )
        let panelHeight = max(260, enlargedSize.height + 92)

        return VStack(alignment: .leading, spacing: Spacing.half) {
            HStack {
                Text("顶部封面预览")
                    .font(.headline)
                    .foregroundStyle(Color.textPrimary)
                Spacer(minLength: 0)
                Text(viewModel.selectedScenario.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.brand)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.brand.opacity(0.14), in: Capsule())
            }

            ZStack {
                RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                    .fill(Color.contentBackground)
                    .overlay {
                        RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                            .stroke(Color.surfaceBorderStrong, lineWidth: CardStyle.borderWidth)
                    }

                ReadCalendarCoverFanStack(
                    items: viewModel.componentItems,
                    maxVisibleCount: viewModel.maxVisibleCount,
                    coverSize: enlargedSize,
                    isAnimated: viewModel.isAnimated,
                    style: viewModel.fanStyle
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(.horizontal, Spacing.double)
            }
            .frame(height: panelHeight)

            if viewModel.componentOverflowCount > 0 {
                Text("组件溢出：+\(viewModel.componentOverflowCount)")
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
            }

            Text("参数配置请通过右上角“配置”面板调整（非模态 Sheet）。")
                .font(.caption2)
                .foregroundStyle(Color.textHint)
        }
    }

    var gridPreviewSection: some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            Text("网格级预览")
                .font(.headline)
                .foregroundStyle(Color.textPrimary)

            // 不做 clip，确保可观察封面跨格溢出效果。
            ZStack {
                RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                    .fill(Color.contentBackground)
                    .overlay {
                        RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                            .stroke(Color.surfaceBorderStrong, lineWidth: CardStyle.borderWidth)
                    }

                ReadCalendarMonthGrid(
                    weeks: viewModel.previewWeeks,
                    laneLimit: 4,
                    displayMode: .bookCover,
                    selectedDate: viewModel.selectedDate,
                    isHapticsEnabled: false,
                    dayPayloadProvider: { date in
                        viewModel.payload(for: date)
                    },
                    coverItemsProvider: { date in
                        viewModel.coverItems(for: date)
                    },
                    bookCoverStyleProvider: { _ in
                        viewModel.fanStyle
                    },
                    coverTransitionNamespace: coverTransitionNamespace,
                    activeCoverTransitionDate: fullscreenPayload?.date,
                    coverTransitionIDProvider: { date in
                        coverTransitionID(for: date)
                    },
                    onOpenBookCoverFullscreen: { date in
                        openFullscreenOverlay(for: date)
                    },
                    onSelectDay: { date in
                        withAnimation(.smooth(duration: 0.2)) {
                            viewModel.selectDay(date)
                        }
                    }
                )
                .padding(.horizontal, Spacing.base)
                .padding(.vertical, Spacing.base)
            }
            .frame(minHeight: 96)

            Text("点击出现 +N 的日期可验证“全屏展开全部封面”效果。")
                .font(.caption2)
                .foregroundStyle(Color.textHint)
        }
    }

    var metricsSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.half) {
                Text("参数回显")
                    .font(.headline)
                    .foregroundStyle(Color.textPrimary)

                infoRow("场景", value: viewModel.selectedScenario.title)
                infoRow("书籍数", value: "\(viewModel.bookCount)")
                infoRow("封面来源", value: viewModel.coverDataSourceTitle)
                infoRow("组件上限", value: "\(viewModel.maxVisibleCount)")
                infoRow("折叠上限", value: "\(viewModel.collapsedVisibleCount)")
                infoRow("最终可见", value: "\(viewModel.componentVisibleLimit)")
                infoRow(
                    "基准尺寸",
                    value: "\(Int(viewModel.coverSize.width)) × \(Int(viewModel.coverSize.height))"
                )
                infoRow("角度", value: "\(Int(viewModel.secondaryRotation))° / \(Int(viewModel.tertiaryRotation))°")
                infoRow(
                    "位移比例",
                    value: String(
                        format: "%.2f, %.2f / %.2f, %.2f",
                        Double(viewModel.secondaryOffsetXRatio),
                        Double(viewModel.secondaryOffsetYRatio),
                        Double(viewModel.tertiaryOffsetXRatio),
                        Double(viewModel.tertiaryOffsetYRatio)
                    )
                )

                if let error = viewModel.bookCoverLoadError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(Color.feedbackWarning)
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    func infoRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundStyle(Color.textSecondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(Color.textPrimary)
            Spacer(minLength: 0)
        }
    }

    func openFullscreenOverlay(for date: Date) {
        let items = viewModel.coverItems(for: date)
        guard !items.isEmpty else { return }
        let normalized = Calendar.current.startOfDay(for: date)
        sharedTransitionPhase = .opening
        withAnimation(
            .spring(response: 0.46, dampingFraction: 0.86),
            completionCriteria: .logicallyComplete
        ) {
            fullscreenPayload = ReadCalendarCoverStackFullscreenPayload(
                date: normalized,
                items: items,
                transitionID: coverTransitionID(for: normalized)
            )
        } completion: {
            sharedTransitionPhase = fullscreenPayload == nil ? .idle : .opened
        }
    }

    func closeFullscreenOverlay() {
        guard fullscreenPayload != nil else {
            sharedTransitionPhase = .idle
            return
        }
        sharedTransitionPhase = .closing
        withAnimation(
            .spring(response: 0.34, dampingFraction: 0.9),
            completionCriteria: .logicallyComplete
        ) {
            fullscreenPayload = nil
        } completion: {
            sharedTransitionPhase = .idle
        }
    }

    func coverTransitionID(for date: Date) -> String {
        let normalized = Calendar.current.startOfDay(for: date)
        let dayStamp = Int(normalized.timeIntervalSince1970 / 86_400)
        return "cover-fullscreen-\(dayStamp)"
    }
}

private struct ReadCalendarCoverStackConfigSheet: View {
    @Bindable var viewModel: ReadCalendarCoverStackTestViewModel
    @Environment(RepositoryContainer.self) private var repositories

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.double) {
                scenarioSection
                dataControlSection
                styleControlSection
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.top, Spacing.base)
            .padding(.bottom, Spacing.base)
        }
    }
}

private extension ReadCalendarCoverStackConfigSheet {
    var scenarioSection: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            Text("预置场景")
                .font(.headline)
                .foregroundStyle(Color.textPrimary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.half) {
                    ForEach(ReadCalendarCoverStackTestViewModel.Scenario.allCases) { scenario in
                        Button(scenario.title) {
                            withAnimation(.snappy(duration: 0.22)) {
                                viewModel.selectScenario(scenario)
                            }
                        }
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            viewModel.selectedScenario == scenario
                            ? Color.brand : Color.bgSecondary
                        )
                        .foregroundStyle(
                            viewModel.selectedScenario == scenario
                            ? Color.white : Color.textPrimary
                        )
                        .clipShape(Capsule())
                    }
                }
            }
        }
    }

    var dataControlSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("数据控制")
                    .font(.headline)
                    .foregroundStyle(Color.textPrimary)

                HStack(spacing: Spacing.half) {
                    Button("刷新 Book 表封面") {
                        Task {
                            await viewModel.reloadBookCovers(using: repositories.bookRepository)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isLoadingBookCovers)

                    if viewModel.isLoadingBookCovers {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                Text("当前来源：\(viewModel.coverDataSourceTitle)")
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)

                Stepper(value: $viewModel.bookCount, in: 0...12) {
                    Text("书籍数量：\(viewModel.bookCount)")
                        .font(.subheadline)
                        .foregroundStyle(Color.textPrimary)
                }

                Stepper(value: $viewModel.maxVisibleCount, in: 1...12) {
                    Text("组件可见上限：\(viewModel.maxVisibleCount)")
                        .font(.subheadline)
                        .foregroundStyle(Color.textPrimary)
                }

                Stepper(value: $viewModel.collapsedVisibleCount, in: 1...12) {
                    Text("业务折叠上限：\(viewModel.collapsedVisibleCount)")
                        .font(.subheadline)
                        .foregroundStyle(Color.textPrimary)
                }

                Stepper(value: $viewModel.targetDayIndex, in: 0...6) {
                    Text("网格目标列：\(viewModel.targetDayIndex + 1)")
                        .font(.subheadline)
                        .foregroundStyle(Color.textPrimary)
                }

                Toggle("启用动画", isOn: $viewModel.isAnimated)
                    .font(.subheadline)

                HStack(spacing: Spacing.half) {
                    Button("重置场景值") {
                        withAnimation(.snappy(duration: 0.22)) {
                            viewModel.resetScenarioValues()
                        }
                    }
                    .buttonStyle(.bordered)

                    Button("重置样式值") {
                        withAnimation(.snappy(duration: 0.22)) {
                            viewModel.resetStyleValues()
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    var styleControlSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("样式参数")
                    .font(.headline)
                    .foregroundStyle(Color.textPrimary)

                sliderRow(
                    title: "封面宽",
                    value: $viewModel.coverWidth,
                    range: 16...96,
                    formatter: { "\(Int($0))" }
                )
                sliderRow(
                    title: "封面高",
                    value: $viewModel.coverHeight,
                    range: 24...140,
                    formatter: { "\(Int($0))" }
                )
                sliderRow(
                    title: "第二层角度",
                    value: $viewModel.secondaryRotation,
                    range: -35...0,
                    formatter: { "\(Int($0))°" }
                )
                sliderRow(
                    title: "第三层角度",
                    value: $viewModel.tertiaryRotation,
                    range: -35...0,
                    formatter: { "\(Int($0))°" }
                )
                sliderRow(
                    title: "第二层 X 比例",
                    value: $viewModel.secondaryOffsetXRatio,
                    range: -0.8...0.4,
                    formatter: { String(format: "%.2f", Double($0)) }
                )
                sliderRow(
                    title: "第三层 X 比例",
                    value: $viewModel.tertiaryOffsetXRatio,
                    range: -0.8...0.4,
                    formatter: { String(format: "%.2f", Double($0)) }
                )
                sliderRow(
                    title: "第二层 Y 比例",
                    value: $viewModel.secondaryOffsetYRatio,
                    range: -0.8...0.4,
                    formatter: { String(format: "%.2f", Double($0)) }
                )
                sliderRow(
                    title: "第三层 Y 比例",
                    value: $viewModel.tertiaryOffsetYRatio,
                    range: -0.8...0.4,
                    formatter: { String(format: "%.2f", Double($0)) }
                )
                sliderRow(
                    title: "阴影透明度",
                    value: $viewModel.shadowOpacity,
                    range: 0...0.45,
                    formatter: { String(format: "%.2f", Double($0)) }
                )
                sliderRow(
                    title: "阴影半径",
                    value: $viewModel.shadowRadius,
                    range: 0...10,
                    formatter: { String(format: "%.1f", Double($0)) }
                )
                sliderRow(
                    title: "阴影 X",
                    value: $viewModel.shadowX,
                    range: -4...8,
                    formatter: { String(format: "%.1f", Double($0)) }
                )
                sliderRow(
                    title: "阴影 Y",
                    value: $viewModel.shadowY,
                    range: -4...8,
                    formatter: { String(format: "%.1f", Double($0)) }
                )
            }
            .padding(Spacing.contentEdge)
        }
    }

    func sliderRow(
        title: String,
        value: Binding<CGFloat>,
        range: ClosedRange<CGFloat>,
        formatter: @escaping (CGFloat) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
                Spacer()
                Text(formatter(value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.textPrimary)
            }
            Slider(value: value, in: range)
                .tint(Color.brand)
        }
    }

    func sliderRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        formatter: @escaping (Double) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
                Spacer()
                Text(formatter(value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.textPrimary)
            }
            Slider(value: value, in: range)
                .tint(Color.brand)
        }
    }
}

private struct ReadCalendarCoverStackFullscreenPayload: Identifiable, Hashable {
    let date: Date
    let items: [ReadCalendarCoverFanStack.Item]
    let transitionID: String

    var id: Date { date }
}

private enum ReadCalendarCoverSharedTransitionPhase: Hashable {
    case idle
    case opening
    case opened
    case closing
}

private enum ReadCalendarCoverLayoutPhase: Hashable {
    case stacked
    case grid
}

private enum ReadCalendarCoverTransitionSource {
    case automatic
    case manual
}

private enum ReadCalendarCoverOverlayRevealPhase {
    case sourceAligned
    case settled
}

private struct ReadCalendarCoverStackTestFullscreenOverlay: View {
    private enum Layout {
        static let backdropMaxOpacity: CGFloat = 0.24
        static let backdropMaterialOpacity: CGFloat = 0.34
        static let closeButtonSize: CGFloat = 24
        static let panelCornerRadius: CGFloat = CornerRadius.containerLarge
        static let dismissDragThreshold: CGFloat = 108
        static let autoGridDelayNanoseconds: UInt64 = 920_000_000
        static let toggleButtonHorizontalPadding: CGFloat = 16
        static let toggleButtonVerticalPadding: CGFloat = 10
        static let toggleButtonBottomInsetExtra: CGFloat = 6
        static let switchAnimationResponse: CGFloat = 0.42
        static let switchAnimationDamping: CGFloat = 0.86
        static let revealDelayNanoseconds: UInt64 = 110_000_000
        static let revealDuration: Double = 0.24
        static let panelShadowBaseOpacity: CGFloat = 0.14
        static let panelShadowExtraOpacity: CGFloat = 0.12
        static let panelShadowBaseRadius: CGFloat = 10
        static let panelShadowExtraRadius: CGFloat = 8
        static let previewLimit = 12
    }

    let payload: ReadCalendarCoverStackFullscreenPayload
    let coverTransitionNamespace: Namespace.ID
    let isSharedTransitionActive: Bool
    let style: ReadCalendarCoverFanStack.Style
    let isAnimated: Bool
    let onClose: () -> Void

    @State private var dragOffsetY: CGFloat = 0
    @State private var layoutPhase: ReadCalendarCoverLayoutPhase = .stacked
    @State private var phaseToken = 0
    @State private var hasAutoTransitioned = false
    @State private var autoGridTask: Task<Void, Never>?
    @State private var revealPhase: ReadCalendarCoverOverlayRevealPhase = .sourceAligned
    @State private var revealTask: Task<Void, Never>?

    var revealProgress: CGFloat {
        revealPhase == .settled ? 1 : 0
    }

    var shouldEnableGridPhase: Bool {
        payload.items.count > Layout.previewLimit
    }

    var body: some View {
        GeometryReader { proxy in
            let coverSize = resolvedCoverSize(in: proxy.size)
            let panelHeight = resolvedPanelHeight(
                in: proxy.size,
                coverSize: coverSize,
                canScrollGrid: shouldEnableGridPhase
            )
            let panelInnerSize = CGSize(
                width: max(0, proxy.size.width - Spacing.screenEdge * 2 - Spacing.double * 2),
                height: max(0, panelHeight - Spacing.base * 2)
            )
            let toggleBottomInset = max(
                Spacing.base,
                proxy.safeAreaInsets.bottom + Layout.toggleButtonBottomInsetExtra
            )
            let seed = ReadCalendarCoverFanStack.makeLayoutSeed(
                date: payload.date,
                items: payload.items,
                mode: .fullscreen
            )
            let panelShape = RoundedRectangle(
                cornerRadius: Layout.panelCornerRadius,
                style: .continuous
            )

            ZStack(alignment: .top) {
                ZStack {
                    Color.black.opacity(Layout.backdropMaxOpacity * revealProgress)
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .opacity(Layout.backdropMaterialOpacity * revealProgress)
                }
                .ignoresSafeArea()
                .onTapGesture {
                    dismiss()
                }

                VStack(spacing: Spacing.base) {
                    header
                        .padding(.horizontal, Spacing.screenEdge)
                        .padding(.top, Spacing.double)
                        .opacity(Double(revealProgress))

                    Spacer(minLength: 0)

                    ZStack {
                        panelShape
                            .fill(Color.contentBackground.opacity(0.78))

                        fullscreenDeckStage(
                            coverSize: coverSize,
                            panelInnerSize: panelInnerSize,
                            seed: seed
                        )
                    }
                    .clipShape(panelShape)
                    .overlay {
                        panelShape
                            .stroke(Color.white.opacity(0.22 + 0.1 * revealProgress), lineWidth: CardStyle.borderWidth)
                    }
                    .frame(height: panelHeight)
                    .padding(.horizontal, Spacing.screenEdge)
                    .shadow(
                        color: Color.black.opacity(
                            Layout.panelShadowBaseOpacity
                            + Layout.panelShadowExtraOpacity * revealProgress
                        ),
                        radius: Layout.panelShadowBaseRadius + Layout.panelShadowExtraRadius * revealProgress,
                        x: 0,
                        y: 8
                    )
                    .opacity(Double(0.72 + 0.28 * revealProgress))

                    Text(phaseHintText)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.white.opacity(0.9))
                        .opacity(Double(revealProgress))

                    if shouldEnableGridPhase {
                        toggleButton
                            .padding(.bottom, toggleBottomInset)
                            .opacity(Double(revealProgress))
                    } else {
                        Spacer(minLength: toggleBottomInset)
                    }
                }
                .offset(y: dragOffsetY)
            }
            .contentShape(Rectangle())
            .gesture(dismissDragGesture)
            .onAppear {
                handleAppear()
            }
            .onDisappear {
                cancelAutoGridTask()
                cancelRevealAnimation()
            }
        }
    }

    var phaseHintText: String {
        if !shouldEnableGridPhase {
            return "当日共 \(payload.items.count) 本"
        }
        switch layoutPhase {
        case .stacked:
            if hasAutoTransitioned {
                return "当日共 \(payload.items.count) 本，已返回堆叠，可继续切换列表"
            }
            return "当日共 \(payload.items.count) 本，约 1 秒后自动切换列表"
        case .grid:
            return "当日共 \(payload.items.count) 本，向上滑动浏览全部"
        }
    }

    var toggleButton: some View {
        let isStacked = layoutPhase == .stacked
        return Button {
            toggleLayoutPhase()
        } label: {
            HStack(spacing: Spacing.half) {
                Image(systemName: isStacked ? "list.bullet.rectangle.portrait.fill" : "square.stack.3d.down.right.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text(isStacked ? "查看列表" : "切回堆叠")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(Color.white.opacity(0.95))
            .padding(.horizontal, Layout.toggleButtonHorizontalPadding)
            .padding(.vertical, Layout.toggleButtonVerticalPadding)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(Color.white.opacity(0.28), lineWidth: CardStyle.borderWidth)
            }
            .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isStacked ? "切换为纵向书籍列表" : "切换为封面堆叠")
    }

    var header: some View {
        HStack(spacing: Spacing.base) {
            Text(formattedDate(payload.date))
                .font(.headline)
                .foregroundStyle(Color.white.opacity(0.95))

            Spacer(minLength: 0)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: Layout.closeButtonSize, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.86))
            }
            .accessibilityLabel("关闭封面展开测试浮层")
        }
    }

    var dismissDragGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard value.translation.height > 0 else { return }
                dragOffsetY = value.translation.height * 0.6
            }
            .onEnded { value in
                if value.translation.height > Layout.dismissDragThreshold {
                    dismiss()
                    return
                }
                withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
                    dragOffsetY = 0
                }
            }
    }

    func resolvedCoverSize(in size: CGSize) -> CGSize {
        let width = max(54, min(92, size.width / 6))
        return CGSize(width: width, height: width * 1.46)
    }

    func resolvedPanelHeight(in size: CGSize, coverSize: CGSize, canScrollGrid: Bool) -> CGFloat {
        let byCover = coverSize.height * (canScrollGrid ? 5.25 : 4.8)
        let byScreen = size.height * (canScrollGrid ? 0.72 : 0.6)
        return min(max(340, byCover), max(380, byScreen))
    }

    @ViewBuilder
    func fullscreenDeckStage(
        coverSize: CGSize,
        panelInnerSize: CGSize,
        seed: ReadCalendarCoverFanStack.LayoutSeed
    ) -> some View {
        let deckContainer = ReadCalendarCoverFullscreenDeckStage(
            items: payload.items,
            style: style,
            coverSize: coverSize,
            containerSize: panelInnerSize,
            phase: layoutPhase == .stacked ? .stacked : .grid,
            phaseToken: phaseToken,
            isAnimated: isAnimated,
            layoutSeed: seed,
            previewLimit: Layout.previewLimit
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Spacing.double)
        .padding(.vertical, Spacing.base)
        if isSharedTransitionActive {
            deckContainer
                .matchedGeometryEffect(
                    id: payload.transitionID,
                    in: coverTransitionNamespace,
                    properties: .frame,
                    anchor: .center,
                    isSource: false
                )
        } else {
            deckContainer
        }
    }

    func handleAppear() {
        layoutPhase = .stacked
        phaseToken += 1
        hasAutoTransitioned = false
        startRevealAnimation()
        scheduleAutoGridTask()
    }

    func scheduleAutoGridTask() {
        cancelAutoGridTask()
        guard shouldEnableGridPhase else { return }
        autoGridTask = Task {
            do {
                try await Task.sleep(nanoseconds: Layout.autoGridDelayNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !hasAutoTransitioned else { return }
                switchPhase(to: .grid, source: .automatic)
            }
        }
    }

    func cancelAutoGridTask() {
        autoGridTask?.cancel()
        autoGridTask = nil
    }

    func toggleLayoutPhase() {
        let target: ReadCalendarCoverLayoutPhase = layoutPhase == .stacked ? .grid : .stacked
        switchPhase(to: target, source: .manual)
    }

    func switchPhase(to target: ReadCalendarCoverLayoutPhase, source: ReadCalendarCoverTransitionSource) {
        guard layoutPhase != target else { return }
        if source == .manual {
            cancelAutoGridTask()
        }
        hasAutoTransitioned = true
        guard isAnimated else {
            layoutPhase = target
            phaseToken += 1
            return
        }
        withAnimation(
            .spring(
                response: Layout.switchAnimationResponse,
                dampingFraction: Layout.switchAnimationDamping
            )
        ) {
            layoutPhase = target
            phaseToken += 1
        }
    }

    func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }

    func dismiss() {
        cancelAutoGridTask()
        cancelRevealAnimation()
        withAnimation(.smooth(duration: 0.2)) {
            dragOffsetY = 0
        }
        onClose()
    }

    func startRevealAnimation() {
        cancelRevealAnimation()
        revealPhase = .sourceAligned
        revealTask = Task {
            do {
                try await Task.sleep(nanoseconds: Layout.revealDelayNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: Layout.revealDuration)) {
                    revealPhase = .settled
                }
            }
        }
    }

    func cancelRevealAnimation() {
        revealTask?.cancel()
        revealTask = nil
    }
}

#Preview {
    NavigationStack {
        ReadCalendarCoverStackTestView()
    }
}
#endif
