/**
 * [INPUT]: 依赖 SwiftUI buttonStyle、系统 Material、动态无障碍与 DesignTokens 语义色能力
 * [OUTPUT]: 对外提供 View.topBarActionButtonStyle、topBarGlassButtonStyle 与 topBarGlassCapsuleStyle 扩展
 * [POS]: UIComponents/TopBar 的交互样式扩展，为顶部栏圆形按钮提供模糊材质底与轻量按压反馈，并保留胶囊操作组玻璃样式
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

extension View {
    /// 为顶部圆形 action 附加轻量模糊材质底与统一按压反馈。
    func topBarActionButtonStyle(_ enabled: Bool, showsBackground: Bool = true) -> some View {
        buttonStyle(TopBarActionPressFeedbackStyle(isEnabled: enabled, showsBackground: showsBackground))
    }

    /// 为顶部圆形 action 附加统一样式，保留旧命名以兼容现有调用点。
    @ViewBuilder
    func topBarGlassButtonStyle(_ enabled: Bool) -> some View {
        if enabled {
            topBarActionButtonStyle(true)
        } else {
            buttonStyle(.plain)
        }
    }

    /// 按可用态为顶部组合操作区附加统一胶囊玻璃样式。
    @ViewBuilder
    func topBarGlassCapsuleStyle(_ enabled: Bool) -> some View {
        if enabled {
            self.buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
        } else {
            self.buttonStyle(.plain)
        }
    }
}

/// 顶部 action icon 的轻量材质底与按压反馈，只在交互瞬间呈现中性反馈层。
private struct TopBarActionPressFeedbackStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isEnabled: Bool
    let showsBackground: Bool

    private enum Metrics {
        static let visualSize: CGFloat = 32
        static let borderWidth: CGFloat = 1
        static let whiteWashOpacity = 0.32
        static let borderOpacity = 0.30
        static let pressedBorderOpacity = 0.36
        static let innerHighlightOpacity = 0.28
        static let pressedScale = 0.95
        static let pressedNeutralOpacity = 0.08
    }

    func makeBody(configuration: Configuration) -> some View {
        let isPressed = isEnabled && configuration.isPressed

        configuration.label
            .background {
                if showsBackground || isPressed {
                    Circle()
                        .fill(.regularMaterial)
                        .overlay {
                            Circle()
                                .fill(Color.white.opacity(Metrics.whiteWashOpacity))
                        }
                        .overlay {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color.white.opacity(Metrics.innerHighlightOpacity),
                                            Color.white.opacity(0)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        }
                        .overlay {
                            if isPressed {
                                Circle()
                                    .fill(Color.textPrimary.opacity(Metrics.pressedNeutralOpacity))
                            }
                        }
                        .overlay {
                            Circle()
                                .stroke(
                                    Color.white.opacity(isPressed ? Metrics.pressedBorderOpacity : Metrics.borderOpacity),
                                    lineWidth: Metrics.borderWidth
                                )
                        }
                        .frame(width: Metrics.visualSize, height: Metrics.visualSize)
                }
            }
            .scaleEffect(!reduceMotion && isPressed ? Metrics.pressedScale : 1)
            .animation(reduceMotion ? nil : .snappy(duration: 0.12), value: configuration.isPressed)
    }
}
