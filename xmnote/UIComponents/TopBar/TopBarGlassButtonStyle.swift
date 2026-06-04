/**
 * [INPUT]: 依赖 SwiftUI buttonStyle 与 glassEffect 能力
 * [OUTPUT]: 对外提供 View.topBarGlassButtonStyle 与 topBarGlassCapsuleStyle 扩展
 * [POS]: UIComponents/TopBar 的交互样式扩展，为顶部栏圆形按钮与胶囊操作组提供统一玻璃态按压反馈
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

extension View {
    /// 按可用态为顶部按钮附加统一玻璃按钮样式。
    @ViewBuilder
    func topBarGlassButtonStyle(_ enabled: Bool) -> some View {
        if enabled {
            self.buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
        } else {
            self.buttonStyle(.plain)
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
