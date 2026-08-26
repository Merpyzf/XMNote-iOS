#if DEBUG
/**
 * [INPUT]: 依赖 NoteReviewPagingTestViewModel 提供调试数据、参数与刷新模式，依赖 NoteReviewPagingDeck 渲染 BigUIPaging Core 之上的 XMNote 自定义卡组效果
 * [OUTPUT]: 对外提供 NoteReviewPagingTestView（书摘回顾 XMNote 自定义卡组测试页）
 * [POS]: Debug 测试页，集中验证书摘回顾卡组的左右滑动、刷新、长内容滚动仲裁与边界状态
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

struct NoteReviewPagingTestView: View {
    @State private var viewModel = NoteReviewPagingTestViewModel()

    var body: some View {
        NoteReviewPagingTestContentView(viewModel: viewModel)
    }
}

private struct NoteReviewPagingTestContentView: View {
    @Bindable var viewModel: NoteReviewPagingTestViewModel
    @State private var isConfigPresented = false

    private var deckConfiguration: NoteReviewPagingDeckConfiguration {
        var configuration = viewModel.configuration
        if viewModel.isReduceMotionPreviewEnabled {
            configuration.motionSpec = configuration.motionSpec.applyingReduceMotion(true)
        }
        return configuration
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.section) {
                scenarioSection
                deckSection
                controlSection
                stateSection
                logSection
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
            .safeAreaPadding(.bottom)
        }
        .background(Color.surfacePage)
        .navigationTitle("XMNote 回顾卡组")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isConfigPresented = true
                } label: {
                    Label("配置", systemImage: "slider.horizontal.3")
                }
                .accessibilityLabel("打开回顾卡组配置")
            }
        }
        .sheet(isPresented: $isConfigPresented) {
            NoteReviewPagingConfigSheet(viewModel: viewModel)
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
                    ForEach(NoteReviewPagingTestViewModel.Scenario.allCases) { scenario in
                        Text(scenario.title).tag(scenario)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: viewModel.scenario) { _, scenario in
                    viewModel.applyScenario(scenario)
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    private var deckSection: some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            HStack {
                Text("卡组预览")
                    .font(AppTypography.headline)
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                Text("\(viewModel.notes.count) 张")
                    .font(AppTypography.captionMedium)
                    .foregroundStyle(Color.textSecondary)
            }

            NoteReviewPagingDeck(
                items: viewModel.notes,
                selection: $viewModel.selectedNoteID,
                hasMoreItems: viewModel.hasMoreItems,
                configuration: deckConfiguration,
                onCardAppeared: { note, index in
                    viewModel.appendLog("出现 \(index + 1): \(note.bookTitle)")
                },
                onNeedsMoreItems: {
                    viewModel.appendLog("触发预加载")
                    viewModel.appendSimulatedPage()
                },
                onTap: { note, index in
                    viewModel.appendLog("点击 \(index + 1): \(note.bookTitle)")
                },
                content: { note, _ in
                    NoteReviewPagingSampleCard(note: note)
                },
                emptyContent: {
                    NoteReviewPagingEmptyPreview()
                }
            )
            .frame(height: 520)
            .accessibilityLabel("书摘回顾 XMNote 自定义卡组预览")
        }
    }

    private var controlSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("控制")
                    .font(AppTypography.headline)

                HStack(spacing: Spacing.base) {
                    Button {
                        viewModel.navigate(.previous)
                    } label: {
                        Label("上一条", systemImage: "chevron.left")
                    }
                    .disabled(viewModel.notes.count < 2)

                    Button {
                        viewModel.navigate(.next)
                    } label: {
                        Label("下一条", systemImage: "chevron.right")
                    }
                    .disabled(viewModel.notes.count < 2)

                    Button {
                        viewModel.orderedRefresh()
                    } label: {
                        Label("顺序刷新", systemImage: "arrow.clockwise")
                    }
                    .disabled(viewModel.notes.isEmpty)

                    Button {
                        viewModel.shuffledRefresh()
                    } label: {
                        Label("乱序刷新", systemImage: "shuffle")
                    }
                    .disabled(viewModel.notes.isEmpty)

                    Button {
                        viewModel.selectFirst()
                    } label: {
                        Label("回首张", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(viewModel.notes.isEmpty)
                }
                .buttonStyle(.bordered)
                .labelStyle(.iconOnly)
                .accessibilityElement(children: .contain)

                Toggle("Reduce Motion 预览", isOn: $viewModel.isReduceMotionPreviewEnabled)
                    .font(AppTypography.captionMedium)
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
                    statePill("current", viewModel.currentIndex)
                    Text(viewModel.hasMoreItems ? "hasMore" : "complete")
                        .font(AppTypography.captionMedium)
                        .foregroundStyle(viewModel.hasMoreItems ? Color.appTint : Color.textSecondary)
                    Text(viewModel.stateText)
                        .font(AppTypography.captionMedium)
                        .foregroundStyle(Color.textSecondary)
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

private struct NoteReviewPagingSampleCard: View {
    let note: NoteReviewPagingSampleNote

    @Environment(\.noteReviewPagingCardContentVisibility) private var cardContentVisibility

    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: CornerRadius.containerLarge, style: .continuous)
                .fill(Color.xmHex(note.palette.backgroundHex))
                .overlay(alignment: .bottomLeading) {
                    NoteReviewPagingSampleArtwork(color: Color.xmHex(note.palette.accentHex))
                        .frame(height: 220)
                        .opacity(0.42)
                        .padding(.horizontal, Spacing.base)
                }

            VStack(spacing: Spacing.base) {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.base) {
                        if !note.content.isEmpty {
                            Text(note.content)
                                .font(ReadingContentTypography.body)
                                .lineSpacing(ReadingContentTypography.bodyLineSpacing)
                                .foregroundStyle(Color.textPrimary)
                        }

                        if !note.idea.isEmpty {
                            Text(note.idea)
                                .font(ReadingContentTypography.annotation)
                                .lineSpacing(ReadingContentTypography.annotationLineSpacing)
                                .foregroundStyle(Color.textSecondary)
                                .padding(Spacing.base)
                                .background(Color.white.opacity(0.22), in: RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous))
                        }

                        if note.kind == .imageOnly {
                            NoteReviewPagingImageOnlyPlaceholder()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.contentEdge)
                }
                .scrollIndicators(.visible)
                .opacity(cardContentVisibility.bodyOpacity)

                VStack(spacing: Spacing.half) {
                    Text(note.bookTitle)
                        .font(AppTypography.captionMedium)
                        .foregroundStyle(Color.textSecondary)
                    if !note.tags.isEmpty {
                        HStack(spacing: Spacing.tiny) {
                            ForEach(note.tags, id: \.self) { tag in
                                Text(tag)
                                    .font(ReadingContentTypography.metadata)
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
                .opacity(cardContentVisibility.footerOpacity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.containerLarge, style: .continuous))
        .shadow(color: Color.black.opacity(0.14), radius: 10, x: 0, y: 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(note.bookTitle), \(note.content.isEmpty ? note.idea : note.content)")
    }
}

private struct NoteReviewPagingImageOnlyPlaceholder: View {
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

private struct NoteReviewPagingSampleArtwork: View {
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

private struct NoteReviewPagingEmptyPreview: View {
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

private struct NoteReviewPagingConfigSheet: View {
    @Bindable var viewModel: NoteReviewPagingTestViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section("堆叠") {
                    Stepper("可见张数 \(viewModel.configuration.visibleCount)", value: $viewModel.configuration.visibleCount, in: 1...5)
                    VStack(alignment: .leading) {
                        Text("缩放 \(viewModel.configuration.motionSpec.scaleInterval, format: .number.precision(.fractionLength(2)))")
                        Slider(value: $viewModel.configuration.motionSpec.scaleInterval, in: 0.86...1.0, step: 0.01)
                    }
                    VStack(alignment: .leading) {
                        Text("垂直补位 \(viewModel.configuration.motionSpec.verticalTranslationInterval, format: .number.precision(.fractionLength(0)))")
                        Slider(value: $viewModel.configuration.motionSpec.verticalTranslationInterval, in: 0...24, step: 1)
                    }
                    VStack(alignment: .leading) {
                        Text("水平露出 \(viewModel.configuration.motionSpec.horizontalPeekRatio, format: .number.precision(.fractionLength(3)))")
                        Slider(value: $viewModel.configuration.motionSpec.horizontalPeekRatio, in: 0...0.16, step: 0.005)
                    }
                    VStack(alignment: .leading) {
                        Text("甩出倍率 \(viewModel.configuration.motionSpec.swingOutMultiplier, format: .number.precision(.fractionLength(0)))")
                        Slider(value: $viewModel.configuration.motionSpec.swingOutMultiplier, in: 0...24, step: 1)
                    }
                    VStack(alignment: .leading) {
                        Text("接管阈值 \(viewModel.configuration.motionSpec.handoffProgress, format: .number.precision(.fractionLength(2)))")
                        Slider(value: $viewModel.configuration.motionSpec.handoffProgress, in: 0.45...0.68, step: 0.01)
                    }
                    VStack(alignment: .leading) {
                        Text("Footer 出现 \(viewModel.configuration.motionSpec.targetFooterRevealStartProgress, format: .number.precision(.fractionLength(2)))")
                        Slider(value: $viewModel.configuration.motionSpec.targetFooterRevealStartProgress, in: 0...0.35, step: 0.01)
                    }
                    VStack(alignment: .leading) {
                        Text("正文出现 \(viewModel.configuration.motionSpec.targetBodyRevealStartProgress, format: .number.precision(.fractionLength(2)))")
                        Slider(value: $viewModel.configuration.motionSpec.targetBodyRevealStartProgress, in: 0.08...0.45, step: 0.01)
                    }
                    VStack(alignment: .leading) {
                        Text("正文预览 \(viewModel.configuration.motionSpec.targetBodyPreviewMinimumOpacity, format: .number.precision(.fractionLength(2)))")
                        Slider(value: $viewModel.configuration.motionSpec.targetBodyPreviewMinimumOpacity, in: 0...0.35, step: 0.01)
                    }
                    VStack(alignment: .leading) {
                        Text("正文可读 \(viewModel.configuration.motionSpec.targetBodyReadableProgress, format: .number.precision(.fractionLength(2)))")
                        Slider(value: $viewModel.configuration.motionSpec.targetBodyReadableProgress, in: 0.45...0.9, step: 0.01)
                    }
                }

                Section("手势") {
                    VStack(alignment: .leading) {
                        Text("位移阈值 \(viewModel.configuration.motionSpec.commitDistanceRatio, format: .number.precision(.fractionLength(2)))")
                        Slider(value: $viewModel.configuration.motionSpec.commitDistanceRatio, in: 0.1...0.5, step: 0.01)
                    }
                    VStack(alignment: .leading) {
                        Text("预测阈值 \(viewModel.configuration.motionSpec.predictedCommitDistanceRatio, format: .number.precision(.fractionLength(2)))")
                        Slider(value: $viewModel.configuration.motionSpec.predictedCommitDistanceRatio, in: 0.18...0.65, step: 0.01)
                    }
                    VStack(alignment: .leading) {
                        Text("旋转 \(viewModel.configuration.motionSpec.maxRotationDegrees, format: .number.precision(.fractionLength(0))) 度")
                        Slider(value: $viewModel.configuration.motionSpec.maxRotationDegrees, in: 0...18, step: 1)
                    }
                    Toggle("允许滑动", isOn: $viewModel.configuration.isSwipeEnabled)
                    Toggle("允许点击", isOn: $viewModel.configuration.isTapEnabled)
                    Toggle("末尾循环", isOn: $viewModel.configuration.isLoopingEnabled)
                    Toggle("Reduce Motion 预览", isOn: $viewModel.isReduceMotionPreviewEnabled)
                }

                Section {
                    Button("重置为 iOS 手感") {
                        viewModel.resetConfiguration()
                    }
                }
            }
            .font(AppTypography.body)
            .navigationTitle("BigUIPaging 配置")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#Preview {
    NavigationStack {
        NoteReviewPagingTestView()
    }
}
#endif
