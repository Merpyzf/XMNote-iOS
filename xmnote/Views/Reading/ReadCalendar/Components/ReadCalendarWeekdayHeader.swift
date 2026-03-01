import SwiftUI

/**
 * [INPUT]: 依赖 weekday 文本数组与 DesignTokens 颜色语义
 * [OUTPUT]: 对外提供 ReadCalendarWeekdayHeader（阅读日历星期标题行）
 * [POS]: ReadCalendar 业务内复用组件，统一星期标题样式并减少壳层重复代码
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

struct ReadCalendarWeekdayHeader: View {
    private static let weekdays = ["一", "二", "三", "四", "五", "六", "日"]

    let minHeight: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Self.weekdays, id: \.self) { weekday in
                Text(weekday)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.readCalendarSubtleText)
                    .frame(maxWidth: .infinity, minHeight: minHeight)
            }
        }
    }
}
