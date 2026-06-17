#if DEBUG
import SwiftUI

/**
 * [INPUT]: 依赖 HomeTopHeaderGradient、CardContainer、DesignTokens 与 SwiftUI Material 能力模拟首页顶部 action icon 场景
 * [OUTPUT]: 对外提供 TopBarActionStyleLabTestView（顶部工具按钮样式调参页）
 * [POS]: Debug 测试页，仅用于顶部右侧工具按钮在真实首页渐变背景上的层级、材质、描边与按压反馈调参
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

struct TopBarActionStyleLabTestView: View {
    @State private var parameters = TopBarActionStyleLabParameters()
    @State private var schemeMode: TopBarActionStyleLabScheme = .system
    @State private var showsScopeSelector = true
    @State private var showsReferenceCards = true
    @State private var reduceMotionPreview = false

    var body: some View {
        VStack(spacing: 0) {
            pinnedPreviewPane
                .zIndex(1)

            ScrollView {
                VStack(spacing: Spacing.base) {
                    contextSection
                    sizeSection
                    pillSection
                    backgroundSection
                    borderSection
                    iconSection
                    pressSection
                    summarySection
                }
                .padding(.horizontal, Spacing.screenEdge)
                .padding(.top, Spacing.base)
                .padding(.bottom, Spacing.base)
                .safeAreaPadding(.bottom)
            }
        }
        .background(Color.surfacePage)
        .navigationTitle("顶部工具按钮")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(schemeMode.colorScheme)
    }
}

private extension TopBarActionStyleLabTestView {
    var pinnedPreviewPane: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            sectionHeader(
                "真实顶部背景预览",
                subtitle: "复用 HomeTopHeaderGradient，对照独立圆与 Pill 胶囊两种顶部 action 关系。"
            )

            TopBarActionStylePreviewStage(
                parameters: parameters,
                showsScopeSelector: showsScopeSelector,
                showsReferenceCards: showsReferenceCards,
                reduceMotionPreview: reduceMotionPreview
            )
        }
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.top, Spacing.base)
        .padding(.bottom, Spacing.base)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            Color.surfacePage
        }
        .overlay(alignment: .bottom) {
            LinearGradient(
                colors: [
                    Color.black.opacity(0.05),
                    Color.black.opacity(0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 10)
            .offset(y: 10)
            .allowsHitTesting(false)
        }
    }

    var contextSection: some View {
        debugCard("预览上下文") {
            pickerRow("外观模式", selection: $schemeMode, values: TopBarActionStyleLabScheme.allCases)
            Toggle("显示分段选择器参照物", isOn: $showsScopeSelector)
            Toggle("显示内容卡片参照物", isOn: $showsReferenceCards)
        }
    }

    var sizeSection: some View {
        debugCard("尺寸与位置") {
            sliderRow("视觉圆直径", value: $parameters.visualSize, range: 28...44, step: 1, decimals: 0, tag: "pt")
            sliderRow("触控热区", value: $parameters.hitSize, range: 44...58, step: 1, decimals: 0, tag: "pt")
            sliderRow("图标字号", value: $parameters.iconSize, range: 12...20, step: 1, decimals: 0, tag: "pt")
            sliderRow("按钮间距", value: $parameters.buttonSpacing, range: 0...18, step: 1, decimals: 0, tag: "pt")
            sliderRow("顶部偏移", value: $parameters.topOffset, range: -18...28, step: 1, decimals: 0, tag: "pt")
        }
    }

    var pillSection: some View {
        debugCard("Pill 胶囊") {
            sliderRow("胶囊高度", value: $parameters.pillHeight, range: 32...52, step: 1, decimals: 0, tag: "pt")
            sliderRow("横向内边距", value: $parameters.pillHorizontalPadding, range: 0...12, step: 1, decimals: 0, tag: "pt")
            sliderRow("内部间距", value: $parameters.pillButtonSpacing, range: 0...12, step: 1, decimals: 0, tag: "pt")
            sliderRow("胶囊圆角", value: $parameters.pillCornerRadius, range: 12...26, step: 1, decimals: 0, tag: "pt")
            sliderRow("分隔线 Opacity", value: $parameters.pillDividerOpacity, range: 0...0.36, step: 0.01, tag: "线")
            sliderRow("分隔线高度", value: $parameters.pillDividerHeight, range: 8...28, step: 1, decimals: 0, tag: "pt")
        }
    }

    var backgroundSection: some View {
        debugCard("背景材质") {
            pickerRow("背景类型", selection: $parameters.backgroundStyle, values: TopBarActionStyleLabBackgroundStyle.allCases)
            sliderRow("白色 Wash", value: $parameters.whiteWashOpacity, range: 0...0.32, step: 0.01, tag: "白")
            sliderRow("黑色 Wash", value: $parameters.blackWashOpacity, range: 0...0.22, step: 0.01, tag: "黑")
        }
    }

    var borderSection: some View {
        debugCard("边界与高光") {
            sliderRow("描边 Opacity", value: $parameters.borderOpacity, range: 0...0.42, step: 0.01, tag: "线")
            sliderRow("描边宽度", value: $parameters.borderWidth, range: 0...2, step: 0.1, tag: "pt")
            sliderRow("内高光", value: $parameters.innerHighlightOpacity, range: 0...0.28, step: 0.01, tag: "光")
        }
    }

    var iconSection: some View {
        debugCard("图标表现") {
            pickerRow("图标颜色", selection: $parameters.iconColor, values: TopBarActionStyleLabIconColor.allCases)
            sliderRow("图标 Opacity", value: $parameters.iconOpacity, range: 0.42...1.00, step: 0.01, tag: "透明")
        }
    }

    var pressSection: some View {
        debugCard("按压反馈") {
            Toggle("模拟 Reduce Motion", isOn: $reduceMotionPreview)
            Toggle("Reduce Motion 下禁用缩放", isOn: $parameters.disablesScaleWhenReduceMotion)
            sliderRow("按压 Scale", value: $parameters.pressedScale, range: 0.88...1.00, step: 0.01, tag: "压")
            sliderRow("品牌反馈", value: $parameters.pressedBrandOpacity, range: 0...0.26, step: 0.01, tag: "绿")
        }
    }

    var summarySection: some View {
        debugCard("参数摘要") {
            Text(parameters.codeSummary)
                .font(AppTypography.caption2)
                .monospaced()
                .foregroundStyle(Color.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .accessibilityLabel("当前顶部工具按钮参数摘要")
        }
    }

    func debugCard<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        CardContainer(showsBorder: true, borderColor: .surfaceBorderSubtle) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text(title)
                    .font(AppTypography.headlineSemibold)
                    .foregroundStyle(Color.textPrimary)
                content()
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

    func pickerRow<Value: CaseIterable & Identifiable & Hashable & TopBarActionStyleLabOptionTitle>(
        _ title: String,
        selection: Binding<Value>,
        values: [Value]
    ) -> some View where Value.ID == String {
        VStack(alignment: .leading, spacing: Spacing.half) {
            Text(title)
                .font(AppTypography.captionMedium)
                .foregroundStyle(Color.textSecondary)
            Picker(title, selection: selection) {
                ForEach(values) { value in
                    Text(value.title).tag(value)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    func sliderRow(
        _ title: String,
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
                Text("\(formatted(value.wrappedValue, decimals: decimals)) \(tag)")
                    .font(AppTypography.caption2Semibold)
                    .foregroundStyle(Color.brandDeep)
                    .padding(.horizontal, Spacing.half)
                    .padding(.vertical, 4)
                    .background(Color.brand.opacity(0.10), in: Capsule())
                Spacer()
            }
            Slider(value: value, in: range, step: step)
                .tint(Color.brand)
        }
    }

    func formatted(_ value: Double, decimals: Int) -> String {
        String(format: "%.\(decimals)f", value)
    }
}

private struct TopBarActionStylePreviewStage: View {
    let parameters: TopBarActionStyleLabParameters
    let showsScopeSelector: Bool
    let showsReferenceCards: Bool
    let reduceMotionPreview: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color.surfacePage
            HomeTopHeaderGradient()

            VStack(spacing: 0) {
                toolbarStack
                    .padding(.top, 24 + CGFloat(parameters.topOffset))

                if showsScopeSelector {
                    scopeSelector
                        .padding(.top, 22)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }

                if showsReferenceCards {
                    referenceCards
                        .padding(.top, Spacing.base)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.screenEdge)
        }
        .frame(height: 388)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
        }
        .animation(.snappy(duration: 0.16), value: showsScopeSelector)
        .animation(.snappy(duration: 0.16), value: showsReferenceCards)
    }

    private var toolbarStack: some View {
        VStack(spacing: 14) {
            TopBarActionStyleLabToolbarRow(
                style: .separate,
                parameters: parameters,
                reduceMotionPreview: reduceMotionPreview
            )

            TopBarActionStyleLabToolbarRow(
                style: .pill,
                parameters: parameters,
                reduceMotionPreview: reduceMotionPreview
            )
        }
    }

    private var scopeSelector: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.controlFillSecondary.opacity(0.46))
                .overlay {
                    Capsule()
                        .stroke(Color.surfaceBorderSubtle.opacity(0.18), lineWidth: CardStyle.borderWidth)
                }

            HStack(spacing: 0) {
                Capsule()
                    .fill(Color.surfaceCard)
                    .overlay {
                        Capsule()
                            .stroke(Color.white.opacity(0.46), lineWidth: CardStyle.borderWidth)
                    }
                    .frame(maxWidth: .infinity)

                Color.clear.frame(maxWidth: .infinity)
            }
            .padding(4)

            HStack(spacing: 0) {
                Text("我的书单  2")
                    .font(AppTypography.subheadlineSemibold)
                    .foregroundStyle(Color.textPrimary)
                    .frame(maxWidth: .infinity)
                Text("年度书单  7")
                    .font(AppTypography.subheadlineSemibold)
                    .foregroundStyle(Color.textSecondary)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, Spacing.base)
        }
        .frame(height: 48)
    }

    private var referenceCards: some View {
        HStack(spacing: Spacing.base) {
            referenceCard(title: "操作层", subtitle: "按钮是否抢层级")
            referenceCard(title: "内容层", subtitle: "卡片对比关系")
        }
    }

    private func referenceCard(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            Text(title)
                .font(AppTypography.headlineSemibold)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
            Text(subtitle)
                .font(AppTypography.caption)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
        }
        .padding(Spacing.contentEdge)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                .stroke(Color.surfaceBorderSubtle.opacity(0.38), lineWidth: CardStyle.borderWidth)
        }
    }
}

private enum TopBarActionStyleLabToolbarStyle {
    case separate
    case pill
}

private struct TopBarActionStyleLabToolbarRow: View {
    let style: TopBarActionStyleLabToolbarStyle
    let parameters: TopBarActionStyleLabParameters
    let reduceMotionPreview: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            HStack(spacing: Spacing.double) {
                Text("书籍")
                    .font(BookshelfTypography.topUnselected)
                    .foregroundStyle(Color.textHint)
                Text("书单")
                    .font(BookshelfTypography.topSelected)
                    .foregroundStyle(Color.textPrimary)
            }

            Spacer(minLength: Spacing.base)

            actionArea
        }
    }

    @ViewBuilder
    private var actionArea: some View {
        switch style {
        case .separate:
            HStack(spacing: CGFloat(parameters.buttonSpacing)) {
                TopBarActionStyleLabIconButton(
                    systemName: "plus",
                    accessibilityLabel: "新建书单",
                    parameters: parameters,
                    reduceMotionPreview: reduceMotionPreview
                )

                TopBarActionStyleLabIconButton(
                    systemName: "arrow.up.arrow.down",
                    accessibilityLabel: "调整排序",
                    parameters: parameters,
                    reduceMotionPreview: reduceMotionPreview
                )
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("独立圆顶部工具按钮")
        case .pill:
            TopBarActionStyleLabPillButtonGroup(
                parameters: parameters,
                reduceMotionPreview: reduceMotionPreview
            )
        }
    }
}

private struct TopBarActionStyleLabPillButtonGroup: View {
    let parameters: TopBarActionStyleLabParameters
    let reduceMotionPreview: Bool

    var body: some View {
        HStack(spacing: CGFloat(parameters.pillButtonSpacing)) {
            TopBarActionStyleLabPillIconButton(
                systemName: "plus",
                accessibilityLabel: "新建书单",
                parameters: parameters,
                reduceMotionPreview: reduceMotionPreview
            )

            divider

            TopBarActionStyleLabPillIconButton(
                systemName: "arrow.up.arrow.down",
                accessibilityLabel: "调整排序",
                parameters: parameters,
                reduceMotionPreview: reduceMotionPreview
            )
        }
        .padding(.horizontal, CGFloat(parameters.pillHorizontalPadding))
        .frame(height: CGFloat(parameters.hitSize))
        .background {
            if parameters.backgroundStyle != .none {
                pillBackground
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pill 胶囊顶部工具按钮")
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(parameters.pillDividerOpacity))
            .frame(width: max(CGFloat(parameters.borderWidth), CardStyle.borderWidth), height: CGFloat(parameters.pillDividerHeight))
            .accessibilityHidden(true)
    }

    private var pillBackground: some View {
        let shape = RoundedRectangle(cornerRadius: CGFloat(parameters.pillCornerRadius), style: .continuous)

        return materialFill(shape: shape)
            .overlay {
                shape.fill(Color.white.opacity(parameters.whiteWashOpacity))
            }
            .overlay {
                shape.fill(Color.black.opacity(parameters.blackWashOpacity))
            }
            .overlay {
                if parameters.innerHighlightOpacity > 0 {
                    shape.fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(parameters.innerHighlightOpacity),
                                Color.white.opacity(0)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                }
            }
            .overlay {
                shape.stroke(Color.white.opacity(parameters.borderOpacity), lineWidth: parameters.borderWidth)
            }
            .frame(height: CGFloat(parameters.pillHeight))
    }

    @ViewBuilder
    private func materialFill(shape: RoundedRectangle) -> some View {
        switch parameters.backgroundStyle {
        case .none:
            shape.fill(Color.clear)
        case .ultraThin:
            shape.fill(.ultraThinMaterial)
        case .thin:
            shape.fill(.thinMaterial)
        case .regular:
            shape.fill(.regularMaterial)
        }
    }
}

private struct TopBarActionStyleLabPillIconButton: View {
    let systemName: String
    let accessibilityLabel: String
    let parameters: TopBarActionStyleLabParameters
    let reduceMotionPreview: Bool

    var body: some View {
        Button { } label: {
            Image(systemName: systemName)
                .font(.system(size: CGFloat(parameters.iconSize), weight: .medium))
                .foregroundStyle(parameters.iconColor.color.opacity(parameters.iconOpacity))
                .frame(width: CGFloat(parameters.visualSize), height: CGFloat(parameters.visualSize))
                .frame(width: CGFloat(parameters.hitSize), height: CGFloat(parameters.hitSize))
                .contentShape(Rectangle())
        }
        .buttonStyle(TopBarActionStyleLabPillSegmentButtonStyle(parameters: parameters, reduceMotionPreview: reduceMotionPreview))
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct TopBarActionStyleLabPillSegmentButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let parameters: TopBarActionStyleLabParameters
    let reduceMotionPreview: Bool

    func makeBody(configuration: Configuration) -> some View {
        let isPressed = configuration.isPressed
        let disablesScale = parameters.disablesScaleWhenReduceMotion && (reduceMotion || reduceMotionPreview)

        configuration.label
            .background {
                if isPressed && parameters.pressedBrandOpacity > 0 {
                    RoundedRectangle(cornerRadius: segmentCornerRadius, style: .continuous)
                        .fill(Color.brand.opacity(parameters.pressedBrandOpacity))
                        .frame(
                            width: CGFloat(max(parameters.hitSize - 4, parameters.visualSize)),
                            height: CGFloat(max(parameters.pillHeight - 4, parameters.visualSize))
                        )
                }
            }
            .scaleEffect(!disablesScale && isPressed ? parameters.pressedScale : 1)
            .animation(disablesScale ? nil : .snappy(duration: 0.12), value: configuration.isPressed)
    }

    private var segmentCornerRadius: CGFloat {
        max(CGFloat(parameters.pillCornerRadius - parameters.pillHorizontalPadding), 0)
    }
}

private struct TopBarActionStyleLabIconButton: View {
    let systemName: String
    let accessibilityLabel: String
    let parameters: TopBarActionStyleLabParameters
    let reduceMotionPreview: Bool

    var body: some View {
        Button { } label: {
            Image(systemName: systemName)
                .font(.system(size: CGFloat(parameters.iconSize), weight: .medium))
                .foregroundStyle(parameters.iconColor.color.opacity(parameters.iconOpacity))
                .frame(width: CGFloat(parameters.visualSize), height: CGFloat(parameters.visualSize))
                .frame(width: CGFloat(parameters.hitSize), height: CGFloat(parameters.hitSize))
                .contentShape(Circle())
        }
        .buttonStyle(TopBarActionStyleLabButtonStyle(parameters: parameters, reduceMotionPreview: reduceMotionPreview))
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct TopBarActionStyleLabButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let parameters: TopBarActionStyleLabParameters
    let reduceMotionPreview: Bool

    func makeBody(configuration: Configuration) -> some View {
        let isPressed = configuration.isPressed
        let disablesScale = parameters.disablesScaleWhenReduceMotion && (reduceMotion || reduceMotionPreview)

        configuration.label
            .background {
                if parameters.backgroundStyle != .none || isPressed {
                    materialCircle(isPressed: isPressed)
                }
            }
            .scaleEffect(!disablesScale && isPressed ? parameters.pressedScale : 1)
            .animation(disablesScale ? nil : .snappy(duration: 0.12), value: configuration.isPressed)
    }

    @ViewBuilder
    private func materialCircle(isPressed: Bool) -> some View {
        materialFill
            .overlay {
                Circle()
                    .fill(Color.white.opacity(parameters.whiteWashOpacity))
            }
            .overlay {
                Circle()
                    .fill(Color.black.opacity(parameters.blackWashOpacity))
            }
            .overlay {
                if parameters.innerHighlightOpacity > 0 {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(parameters.innerHighlightOpacity),
                                    Color.white.opacity(0)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            }
            .overlay {
                if isPressed && parameters.pressedBrandOpacity > 0 {
                    Circle()
                        .fill(Color.brand.opacity(parameters.pressedBrandOpacity))
                }
            }
            .overlay {
                Circle()
                    .stroke(
                        Color.white.opacity(pressedBorderOpacity(isPressed: isPressed)),
                        lineWidth: parameters.borderWidth
                    )
            }
            .frame(width: CGFloat(parameters.visualSize), height: CGFloat(parameters.visualSize))
    }

    @ViewBuilder
    private var materialFill: some View {
        switch parameters.backgroundStyle {
        case .none:
            Circle().fill(Color.clear)
        case .ultraThin:
            Circle().fill(.ultraThinMaterial)
        case .thin:
            Circle().fill(.thinMaterial)
        case .regular:
            Circle().fill(.regularMaterial)
        }
    }

    private func pressedBorderOpacity(isPressed: Bool) -> Double {
        min(isPressed ? parameters.borderOpacity + 0.06 : parameters.borderOpacity, 1)
    }
}

private struct TopBarActionStyleLabParameters: Equatable {
    var visualSize = 32.0
    var hitSize = 44.0
    var iconSize = 12.0
    var buttonSpacing = 0.0
    var topOffset = 0.0
    var backgroundStyle: TopBarActionStyleLabBackgroundStyle = .regular
    var whiteWashOpacity = 0.32
    var blackWashOpacity = 0.0
    var borderOpacity = 0.30
    var borderWidth = 1.0
    var innerHighlightOpacity = 0.28
    var iconColor: TopBarActionStyleLabIconColor = .semanticPrimary
    var iconOpacity = 0.80
    var pressedScale = 0.95
    var pressedBrandOpacity = 0.12
    var disablesScaleWhenReduceMotion = true
    var pillHeight = 36.0
    var pillHorizontalPadding = 2.0
    var pillButtonSpacing = 0.0
    var pillCornerRadius = 18.0
    var pillDividerOpacity = 0.16
    var pillDividerHeight = 18.0

    var codeSummary: String {
        """
        visualSize = \(format(visualSize))
        hitSize = \(format(hitSize))
        iconSize = \(format(iconSize))
        buttonSpacing = \(format(buttonSpacing))
        topOffset = \(format(topOffset))
        backgroundStyle = \(backgroundStyle.codeName)
        whiteWashOpacity = \(format(whiteWashOpacity, decimals: 2))
        blackWashOpacity = \(format(blackWashOpacity, decimals: 2))
        borderOpacity = \(format(borderOpacity, decimals: 2))
        pressedBorderOpacity = \(format(min(borderOpacity + 0.06, 1), decimals: 2))
        borderWidth = \(format(borderWidth, decimals: 2))
        innerHighlightOpacity = \(format(innerHighlightOpacity, decimals: 2))
        iconColor = \(iconColor.codeName)
        iconOpacity = \(format(iconOpacity, decimals: 2))
        pressedScale = \(format(pressedScale, decimals: 2))
        pressedBrandOpacity = \(format(pressedBrandOpacity, decimals: 2))
        disablesScaleWhenReduceMotion = \(disablesScaleWhenReduceMotion)
        pillHeight = \(format(pillHeight))
        pillHorizontalPadding = \(format(pillHorizontalPadding))
        pillButtonSpacing = \(format(pillButtonSpacing))
        pillCornerRadius = \(format(pillCornerRadius))
        pillDividerOpacity = \(format(pillDividerOpacity, decimals: 2))
        pillDividerHeight = \(format(pillDividerHeight))
        """
    }

    private func format(_ value: Double, decimals: Int = 0) -> String {
        String(format: "%.\(decimals)f", value)
    }
}

private protocol TopBarActionStyleLabOptionTitle {
    var title: String { get }
}

private enum TopBarActionStyleLabBackgroundStyle: String, CaseIterable, Identifiable, Hashable, TopBarActionStyleLabOptionTitle {
    case none
    case ultraThin
    case thin
    case regular

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none:
            return "无底"
        case .ultraThin:
            return "UltraThin"
        case .thin:
            return "Thin"
        case .regular:
            return "Regular"
        }
    }

    var codeName: String {
        switch self {
        case .none:
            return "none"
        case .ultraThin:
            return "ultraThinMaterial"
        case .thin:
            return "thinMaterial"
        case .regular:
            return "regularMaterial"
        }
    }
}

private enum TopBarActionStyleLabIconColor: String, CaseIterable, Identifiable, Hashable, TopBarActionStyleLabOptionTitle {
    case semanticPrimary
    case secondary
    case brand

    var id: String { rawValue }

    var title: String {
        switch self {
        case .semanticPrimary:
            return "语义黑"
        case .secondary:
            return "次级灰"
        case .brand:
            return "品牌绿"
        }
    }

    var color: Color {
        switch self {
        case .semanticPrimary:
            return Color.textPrimary
        case .secondary:
            return Color.textSecondary
        case .brand:
            return Color.brand
        }
    }

    var codeName: String {
        switch self {
        case .semanticPrimary:
            return "Color.textPrimary"
        case .secondary:
            return "Color.textSecondary"
        case .brand:
            return "Color.brand"
        }
    }
}

private enum TopBarActionStyleLabScheme: String, CaseIterable, Identifiable, Hashable, TopBarActionStyleLabOptionTitle {
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
}

#Preview {
    NavigationStack {
        TopBarActionStyleLabTestView()
    }
}
#endif
