/**
 * [INPUT]: 依赖 SwiftUI safeAreaBar / scrollEdgeEffectStyle、XMScrollEdgeWash 与项目 DesignTokens 间距令牌
 * [OUTPUT]: 对外提供 XMScrollEdgeChrome 与 XMScrollEdgeChromePresentation，统一承载固定滚动边缘栏、系统 soft/hard 滚动边缘效果与 contained 模式视口柔化层
 * [POS]: UIComponents/Foundation 的滚动边缘基础组件，服务搜索、Sheet 与存在固定边缘控件的滚动页面
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 滚动边缘 chrome 的呈现语义，区分占位式固定栏与系统浮层式软硬边缘。
enum XMScrollEdgeChromePresentation: Hashable {
    case contained
    case overlaySoft
    case overlayHard
}

/// 承载固定顶部/底部边缘栏的通用滚动容器，按页面语义决定内容是否允许进入固定栏下方。
struct XMScrollEdgeChrome<Content: View, TopBar: View, BottomBar: View>: View {
    let presentation: XMScrollEdgeChromePresentation
    let edges: Edge.Set
    let contentSpacing: CGFloat
    let washStyle: XMScrollEdgeWashStyle

    private let hasTopBar: Bool
    private let hasBottomBar: Bool
    private let content: Content
    private let topBar: TopBar
    private let bottomBar: BottomBar

    /// 注入顶部与底部固定栏，按 presentation 决定固定栏参与布局或使用指定的系统滚动边缘效果。
    init(
        presentation: XMScrollEdgeChromePresentation = .contained,
        edges: Edge.Set = [.top, .bottom],
        contentSpacing: CGFloat = Spacing.none,
        washStyle: XMScrollEdgeWashStyle = .standard,
        @ViewBuilder topBar: () -> TopBar,
        @ViewBuilder bottomBar: () -> BottomBar,
        @ViewBuilder content: () -> Content
    ) {
        self.presentation = presentation
        self.edges = edges
        self.contentSpacing = contentSpacing
        self.washStyle = washStyle
        self.hasTopBar = true
        self.hasBottomBar = true
        self.content = content()
        self.topBar = topBar()
        self.bottomBar = bottomBar()
    }

    /// 注入顶部固定栏，默认使用占位式布局让滚动内容从固定栏下方开始。
    init(
        presentation: XMScrollEdgeChromePresentation = .contained,
        edges: Edge.Set = .top,
        contentSpacing: CGFloat = Spacing.none,
        washStyle: XMScrollEdgeWashStyle = .standard,
        @ViewBuilder topBar: () -> TopBar,
        @ViewBuilder content: () -> Content
    ) where BottomBar == EmptyView {
        self.presentation = presentation
        self.edges = edges
        self.contentSpacing = contentSpacing
        self.washStyle = washStyle
        self.hasTopBar = true
        self.hasBottomBar = false
        self.content = content()
        self.topBar = topBar()
        self.bottomBar = EmptyView()
    }

    /// 注入底部固定栏，默认使用占位式布局让滚动内容在固定栏上方结束。
    init(
        presentation: XMScrollEdgeChromePresentation = .contained,
        edges: Edge.Set = .bottom,
        contentSpacing: CGFloat = Spacing.none,
        washStyle: XMScrollEdgeWashStyle = .standard,
        @ViewBuilder bottomBar: () -> BottomBar,
        @ViewBuilder content: () -> Content
    ) where TopBar == EmptyView {
        self.presentation = presentation
        self.edges = edges
        self.contentSpacing = contentSpacing
        self.washStyle = washStyle
        self.hasTopBar = false
        self.hasBottomBar = true
        self.content = content()
        self.topBar = EmptyView()
        self.bottomBar = bottomBar()
    }

    /// 不注入固定栏，仅作为滚动内容的通用包装容器。
    init(
        presentation: XMScrollEdgeChromePresentation = .contained,
        edges: Edge.Set = [],
        contentSpacing: CGFloat = Spacing.none,
        washStyle: XMScrollEdgeWashStyle = .standard,
        @ViewBuilder content: () -> Content
    ) where TopBar == EmptyView, BottomBar == EmptyView {
        self.presentation = presentation
        self.edges = edges
        self.contentSpacing = contentSpacing
        self.washStyle = washStyle
        self.hasTopBar = false
        self.hasBottomBar = false
        self.content = content()
        self.topBar = EmptyView()
        self.bottomBar = EmptyView()
    }

    var body: some View {
        switch presentation {
        case .contained:
            containedBody
        case .overlaySoft:
            overlayBody(style: .soft)
        case .overlayHard:
            overlayBody(style: .hard)
        }
    }

    private var containedBody: some View {
        VStack(spacing: contentSpacing) {
            if hasTopBar {
                topBar
            }

            content
                .xmScrollEdgeWash(edges: containedWashEdges, style: washStyle)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if hasBottomBar {
                bottomBar
            }
        }
    }

    private var containedWashEdges: Edge.Set {
        var result = Edge.Set()
        if hasTopBar, edges.contains(.top) {
            result.insert(.top)
        }
        if hasBottomBar, edges.contains(.bottom) {
            result.insert(.bottom)
        }
        return result
    }

    private func overlayBody(style: ScrollEdgeEffectStyle) -> some View {
        content
            .modifier(
                XMVerticalSafeAreaBarModifier(
                    edge: .top,
                    isEnabled: hasTopBar,
                    spacing: contentSpacing,
                    bar: topBar
                )
            )
            .modifier(
                XMVerticalSafeAreaBarModifier(
                    edge: .bottom,
                    isEnabled: hasBottomBar,
                    spacing: contentSpacing,
                    bar: bottomBar
                )
            )
            .scrollEdgeEffectStyle(style, for: edges)
    }
}

private struct XMVerticalSafeAreaBarModifier<Bar: View>: ViewModifier {
    let edge: VerticalEdge
    let isEnabled: Bool
    let spacing: CGFloat
    let bar: Bar

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.safeAreaBar(edge: edge, spacing: spacing) {
                bar
            }
        } else {
            content
        }
    }
}
