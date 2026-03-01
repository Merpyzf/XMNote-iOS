import SwiftUI

/**
 * [INPUT]: 依赖 DesignTokens 与 SwiftUI glassEffect，依赖回调触发月度统计弹层
 * [OUTPUT]: 对外提供 ReadCalendarSummaryFloatingButton（月度统计悬浮按钮）
 * [POS]: ReadCalendar 业务内浮层入口组件，承载右下角液态玻璃按钮交互
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

struct ReadCalendarSummaryFloatingButton: View {
    private enum Layout {
        static let buttonSize: CGFloat = 48
        static let iconSize: CGFloat = 16
    }

    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chart.bar.yaxis")
                .font(.system(size: Layout.iconSize, weight: .medium))
                .foregroundStyle(Color.readCalendarTopAction)
                .frame(width: Layout.buttonSize, height: Layout.buttonSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.clear.interactive(), in: .circle)
        .accessibilityLabel("月度阅读总结")
    }
}
