#if DEBUG
/**
 * [INPUT]: 依赖 NoteReviewCardStackTestViewModel 提供调试数据、参数与刷新模式，依赖 NoteReviewCardStack 渲染 UIKit 源码卡堆桥接效果
 * [OUTPUT]: 对外提供 NoteReviewCardStackTestView（书摘回顾卡堆测试页）
 * [POS]: Debug 测试页，集中验证书摘回顾卡堆的滑动手感、程序化控制、长内容滚动仲裁与边界状态
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

struct NoteReviewCardStackTestView: View {
    @State private var viewModel = NoteReviewCardStackTestViewModel()
    @State private var controller = NoteReviewCardStackController()

    var body: some View {
        NoteReviewCardStackTestContentView(viewModel: viewModel, controller: controller)
    }
}

private struct NoteReviewCardStackTestContentView: View {
    @Bindable var viewModel: NoteReviewCardStackTestViewModel
    @Bindable var controller: NoteReviewCardStackController
    @State private var isConfigPresented = false

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.section) {
                scenarioSection
                stackSection
                controlSection
                stateSection
                logSection
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
            .safeAreaPadding(.bottom)
        }
        .background(Color.surfacePage)
        .navigationTitle("书摘卡堆测试")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isConfigPresented = true
                } label: {
                    Label("配置", systemImage: "slider.horizontal.3")
                }
                .accessibilityLabel("打开书摘卡堆配置")
            }
        }
        .sheet(isPresented: $isConfigPresented) {
            NoteReviewCardStackConfigSheet(viewModel: viewModel)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.regularMaterial)
        }
    }

    private var scenarioSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("场景")
                    .font(AppTypography.headline)
                    .foregroundStyle(Color.textPrimary)

                Picker("场景", selection: $viewModel.scenario) {
                    ForEach(NoteReviewCardStackTestViewModel.Scenario.allCases) { scenario in
                        Text(scenario.title).tag(scenario)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(controller.isRefreshing)
                .onChange(of: viewModel.scenario) { _, scenario in
                    viewModel.applyScenario(scenario)
                    controller.reload(keepingPosition: false)
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    private var stackSection: some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            HStack {
                Text("卡堆预览")
                    .font(AppTypography.headline)
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                Text("\(viewModel.notes.count) 张")
                    .font(AppTypography.captionMedium)
                    .foregroundStyle(Color.textSecondary)
            }

            NoteReviewCardStack(
                items: viewModel.notes,
                controller: controller,
                configuration: viewModel.configuration,
                onCardAppeared: { note, index in
                    viewModel.appendLog("出现 \(index + 1): \(note.bookTitle)")
                },
                onCardDisappeared: { note, index in
                    viewModel.appendLog("消失 \(index + 1): \(note.bookTitle)")
                },
                onSwipeCompleted: { _, index, direction in
                    viewModel.appendLog("滑出 \(index + 1): \(direction.title)")
                },
                onRewound: { note, index in
                    viewModel.appendLog("撤回 \(index + 1): \(note.bookTitle)")
                },
                onReachEnd: {
                    viewModel.appendLog("到达末尾")
                },
                onNeedsMoreItems: {
                    viewModel.appendLog("触发预加载")
                    viewModel.appendSimulatedPage()
                },
                onTap: { note, index in
                    viewModel.appendLog("点击 \(index + 1): \(note.bookTitle)")
                },
                onLongPress: { note, index in
                    viewModel.appendLog("长按 \(index + 1): \(note.bookTitle)")
                },
                content: { note, _ in
                    NoteReviewCardStackSampleCard(note: note)
                },
                emptyContent: {
                    NoteReviewCardStackEmptyPreview()
                }
            )
            .frame(height: 520)
            .accessibilityLabel("书摘回顾卡堆预览")
        }
    }

    private var controlSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                HStack {
                    Text("控制")
                        .font(AppTypography.headline)
                    Spacer()
                    Picker("方向", selection: $viewModel.selectedSwipeDirection) {
                        ForEach(NoteReviewCardStackDirection.allCases) { direction in
                            Text(direction.title).tag(direction)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 180)
                }

                HStack(spacing: Spacing.base) {
                    Button {
                        controller.rewind()
                    } label: {
                        Label("上一条", systemImage: "chevron.left")
                    }
                    .disabled(viewModel.notes.isEmpty || controller.isAnimating || controller.isRefreshing)

                    Button {
                        controller.swipe(direction: viewModel.selectedSwipeDirection)
                    } label: {
                        Label("下一条", systemImage: "chevron.right")
                    }
                    .disabled(viewModel.notes.isEmpty || controller.isAnimating || controller.isRefreshing)

                    Button {
                        viewModel.logOrderedRefresh()
                        controller.refresh(mode: .ordered)
                    } label: {
                        Label("顺序刷新", systemImage: "arrow.clockwise")
                    }
                    .disabled(viewModel.notes.isEmpty || controller.isAnimating || controller.isRefreshing)

                    Button {
                        viewModel.shuffleNotesForRefresh()
                        controller.refresh(mode: .shuffled)
                    } label: {
                        Label("乱序刷新", systemImage: "shuffle")
                    }
                    .disabled(viewModel.notes.isEmpty || controller.isAnimating || controller.isRefreshing)

                    Button {
                        controller.scrollToFirst()
                    } label: {
                        Label("回首张", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(viewModel.notes.isEmpty || controller.isAnimating || controller.isRefreshing)
                }
                .buttonStyle(.bordered)
                .labelStyle(.iconOnly)
                .accessibilityElement(children: .contain)
            }
            .padding(Spacing.contentEdge)
        }
    }

    private var stateSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.half) {
                Text("状态")
                    .font(AppTypography.headline)
                HStack {
                    statePill("current", controller.currentIndex)
                    statePill("appeared", controller.appearedIndex)
                    statePill("disappeared", controller.disappearedIndex)
                    Text(controller.isRefreshing ? "refreshing" : (controller.isAnimating ? "animating" : "idle"))
                        .font(AppTypography.captionMedium)
                        .foregroundStyle(controller.isRefreshing || controller.isAnimating ? Color.brand : Color.textSecondary)
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    private var logSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.half) {
                Text("事件日志")
                    .font(AppTypography.headline)
                if viewModel.eventLog.isEmpty {
                    Text("暂无事件")
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textHint)
                } else {
                    ForEach(viewModel.eventLog, id: \.self) { message in
                        Text(message)
                            .font(AppTypography.caption)
                            .foregroundStyle(Color.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    private func statePill(_ title: String, _ value: Int?) -> some View {
        Text("\(title): \(value.map { String($0 + 1) } ?? "-")")
            .font(AppTypography.captionMedium)
            .foregroundStyle(Color.textSecondary)
            .padding(.horizontal, Spacing.half)
            .padding(.vertical, Spacing.tiny)
            .background(Color.surfacePage, in: Capsule())
    }
}

private struct NoteReviewCardStackSampleCard: View {
    let note: NoteReviewCardStackSampleNote

    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: CornerRadius.containerLarge, style: .continuous)
                .fill(Color(hex: note.palette.backgroundHex))
                .overlay(alignment: .bottomLeading) {
                    NoteReviewCardStackSampleArtwork(color: Color(hex: note.palette.accentHex))
                        .frame(height: 220)
                        .opacity(0.42)
                        .padding(.horizontal, Spacing.base)
                }

            VStack(spacing: Spacing.base) {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.base) {
                        if !note.content.isEmpty {
                            Text(note.content)
                                .font(NoteExcerptTypography.body)
                                .lineSpacing(NoteExcerptTypography.bodyLineSpacing)
                                .foregroundStyle(Color.textPrimary)
                        }

                        if !note.idea.isEmpty {
                            Text(note.idea)
                                .font(NoteExcerptTypography.idea)
                                .lineSpacing(NoteExcerptTypography.ideaLineSpacing)
                                .foregroundStyle(Color.textSecondary)
                                .padding(Spacing.base)
                                .background(Color.white.opacity(0.22), in: RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous))
                        }

                        if note.kind == .imageOnly {
                            NoteReviewCardStackImageOnlyPlaceholder()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.contentEdge)
                }
                .scrollIndicators(.visible)

                VStack(spacing: Spacing.half) {
                    Text(note.bookTitle)
                        .font(AppTypography.captionMedium)
                        .foregroundStyle(Color.textSecondary)
                    if !note.tags.isEmpty {
                        HStack(spacing: Spacing.tiny) {
                            ForEach(note.tags, id: \.self) { tag in
                                Text(tag)
                                    .font(NoteExcerptTypography.footer)
                                    .foregroundStyle(Color.textPrimary.opacity(0.72))
                                    .padding(.horizontal, Spacing.half)
                                    .padding(.vertical, 3)
                                    .background(Color.white.opacity(0.24), in: Capsule())
                            }
                        }
                    }
                }
                .padding(.horizontal, Spacing.contentEdge)
                .padding(.bottom, Spacing.contentEdge)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.containerLarge, style: .continuous))
        .shadow(color: Color.black.opacity(0.14), radius: 10, x: 0, y: 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(note.bookTitle), \(note.content.isEmpty ? note.idea : note.content)")
    }
}

private struct NoteReviewCardStackImageOnlyPlaceholder: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                .fill(Color.white.opacity(0.22))
            Image(systemName: "photo.on.rectangle.angled")
                .font(AppTypography.largeTitle)
                .foregroundStyle(Color.textSecondary)
        }
        .frame(height: 250)
        .accessibilityLabel("图片占位")
    }
}

private struct NoteReviewCardStackSampleArtwork: View {
    let color: Color

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            UnevenRoundedRectangle(cornerRadii: RectangleCornerRadii(topLeading: 60, bottomLeading: 18, bottomTrailing: 100, topTrailing: 40), style: .continuous)
                .fill(color.opacity(0.42))
                .offset(x: 24, y: -28)
            UnevenRoundedRectangle(cornerRadii: RectangleCornerRadii(topLeading: 30, bottomLeading: 90, bottomTrailing: 20, topTrailing: 50), style: .continuous)
                .fill(color.opacity(0.58))
                .offset(x: -18, y: 18)
        }
    }
}

private struct NoteReviewCardStackEmptyPreview: View {
    var body: some View {
        VStack(spacing: Spacing.base) {
            Image(systemName: "rectangle.stack")
                .font(AppTypography.largeTitle)
                .foregroundStyle(Color.textHint)
            Text("暂无可回顾书摘")
                .font(AppTypography.bodyMedium)
                .foregroundStyle(Color.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.containerLarge, style: .continuous))
    }
}

private struct NoteReviewCardStackConfigSheet: View {
    @Bindable var viewModel: NoteReviewCardStackTestViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section("堆叠") {
                    Stepper("可见张数 \(viewModel.configuration.visibleCount)", value: $viewModel.configuration.visibleCount, in: 1...5)
                    VStack(alignment: .leading) {
                        Text("缩放 \(viewModel.configuration.scaleInterval, format: .number.precision(.fractionLength(2)))")
                        Slider(value: $viewModel.configuration.scaleInterval, in: 0.86...1.0, step: 0.01)
                    }
                    VStack(alignment: .leading) {
                        Text("位移 \(viewModel.configuration.translationInterval, format: .number.precision(.fractionLength(0)))")
                        Slider(value: $viewModel.configuration.translationInterval, in: 0...24, step: 1)
                    }
                }

                Section("手势") {
                    VStack(alignment: .leading) {
                        Text("阈值 \(viewModel.configuration.swipeThreshold, format: .number.precision(.fractionLength(2)))")
                        Slider(value: $viewModel.configuration.swipeThreshold, in: 0.1...0.5, step: 0.01)
                    }
                    VStack(alignment: .leading) {
                        Text("旋转 \(viewModel.configuration.maxRotationDegrees, format: .number.precision(.fractionLength(0))) 度")
                        Slider(value: $viewModel.configuration.maxRotationDegrees, in: 0...22, step: 1)
                    }
                    Toggle("允许滑动", isOn: $viewModel.configuration.isSwipeEnabled)
                    Toggle("允许点击", isOn: $viewModel.configuration.isTapEnabled)
                    Toggle("卡内滚动优先", isOn: $viewModel.configuration.prefersEmbeddedVerticalScroll)
                    Toggle("末尾循环", isOn: $viewModel.configuration.isLoopingEnabled)
                    Toggle("方向 overlay", isOn: $viewModel.configuration.showsDirectionOverlay)
                }

                Section("方向") {
                    ForEach(NoteReviewCardStackDirection.allCases) { direction in
                        Toggle(direction.title, isOn: Binding(
                            get: { viewModel.configuration.allowedDirections.contains(direction) },
                            set: { isOn in
                                if isOn {
                                    viewModel.configuration.allowedDirections.insert(direction)
                                } else {
                                    viewModel.configuration.allowedDirections.remove(direction)
                                }
                            }
                        ))
                    }
                }

                Section {
                    Button("重置为 iOS 手感") {
                        viewModel.resetConfiguration()
                    }
                }
            }
            .font(AppTypography.body)
            .navigationTitle("卡堆配置")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#Preview {
    NavigationStack {
        NoteReviewCardStackTestView()
    }
}
#endif
