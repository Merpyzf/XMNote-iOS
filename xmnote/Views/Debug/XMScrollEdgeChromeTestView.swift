#if DEBUG
/**
 * [INPUT]: 依赖 XMScrollEdgeChrome、XMScrollEdgeWash、XMSystemScrollEdgeRegistration 与 DesignTokens，提供系统原生和局部滚动边缘的多场景 Debug 验证样本
 * [OUTPUT]: 对外提供 XMScrollEdgeChromeTestView，集中验证 SwiftUI/UIKit 顶部/底部/双向系统边缘，以及局部 Wash 的背景、强度、深色模式与点击穿透行为
 * [POS]: Debug 测试页，仅用于滚动边缘基础设施接入真实页面前的可视化验证
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 滚动边缘覆盖层测试页，验证基础组件在固定栏、普通滚动区和不同表层背景下的表现。
struct XMScrollEdgeChromeTestView: View {
    @State private var lastTapped = "尚未点击"
    @State private var controlledWashEdges = XMScrollEdgeWashEdges.hidden

    private let strengths: [XMScrollEdgeWashStrength] = [.subtle, .regular, .prominent]
    private let heights: [CGFloat] = [16, 24, 36]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.base) {
                introCard
                systemNativeSection
                topEdgeSection
                bottomEdgeSection
                bothEdgesSection
                backgroundSection
                matrixSection
                darkModeSection
                controlledSection
                tapStatusCard
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
        }
        .background(Color.surfacePage)
        .navigationTitle("滚动边缘覆盖层")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var systemNativeSection: some View {
        XMScrollEdgeDemoCard(title: "系统原生安全区") {
            VStack(alignment: .leading, spacing: Spacing.cozy) {
                Text("以下样本在独立页面验证真实 NavigationStack、安全区和单一滚动 owner，不使用 Wash 或自绘柔化层。")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)

                systemDemoLink(
                    title: "SwiftUI 原生滚动",
                    subtitle: "直接验证顶部、底部与双边缘 soft 过渡"
                ) {
                    XMSystemScrollEdgeSwiftUIDemo()
                }

                systemDemoLink(
                    title: "UIKit 窄桥接",
                    subtitle: "验证 UIViewRepresentable 注册、重建与安全释放"
                ) {
                    XMSystemScrollEdgeUIKitDemo()
                }
            }
        }
    }

    private var introCard: some View {
        XMScrollEdgeDemoCard(title: "组件语义") {
            VStack(alignment: .leading, spacing: Spacing.cozy) {
                Text("XMScrollEdgeWash 用于滚动视口边缘的柔和收口，不承载交互语义，不替代系统导航栏或 Sheet 的 scrollEdgeEffectStyle。")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                Text("静止顶部时自动隐藏顶部 wash；底部 wash 用于提示内容仍可继续滚动。")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
            }
        }
    }

    private var topEdgeSection: some View {
        XMScrollEdgeDemoCard(title: "顶部边界") {
            XMScrollEdgeChrome(
                presentation: .contained,
                edges: .top,
                washStyle: .standard,
                topBar: {
                    fixedHeader("固定筛选栏", subtitle: "列表从下方开始，滚动后顶缘柔化")
                }
            ) {
                demoScrollList(surface: .page, rowPrefix: "Top")
            }
            .frame(height: 340)
            .background(Color.surfacePage)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
            .overlay(demoBorder)
        }
    }

    private var bottomEdgeSection: some View {
        XMScrollEdgeDemoCard(title: "底部边界") {
            XMScrollEdgeChrome(
                presentation: .contained,
                edges: .bottom,
                washStyle: .standard,
                bottomBar: {
                    fixedFooter("底部工具条")
                }
            ) {
                demoScrollList(surface: .page, rowPrefix: "Bottom")
            }
            .frame(height: 340)
            .background(Color.surfacePage)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
            .overlay(demoBorder)
        }
    }

    private var bothEdgesSection: some View {
        XMScrollEdgeDemoCard(title: "顶部 + 底部") {
            demoScrollList(surface: .card, rowPrefix: "Both")
                .xmScrollEdgeWash(
                    edges: [.top, .bottom],
                    style: XMScrollEdgeWashStyle(height: 24, strength: .regular, surface: .card)
                )
                .frame(height: 300)
                .background(Color.surfaceCard)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
                .overlay(demoBorder)
        }
    }

    private var backgroundSection: some View {
        XMScrollEdgeDemoCard(title: "不同背景") {
            VStack(spacing: Spacing.base) {
                ForEach(XMScrollEdgeDemoSurface.allCases) { surface in
                    VStack(alignment: .leading, spacing: Spacing.half) {
                        Text(surface.title)
                            .font(AppTypography.captionMedium)
                            .foregroundStyle(Color.textSecondary)
                            .padding(.horizontal, Spacing.compact)

                        demoScrollList(surface: surface, rowPrefix: surface.title)
                            .xmScrollEdgeWash(
                                edges: [.top, .bottom],
                                style: XMScrollEdgeWashStyle(height: 24, strength: .regular, surface: surface.washSurface)
                            )
                            .frame(height: 220)
                            .background(surface.background)
                            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
                            .overlay(demoBorder)
                    }
                }
            }
        }
    }

    private var matrixSection: some View {
        XMScrollEdgeDemoCard(title: "高度与强度矩阵") {
            VStack(spacing: Spacing.base) {
                ForEach(heights, id: \.self) { height in
                    VStack(alignment: .leading, spacing: Spacing.half) {
                        Text("\(Int(height))pt")
                            .font(AppTypography.captionMedium)
                            .foregroundStyle(Color.textSecondary)
                            .padding(.horizontal, Spacing.compact)

                        HStack(spacing: Spacing.cozy) {
                            ForEach(strengths, id: \.debugTitle) { strength in
                                staticSwatch(
                                    title: strength.debugTitle,
                                    style: XMScrollEdgeWashStyle(height: height, strength: strength, surface: .page)
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private var darkModeSection: some View {
        XMScrollEdgeDemoCard(title: "深色模式") {
            VStack(alignment: .leading, spacing: Spacing.half) {
                Text("使用同一 API，在深色语义色下观察顶部与底部收口")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)

                demoScrollList(surface: .page, rowPrefix: "Dark")
                    .xmScrollEdgeWash(
                        edges: [.top, .bottom],
                        style: XMScrollEdgeWashStyle(height: 24, strength: .regular, surface: .page)
                    )
                    .frame(height: 260)
                    .background(Color.surfacePage)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
                    .overlay(demoBorder)
                    .environment(\.colorScheme, .dark)
            }
        }
    }

    private var controlledSection: some View {
        XMScrollEdgeDemoCard(title: "外部状态控制") {
            VStack(alignment: .leading, spacing: Spacing.half) {
                Text("模拟 UIKit bridge 主动上报顶部与底部滚动状态，验证 controlled 模式复用同一套柔化层。")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)

                HStack(spacing: Spacing.base) {
                    Toggle("顶部", isOn: controlledTopBinding)
                    Toggle("底部", isOn: controlledBottomBinding)
                }
                .font(AppTypography.captionMedium)

                demoScrollList(surface: .page, rowPrefix: "Controlled")
                    .xmScrollEdgeWash(
                        edges: [.top, .bottom],
                        style: XMScrollEdgeWashStyle(height: 24, strength: .regular, surface: .page),
                        activeEdges: controlledWashEdges
                    )
                    .frame(height: 260)
                    .background(Color.surfacePage)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
                    .overlay(demoBorder)
            }
        }
    }

    private var tapStatusCard: some View {
        XMScrollEdgeDemoCard(title: "点击穿透") {
            Text(lastTapped)
                .font(AppTypography.captionMedium)
                .foregroundStyle(Color.textSecondary)
        }
    }

    private func demoScrollList(
        surface: XMScrollEdgeDemoSurface,
        rowPrefix: String
    ) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: Spacing.cozy) {
                ForEach(1...28, id: \.self) { index in
                    Button {
                        lastTapped = "\(rowPrefix) 第 \(index) 行已点击"
                    } label: {
                        HStack(spacing: Spacing.cozy) {
                            Text("\(index)")
                                .font(AppTypography.caption2Semibold)
                                .foregroundStyle(Color.selectionForeground)
                                .frame(width: 28, height: 28)
                                .background(Color.selectionAccent.opacity(0.12), in: Circle())

                            VStack(alignment: .leading, spacing: Spacing.tiny) {
                                Text("滚动边缘样本行")
                                    .font(AppTypography.subheadlineMedium)
                                    .foregroundStyle(Color.textPrimary)
                                Text(index.isMultiple(of: 3) ? "靠近边界时观察文字是否被明显污染" : "可点击行，用于验证 wash 不拦截交互")
                                    .font(AppTypography.caption)
                                    .foregroundStyle(Color.textSecondary)
                                    .lineLimit(1)
                            }

                            Spacer()
                        }
                        .padding(Spacing.cozy)
                        .background(surface.rowBackground, in: RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(Spacing.base)
        }
    }

    private func fixedHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tiny) {
            Text(title)
                .font(AppTypography.subheadlineSemibold)
                .foregroundStyle(Color.textPrimary)
            Text(subtitle)
                .font(AppTypography.caption)
                .foregroundStyle(Color.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.base)
        .background(Color.surfaceCard)
    }

    private func fixedFooter(_ title: String) -> some View {
        HStack {
            Image(systemName: "slider.horizontal.3")
                .font(AppTypography.body)
                .foregroundStyle(Color.appTint)
            Text(title)
                .font(AppTypography.subheadlineSemibold)
                .foregroundStyle(Color.textPrimary)
            Spacer()
            Text("固定")
                .font(AppTypography.captionMedium)
                .foregroundStyle(Color.textSecondary)
        }
        .padding(Spacing.base)
        .background(Color.surfaceCard)
    }

    private func systemDemoLink<Destination: View>(
        title: String,
        subtitle: String,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink(destination: destination()) {
            HStack(spacing: Spacing.cozy) {
                VStack(alignment: .leading, spacing: Spacing.tiny) {
                    Text(title)
                        .font(AppTypography.subheadlineMedium)
                        .foregroundStyle(Color.textPrimary)
                    Text(subtitle)
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.forward")
                    .font(AppTypography.captionSemibold)
                    .foregroundStyle(Color.iconSecondary)
                    .accessibilityHidden(true)
            }
            .padding(Spacing.cozy)
            .frame(minHeight: InteractionMetrics.minimumTouchTarget)
            .background(
                Color.surfaceNested,
                in: RoundedRectangle(
                    cornerRadius: CornerRadius.blockSmall,
                    style: .continuous
                )
            )
        }
        .buttonStyle(.plain)
    }

    private func staticSwatch(title: String, style: XMScrollEdgeWashStyle) -> some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            Text(title)
                .font(AppTypography.caption2Medium)
                .foregroundStyle(Color.textSecondary)

            VStack(spacing: Spacing.tiny) {
                ForEach(0..<5, id: \.self) { index in
                    RoundedRectangle(cornerRadius: CornerRadius.inlayMedium, style: .continuous)
                        .fill(index.isMultiple(of: 2) ? Color.surfaceCard : Color.surfaceNested)
                        .frame(height: 14)
                }
            }
            .padding(Spacing.cozy)
            .xmScrollEdgeWash(edges: [.top, .bottom], style: style, visibility: .always)
            .frame(height: 96)
            .background(Color.surfacePage)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))
            .overlay(demoBorder)
        }
        .frame(maxWidth: .infinity)
    }

    private var controlledTopBinding: Binding<Bool> {
        Binding(
            get: { controlledWashEdges.top },
            set: { isActive in
                controlledWashEdges = XMScrollEdgeWashEdges(
                    top: isActive,
                    bottom: controlledWashEdges.bottom
                )
            }
        )
    }

    private var controlledBottomBinding: Binding<Bool> {
        Binding(
            get: { controlledWashEdges.bottom },
            set: { isActive in
                controlledWashEdges = XMScrollEdgeWashEdges(
                    top: controlledWashEdges.top,
                    bottom: isActive
                )
            }
        )
    }

    private var demoBorder: some View {
        RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
            .stroke(Color.surfaceBorderSubtle.opacity(0.56), lineWidth: StrokeWidth.hairline)
    }
}

private struct XMSystemScrollEdgeSwiftUIDemo: View {
    @State private var selectedEdges = XMSystemScrollEdgeDemoEdges.both

    var body: some View {
        ScrollView {
            XMSystemScrollEdgeDemoRows(prefix: "SwiftUI")
        }
        .background(Color.surfacePage)
        .ignoresSafeArea(.container, edges: selectedEdges.swiftUIEdges)
        .modifier(
            XMSystemScrollEdgeDemoBottomBarModifier(
                isEnabled: selectedEdges.includesBottom
            )
        )
        .scrollEdgeEffectStyle(.soft, for: selectedEdges.swiftUIEdges)
        .navigationTitle("SwiftUI 系统边缘")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                systemEdgeMenu(selection: $selectedEdges)
            }
        }
    }
}

private struct XMSystemScrollEdgeUIKitDemo: View {
    @State private var selectedEdges = XMSystemScrollEdgeDemoEdges.both

    var body: some View {
        XMSystemScrollEdgeUIKitRepresentable(edges: selectedEdges.uiKitEdges)
            .id(selectedEdges)
            .background(Color.surfacePage)
            .ignoresSafeArea(.container, edges: selectedEdges.swiftUIEdges)
            .modifier(
                XMSystemScrollEdgeDemoBottomBarModifier(
                    isEnabled: selectedEdges.includesBottom
                )
            )
            .navigationTitle("UIKit 系统边缘")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    systemEdgeMenu(selection: $selectedEdges)
                }
            }
    }
}

private struct XMSystemScrollEdgeUIKitRepresentable: UIViewRepresentable {
    let edges: UIRectEdge

    /// 创建具备真实滚动内容和系统栏观察生命周期的 UIKit 验证宿主。
    func makeUIView(context: Context) -> XMSystemScrollEdgeUIKitHostView {
        XMSystemScrollEdgeUIKitHostView(edges: edges)
    }

    /// 边缘切换通过稳定枚举 ID 重建宿主，避免在验证中混合两套注册器。
    func updateUIView(_ uiView: XMSystemScrollEdgeUIKitHostView, context: Context) {}

    /// 拆卸 representable 时显式释放系统栏观察关系。
    static func dismantleUIView(
        _ uiView: XMSystemScrollEdgeUIKitHostView,
        coordinator: ()
    ) {
        uiView.prepareForReuse()
    }
}

private final class XMSystemScrollEdgeUIKitHostView: UIScrollView {
    private let systemScrollEdgeRegistration: XMSystemScrollEdgeRegistration

    /// 构造使用系统安全区调整的纵向 UIScrollView 样本。
    init(edges: UIRectEdge) {
        systemScrollEdgeRegistration = XMSystemScrollEdgeRegistration(edges: edges)
        super.init(frame: .zero)
        alwaysBounceVertical = true
        showsVerticalScrollIndicator = true
        contentInsetAdjustmentBehavior = .always
        backgroundColor = UIColor(Color.surfacePage)
        installRows()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 入窗时建立、离窗时释放系统栏观察关系。
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            systemScrollEdgeRegistration.invalidate()
        } else {
            systemScrollEdgeRegistration.update(scrollView: self)
        }
    }

    /// 布局变化时幂等确认系统仍观察当前滚动视图。
    override func layoutSubviews() {
        super.layoutSubviews()
        systemScrollEdgeRegistration.update(scrollView: self)
    }

    /// 供 UIViewRepresentable 拆卸时主动释放系统栏关系。
    func prepareForReuse() {
        systemScrollEdgeRegistration.invalidate()
    }

    /// 使用原生 Auto Layout 构造足够跨越上下安全区的验证内容。
    private func installRows() {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = Spacing.cozy
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(
            top: Spacing.base,
            left: Spacing.screenEdge,
            bottom: Spacing.base,
            right: Spacing.screenEdge
        )
        stack.translatesAutoresizingMaskIntoConstraints = false

        for index in 1...30 {
            let label = UILabel()
            label.font = UIFont.preferredFont(forTextStyle: .body)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = UIColor(Color.textPrimary)
            label.backgroundColor = UIColor(Color.surfaceCard)
            label.text = "UIKit 系统滚动样本 \(index)"
            label.layer.cornerRadius = CornerRadius.blockSmall
            label.layer.cornerCurve = .continuous
            label.clipsToBounds = true
            label.layoutMargins = UIEdgeInsets(
                top: Spacing.cozy,
                left: Spacing.base,
                bottom: Spacing.cozy,
                right: Spacing.base
            )
            let minimumHeight = label.heightAnchor.constraint(
                greaterThanOrEqualToConstant: InteractionMetrics.minimumTouchTarget
            )
            minimumHeight.isActive = true
            stack.addArrangedSubview(label)
        }

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: frameLayoutGuide.widthAnchor)
        ])
    }
}

private struct XMSystemScrollEdgeDemoRows: View {
    let prefix: String

    var body: some View {
        LazyVStack(spacing: Spacing.cozy) {
            ForEach(1...30, id: \.self) { index in
                Text("\(prefix) 系统滚动样本 \(index)")
                    .font(AppTypography.body)
                    .foregroundStyle(Color.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.base)
                    .background(
                        Color.surfaceCard,
                        in: RoundedRectangle(
                            cornerRadius: CornerRadius.blockSmall,
                            style: .continuous
                        )
                    )
            }
        }
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.vertical, Spacing.base)
    }
}

private struct XMSystemScrollEdgeDemoBottomBarModifier: ViewModifier {
    let isEnabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.safeAreaBar(edge: .bottom, spacing: Spacing.none) {
                HStack(spacing: Spacing.cozy) {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(Color.iconPrimary)
                    Text("系统 Bottom Bar")
                        .font(AppTypography.subheadlineMedium)
                        .foregroundStyle(Color.textPrimary)
                    Spacer()
                    Text("Soft")
                        .font(AppTypography.captionMedium)
                        .foregroundStyle(Color.textSecondary)
                }
                .padding(.horizontal, Spacing.screenEdge)
                .frame(minHeight: InteractionMetrics.minimumTouchTarget)
            }
        } else {
            content
        }
    }
}

private enum XMSystemScrollEdgeDemoEdges: String, CaseIterable, Identifiable {
    case top = "顶部"
    case bottom = "底部"
    case both = "双边缘"

    var id: Self { self }

    var swiftUIEdges: Edge.Set {
        switch self {
        case .top:
            return .top
        case .bottom:
            return .bottom
        case .both:
            return [.top, .bottom]
        }
    }

    var uiKitEdges: UIRectEdge {
        switch self {
        case .top:
            return .top
        case .bottom:
            return .bottom
        case .both:
            return [.top, .bottom]
        }
    }

    var includesBottom: Bool {
        self != .top
    }
}

private func systemEdgeMenu(
    selection: Binding<XMSystemScrollEdgeDemoEdges>
) -> some View {
    Menu {
        Picker("系统边缘", selection: selection) {
            ForEach(XMSystemScrollEdgeDemoEdges.allCases) { edges in
                Text(edges.rawValue).tag(edges)
            }
        }
    } label: {
        Text(selection.wrappedValue.rawValue)
    }
    .accessibilityLabel("选择系统滚动边缘")
}

private struct XMScrollEdgeDemoCard<Content: View>: View {
    let title: String
    let content: Content

    /// 注入测试标题与内容，按 Debug 页面统一卡片节奏承载滚动边缘样本。
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            Text(title)
                .font(AppTypography.footnoteSemibold)
                .foregroundStyle(Color.textSecondary)
                .padding(.horizontal, Spacing.compact)

            CardContainer {
                content
                    .padding(Spacing.contentEdge)
            }
        }
    }
}

private enum XMScrollEdgeDemoSurface: CaseIterable, Identifiable {
    case page
    case card
    case sheet
    case custom

    var id: Self { self }

    var title: String {
        switch self {
        case .page:
            return "Page"
        case .card:
            return "Card"
        case .sheet:
            return "Sheet"
        case .custom:
            return "Custom"
        }
    }

    var washSurface: XMScrollEdgeWashSurface {
        switch self {
        case .page:
            return .page
        case .card:
            return .card
        case .sheet:
            return .sheet
        case .custom:
            return .custom(background)
        }
    }

    var background: Color {
        switch self {
        case .page:
            return Color.surfacePage
        case .card:
            return Color.surfaceCard
        case .sheet:
            return Color.surfaceSheet
        case .custom:
            return Color.xmAdaptive(light: Color.xmHex(0xEEF4F1), dark: Color.xmHex(0x17201C))
        }
    }

    var rowBackground: Color {
        switch self {
        case .page:
            return Color.surfaceCard
        case .card:
            return Color.surfaceNested
        case .sheet:
            return Color.surfaceCard
        case .custom:
            return Color.xmAdaptive(light: Color.white.opacity(0.74), dark: Color.white.opacity(0.08))
        }
    }
}

private extension XMScrollEdgeWashStrength {
    var debugTitle: String {
        switch self {
        case .subtle:
            return "Subtle"
        case .regular:
            return "Regular"
        case .prominent:
            return "Prominent"
        }
    }
}

#Preview {
    NavigationStack {
        XMScrollEdgeChromeTestView()
    }
}
#endif
