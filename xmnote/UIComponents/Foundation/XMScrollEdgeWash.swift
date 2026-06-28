/**
 * [INPUT]: 依赖 SwiftUI ScrollGeometry、Material 与 DesignTokens 语义表层色
 * [OUTPUT]: 对外提供 XMScrollEdgeWashStyle、XMScrollEdgeWashStrength、XMScrollEdgeWashSurface、XMScrollEdgeWashEdges、XMScrollEdgeWashVisibility 与 View.xmScrollEdgeWash 滚动边缘柔化能力
 * [POS]: UIComponents/Foundation 的滚动边缘柔化基础设施，被固定筛选栏、底部工具栏与卡片内滚动视口复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 滚动边缘柔化层的强度等级，控制材质采样和语义底色渐隐的存在感。
enum XMScrollEdgeWashStrength {
    case subtle
    case regular
    case prominent

    var materialOpacity: Double {
        switch self {
        case .subtle:
            return 0.18
        case .regular:
            return 0.32
        case .prominent:
            return 0.46
        }
    }

    var surfaceStartOpacity: Double {
        switch self {
        case .subtle:
            return 0.82
        case .regular:
            return 0.94
        case .prominent:
            return 1
        }
    }

    var surfaceMidOpacity: Double {
        switch self {
        case .subtle:
            return 0.50
        case .regular:
            return 0.72
        case .prominent:
            return 0.86
        }
    }
}

/// 滚动边缘柔化层采样后的承托表层，保证浅色、深色和嵌套卡片场景使用对应语义底色。
enum XMScrollEdgeWashSurface {
    case page
    case card
    case sheet
    case custom(Color)

    var color: Color {
        switch self {
        case .page:
            return Color.surfacePage
        case .card:
            return Color.surfaceCard
        case .sheet:
            return Color.surfaceSheet
        case .custom(let color):
            return color
        }
    }
}

/// 滚动边缘柔化层的外部可见状态，用于 UIKit bridge 或自定义滚动容器主动驱动边缘显隐。
struct XMScrollEdgeWashEdges: Equatable {
    static let hidden = XMScrollEdgeWashEdges()

    var top: Bool
    var bottom: Bool

    /// 配置顶部与底部柔化层是否处于激活状态。
    init(top: Bool = false, bottom: Bool = false) {
        self.top = top
        self.bottom = bottom
    }
}

/// 滚动边缘柔化层的可见性策略，区分随滚动状态显示、外部控制、始终显示与完全关闭。
enum XMScrollEdgeWashVisibility {
    case automatic
    case controlled(XMScrollEdgeWashEdges)
    case always
    case hidden
}

/// 滚动边缘柔化层的视觉规格，保持 API 克制，只暴露高度、强度和表层语义。
struct XMScrollEdgeWashStyle {
    static let standard = XMScrollEdgeWashStyle()

    let height: CGFloat
    let strength: XMScrollEdgeWashStrength
    let surface: XMScrollEdgeWashSurface

    /// 配置柔化层高度、强度与承托表层，默认适配页面级滚动列表。
    init(
        height: CGFloat = 24,
        strength: XMScrollEdgeWashStrength = .regular,
        surface: XMScrollEdgeWashSurface = .page
    ) {
        self.height = height
        self.strength = strength
        self.surface = surface
    }
}

extension View {
    /// 为滚动视口添加顶部、底部或双向柔化层；装饰层不参与点击和无障碍。
    func xmScrollEdgeWash(
        edges: Edge.Set = .top,
        style: XMScrollEdgeWashStyle = .standard,
        visibility: XMScrollEdgeWashVisibility = .automatic
    ) -> some View {
        modifier(
            XMScrollEdgeWashModifier(
                edges: edges,
                style: style,
                visibility: visibility
            )
        )
    }

    /// 使用外部滚动状态控制柔化层显隐，适合 UIKit bridge 或自定义滚动容器。
    func xmScrollEdgeWash(
        edges: Edge.Set = .top,
        style: XMScrollEdgeWashStyle = .standard,
        activeEdges: XMScrollEdgeWashEdges
    ) -> some View {
        xmScrollEdgeWash(
            edges: edges,
            style: style,
            visibility: .controlled(activeEdges)
        )
    }
}

private struct XMScrollEdgeWashModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let edges: Edge.Set
    let style: XMScrollEdgeWashStyle
    let visibility: XMScrollEdgeWashVisibility

    @State private var automaticEdges = XMScrollEdgeWashEdges.hidden

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: XMScrollEdgeWashEdges.self) { geometry in
                guard isAutomaticVisibility else { return .hidden }
                return XMScrollEdgeWashEdges(
                    top: shouldShowTopWash(geometry),
                    bottom: shouldShowBottomWash(geometry)
                )
            } action: { _, newValue in
                guard automaticEdges != newValue else { return }
                automaticEdges = newValue
            }
            .overlay(alignment: .top) {
                if edges.contains(.top) {
                    XMScrollEdgeWashLayer(edge: .top, style: style)
                        .opacity(isVisible(.top) ? 1 : 0)
                        .animation(edgeAnimation, value: resolvedActiveEdges)
                }
            }
            .overlay(alignment: .bottom) {
                if edges.contains(.bottom) {
                    XMScrollEdgeWashLayer(edge: .bottom, style: style)
                        .opacity(isVisible(.bottom) ? 1 : 0)
                        .animation(edgeAnimation, value: resolvedActiveEdges)
                }
            }
    }

    private var isAutomaticVisibility: Bool {
        if case .automatic = visibility {
            return true
        }
        return false
    }

    private var resolvedActiveEdges: XMScrollEdgeWashEdges {
        switch visibility {
        case .automatic:
            return automaticEdges
        case .controlled(let controlledEdges):
            return controlledEdges
        case .always:
            return XMScrollEdgeWashEdges(
                top: edges.contains(.top),
                bottom: edges.contains(.bottom)
            )
        case .hidden:
            return .hidden
        }
    }

    private var edgeAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: 0.16)
    }

    private func shouldShowTopWash(_ geometry: ScrollGeometry) -> Bool {
        guard edges.contains(.top) else { return false }
        return geometry.contentOffset.y + geometry.contentInsets.top > Spacing.hairline
    }

    private func shouldShowBottomWash(_ geometry: ScrollGeometry) -> Bool {
        guard edges.contains(.bottom) else { return false }
        return geometry.contentSize.height - geometry.visibleRect.maxY > Spacing.hairline
    }

    private func isVisible(_ edge: VerticalEdge) -> Bool {
        switch edge {
        case .top:
            return edges.contains(.top) && resolvedActiveEdges.top
        case .bottom:
            return edges.contains(.bottom) && resolvedActiveEdges.bottom
        }
    }
}

private struct XMScrollEdgeWashLayer: View {
    let edge: VerticalEdge
    let style: XMScrollEdgeWashStyle

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(style.strength.materialOpacity)

            LinearGradient(
                colors: [
                    style.surface.color.opacity(style.strength.surfaceStartOpacity),
                    style.surface.color.opacity(style.strength.surfaceMidOpacity),
                    style.surface.color.opacity(0)
                ],
                startPoint: gradientStart,
                endPoint: gradientEnd
            )
        }
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black.opacity(0.86), location: 0.42),
                    .init(color: .clear, location: 1)
                ],
                startPoint: gradientStart,
                endPoint: gradientEnd
            )
        }
        .frame(height: style.height)
        .frame(maxWidth: .infinity, alignment: edge == .top ? .top : .bottom)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var gradientStart: UnitPoint {
        edge == .top ? .top : .bottom
    }

    private var gradientEnd: UnitPoint {
        edge == .top ? .bottom : .top
    }
}
