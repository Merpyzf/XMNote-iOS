import SwiftUI

/**
 * [INPUT]: 依赖 DesignTokens 与 SwiftUI glassEffect，依赖图标/文案与回调触发月度或年度统计弹层
 * [OUTPUT]: 对外提供 ReadCalendarSummaryFloatingButton（统计悬浮按钮）
 * [POS]: ReadCalendar 业务内浮层入口组件，承载右下角液态玻璃按钮交互
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 统计悬浮按钮组件，统一月度与年度总结入口的液态玻璃外观。
struct ReadCalendarSummaryFloatingButton: View {
    private enum Layout {
        static let buttonSize: CGFloat = 48
        static let iconSize: CGFloat = 16
    }

    let iconSystemName: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: iconSystemName)
                .font(.system(size: Layout.iconSize, weight: .medium))
                .foregroundStyle(Color.readCalendarTopAction)
                .frame(width: Layout.buttonSize, height: Layout.buttonSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.clear.interactive(), in: .circle)
        .accessibilityLabel(accessibilityLabel)
    }
}
