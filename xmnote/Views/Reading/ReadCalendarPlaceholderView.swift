import SwiftUI

/**
 * [INPUT]: 依赖 DateFormatter 和 DesignTokens 展示选中日期
 * [OUTPUT]: 对外提供 ReadCalendarPlaceholderView（阅读日历占位页）
 * [POS]: 在读路由 readCalendar 的承接页面，先打通“热力图方格点击→日历页”导航链路
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

struct ReadCalendarPlaceholderView: View {
    let date: Date?

    var body: some View {
        ZStack {
            Color.windowBackground.ignoresSafeArea()
            CardContainer {
                VStack(spacing: Spacing.base) {
                    Text("阅读日历")
                        .font(.headline)
                        .foregroundStyle(Color.textPrimary)

                    Text(formattedDate)
                        .font(.body.monospaced())
                        .foregroundStyle(Color.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(Spacing.double)
            }
            .padding(.horizontal, Spacing.screenEdge)
        }
        .navigationTitle("阅读日历")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var formattedDate: String {
        guard let date else { return "未指定日期" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "选中日期：\(formatter.string(from: date))"
    }
}
