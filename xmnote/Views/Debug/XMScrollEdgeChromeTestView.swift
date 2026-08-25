#if DEBUG
/**
 * [INPUT]: 依赖 XMScrollEdgeChrome、XMScrollEdgeWash 与 DesignTokens，提供滚动边缘柔化层的多场景 Debug 验证样本
 * [OUTPUT]: 对外提供 XMScrollEdgeChromeTestView，集中验证顶部/底部/双向边界、背景、强度、高度、深色模式与点击穿透行为
 * [POS]: Debug 测试页，仅用于滚动边缘基础设施接入真实页面前的可视化验证
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

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
                                .foregroundStyle(Color.brandDeep)
                                .frame(width: 28, height: 28)
                                .background(Color.brand.opacity(0.12), in: Circle())

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
                .foregroundStyle(Color.brand)
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
            .stroke(Color.surfaceBorderSubtle.opacity(0.56), lineWidth: CardStyle.borderWidth)
    }
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
