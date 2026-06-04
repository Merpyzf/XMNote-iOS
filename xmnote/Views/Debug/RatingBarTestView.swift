#if DEBUG
import SwiftUI

/**
 * [INPUT]: 依赖 XMRatingBar 评分基础设施、DesignTokens 语义色与 Debug 页面基础容器
 * [OUTPUT]: 对外提供 RatingBarTestView（评分组件调试页）
 * [POS]: Debug 测试页，集中验证评分组件的尺寸、步进、交互、颜色与浅深色表现
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 评分组件调试页，覆盖只读展示、表单输入、弹窗尺寸和自定义参数组合。
struct RatingBarTestView: View {
    @State private var ratingValue: Double = 3.5
    @State private var step: XMRatingBarStep = .half
    @State private var isIndicator = false
    @State private var backgroundMode: PreviewBackgroundMode = .system
    @State private var starCount = 5
    @State private var customSize: Double = 24
    @State private var customSpacing: Double = 4
    @State private var usesMutedPalette = false

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.base) {
                section("实时预览") {
                    previewPanel
                }

                section("参数") {
                    controlsPanel
                }

                section("场景") {
                    scenarioPanel
                }

                section("固定样本") {
                    samplePanel
                }
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
        }
        .background(Color.surfacePage)
        .navigationTitle("评分组件")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: starCount) { _, newValue in
            ratingValue = min(ratingValue, Double(newValue))
        }
    }

    private var previewPanel: some View {
        previewSurface {
            VStack(alignment: .leading, spacing: Spacing.base) {
                HStack(alignment: .firstTextBaseline) {
                    Text("当前评分")
                        .font(AppTypography.subheadlineMedium)
                        .foregroundStyle(Color.textPrimary)

                    Spacer()

                    VStack(alignment: .trailing, spacing: Spacing.micro) {
                        Text(ratingTitle)
                            .font(AppTypography.subheadlineMedium)
                            .foregroundStyle(ratingValue > 0 ? Color.textPrimary : Color.feedbackError)

                        Text("score = \(scoreValue)")
                            .font(AppTypography.caption)
                            .foregroundStyle(Color.textSecondary)
                            .monospacedDigit()
                    }
                }

                XMRatingBar(
                    value: $ratingValue,
                    starCount: starCount,
                    size: CGFloat(customSize),
                    spacing: CGFloat(customSpacing),
                    step: step,
                    isIndicator: isIndicator,
                    activeColor: activeColor,
                    inactiveColor: inactiveColor
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                Slider(value: $ratingValue, in: 0...Double(starCount), step: step.rawValue)
                    .accessibilityLabel("评分")
            }
        }
    }

    private var controlsPanel: some View {
        CardContainer {
            VStack(spacing: Spacing.base) {
                Picker("步进", selection: $step) {
                    ForEach(XMRatingBarStep.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                Picker("背景", selection: $backgroundMode) {
                    ForEach(PreviewBackgroundMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("只读模式", isOn: $isIndicator)
                    .font(AppTypography.body)

                Toggle("低饱和未激活色", isOn: $usesMutedPalette)
                    .font(AppTypography.body)

                Divider()

                Stepper(value: $starCount, in: 1...10) {
                    controlValueRow("星星数量", value: "\(starCount)")
                }

                controlSlider(
                    title: "星星尺寸",
                    value: $customSize,
                    range: 10...40,
                    displayValue: "\(Int(customSize.rounded()))pt"
                )

                controlSlider(
                    title: "星星间距",
                    value: $customSpacing,
                    range: 0...12,
                    displayValue: "\(Int(customSpacing.rounded()))pt"
                )
            }
            .padding(Spacing.contentEdge)
        }
    }

    private var scenarioPanel: some View {
        CardContainer {
            VStack(spacing: 0) {
                scenarioRow(title: "业务列表小星", subtitle: "只读 14pt / 1pt", rating: 4.5) {
                    XMRatingBar(value: 4.5, preset: .listSmall)
                }

                Divider()

                scenarioRow(title: "表单评分行", subtitle: "交互 20pt / 半星", rating: ratingValue) {
                    XMRatingBar(value: $ratingValue, preset: .form, step: step, isIndicator: isIndicator)
                }

                Divider()

                scenarioRow(title: "弹窗评分条", subtitle: "交互 30pt / 2pt", rating: ratingValue) {
                    XMRatingBar(value: $ratingValue, preset: .dialog, step: step, isIndicator: isIndicator)
                }
            }
        }
    }

    private var samplePanel: some View {
        CardContainer {
            VStack(spacing: Spacing.base) {
                ForEach(Self.sampleRatings, id: \.self) { sample in
                    HStack(spacing: Spacing.base) {
                        Text(String(format: "%.1f", sample))
                            .font(AppTypography.captionMedium)
                            .foregroundStyle(Color.textSecondary)
                            .monospacedDigit()
                            .frame(width: 36, alignment: .leading)

                        XMRatingBar(
                            value: sample,
                            starCount: starCount,
                            preset: .listSmall,
                            activeColor: activeColor,
                            inactiveColor: inactiveColor
                        )

                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Section {
            content()
        } header: {
            Text(title)
                .font(AppTypography.captionSemibold)
                .foregroundStyle(Color.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.micro)
                .padding(.bottom, Spacing.half)
        }
    }

    private func previewSurface<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        CardContainer {
            content()
                .padding(Spacing.contentEdge)
                .background(backgroundMode.backgroundColor, in: RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))
                .environment(\.colorScheme, backgroundMode.colorScheme ?? currentScheme)
        }
    }

    private func scenarioRow<Content: View>(
        title: String,
        subtitle: String,
        rating: Double,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: Spacing.base) {
            VStack(alignment: .leading, spacing: Spacing.micro) {
                Text(title)
                    .font(AppTypography.subheadlineMedium)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)

                Text("\(subtitle) · \(String(format: "%.1f", rating)) 星")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Spacing.base)

            content()
        }
        .padding(Spacing.contentEdge)
    }

    private func controlValueRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(AppTypography.body)
                .foregroundStyle(Color.textPrimary)

            Spacer()

            Text(value)
                .font(AppTypography.body)
                .foregroundStyle(Color.textSecondary)
                .monospacedDigit()
        }
    }

    private func controlSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        displayValue: String
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            controlValueRow(title, value: displayValue)

            Slider(value: value, in: range, step: 1)
                .accessibilityLabel(title)
        }
    }

    @Environment(\.colorScheme) private var currentScheme

    private var ratingTitle: String {
        guard ratingValue > 0 else { return "未评分" }
        return String(format: "%.1f 星", ratingValue)
    }

    private var scoreValue: Int64 {
        Int64((ratingValue * 10).rounded())
    }

    private var activeColor: Color {
        usesMutedPalette ? Color.ratingActive.opacity(0.82) : .ratingActive
    }

    private var inactiveColor: Color {
        usesMutedPalette ? Color.textHint.opacity(0.28) : .ratingInactive
    }

    private static let sampleRatings: [Double] = [0, 0.5, 2.5, 4.5, 5]

    private enum PreviewBackgroundMode: String, CaseIterable, Identifiable {
        case system
        case light
        case dark

        var id: String { rawValue }

        var title: String {
            switch self {
            case .system:
                return "系统"
            case .light:
                return "浅色"
            case .dark:
                return "深色"
            }
        }

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

        var backgroundColor: Color {
            switch self {
            case .system:
                return .surfaceNested
            case .light:
                return Color(hex: 0xFFFFFF)
            case .dark:
                return Color(hex: 0x1C1C1E)
            }
        }
    }
}

#Preview {
    NavigationStack {
        RatingBarTestView()
    }
}
#endif
