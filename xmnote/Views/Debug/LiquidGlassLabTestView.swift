#if DEBUG
import SwiftUI
import UIKit

/**
 * [INPUT]: 依赖 LiquidGlassLabTestViewModel 提供参数、预设、截图、FPS 与真实书封背景样例
 * [OUTPUT]: 对外提供 LiquidGlassLabTestView（iOS 26 Liquid Glass 液态玻璃专项测试页）
 * [POS]: Debug 测试页，集中验证图片背景上的液态玻璃文本、工具栏、控件栏、截图对比与性能观测
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

struct LiquidGlassLabTestView: View {
    @State private var viewModel = LiquidGlassLabTestViewModel()

    var body: some View {
        LiquidGlassLabTestContentView(viewModel: viewModel)
    }
}

private struct LiquidGlassLabTestContentView: View {
    @Bindable var viewModel: LiquidGlassLabTestViewModel
    @Environment(RepositoryContainer.self) private var repositories
    @State private var snapshotAnchorView: UIView?
    @State private var isParameterSheetPresented = false

    var body: some View {
        VStack(spacing: 0) {
            topTelemetryBar

            ScrollView {
                VStack(spacing: Spacing.base) {
                    previewSection
                    screenshotSection
                }
                .padding(.horizontal, Spacing.screenEdge)
                .padding(.vertical, Spacing.base)
                .safeAreaPadding(.bottom)
            }
        }
        .background(Color.surfacePage)
        .navigationTitle("iOS 26 Liquid Glass")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(viewModel.schemeMode.colorScheme)
        .overlay(alignment: .topLeading) {
            LiquidGlassFPSProbe { timestamp in
                viewModel.recordFrame(timestamp: timestamp)
            }
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .opacity(0.01)
        }
        .sheet(isPresented: $isParameterSheetPresented) {
            parameterSheet
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        .task {
            await viewModel.loadBookCoversIfNeeded(using: repositories.bookRepository)
        }
    }
}

private extension LiquidGlassLabTestContentView {
    typealias Parameters = LiquidGlassLabTestViewModel.GlassLabParameters
    typealias PreviewScene = LiquidGlassLabTestViewModel.PreviewScene
    typealias BackgroundKind = LiquidGlassLabTestViewModel.BackgroundKind
    typealias SchemeMode = LiquidGlassLabTestViewModel.SchemeMode
    typealias GlassVariant = LiquidGlassLabTestViewModel.GlassVariant
    typealias GlassShapeOption = LiquidGlassLabTestViewModel.GlassShapeOption
    typealias TintOption = LiquidGlassLabTestViewModel.TintOption
    typealias MaterialStyle = LiquidGlassLabTestViewModel.MaterialStyle
    typealias BlendModeOption = LiquidGlassLabTestViewModel.BlendModeOption
    typealias BackgroundSampling = LiquidGlassLabTestViewModel.BackgroundSampling

    var topTelemetryBar: some View {
        HStack(spacing: Spacing.half) {
            statusBadge("原生", value: viewModel.parameters.glassVariant.title, tint: .brand)
            statusBadge("模拟", value: viewModel.parameters.materialStyle.title, tint: .liquidGlassLabBlue)
            statusBadge("观测", value: viewModel.performanceSummary, tint: .liquidGlassLabOrange)
        }
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.vertical, Spacing.half)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surfaceCard)
    }

    var previewSection: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            sectionHeader(
                viewModel.previewScene.title,
                subtitle: "\(viewModel.previewScene.subtitle)\n\(viewModel.sourceStatusText)"
            )

            LiquidGlassPreviewStage(
                viewModel: viewModel,
                snapshotAnchorView: $snapshotAnchorView
            )

            HStack(spacing: Spacing.half) {
                Button {
                    isParameterSheetPresented = true
                } label: {
                    Label("调节参数", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    Task {
                        await viewModel.captureSnapshot(from: snapshotAnchorView)
                    }
                } label: {
                    Label("截图对比", systemImage: "camera.viewfinder")
                }
                .buttonStyle(.bordered)

                Button {
                    withAnimation(.snappy) {
                        viewModel.resetParameters()
                    }
                } label: {
                    Label("恢复基线", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)

                Spacer()
            }
            .font(AppTypography.captionMedium)

            if let message = viewModel.captureStatusMessage {
                Text(message)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var parameterSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.base) {
                    modeControlSection
                    nativeParameterSection
                    shapeParameterSection
                    readabilityParameterSection
                    toolbarParameterSection
                    presetSection
                    parameterSummarySection
                }
                .padding(.horizontal, Spacing.screenEdge)
                .padding(.vertical, Spacing.base)
                .safeAreaPadding(.bottom)
            }
            .background(Color.surfacePage)
            .navigationTitle("Liquid Glass 参数")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        isParameterSheetPresented = false
                    }
                    .font(AppTypography.callout)
                }
            }
        }
    }

    var modeControlSection: some View {
        CardContainer(showsBorder: true, borderColor: .surfaceBorderSubtle) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                sectionHeader("场景与背景", subtitle: "使用按钮网格切换，避免窄屏 segmented 控件被压缩。")
                optionGrid(title: "预览场景", selection: sceneBinding(), values: PreviewScene.allCases, minimumWidth: 118)
                optionGrid(title: "背景来源", selection: backgroundBinding(), values: BackgroundKind.allCases, minimumWidth: 92)
                optionGrid(title: "外观模式", selection: schemeBinding(), values: SchemeMode.allCases, minimumWidth: 92)
            }
            .padding(Spacing.contentEdge)
        }
    }

    var nativeParameterSection: some View {
        CardContainer(showsBorder: true, borderColor: .surfaceBorderSubtle) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                sectionHeader("原生 Liquid Glass", subtitle: "保持原生 glassEffect 为主效果，只调整常用生产参数。")

                optionGrid(title: "Glass", selection: parameterBinding(\.glassVariant), values: GlassVariant.allCases, minimumWidth: 92)
                twoColumnPicker(
                    title: "Tint Color",
                    selection: parameterBinding(\.tint),
                    values: TintOption.allCases
                )
                Toggle("Interactive Glass", isOn: parameterBinding(\.isInteractive))
            }
            .font(AppTypography.caption)
            .padding(Spacing.contentEdge)
        }
    }

    var shapeParameterSection: some View {
        CardContainer(showsBorder: true, borderColor: .surfaceBorderSubtle) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                sectionHeader("形状与布局", subtitle: "调整控件圆角、容器间距与轻量位移，贴近真实工具栏使用。")

                optionGrid(title: "Shape", selection: parameterBinding(\.glassShape), values: GlassShapeOption.allCases, minimumWidth: 108)
                sliderRow(title: "Corner Radius", value: doubleBinding(\.cornerRadius), range: 8...36, step: 1, decimals: 0, tag: "形状")
                sliderRow(title: "Container Spacing", value: doubleBinding(\.containerSpacing), range: 8...32, step: 1, decimals: 0, tag: "容器")
                sliderRow(title: "Motion / Parallax", value: doubleBinding(\.motionParallax), range: 0...0.35, step: 0.01, tag: "动效")
            }
            .font(AppTypography.caption)
            .padding(Spacing.contentEdge)
        }
    }

    var readabilityParameterSection: some View {
        CardContainer(showsBorder: true, borderColor: .surfaceBorderSubtle) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                sectionHeader("可读性增强", subtitle: "仅保留正常图片背景上常用的轻量兜底，不再默认叠满高光和反射。")

                twoColumnPicker(
                    title: "Material Style",
                    selection: parameterBinding(\.materialStyle),
                    values: MaterialStyle.allCases
                )
                twoColumnPicker(
                    title: "Background Sampling",
                    selection: parameterBinding(\.backgroundSampling),
                    values: BackgroundSampling.allCases
                )

                sliderRow(title: "Blur Radius", value: doubleBinding(\.blurRadius), range: 0...12, step: 1, decimals: 0, tag: "采样")
                sliderRow(title: "Tint Opacity", value: doubleBinding(\.tintOpacity), range: 0...0.22, step: 0.01, tag: "底色")
                sliderRow(title: "Opacity", value: doubleBinding(\.opacity), range: 0.86...1.00, step: 0.01, tag: "透明")
                sliderRow(title: "Shadow", value: doubleBinding(\.shadow), range: 0...0.30, step: 0.01, tag: "阴影")
                sliderRow(title: "Highlight", value: doubleBinding(\.highlightIntensity), range: 0...0.24, step: 0.01, tag: "高光")
                sliderRow(title: "Border Light", value: doubleBinding(\.borderLight), range: 0...0.24, step: 0.01, tag: "描边")
                sliderRow(title: "Vibrancy", value: doubleBinding(\.vibrancy), range: 0...0.35, step: 0.01, tag: "文字")
            }
            .font(AppTypography.caption)
            .padding(Spacing.contentEdge)
        }
    }

    var toolbarParameterSection: some View {
        CardContainer(showsBorder: true, borderColor: .surfaceBorderSubtle) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                sectionHeader("工具栏表现", subtitle: "用于调底部栏、浮动栏在滚动与图片背景上的稳定性。")

                Toggle("显示辅助按钮", isOn: parameterBinding(\.usesMorphingProbe))
                sliderRow(title: "Saturation", value: doubleBinding(\.saturation), range: 0.90...1.25, step: 0.01, tag: "色彩")
                sliderRow(title: "Contrast", value: doubleBinding(\.contrast), range: 0.92...1.18, step: 0.01, tag: "对比")
                sliderRow(title: "Scroll Reactive", value: doubleBinding(\.scrollReactiveEffects), range: 0...0.35, step: 0.01, tag: "滚动")
                sliderRow(title: "Dynamic Brightness", value: doubleBinding(\.dynamicBrightnessAdaptation), range: 0...0.30, step: 0.01, tag: "亮度")
            }
            .font(AppTypography.caption)
            .padding(Spacing.contentEdge)
        }
    }

    var presetSection: some View {
        CardContainer(showsBorder: true, borderColor: .surfaceBorderSubtle) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                sectionHeader("参数预设", subtitle: "保存到 UserDefaults，重启后仍可继续调参。")

                HStack(spacing: Spacing.half) {
                    TextField("预设名称", text: $viewModel.presetNameDraft)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        viewModel.savePreset()
                    } label: {
                        Label("保存", systemImage: "tray.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                }
                .font(AppTypography.caption)

                if viewModel.savedPresets.isEmpty {
                    Text("暂无保存的参数组合。")
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(viewModel.savedPresets) { preset in
                            presetRow(preset)
                            if preset.id != viewModel.savedPresets.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    var screenshotSection: some View {
        CardContainer(showsBorder: true, borderColor: .surfaceBorderSubtle) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                sectionHeader("截图对比", subtitle: "PNG 与参数 JSON 保存到 Documents/Debug/LiquidGlassLab。")

                if viewModel.screenshotRecords.isEmpty {
                    Text("暂无截图。点击预览区下方“截图对比”保存当前效果。")
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 142), spacing: Spacing.base)], spacing: Spacing.base) {
                        ForEach(viewModel.screenshotRecords) { record in
                            screenshotCard(record)
                        }
                    }
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    var parameterSummarySection: some View {
        CardContainer(showsBorder: true, borderColor: .surfaceBorderSubtle) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                sectionHeader("参数摘要", subtitle: "复制截图 JSON 前，可先在这里核对当前运行参数。")

                Text(viewModel.nativeParameterSummary)
                    .font(AppTypography.captionMedium)
                    .foregroundStyle(Color.textPrimary)

                Text(viewModel.simulationParameterSummary)
                    .font(AppTypography.caption2)
                    .monospacedDigit()
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Spacing.contentEdge)
        }
    }

    func sectionHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(AppTypography.headlineSemibold)
                .foregroundStyle(Color.textPrimary)
            Text(subtitle)
                .font(AppTypography.caption)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    func labelText(_ title: String) -> some View {
        Text(title)
            .font(AppTypography.captionMedium)
            .foregroundStyle(Color.textSecondary)
    }

    func statusBadge(_ label: String, value: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(AppTypography.caption2Semibold)
                .foregroundStyle(tint)
            Text(value)
                .font(AppTypography.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.horizontal, Spacing.half)
        .padding(.vertical, 5)
        .background(tint.opacity(0.10), in: Capsule())
        .overlay {
            Capsule().stroke(tint.opacity(0.20), lineWidth: CardStyle.borderWidth)
        }
    }

    func sliderRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        decimals: Int = 2,
        tag: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Spacing.half) {
                Text(title)
                    .font(AppTypography.captionMedium)
                    .foregroundStyle(Color.textPrimary)
                statusBadge(tag, value: formatted(value.wrappedValue, decimals: decimals), tint: .liquidGlassLabBlue)
                Spacer()
            }
            Slider(value: value, in: range, step: step)
        }
    }

    func formatted(_ value: Double, decimals: Int) -> String {
        String(format: "%.\(decimals)f", value)
    }

    func twoColumnPicker<Value: Identifiable & Hashable>(
        title: String,
        selection: Binding<Value>,
        values: [Value]
    ) -> some View where Value.ID == String {
        VStack(alignment: .leading, spacing: Spacing.half) {
            labelText(title)
            Picker(title, selection: selection) {
                ForEach(values) { value in
                    Text(valueTitle(value)).tag(value)
                }
            }
            .pickerStyle(.menu)
        }
    }

    func optionGrid<Value: Identifiable & Hashable>(
        title: String,
        selection: Binding<Value>,
        values: [Value],
        minimumWidth: CGFloat
    ) -> some View where Value.ID == String {
        VStack(alignment: .leading, spacing: Spacing.half) {
            labelText(title)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumWidth), spacing: Spacing.half)], spacing: Spacing.half) {
                ForEach(values) { value in
                    let isSelected = selection.wrappedValue == value
                    Button {
                        withAnimation(.snappy) {
                            selection.wrappedValue = value
                        }
                    } label: {
                        Text(valueTitle(value))
                            .font(AppTypography.captionMedium)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, Spacing.half)
                            .padding(.vertical, 8)
                            .foregroundStyle(isSelected ? Color.white : Color.textPrimary)
                            .background(
                                isSelected ? Color.brand : Color.surfaceNested,
                                in: RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                                    .stroke(isSelected ? Color.brand.opacity(0.24) : Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    func valueTitle<Value>(_ value: Value) -> String {
        switch value {
        case let option as PreviewScene:
            return option.title
        case let option as BackgroundKind:
            return option.title
        case let option as SchemeMode:
            return option.title
        case let option as GlassVariant:
            return option.title
        case let option as GlassShapeOption:
            return option.title
        case let option as TintOption:
            return option.title
        case let option as MaterialStyle:
            return option.title
        case let option as BlendModeOption:
            return option.title
        case let option as BackgroundSampling:
            return option.title
        default:
            return "\(value)"
        }
    }

    func presetRow(_ preset: LiquidGlassLabTestViewModel.Preset) -> some View {
        HStack(spacing: Spacing.base) {
            VStack(alignment: .leading, spacing: 3) {
                Text(preset.name)
                    .font(AppTypography.captionMedium)
                    .foregroundStyle(Color.textPrimary)
                Text("Glass \(preset.parameters.glassVariant.title) · \(preset.parameters.materialStyle.title) · Corner \(viewModel.format(preset.parameters.cornerRadius))")
                    .font(AppTypography.caption2)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                withAnimation(.snappy) {
                    viewModel.applyPreset(preset)
                }
            } label: {
                Image(systemName: "arrow.down.circle")
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("加载预设")

            Button {
                viewModel.deletePreset(preset)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(Color.feedbackError)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("删除预设")
        }
        .padding(.vertical, Spacing.half)
    }

    func screenshotCard(_ record: LiquidGlassLabTestViewModel.ScreenshotRecord) -> some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            Group {
                if let url = viewModel.screenshotURL(for: record),
                   let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Color.surfaceNested
                        Image(systemName: "photo")
                            .font(AppTypography.title3)
                            .foregroundStyle(Color.textHint)
                    }
                }
            }
            .frame(height: 96)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous))

            Text(record.title)
                .font(AppTypography.captionMedium)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
            Text("\(record.previewScene.title) · \(record.backgroundKind.title) · \(record.sizeDescription)")
                .font(AppTypography.caption2)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(2)

            Button {
                viewModel.deleteScreenshot(record)
            } label: {
                Label("删除截图", systemImage: "trash")
                    .font(AppTypography.caption2)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.feedbackError)
        }
        .padding(Spacing.half)
        .background(Color.surfaceNested, in: RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous))
    }

    func doubleBinding(_ keyPath: WritableKeyPath<Parameters, Double>) -> Binding<Double> {
        Binding(
            get: { viewModel.parameters[keyPath: keyPath] },
            set: { newValue in
                viewModel.parameters[keyPath: keyPath] = newValue
                viewModel.markParametersEdited()
            }
        )
    }

    func parameterBinding<Value>(_ keyPath: WritableKeyPath<Parameters, Value>) -> Binding<Value> {
        Binding(
            get: { viewModel.parameters[keyPath: keyPath] },
            set: { newValue in
                viewModel.parameters[keyPath: keyPath] = newValue
                viewModel.markParametersEdited()
            }
        )
    }

    func sceneBinding() -> Binding<PreviewScene> {
        Binding(
            get: { viewModel.previewScene },
            set: { viewModel.setPreviewScene($0) }
        )
    }

    func backgroundBinding() -> Binding<BackgroundKind> {
        Binding(
            get: { viewModel.backgroundKind },
            set: { viewModel.setBackgroundKind($0) }
        )
    }

    func schemeBinding() -> Binding<SchemeMode> {
        Binding(
            get: { viewModel.schemeMode },
            set: { viewModel.setSchemeMode($0) }
        )
    }
}

private struct LiquidGlassPreviewStage: View {
    @Bindable var viewModel: LiquidGlassLabTestViewModel
    @Binding var snapshotAnchorView: UIView?

    var body: some View {
        ZStack {
            TimelineView(.animation) { timeline in
                let phase = timeline.date.timeIntervalSinceReferenceDate

                ZStack {
                    LiquidGlassLabBackground(
                        kind: viewModel.backgroundKind,
                        samples: viewModel.bookSamples,
                        phase: phase
                    )

                    switch viewModel.previewScene {
                    case .readability:
                        readabilityScene(phase: phase)
                    case .controls:
                        controlsScene(phase: phase)
                    case .matrix:
                        matrixScene(phase: phase)
                    case .scrollReactive:
                        scrollReactiveScene(phase: phase)
                    }
                }
                .id(viewModel.previewRefreshID)
            }

            SnapshotAnchorView { view in
                if snapshotAnchorView !== view {
                    snapshotAnchorView = view
                }
            }
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity)
        .frame(height: viewModel.previewScene == .scrollReactive ? 620 : 520)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.containerLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.containerLarge, style: .continuous)
                .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
        }
        .animation(.snappy, value: viewModel.previewScene)
        .animation(.snappy, value: viewModel.backgroundKind)
    }
}

private extension LiquidGlassPreviewStage {
    func readabilityScene(phase: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            HStack(alignment: .top, spacing: Spacing.base) {
                LiquidGlassDebugSurface(
                    parameters: viewModel.parameters,
                    reactiveProgress: viewModel.scrollReactiveProgress,
                    phase: phase
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        glassLabel("生产基线")
                        Text("图片背景上的文字可读性")
                            .font(AppTypography.title3Semibold)
                            .foregroundStyle(.white.opacity(0.96 + viewModel.parameters.vibrancy * 0.03))
                        Text("用于观察轻量 tint、shadow 与 border light 对正文稳定性的影响。")
                            .font(AppTypography.caption)
                            .foregroundStyle(.white.opacity(0.78 + viewModel.parameters.vibrancy * 0.12))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                LiquidGlassDebugSurface(
                    parameters: compactParameters(cornerRadius: 18),
                    reactiveProgress: viewModel.scrollReactiveProgress,
                    phase: phase
                ) {
                    VStack(spacing: 4) {
                        Text("92%")
                            .font(AppTypography.brandDisplay(size: 30, relativeTo: .title2))
                            .foregroundStyle(.white)
                        Text("Readable")
                            .font(AppTypography.caption2Medium)
                            .foregroundStyle(.white.opacity(0.76))
                    }
                    .frame(minWidth: 88)
                }
            }

            Spacer(minLength: 0)

            HStack(alignment: .bottom, spacing: Spacing.base) {
                LiquidGlassDebugSurface(
                    parameters: compactParameters(cornerRadius: 22),
                    reactiveProgress: viewModel.scrollReactiveProgress,
                    phase: phase
                ) {
                    Label("浅色图片", systemImage: "sun.max")
                        .font(AppTypography.captionMedium)
                        .foregroundStyle(.white)
                }

                LiquidGlassDebugSurface(
                    parameters: compactParameters(cornerRadius: 22),
                    reactiveProgress: viewModel.scrollReactiveProgress,
                    phase: phase + 0.7
                ) {
                    Label("深色图片", systemImage: "moon.stars")
                        .font(AppTypography.captionMedium)
                        .foregroundStyle(.white)
                }

                Spacer()
            }
        }
        .padding(Spacing.contentEdge)
    }

    func controlsScene(phase: TimeInterval) -> some View {
        ZStack {
            VStack {
                LiquidGlassToolbar(parameters: viewModel.parameters, phase: phase, title: "Toolbar")
                Spacer()
            }
            .padding(Spacing.contentEdge)

            HStack {
                Spacer()
                LiquidGlassRoundAction(systemName: "wand.and.stars", parameters: viewModel.parameters, phase: phase)
                    .offset(
                        x: sin(phase) * 14 * viewModel.parameters.motionParallax,
                        y: cos(phase * 0.7) * 18 * viewModel.parameters.motionParallax
                    )
            }
            .padding(Spacing.contentEdge)

            VStack {
                Spacer()
                LiquidGlassBottomBar(parameters: viewModel.parameters, phase: phase)
            }
            .padding(Spacing.contentEdge)
        }
    }

    func matrixScene(phase: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            HStack {
                glassLabel("多组件同时对照")
                Spacer()
                Text(viewModel.nativeParameterSummary)
                    .font(AppTypography.caption2)
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 138), spacing: Spacing.base)], spacing: Spacing.base) {
                ForEach(LiquidGlassLabTestViewModel.BackgroundKind.allCases) { kind in
                    ZStack {
                        LiquidGlassLabBackground(kind: kind, samples: viewModel.bookSamples, phase: phase)
                        VStack(alignment: .leading, spacing: Spacing.half) {
                            Text(kind.title)
                                .font(AppTypography.captionMedium)
                                .foregroundStyle(.white)
                            LiquidGlassDebugSurface(
                                parameters: compactParameters(cornerRadius: 18),
                                reactiveProgress: 0,
                                phase: phase
                            ) {
                                Label("Aa", systemImage: "sparkle.magnifyingglass")
                                    .font(AppTypography.captionMedium)
                                    .foregroundStyle(.white)
                            }
                            LiquidGlassToolbar(parameters: compactParameters(cornerRadius: 16), phase: phase, title: "Mini")
                        }
                        .padding(Spacing.half)
                    }
                    .frame(height: 138)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
                }
            }
        }
        .padding(Spacing.contentEdge)
    }

    func scrollReactiveScene(phase: TimeInterval) -> some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: LiquidGlassScrollOffsetKey.self,
                        value: proxy.frame(in: .named("LiquidGlassScrollSpace")).minY
                    )
                }
                .frame(height: 0)

                VStack(spacing: Spacing.base) {
                    ForEach(0..<16, id: \.self) { index in
                        LiquidGlassScrollRow(index: index)
                    }
                }
                .padding(Spacing.contentEdge)
                .padding(.bottom, 116)
            }
            .coordinateSpace(name: "LiquidGlassScrollSpace")
            .onPreferenceChange(LiquidGlassScrollOffsetKey.self) { offset in
                viewModel.updateScrollOffset(offset)
            }

            LinearGradient(
                colors: [.clear, .black.opacity(0.22), .black.opacity(0.38)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 160)
            .allowsHitTesting(false)

            LiquidGlassBottomBar(
                parameters: viewModel.parameters,
                phase: phase,
                reactiveProgress: viewModel.scrollReactiveProgress
            )
            .padding(.horizontal, Spacing.contentEdge)
            .padding(.bottom, Spacing.contentEdge)
        }
    }

    func compactParameters(cornerRadius: Double) -> LiquidGlassLabTestViewModel.GlassLabParameters {
        var copy = viewModel.parameters
        copy.cornerRadius = cornerRadius
        copy.containerSpacing = min(copy.containerSpacing, 20)
        return copy
    }

    func glassLabel(_ text: String) -> some View {
        Text(text)
            .font(AppTypography.caption2Semibold)
            .foregroundStyle(.white.opacity(0.82))
            .padding(.horizontal, Spacing.half)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.16), in: Capsule())
    }
}

private struct LiquidGlassDebugSurface<Content: View>: View {
    let parameters: LiquidGlassLabTestViewModel.GlassLabParameters
    var reactiveProgress: Double = 0
    var phase: TimeInterval = 0
    @ViewBuilder let content: Content

    var body: some View {
        let shape = LiquidGlassLabShape(option: parameters.glassShape, cornerRadius: parameters.cornerRadius)
        let reactiveBoost = reactiveProgress * parameters.scrollReactiveEffects
        let parallaxX = sin(phase * 0.9) * 8 * parameters.motionParallax
        let parallaxY = cos(phase * 0.7) * 6 * parameters.motionParallax

        content
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background {
                simulatedBackground(shape: shape, reactiveBoost: reactiveBoost)
            }
            .overlay {
                simulatedForeground(shape: shape, reactiveBoost: reactiveBoost)
            }
            .saturation(parameters.saturation + reactiveBoost * 0.12)
            .brightness(parameters.brightness + reactiveBoost * parameters.dynamicBrightnessAdaptation * 0.08)
            .contrast(parameters.contrast)
            .opacity(parameters.opacity)
            .shadow(
                color: Color.black.opacity(parameters.shadow),
                radius: 18 * parameters.shadow,
                x: 0,
                y: 10 * parameters.shadow
            )
            .scaleEffect(parameters.backdropScale)
            .offset(x: parallaxX, y: parallaxY)
            .blendMode(parameters.blendMode.swiftUIBlendMode)
            .liquidGlassNativeEffect(parameters: parameters, shape: shape)
    }

    @ViewBuilder
    private func simulatedBackground(shape: LiquidGlassLabShape, reactiveBoost: Double) -> some View {
        ZStack {
            if parameters.backgroundSampling != .nativeOnly {
                materialFill(shape)
                    .opacity(materialOpacity)
                    .blur(radius: parameters.blurRadius)
            }

            shape.fill(parameters.tint.colorValue.opacity(parameters.tintOpacity + reactiveBoost * 0.08))

            shape.fill(Color.white.opacity(parameters.frostedLayerDepth * 0.12))

            if parameters.backgroundSampling == .expanded {
                shape
                    .stroke(Color.white.opacity(parameters.borderLight + reactiveBoost * 0.10), lineWidth: 10 * parameters.glassThickness)
                    .blur(radius: parameters.blurRadius * 0.35)
                    .opacity(0.38)
            }
        }
        .compositingGroup()
    }

    @ViewBuilder
    private func simulatedForeground(shape: LiquidGlassLabShape, reactiveBoost: Double) -> some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.white.opacity(parameters.highlightIntensity + reactiveBoost * 0.12),
                    Color.white.opacity(0),
                    Color.black.opacity(parameters.glassThickness * 0.10)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .clipShape(shape)

            LinearGradient(
                colors: [
                    Color.white.opacity(parameters.reflectionStrength),
                    Color.white.opacity(0)
                ],
                startPoint: .topTrailing,
                endPoint: .center
            )
            .clipShape(shape)
            .blendMode(.screen)

            LiquidGlassNoiseTexture(intensity: parameters.noise)
                .clipShape(shape)
                .blendMode(.overlay)

            shape
                .stroke(Color.white.opacity(parameters.borderLight + parameters.edgeGlow), lineWidth: 1 + 2 * parameters.glassThickness)

            shape
                .stroke(Color.white.opacity(parameters.edgeGlow), lineWidth: 8)
                .blur(radius: 7)
                .opacity(parameters.edgeGlow)
        }
        .allowsHitTesting(false)
    }

    private var materialOpacity: Double {
        switch parameters.materialStyle {
        case .ultraThin:
            return 0.22
        case .thin:
            return 0.32
        case .regular:
            return 0.44
        case .thick:
            return 0.56
        }
    }

    @ViewBuilder
    private func materialFill(_ shape: LiquidGlassLabShape) -> some View {
        switch parameters.materialStyle {
        case .ultraThin:
            shape.fill(.ultraThinMaterial)
        case .thin:
            shape.fill(.thinMaterial)
        case .regular:
            shape.fill(.regularMaterial)
        case .thick:
            shape.fill(.thickMaterial)
        }
    }
}

private struct LiquidGlassToolbar: View {
    let parameters: LiquidGlassLabTestViewModel.GlassLabParameters
    let phase: TimeInterval
    var title: String

    var body: some View {
        GlassEffectContainer(spacing: parameters.containerSpacing) {
            HStack(spacing: Spacing.half) {
                LiquidGlassRoundAction(systemName: "line.3.horizontal.decrease", parameters: parameters, phase: phase)
                LiquidGlassDebugSurface(parameters: parameters, phase: phase) {
                    Text(title)
                        .font(AppTypography.captionMedium)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                if parameters.usesMorphingProbe {
                    LiquidGlassRoundAction(systemName: "sparkles", parameters: parameters, phase: phase)
                        .transition(.scale.combined(with: .opacity))
                }
                LiquidGlassRoundAction(systemName: "slider.horizontal.3", parameters: parameters, phase: phase)
            }
        }
    }
}

private struct LiquidGlassBottomBar: View {
    let parameters: LiquidGlassLabTestViewModel.GlassLabParameters
    let phase: TimeInterval
    var reactiveProgress: Double = 0

    var body: some View {
        GlassEffectContainer(spacing: parameters.containerSpacing) {
            HStack(spacing: Spacing.half) {
                barButton("textformat", "Text")
                barButton("photo", "Image")
                barButton("square.and.arrow.down", "Save")
                barButton("camera.metering.matrix", "Shot")
            }
            .padding(.horizontal, Spacing.half)
            .padding(.vertical, Spacing.half)
            .background(Color.black.opacity(0.06), in: Capsule())
        }
    }

    func barButton(_ systemName: String, _ title: String) -> some View {
        LiquidGlassDebugSurface(parameters: compactParameters, reactiveProgress: reactiveProgress, phase: phase) {
            VStack(spacing: 3) {
                Image(systemName: systemName)
                    .font(AppTypography.callout)
                Text(title)
                    .font(AppTypography.caption2)
            }
            .foregroundStyle(.white)
            .frame(minWidth: 48)
        }
    }

    var compactParameters: LiquidGlassLabTestViewModel.GlassLabParameters {
        var copy = parameters
        copy.glassShape = .capsule
        copy.cornerRadius = 28
        return copy
    }
}

private struct LiquidGlassRoundAction: View {
    let systemName: String
    let parameters: LiquidGlassLabTestViewModel.GlassLabParameters
    let phase: TimeInterval

    var body: some View {
        var copy = parameters
        copy.glassShape = .circle
        copy.cornerRadius = 26
        return LiquidGlassDebugSurface(parameters: copy, phase: phase) {
            Image(systemName: systemName)
                .font(AppTypography.callout)
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
        }
        .accessibilityLabel(Text(systemName))
    }
}

private struct LiquidGlassScrollRow: View {
    let index: Int

    var body: some View {
        HStack(spacing: Spacing.base) {
            RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                .fill(Color.white.opacity(index.isMultiple(of: 2) ? 0.22 : 0.14))
                .frame(width: 48, height: 62)
                .overlay {
                    Image(systemName: index.isMultiple(of: 2) ? "book.closed" : "doc.text")
                        .foregroundStyle(.white.opacity(0.82))
                }

            VStack(alignment: .leading, spacing: 5) {
                Text("滚动内容样本 \(index + 1)")
                    .font(AppTypography.captionMedium)
                    .foregroundStyle(.white)
                Text("用于观察底部玻璃栏在滚动位移、背景复杂度和动态亮度下的稳定性。")
                    .font(AppTypography.caption2)
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(Spacing.base)
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
    }
}

private struct LiquidGlassLabBackground: View {
    let kind: LiquidGlassLabTestViewModel.BackgroundKind
    let samples: [LiquidGlassLabTestViewModel.BookCoverSample]
    let phase: TimeInterval

    var body: some View {
        switch kind {
        case .solid:
            Color(light: Color(hex: 0xEFF6F2), dark: Color(hex: 0x151B18))
        case .gradient:
            LinearGradient(
                colors: [
                    Color.brand.opacity(0.50),
                    Color.liquidGlassLabBlue.opacity(0.42),
                    Color.liquidGlassLabOrange.opacity(0.26),
                    Color.surfacePage
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .lowComplexity:
            lowComplexityBackground
        case .highComplexity:
            highComplexityBackground
        case .dynamicImage:
            dynamicBackground
        case .bookMosaic:
            bookMosaicBackground
        }
    }

    var lowComplexityBackground: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: 0xDAF3E4), Color(hex: 0xF7F2DA), Color(hex: 0xD7EAF7)],
                startPoint: .top,
                endPoint: .bottom
            )
            Circle()
                .fill(Color.brand.opacity(0.20))
                .frame(width: 220, height: 220)
                .offset(x: -120, y: -140)
            RoundedRectangle(cornerRadius: 60, style: .continuous)
                .fill(Color.liquidGlassLabBlue.opacity(0.18))
                .frame(width: 260, height: 190)
                .rotationEffect(.degrees(-14))
                .offset(x: 110, y: 120)
        }
    }

    var highComplexityBackground: some View {
        Canvas { context, size in
            let base = Path(CGRect(origin: .zero, size: size))
            context.fill(base, with: .linearGradient(
                Gradient(colors: [Color(hex: 0x17324D), Color(hex: 0x2E6F74), Color(hex: 0xF1C36B)]),
                startPoint: .zero,
                endPoint: CGPoint(x: size.width, y: size.height)
            ))

            for index in 0..<48 {
                let x = pseudoRandom(index, salt: 3) * size.width
                let y = pseudoRandom(index, salt: 11) * size.height
                let width = 30 + pseudoRandom(index, salt: 19) * 140
                let height = 18 + pseudoRandom(index, salt: 29) * 120
                let rect = CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height)
                let hue = pseudoRandom(index, salt: 37)
                let color = Color(
                    hue: hue,
                    saturation: 0.35 + pseudoRandom(index, salt: 41) * 0.55,
                    brightness: 0.45 + pseudoRandom(index, salt: 47) * 0.45
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 18),
                    with: .color(color.opacity(0.26))
                )
            }
        }
    }

    var dynamicBackground: some View {
        ZStack {
            highComplexityBackground
            AngularGradient(
                colors: [
                    Color.white.opacity(0.22),
                    Color.brand.opacity(0.18),
                    Color.liquidGlassLabBlue.opacity(0.20),
                    Color.liquidGlassLabOrange.opacity(0.20),
                    Color.white.opacity(0.22)
                ],
                center: .center,
                angle: .degrees(phase.truncatingRemainder(dividingBy: 12) * 30)
            )
            .scaleEffect(1.5)
            .blur(radius: 18)
            .blendMode(.screen)
        }
    }

    var bookMosaicBackground: some View {
        GeometryReader { proxy in
            let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 5)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(0..<25, id: \.self) { index in
                    XMBookCover.fixedSize(
                        width: max(48, proxy.size.width / 5 - 10),
                        height: max(70, proxy.size.height / 5 - 8),
                        urlString: coverURL(at: index),
                        cornerRadius: CornerRadius.inlaySmall,
                        border: .init(color: .white.opacity(0.18), width: CardStyle.borderWidth),
                        placeholderIconSize: .hidden,
                        surfaceStyle: .spine
                    )
                    .opacity(0.90)
                }
            }
            .padding(8)
            .frame(width: proxy.size.width, height: proxy.size.height)
            .background(Color.surfaceNested)
            .overlay {
                LinearGradient(
                    colors: [Color.black.opacity(0.18), Color.black.opacity(0.34)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
    }

    func coverURL(at index: Int) -> String {
        guard !samples.isEmpty else { return "" }
        return samples[index % samples.count].urlString
    }

    func pseudoRandom(_ index: Int, salt: Int) -> Double {
        let value = sin(Double(index * 73 + salt * 97)) * 43758.5453
        return value - floor(value)
    }
}

private struct LiquidGlassNoiseTexture: View {
    let intensity: Double

    var body: some View {
        Canvas { context, size in
            guard intensity > 0 else { return }
            for index in 0..<120 {
                let x = pseudoRandom(index, salt: 5) * size.width
                let y = pseudoRandom(index, salt: 13) * size.height
                let radius = 0.6 + pseudoRandom(index, salt: 21) * 1.8
                let rect = CGRect(x: x, y: y, width: radius, height: radius)
                context.fill(Path(ellipseIn: rect), with: .color(Color.white.opacity(intensity)))
            }
        }
    }

    func pseudoRandom(_ index: Int, salt: Int) -> Double {
        let value = sin(Double(index * 41 + salt * 17)) * 92821.331
        return value - floor(value)
    }
}

private struct LiquidGlassLabShape: Shape {
    let option: LiquidGlassLabTestViewModel.GlassShapeOption
    let cornerRadius: Double

    func path(in rect: CGRect) -> Path {
        switch option {
        case .capsule:
            return Capsule(style: .continuous).path(in: rect)
        case .roundedRect:
            return RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).path(in: rect)
        case .circle:
            return Circle().path(in: rect)
        }
    }
}

private struct LiquidGlassFPSProbe: UIViewRepresentable {
    let onFrame: (CFTimeInterval) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFrame: onFrame)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        context.coordinator.start()
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onFrame = onFrame
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        var onFrame: (CFTimeInterval) -> Void
        private var displayLink: CADisplayLink?

        init(onFrame: @escaping (CFTimeInterval) -> Void) {
            self.onFrame = onFrame
        }

        func start() {
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(frameDidTick(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        func stop() {
            displayLink?.invalidate()
            displayLink = nil
        }

        @objc private func frameDidTick(_ link: CADisplayLink) {
            onFrame(link.timestamp)
        }
    }
}

private struct SnapshotAnchorView: UIViewRepresentable {
    let onResolve: (UIView) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        context.coordinator.resolve(view, onResolve: onResolve)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.resolve(uiView, onResolve: onResolve)
    }

    final class Coordinator {
        private weak var resolvedView: UIView?

        func resolve(_ view: UIView, onResolve: @escaping (UIView) -> Void) {
            guard resolvedView !== view else { return }
            resolvedView = view
            DispatchQueue.main.async {
                onResolve(view)
            }
        }
    }
}

private struct LiquidGlassScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private extension View {
    @ViewBuilder
    func liquidGlassNativeEffect(
        parameters: LiquidGlassLabTestViewModel.GlassLabParameters,
        shape: LiquidGlassLabShape
    ) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(configuredGlass(parameters), in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }

    @available(iOS 26.0, *)
    func configuredGlass(_ parameters: LiquidGlassLabTestViewModel.GlassLabParameters) -> Glass {
        let base: Glass
        switch parameters.glassVariant {
        case .regular:
            base = .regular
        case .clear:
            base = .clear
        case .identity:
            base = .identity
        }

        let tinted = base.tint(parameters.tint.optionalColor)
        return parameters.isInteractive ? tinted.interactive() : tinted
    }
}

private extension LiquidGlassLabTestViewModel.TintOption {
    var optionalColor: Color? {
        switch self {
        case .none:
            return nil
        case .white:
            return .white
        case .brand:
            return .brand
        case .blue:
            return .liquidGlassLabBlue
        case .amber:
            return .liquidGlassLabOrange
        case .black:
            return .black
        }
    }

    var colorValue: Color {
        optionalColor ?? .white
    }
}

private extension LiquidGlassLabTestViewModel.BlendModeOption {
    var swiftUIBlendMode: BlendMode {
        switch self {
        case .normal:
            return .normal
        case .screen:
            return .screen
        case .overlay:
            return .overlay
        case .multiply:
            return .multiply
        case .plusLighter:
            return .plusLighter
        }
    }
}

private extension LiquidGlassLabTestViewModel.SchemeMode {
    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}

private extension Color {
    static let liquidGlassLabBlue = Color(uiColor: .systemBlue)
    static let liquidGlassLabOrange = Color(uiColor: .systemOrange)
}

#Preview {
    NavigationStack {
        LiquidGlassLabTestView()
    }
}
#endif
