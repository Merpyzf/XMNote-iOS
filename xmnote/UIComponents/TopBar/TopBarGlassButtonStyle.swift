/**
 * [INPUT]: 依赖 SwiftUI buttonStyle 与 iOS 26 原生 Liquid Glass 能力
 * [OUTPUT]: 对外提供 View.topBarActionButtonStyle、topBarGlassButtonStyle 与 topBarGlassCapsuleStyle 扩展
 * [POS]: UIComponents/TopBar 的交互样式扩展，为顶部栏圆形按钮提供统一原生玻璃外观，并保留胶囊操作组玻璃样式
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

extension View {
    /// 为顶部圆形 action 附加 36pt 原生交互玻璃，同时保留 44pt 点击热区。
    func topBarActionButtonStyle(_ enabled: Bool, showsBackground: Bool = true) -> some View {
        buttonStyle(.plain)
            .modifier(
                TopBarStandaloneGlassModifier(
                    isEnabled: enabled,
                    showsBackground: showsBackground
                )
            )
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

/// 顶部独立 action 的原生玻璃承载层，视觉尺寸与触控尺寸彼此独立。
private struct TopBarStandaloneGlassModifier: ViewModifier {
    let isEnabled: Bool
    let showsBackground: Bool

    private enum Metrics {
        static let visualSize: CGFloat = 36
        static let hitSize: CGFloat = Spacing.actionReserved
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if showsBackground {
            content
                .frame(width: Metrics.visualSize, height: Metrics.visualSize)
                .glassEffect(.clear.interactive(isEnabled), in: .circle)
                .frame(width: Metrics.hitSize, height: Metrics.hitSize)
                .contentShape(Circle())
        } else {
            content
                .frame(width: Metrics.hitSize, height: Metrics.hitSize)
                .contentShape(Circle())
        }
    }
}
