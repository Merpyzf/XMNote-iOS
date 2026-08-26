import SwiftUI

/**
 * [INPUT]: 依赖 weekday 文本数组、ReadCalendarTheme 次级文字色、ReadCalendarTextStyle 与 DesignTokens
 * [OUTPUT]: 对外提供 ReadCalendarWeekdayHeader（阅读日历星期标题行，大字体下保持七列空间结构）
 * [POS]: ReadCalendar 业务内复用组件，统一星期标题样式并减少壳层重复代码
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 星期标题行组件，统一周视图顶部的文字顺序与样式。
struct ReadCalendarWeekdayHeader: View {
    private static let weekdays = ["一", "二", "三", "四", "五", "六", "日"]

    let minHeight: CGFloat
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: Spacing.none) {
            ForEach(Self.weekdays, id: \.self) { weekday in
                Text(weekday)
                    .font(
                        dynamicTypeSize.isAccessibilitySize
                            ? ReadCalendarTextStyle.weekdayHeaderAccessibilityFont
                            : ReadCalendarTextStyle.weekdayHeaderFont
                    )
                    .foregroundStyle(ReadCalendarTheme.subtleText)
                    .frame(maxWidth: .infinity, minHeight: minHeight)
            }
        }
    }
}
