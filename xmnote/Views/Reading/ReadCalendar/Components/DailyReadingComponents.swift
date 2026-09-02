/**
 * [INPUT]: 依赖 DailyReadingBookSummary、DailyReadingTimelineFilter、DailyReadingSortOrder、阅读日历 Reicon 资源与统一顶部菜单样式
 * [OUTPUT]: 对外提供 DailyReadingMoreMenu，以 Reicon 表达打卡/书籍领域入口并集中承载记录类型与排序操作
 * [POS]: ReadCalendar 当日阅读轨迹页面私有顶部组件，保持导航栏仅有一个中性更多入口
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 当日阅读轨迹的统一更多菜单；普通入口保持中性，具体选中状态由系统勾选表达。
struct DailyReadingMoreMenu: View {
    /// 当日阅读轨迹菜单的局部 Reicon 尺寸。
    private enum Layout {
        static let menuIconSize: CGFloat = 18
    }

    let bookCount: Int
    let canCheckIn: Bool
    let isWriting: Bool
    let filter: DailyReadingTimelineFilter
    let sortOrder: DailyReadingSortOrder
    let onCheckIn: () -> Void
    let onShowBookFilter: () -> Void
    let onSelectFilter: (DailyReadingTimelineFilter) -> Void
    let onSelectSort: (DailyReadingSortOrder) -> Void

    var body: some View {
        Menu {
            Button {
                onCheckIn()
            } label: {
                Label {
                    Text("打卡")
                        .fontWeight(.medium)
                } icon: {
                    Image(.reiconCalendarCheckOutline)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: Layout.menuIconSize, height: Layout.menuIconSize)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(Color.menuActionForeground)
            }
            .disabled(!canCheckIn || isWriting)
            .accessibilityLabel("打卡")
            .accessibilityHint(canCheckIn ? "添加这一天的阅读打卡" : "未来日期不能打卡")

            if bookCount > 1 {
                Button {
                    onShowBookFilter()
                } label: {
                    Label {
                        Text("筛选书籍")
                            .fontWeight(.medium)
                    } icon: {
                        Image(.reiconBookOutline)
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: Layout.menuIconSize, height: Layout.menuIconSize)
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(Color.menuActionForeground)
                }
            }

            Menu {
                ForEach(DailyReadingTimelineFilter.allCases) { option in
                    Button {
                        onSelectFilter(option)
                    } label: {
                        XMMenuLabel(option.title, isSelected: option == filter)
                    }
                }
            } label: {
                XMMenuLabel("记录类型", systemImage: "line.3.horizontal.decrease")
            }

            Menu {
                ForEach(DailyReadingSortOrder.allCases) { option in
                    Button {
                        onSelectSort(option)
                    } label: {
                        XMMenuLabel(option.title, isSelected: option == sortOrder)
                    }
                }
            } label: {
                XMMenuLabel("排序", systemImage: "arrow.up.arrow.down")
            }
        } label: {
            Label("更多", systemImage: "ellipsis")
                .labelStyle(.iconOnly)
        }
        .xmToolbarNeutralTint()
        .accessibilityLabel("更多")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("显示打卡、书籍筛选、记录类型和排序操作")
    }

    private var accessibilityValue: String {
        "记录类型：\(filter.title)，排序：\(sortOrder.title)"
    }
}
