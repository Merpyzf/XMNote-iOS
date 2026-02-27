import SwiftUI

/**
 * [INPUT]: 依赖 ReadingHeatmapWidgetView 提供热力图小组件，依赖 EmptyStateView 提供在读列表占位
 * [OUTPUT]: 对外提供 ReadingListPlaceholderView（在读页内容容器）
 * [POS]: Reading 模块首页内容入口，承载热力图卡片并向上抛出“打开阅读日历”事件
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

struct ReadingListPlaceholderView: View {
    var onOpenReadCalendar: (Date) -> Void = { _ in }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.base) {
                ReadingHeatmapWidgetView(onOpenReadCalendar: onOpenReadCalendar)

                CardContainer {
                    EmptyStateView(icon: "book.pages", message: "暂无在读书籍")
                        .frame(height: 220)
                }
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.top, Spacing.half)
            .padding(.bottom, Spacing.base)
        }
    }
}

#Preview {
    ReadingListPlaceholderView()
}
