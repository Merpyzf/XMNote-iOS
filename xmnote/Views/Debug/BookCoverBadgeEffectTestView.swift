#if DEBUG
import SwiftUI
import UIKit

/**
 * [INPUT]: 依赖 BookCoverBadgeEffectTestViewModel 提供可调参数与封面样例，依赖 XMBookCover 与 UIVisualEffectView 渲染书封角标实验效果
 * [OUTPUT]: 对外提供 BookCoverBadgeEffectTestView（书封角标效果测试页）
 * [POS]: Debug 测试页，集中验证书封置顶/数量毛玻璃角标与阅读状态纯色角标在真实封面上的展示效果
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

struct BookCoverBadgeEffectTestView: View {
    @State private var viewModel = BookCoverBadgeEffectTestViewModel()

    var body: some View {
        BookCoverBadgeEffectTestContentView(viewModel: viewModel)
    }
}

private struct BookCoverBadgeEffectTestContentView: View {
    @Bindable var viewModel: BookCoverBadgeEffectTestViewModel
    @Environment(RepositoryContainer.self) private var repositories

    var body: some View {
        VStack(spacing: 0) {
            pinnedPreviewSection

            Divider()

            ScrollView {
                VStack(spacing: Spacing.double) {
                    modePickerSection
                    parameterControlSection
                    activePreviewSection
                    parameterSummarySection
                }
                .padding(.horizontal, Spacing.screenEdge)
                .padding(.vertical, Spacing.base)
                .safeAreaPadding(.bottom)
            }
        }
        .background(Color.surfacePage)
        .navigationTitle("书封角标效果")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.loadBookCoversIfNeeded(using: repositories.bookRepository)
        }
    }
}

private extension BookCoverBadgeEffectTestContentView {
    typealias Parameters = BookCoverBadgeEffectTestViewModel.BadgeEffectParameters
    typealias BlurStyleOption = BookCoverBadgeEffectTestViewModel.BlurStyleOption
    typealias CoverSample = BookCoverBadgeEffectTestViewModel.CoverSample
    typealias PreviewMode = BookCoverBadgeEffectTestViewModel.PreviewMode
    typealias ParameterGroup = BookCoverBadgeEffectTestViewModel.ParameterGroup

    var pinnedPreviewSection: some View {
        HStack(alignment: .top, spacing: Spacing.base) {
            DebugBookCoverBadgePreview(
                urlString: viewModel.selectedSample.urlString,
                width: 104,
                noteText: "29",
                statusText: "在读",
                statusColor: .statusReading,
                parameters: viewModel.parameters
            )

            VStack(alignment: .leading, spacing: Spacing.half) {
                Text("实时预览")
                    .font(AppTypography.headline)
                    .foregroundStyle(Color.textPrimary)

                Picker("预览封面", selection: selectedSampleBinding) {
                    ForEach(viewModel.allSamples) { sample in
                        Text(sample.title).tag(sample.id)
                    }
                }
                .pickerStyle(.menu)

                Picker("毛玻璃样式", selection: binding(\.blurStyle)) {
                    ForEach(BlurStyleOption.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.menu)

                HStack(spacing: Spacing.half) {
                    labelBadge(viewModel.selectedSample.title)
                    labelBadge(viewModel.parameters.blurStyle.title)
                }

                Button {
                    withAnimation(.snappy) {
                        viewModel.resetParameters()
                    }
                } label: {
                    Label("恢复默认", systemImage: "arrow.counterclockwise")
                        .font(AppTypography.captionMedium)
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.vertical, Spacing.base)
        .background(Color.surfaceCard)
    }

    var modePickerSection: some View {
        Picker("预览模式", selection: previewModeBinding) {
            ForEach(PreviewMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
    }

    var parameterControlSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                sectionHeader("参数调节", subtitle: viewModel.sourceStatusText)

                parameterDisclosureGroup(.glass) {
                    VStack(alignment: .leading, spacing: Spacing.half) {
                        labelText("毛玻璃样式")
                        Picker("毛玻璃样式", selection: binding(\.blurStyle)) {
                            ForEach(BlurStyleOption.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    sliderRow(title: "暗色 Overlay", value: binding(\.darkOverlayOpacity), range: 0...0.70, step: 0.01)
                    sliderRow(title: "白雾 Wash", value: binding(\.washOpacity), range: 0...0.20, step: 0.01)
                    sliderRow(title: "内侧边界", value: binding(\.strokeOpacity), range: 0...0.30, step: 0.01)
                }

                Divider()
                parameterDisclosureGroup(.text) {
                    sliderRow(title: "阴影透明度", value: binding(\.contentShadowOpacity), range: 0...0.60, step: 0.01)
                    sliderRow(title: "阴影半径", value: binding(\.contentShadowRadius), range: 0...2.0, step: 0.1)
                    sliderRow(title: "阴影 Y 偏移", value: binding(\.contentShadowYOffset), range: 0...2.0, step: 0.1)
                }

                Divider()
                parameterDisclosureGroup(.size) {
                    sliderRow(title: "水平 Padding", value: binding(\.horizontalPadding), range: 2...12, step: 1, decimals: 0)
                    sliderRow(title: "垂直 Padding", value: binding(\.verticalPadding), range: 1...8, step: 1, decimals: 0)
                    sliderRow(title: "Pin 尺寸", value: binding(\.pinSize), range: 18...32, step: 1, decimals: 0)
                    sliderRow(title: "内侧圆角", value: binding(\.innerCornerRadius), range: 0...10, step: 1, decimals: 0)
                }

                Divider()
                parameterDisclosureGroup(.status) {
                    sliderRow(title: "状态色透明度", value: binding(\.statusOpacity), range: 0.50...1.00, step: 0.01)
                }

                Divider()
                parameterDisclosureGroup(.experiment) {
                    Toggle("使用 Vibrancy 文本", isOn: binding(\.usesVibrancyText))
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textPrimary)
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    @ViewBuilder
    var activePreviewSection: some View {
        switch viewModel.previewMode {
        case .live:
            livePreviewSection
        case .blurStyles:
            blurStyleComparisonSection
        case .matrix:
            matrixSection
        case .themeAndGroup:
            VStack(spacing: Spacing.double) {
                themeSection
                groupPreviewSection
            }
        }
    }

    var livePreviewSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                sectionHeader("实时预览", subtitle: "同一封面同时展示置顶、阅读状态与数量角标。")

                HStack(alignment: .top, spacing: Spacing.double) {
                    DebugBookCoverBadgePreview(
                        urlString: viewModel.selectedSample.urlString,
                        width: 126,
                        noteText: "29",
                        statusText: "在读",
                        statusColor: .statusReading,
                        parameters: viewModel.parameters
                    )

                    VStack(alignment: .leading, spacing: Spacing.half) {
                        labelBadge(viewModel.selectedSample.title)
                        labelBadge(viewModel.selectedSample.note)
                        labelBadge(viewModel.parameters.blurStyle.title)

                        Text("阅读状态为纯色角标，不走毛玻璃；左上和右下用于观察真实背景 blur、叠色和文字可读性。")
                            .font(AppTypography.caption)
                            .foregroundStyle(Color.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(compactParameterSummary)
                            .font(AppTypography.caption2)
                            .monospacedDigit()
                            .foregroundStyle(Color.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    var blurStyleComparisonSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                sectionHeader("Blur Style 对比", subtitle: "固定其它参数，只切换系统 blur style。")

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: Spacing.base) {
                        ForEach(BlurStyleOption.allCases) { option in
                            VStack(alignment: .leading, spacing: Spacing.half) {
                                DebugBookCoverBadgePreview(
                                    urlString: viewModel.selectedSample.urlString,
                                    width: 96,
                                    noteText: "29",
                                    statusText: "在读",
                                    statusColor: .statusReading,
                                    parameters: viewModel.parameters(overriding: option)
                                )
                                Text(option.title)
                                    .font(AppTypography.caption2Medium)
                                    .foregroundStyle(Color.textPrimary)
                                    .lineLimit(2)
                            }
                            .frame(width: 104, alignment: .leading)
                        }
                    }
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    var matrixSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                sectionHeader("封面矩阵", subtitle: "真实封面不足时使用浅色、黄色、黑色、白底与复杂彩色样例兜底。")

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 96), spacing: Spacing.base, alignment: .top)],
                    alignment: .leading,
                    spacing: Spacing.base
                ) {
                    ForEach(viewModel.matrixSamples) { sample in
                        DebugCoverMatrixCell(
                            sample: sample,
                            parameters: viewModel.parameters
                        )
                    }
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    var themeSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                sectionHeader("浅深色对照", subtitle: "同一组参数在不同系统主题下对比干净度。")

                HStack(alignment: .top, spacing: Spacing.base) {
                    themePane(title: "浅色", scheme: .light)
                    themePane(title: "深色", scheme: .dark)
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    var groupPreviewSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                sectionHeader("分组预览", subtitle: "分组仅验证置顶与 N本 数量角标。")

                HStack(alignment: .top, spacing: Spacing.double) {
                    DebugBookCoverGroupBadgePreview(
                        samples: viewModel.matrixSamples,
                        width: 128,
                        countText: "25本",
                        parameters: viewModel.parameters
                    )

                    Text("分组封面沿用 pin 与数量角标参数，阅读状态不参与分组展示。")
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    var parameterSummarySection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                sectionHeader("参数摘要", subtitle: "选定效果后可用这里的参数迁移回生产 token。")

                Text(viewModel.parameterSummary)
                    .font(AppTypography.caption2)
                    .monospacedDigit()
                    .foregroundStyle(Color.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.base)
                    .background(Color.surfaceNested, in: RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous))
                    .textSelection(.enabled)
            }
            .padding(Spacing.contentEdge)
        }
    }

    var selectedSampleBinding: Binding<String> {
        Binding(
            get: { viewModel.selectedSample.id },
            set: { viewModel.selectedSampleID = $0 }
        )
    }

    var previewModeBinding: Binding<PreviewMode> {
        Binding(
            get: { viewModel.previewMode },
            set: { newValue in
                withAnimation(.snappy) {
                    viewModel.previewMode = newValue
                }
            }
        )
    }

    var compactParameterSummary: String {
        "overlay \(formatted(viewModel.parameters.darkOverlayOpacity, decimals: 2)) / wash \(formatted(viewModel.parameters.washOpacity, decimals: 2)) / stroke \(formatted(viewModel.parameters.strokeOpacity, decimals: 2))"
    }

    func binding<Value>(_ keyPath: WritableKeyPath<Parameters, Value>) -> Binding<Value> {
        Binding(
            get: { viewModel.parameters[keyPath: keyPath] },
            set: { viewModel.parameters[keyPath: keyPath] = $0 }
        )
    }

    func parameterGroupBinding(_ group: ParameterGroup) -> Binding<Bool> {
        Binding(
            get: { viewModel.isParameterGroupExpanded(group) },
            set: { isExpanded in
                withAnimation(.snappy) {
                    if isExpanded != viewModel.isParameterGroupExpanded(group) {
                        viewModel.toggleParameterGroup(group)
                    }
                }
            }
        )
    }

    func parameterDisclosureGroup<Content: View>(
        _ group: ParameterGroup,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        DisclosureGroup(isExpanded: parameterGroupBinding(group)) {
            VStack(alignment: .leading, spacing: Spacing.half) {
                content()
            }
            .padding(.top, Spacing.half)
        } label: {
            Text(group.title)
                .font(AppTypography.captionMedium)
                .foregroundStyle(Color.textPrimary)
        }
    }

    func themePane(title: String, scheme: ColorScheme) -> some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            Text(title)
                .font(AppTypography.captionMedium)
                .foregroundStyle(Color.textPrimary)

            DebugBookCoverBadgePreview(
                urlString: viewModel.selectedSample.urlString,
                width: 92,
                noteText: "72",
                statusText: "想读",
                statusColor: .statusWish,
                parameters: viewModel.parameters
            )
        }
        .padding(Spacing.base)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
        .environment(\.colorScheme, scheme)
    }

    func sectionHeader(_ title: String, subtitle: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tiny) {
            Text(title)
                .font(AppTypography.headline)
                .foregroundStyle(Color.textPrimary)

            if let subtitle {
                Text(subtitle)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    func parameterGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            labelText(title)
            content()
        }
    }

    func sliderRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        decimals: Int = 2
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tiny) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                Spacer(minLength: 0)
                Text(formatted(value.wrappedValue, decimals: decimals))
                    .font(AppTypography.caption2)
                    .monospacedDigit()
                    .foregroundStyle(Color.textPrimary)
            }

            Slider(value: value, in: range, step: step)
                .tint(Color.brand)
        }
    }

    func labelText(_ text: String) -> some View {
        Text(text)
            .font(AppTypography.captionMedium)
            .foregroundStyle(Color.textSecondary)
    }

    func labelBadge(_ text: String) -> some View {
        Text(text)
            .font(AppTypography.caption2Medium)
            .foregroundStyle(Color.textPrimary)
            .padding(.horizontal, Spacing.cozy)
            .padding(.vertical, Spacing.compact)
            .background(Color.surfaceNested, in: Capsule())
    }

    func formatted(_ value: Double, decimals: Int) -> String {
        String(format: "%.\(decimals)f", value)
    }
}

private struct DebugCoverMatrixCell: View {
    let sample: BookCoverBadgeEffectTestViewModel.CoverSample
    let parameters: BookCoverBadgeEffectTestViewModel.BadgeEffectParameters

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            DebugBookCoverBadgePreview(
                urlString: sample.urlString,
                width: 92,
                noteText: "29",
                statusText: "在读",
                statusColor: .statusReading,
                parameters: parameters
            )
            Text(sample.title)
                .font(AppTypography.caption2Medium)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
            Text(sample.note)
                .font(AppTypography.caption2)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
        }
        .frame(width: 96, alignment: .leading)
    }
}

private struct DebugBookCoverBadgePreview: View {
    let urlString: String
    let width: CGFloat
    let noteText: String
    let statusText: String
    let statusColor: Color
    let parameters: BookCoverBadgeEffectTestViewModel.BadgeEffectParameters

    private let coverCornerRadius = CornerRadius.inlaySmall

    var body: some View {
        XMBookCover.fixedWidth(
            width,
            urlString: urlString,
            cornerRadius: coverCornerRadius,
            border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth),
            placeholderIconSize: .medium,
            surfaceStyle: .spine
        )
        .overlay {
            DebugBookCoverBadgeLayer(
                noteText: noteText,
                statusText: statusText,
                statusColor: statusColor,
                parameters: parameters,
                cornerRadius: coverCornerRadius
            )
        }
    }
}

private struct DebugBookCoverBadgeLayer: View {
    let noteText: String
    let statusText: String
    let statusColor: Color
    let parameters: BookCoverBadgeEffectTestViewModel.BadgeEffectParameters
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            DebugGlassPinBadge(parameters: parameters, cornerRadius: cornerRadius)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            DebugStatusBadge(
                text: statusText,
                color: statusColor,
                parameters: parameters,
                cornerRadius: cornerRadius
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

            DebugGlassTextBadge(
                text: noteText,
                placement: .bottomTrailing,
                parameters: parameters,
                cornerRadius: cornerRadius
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .allowsHitTesting(false)
    }
}

private struct DebugGlassTextBadge: View {
    let text: String
    let placement: DebugBadgePlacement
    let parameters: BookCoverBadgeEffectTestViewModel.BadgeEffectParameters
    let cornerRadius: CGFloat

    var body: some View {
        effectBadge(placement: placement, parameters: parameters, cornerRadius: cornerRadius) {
            Text(text)
                .font(AppTypography.caption2Medium)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .foregroundStyle(.white)
                .padding(.horizontal, parameters.horizontalPadding)
                .padding(.vertical, parameters.verticalPadding)
                .shadow(
                    color: Color.black.opacity(parameters.contentShadowOpacity),
                    radius: parameters.contentShadowRadius,
                    x: 0,
                    y: parameters.contentShadowYOffset
                )
                .fixedSize(horizontal: true, vertical: true)
        }
        .accessibilityLabel(Text(verbatim: text))
    }
}

private struct DebugGlassPinBadge: View {
    let parameters: BookCoverBadgeEffectTestViewModel.BadgeEffectParameters
    let cornerRadius: CGFloat

    var body: some View {
        effectBadge(placement: .topLeading, parameters: parameters, cornerRadius: cornerRadius) {
            Image(systemName: "pin.fill")
                .font(AppTypography.caption2Semibold)
                .foregroundStyle(.white)
                .frame(width: parameters.pinSize, height: parameters.pinSize)
                .shadow(
                    color: Color.black.opacity(parameters.contentShadowOpacity),
                    radius: parameters.contentShadowRadius,
                    x: 0,
                    y: parameters.contentShadowYOffset
                )
        }
        .accessibilityLabel("已置顶")
    }
}

private struct DebugStatusBadge: View {
    let text: String
    let color: Color
    let parameters: BookCoverBadgeEffectTestViewModel.BadgeEffectParameters
    let cornerRadius: CGFloat

    var body: some View {
        let shape = DebugBadgeShape(
            radii: DebugBadgePlacement.topTrailing.cornerRadii(
                outerRadius: cornerRadius,
                innerRadius: parameters.innerCornerRadius
            )
        )

        Text(text)
            .font(AppTypography.caption2Medium)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .foregroundStyle(.white)
            .padding(.horizontal, parameters.horizontalPadding)
            .padding(.vertical, parameters.verticalPadding)
            .background {
                shape.fill(color.opacity(parameters.statusOpacity))
            }
            .shadow(
                color: Color.black.opacity(parameters.contentShadowOpacity),
                radius: parameters.contentShadowRadius,
                x: 0,
                y: parameters.contentShadowYOffset
            )
            .fixedSize(horizontal: true, vertical: true)
            .accessibilityLabel(Text(verbatim: text))
    }
}

private struct DebugBookCoverGroupBadgePreview: View {
    let samples: [BookCoverBadgeEffectTestViewModel.CoverSample]
    let width: CGFloat
    let countText: String
    let parameters: BookCoverBadgeEffectTestViewModel.BadgeEffectParameters

    private let cornerRadius = CornerRadius.blockLarge

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.surfaceCard)
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
                }

            DebugGroupMosaic(samples: samples)
                .padding(Spacing.half)
        }
        .frame(width: width, height: XMBookCover.height(forWidth: width))
        .overlay {
            ZStack {
                DebugGlassPinBadge(parameters: parameters, cornerRadius: cornerRadius)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                DebugGlassTextBadge(
                    text: countText,
                    placement: .bottomTrailing,
                    parameters: parameters,
                    cornerRadius: cornerRadius
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
            .allowsHitTesting(false)
        }
    }
}

private struct DebugGroupMosaic: View {
    let samples: [BookCoverBadgeEffectTestViewModel.CoverSample]

    var body: some View {
        GeometryReader { proxy in
            let metrics = DebugGroupMosaicMetrics(size: proxy.size)

            ZStack(alignment: .topLeading) {
                mosaicCell(at: 0, metrics: metrics)
                    .frame(width: metrics.largeWidth, height: metrics.topHeight)
                    .offset(x: metrics.origin, y: metrics.origin)

                mosaicCell(at: 1, metrics: metrics)
                    .frame(width: metrics.sideWidth, height: metrics.sideHeight)
                    .offset(x: metrics.sideX, y: metrics.origin)

                mosaicCell(at: 2, metrics: metrics)
                    .frame(width: metrics.sideWidth, height: metrics.sideHeight)
                    .offset(x: metrics.sideX, y: metrics.origin + metrics.sideHeight + metrics.spacing)

                ForEach(0..<3, id: \.self) { index in
                    mosaicCell(at: index + 3, metrics: metrics)
                        .frame(width: metrics.bottomWidth, height: metrics.bottomHeight)
                        .offset(
                            x: metrics.origin + CGFloat(index) * (metrics.bottomWidth + metrics.spacing),
                            y: metrics.bottomY
                        )
                }
            }
        }
    }

    private func mosaicCell(at index: Int, metrics: DebugGroupMosaicMetrics) -> some View {
        XMBookCover.fixedSize(
            width: metrics.cellWidth(for: index),
            height: metrics.cellHeight(for: index),
            urlString: coverURL(at: index),
            cornerRadius: index == 0 ? CornerRadius.inlaySmall : CornerRadius.inlayTiny,
            border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth),
            placeholderIconSize: .hidden,
            surfaceStyle: index == 0 ? .spine : .plain
        )
    }

    private func coverURL(at index: Int) -> String {
        guard samples.indices.contains(index) else { return "" }
        return samples[index].urlString
    }
}

private struct DebugGroupMosaicMetrics {
    let origin: CGFloat
    let spacing: CGFloat
    let largeWidth: CGFloat
    let topHeight: CGFloat
    let sideWidth: CGFloat
    let sideHeight: CGFloat
    let bottomWidth: CGFloat
    let bottomHeight: CGFloat
    let sideX: CGFloat
    let bottomY: CGFloat

    init(size: CGSize) {
        origin = 0
        spacing = Spacing.half
        let contentWidth = max(0, size.width)
        let contentHeight = max(0, size.height)

        let rawSideWidth = max(0, (contentWidth - spacing) * 0.34)
        let rawLargeWidth = max(0, contentWidth - spacing - rawSideWidth)
        let rawBottomWidth = max(0, (contentWidth - spacing * 2) / 3)
        let rawLargeHeight = XMBookCover.height(forWidth: rawLargeWidth)
        let rawSideHeight = XMBookCover.height(forWidth: rawSideWidth)
        let rawBottomHeight = XMBookCover.height(forWidth: rawBottomWidth)
        let coverHeightBudget = max(0, contentHeight - spacing * 2)
        let coverHeightDemand = max(rawLargeHeight, rawSideHeight * 2) + rawBottomHeight
        let scale = coverHeightDemand > 0 ? min(1, coverHeightBudget / coverHeightDemand) : 1

        largeWidth = rawLargeWidth * scale
        sideWidth = rawSideWidth * scale
        bottomWidth = rawBottomWidth * scale
        topHeight = XMBookCover.height(forWidth: largeWidth)
        sideHeight = XMBookCover.height(forWidth: sideWidth)
        bottomHeight = XMBookCover.height(forWidth: bottomWidth)

        let topRowHeight = max(topHeight, sideHeight * 2 + spacing)
        bottomY = topRowHeight + spacing
        sideX = largeWidth + spacing
    }

    func cellWidth(for index: Int) -> CGFloat {
        index == 0 ? largeWidth : (index < 3 ? sideWidth : bottomWidth)
    }

    func cellHeight(for index: Int) -> CGFloat {
        index == 0 ? topHeight : (index < 3 ? sideHeight : bottomHeight)
    }
}

private enum DebugBadgePlacement {
    case topLeading
    case topTrailing
    case bottomTrailing

    func cornerRadii(outerRadius: CGFloat, innerRadius: CGFloat) -> RectangleCornerRadii {
        switch self {
        case .topLeading:
            return RectangleCornerRadii(
                topLeading: outerRadius,
                bottomLeading: CornerRadius.none,
                bottomTrailing: innerRadius,
                topTrailing: CornerRadius.none
            )
        case .topTrailing:
            return RectangleCornerRadii(
                topLeading: CornerRadius.none,
                bottomLeading: innerRadius,
                bottomTrailing: CornerRadius.none,
                topTrailing: outerRadius
            )
        case .bottomTrailing:
            return RectangleCornerRadii(
                topLeading: innerRadius,
                bottomLeading: CornerRadius.none,
                bottomTrailing: outerRadius,
                topTrailing: CornerRadius.none
            )
        }
    }
}

private struct DebugBadgeShape: Shape {
    let radii: RectangleCornerRadii

    func path(in rect: CGRect) -> Path {
        UnevenRoundedRectangle(cornerRadii: radii, style: .continuous)
            .path(in: rect)
    }
}

@ViewBuilder
private func effectBadge<Content: View>(
    placement: DebugBadgePlacement,
    parameters: BookCoverBadgeEffectTestViewModel.BadgeEffectParameters,
    cornerRadius: CGFloat,
    @ViewBuilder content: () -> Content
) -> some View {
    let shape = DebugBadgeShape(
        radii: placement.cornerRadii(
            outerRadius: cornerRadius,
            innerRadius: parameters.innerCornerRadius
        )
    )

    DebugVisualEffectBadge(
        blurStyle: parameters.blurStyle.uiBlurStyle,
        darkOverlayOpacity: parameters.darkOverlayOpacity,
        washOpacity: parameters.washOpacity,
        usesVibrancyText: parameters.usesVibrancyText,
        content: content
    )
    .overlay {
        shape.stroke(Color.white.opacity(parameters.strokeOpacity), lineWidth: CardStyle.borderWidth)
    }
    .compositingGroup()
    .clipShape(shape)
}

private struct DebugVisualEffectBadge<Content: View>: UIViewRepresentable {
    let blurStyle: UIBlurEffect.Style
    let darkOverlayOpacity: Double
    let washOpacity: Double
    let usesVibrancyText: Bool
    let content: Content

    init(
        blurStyle: UIBlurEffect.Style,
        darkOverlayOpacity: Double,
        washOpacity: Double,
        usesVibrancyText: Bool,
        @ViewBuilder content: () -> Content
    ) {
        self.blurStyle = blurStyle
        self.darkOverlayOpacity = darkOverlayOpacity
        self.washOpacity = washOpacity
        self.usesVibrancyText = usesVibrancyText
        self.content = content()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(content: content)
    }

    func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: UIBlurEffect(style: blurStyle))
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        context.coordinator.installBaseViews(in: view)
        return view
    }

    func updateUIView(_ view: UIVisualEffectView, context: Context) {
        let blurEffect = UIBlurEffect(style: blurStyle)
        view.effect = blurEffect
        context.coordinator.update(
            content: content,
            blurEffect: blurEffect,
            darkOverlayOpacity: darkOverlayOpacity,
            washOpacity: washOpacity,
            usesVibrancyText: usesVibrancyText,
            in: view
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UIVisualEffectView,
        context: Context
    ) -> CGSize? {
        let target = CGSize(
            width: proposal.width ?? 1000,
            height: proposal.height ?? 1000
        )
        return context.coordinator.hostingController.sizeThatFits(in: target)
    }

    final class Coordinator {
        let hostingController: UIHostingController<Content>
        private let washView = UIView()
        private let darkOverlayView = UIView()
        private let vibrancyView = UIVisualEffectView(effect: nil)
        private var contentConstraints: [NSLayoutConstraint] = []

        init(content: Content) {
            hostingController = UIHostingController(rootView: content)
            hostingController.view.backgroundColor = .clear
        }

        func installBaseViews(in view: UIVisualEffectView) {
            [washView, darkOverlayView, vibrancyView].forEach { subview in
                subview.translatesAutoresizingMaskIntoConstraints = false
                view.contentView.addSubview(subview)
                NSLayoutConstraint.activate([
                    subview.leadingAnchor.constraint(equalTo: view.contentView.leadingAnchor),
                    subview.trailingAnchor.constraint(equalTo: view.contentView.trailingAnchor),
                    subview.topAnchor.constraint(equalTo: view.contentView.topAnchor),
                    subview.bottomAnchor.constraint(equalTo: view.contentView.bottomAnchor)
                ])
            }
            vibrancyView.isUserInteractionEnabled = false
        }

        func update(
            content: Content,
            blurEffect: UIBlurEffect,
            darkOverlayOpacity: Double,
            washOpacity: Double,
            usesVibrancyText: Bool,
            in view: UIVisualEffectView
        ) {
            hostingController.rootView = content
            washView.backgroundColor = UIColor.white.withAlphaComponent(washOpacity)
            darkOverlayView.backgroundColor = UIColor.black.withAlphaComponent(darkOverlayOpacity)

            if usesVibrancyText {
                vibrancyView.effect = UIVibrancyEffect(blurEffect: blurEffect, style: .label)
                moveContent(to: vibrancyView.contentView)
                view.contentView.bringSubviewToFront(vibrancyView)
            } else {
                vibrancyView.effect = nil
                moveContent(to: view.contentView)
                view.contentView.bringSubviewToFront(hostingController.view)
            }
        }

        private func moveContent(to parent: UIView) {
            guard hostingController.view.superview !== parent else { return }
            NSLayoutConstraint.deactivate(contentConstraints)
            hostingController.view.removeFromSuperview()
            hostingController.view.translatesAutoresizingMaskIntoConstraints = false
            parent.addSubview(hostingController.view)
            contentConstraints = [
                hostingController.view.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
                hostingController.view.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
                hostingController.view.topAnchor.constraint(equalTo: parent.topAnchor),
                hostingController.view.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
            ]
            NSLayoutConstraint.activate(contentConstraints)
        }
    }
}

#Preview {
    NavigationStack {
        BookCoverBadgeEffectTestView()
    }
}
#endif
