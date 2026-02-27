/**
 * [INPUT]: 依赖 SwiftUI buttonStyle 与 glassEffect 能力
 * [OUTPUT]: 对外提供 View.topBarGlassButtonStyle 扩展
 * [POS]: UIComponents/TopBar 的交互样式扩展，为顶部栏按钮提供统一玻璃态按压反馈
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

extension View {
    @ViewBuilder
    func topBarGlassButtonStyle(_ enabled: Bool) -> some View {
        if enabled {
            self.buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
        } else {
            self.buttonStyle(.plain)
        }
    }
}
