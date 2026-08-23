/**
 * [INPUT]: 依赖 SwiftUI ButtonStyle、iOS 26 原生 clear interactive Liquid Glass 与 DesignTokens 尺寸能力
 * [OUTPUT]: 对外提供 TopBarActionPill、TopBarActionPresentation 与顶部工具按钮展示样式扩展
 * [POS]: UIComponents/TopBar 的顶部右侧双按钮胶囊组件，以 36pt 单层交互玻璃承载两个 44pt action 热区
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 顶部工具按钮的展示位置，用于区分独立按钮与胶囊内 segment。
enum TopBarActionPresentation: Equatable {
    case standalone
    case pillSegment
}

extension View {
    /// 按展示位置附加顶部工具按钮样式，保证独立圆按钮与胶囊 segment 使用同一套交互规则。
    @ViewBuilder
    func topBarActionPresentationStyle(_ presentation: TopBarActionPresentation, enabled: Bool = true) -> some View {
        switch presentation {
        case .standalone:
            topBarActionButtonStyle(enabled)
        case .pillSegment:
            topBarActionPillSegmentStyle(enabled)
        }
    }

    /// 为顶部胶囊内单个 segment 移除额外按钮动效，由父级原生交互玻璃统一反馈。
    func topBarActionPillSegmentStyle(_: Bool) -> some View {
        buttonStyle(.plain)
    }
}

/// 顶部双 action 胶囊组，承载两个同权重按钮并提供统一材质底。
struct TopBarActionPill<Leading: View, Trailing: View>: View {
    let leading: Leading
    let trailing: Trailing

    /// 注入左右两个顶部 action，组合为同权重胶囊工具组。
    init(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: TopBarActionPillMetrics.buttonSpacing) {
            leading
            divider
            trailing
        }
        .padding(.horizontal, TopBarActionPillMetrics.horizontalPadding)
        .frame(height: TopBarActionPillMetrics.hitSize)
        .background(pillBackground)
        .accessibilityElement(children: .contain)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(TopBarActionPillMetrics.dividerOpacity))
            .frame(
                width: TopBarActionPillMetrics.borderWidth,
                height: TopBarActionPillMetrics.dividerHeight
            )
            .accessibilityHidden(true)
    }

    private var pillBackground: some View {
        Color.clear
            .frame(height: TopBarActionPillMetrics.height)
            .glassEffect(.clear.interactive(), in: .capsule)
    }
}

private enum TopBarActionPillMetrics {
    static let height: CGFloat = 36
    static let hitSize: CGFloat = Spacing.actionReserved
    static let horizontalPadding: CGFloat = 2
    static let buttonSpacing: CGFloat = 0
    static let dividerOpacity = 0.06
    static let dividerHeight: CGFloat = 12
    static let borderWidth: CGFloat = 1
}
