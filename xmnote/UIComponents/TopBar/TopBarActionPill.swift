/**
 * [INPUT]: 依赖 SwiftUI ButtonStyle、系统 Material、动态无障碍与 DesignTokens 语义色能力
 * [OUTPUT]: 对外提供 TopBarActionPill、TopBarActionPresentation 与顶部工具按钮展示样式扩展
 * [POS]: UIComponents/TopBar 的顶部右侧双按钮胶囊组件，为一级页面 action 组提供统一材质底与分段按压反馈
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

    /// 为顶部胶囊内单个 segment 附加轻量按压反馈，不绘制静止态背景。
    func topBarActionPillSegmentStyle(_ enabled: Bool) -> some View {
        buttonStyle(TopBarActionPillSegmentPressFeedbackStyle(isEnabled: enabled))
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
            .fill(Color.white.opacity(TopBarActionPillMetrics.dividerOpacity))
            .frame(
                width: TopBarActionPillMetrics.borderWidth,
                height: TopBarActionPillMetrics.dividerHeight
            )
            .accessibilityHidden(true)
    }

    private var pillBackground: some View {
        let shape = RoundedRectangle(
            cornerRadius: TopBarActionPillMetrics.cornerRadius,
            style: .continuous
        )

        return shape
            .fill(.regularMaterial)
            .overlay {
                shape.fill(Color.white.opacity(TopBarActionPillMetrics.whiteWashOpacity))
            }
            .overlay {
                shape.fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(TopBarActionPillMetrics.innerHighlightOpacity),
                            Color.white.opacity(0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            }
            .overlay {
                shape.stroke(
                    Color.white.opacity(TopBarActionPillMetrics.borderOpacity),
                    lineWidth: TopBarActionPillMetrics.borderWidth
                )
            }
            .frame(height: TopBarActionPillMetrics.height)
    }
}

private enum TopBarActionPillMetrics {
    static let height: CGFloat = 36
    static let hitSize: CGFloat = Spacing.actionReserved
    static let visualSize: CGFloat = 32
    static let horizontalPadding: CGFloat = 2
    static let buttonSpacing: CGFloat = 0
    static let cornerRadius: CGFloat = 18
    static let dividerOpacity = 0.16
    static let dividerHeight: CGFloat = 18
    static let borderWidth: CGFloat = 1
    static let whiteWashOpacity = 0.32
    static let borderOpacity = 0.30
    static let pressedScale = 0.95
    static let pressedBrandOpacity = 0.12
    static let innerHighlightOpacity = 0.28
}

/// 胶囊内 segment 的按压反馈，只反馈当前按钮，不缩放整组胶囊。
private struct TopBarActionPillSegmentPressFeedbackStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isEnabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        let isPressed = isEnabled && configuration.isPressed

        configuration.label
            .background {
                if isPressed {
                    RoundedRectangle(cornerRadius: segmentCornerRadius, style: .continuous)
                        .fill(Color.brand.opacity(TopBarActionPillMetrics.pressedBrandOpacity))
                        .frame(
                            width: max(TopBarActionPillMetrics.hitSize - 4, TopBarActionPillMetrics.visualSize),
                            height: max(TopBarActionPillMetrics.height - 4, TopBarActionPillMetrics.visualSize)
                        )
                }
            }
            .scaleEffect(!reduceMotion && isPressed ? TopBarActionPillMetrics.pressedScale : 1)
            .animation(reduceMotion ? nil : .snappy(duration: 0.12), value: configuration.isPressed)
    }

    private var segmentCornerRadius: CGFloat {
        max(TopBarActionPillMetrics.cornerRadius - TopBarActionPillMetrics.horizontalPadding, 0)
    }
}
