/**
 * [INPUT]: 依赖 SwiftUI、DesignTokens 状态色/排版/间距令牌与 CardContainer 内容表层
 * [OUTPUT]: 对外提供 ReadingStatusTimeline 核心时间线、Status/Item 输入模型与 ReadingStatusTimelineCard 卡片封装，并以单一虚线路径绘制相邻状态连接边
 * [POS]: UIComponents/Foundation 的跨模块阅读历程基础组件，供后续阅读详情与只读分享场景复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 以“最新在上”的顺序展示阅读状态事件、绝对时间与相邻事件间隔。
struct ReadingStatusTimeline: View {
    /// 允许主题页面覆盖时间线文字色；默认值维持组件在其他页面的既有语义色。
    struct Style {
        let primaryTextColor: Color
        let secondaryTextColor: Color

        static let `default` = Style(
            primaryTextColor: .textPrimary,
            secondaryTextColor: .textSecondary
        )
    }

    /// 阅读历程支持的状态语义，数值与 Android `BookReadingStatus` 保持一致。
    enum Status: Int64, CaseIterable, Hashable, Sendable {
        case addedToShelf = -1
        case unknown = 0
        case wantRead = 1
        case reading = 2
        case readDone = 3
        case abandoned = 4
        case onHold = 5

        var title: LocalizedStringResource {
            switch self {
            case .addedToShelf:
                "加入书架"
            case .unknown:
                "未知状态"
            case .wantRead:
                "想读"
            case .reading:
                "在读"
            case .readDone:
                "读完"
            case .abandoned:
                "弃读"
            case .onHold:
                "搁置"
            }
        }

        var tint: Color {
            switch self {
            case .addedToShelf, .unknown:
                .textHint
            case .wantRead:
                .statusWish
            case .reading:
                .statusReading
            case .readDone:
                .statusDone
            case .abandoned:
                .statusAbandoned
            case .onHold:
                .statusOnHold
            }
        }

        var allowsEditing: Bool {
            self != .addedToShelf && self != .unknown
        }
    }

    /// 单条阅读历程输入；调用方负责提供稳定 ID，并按最新到最早排列数组。
    struct Item: Identifiable, Hashable, Sendable {
        let id: String
        let status: Status
        let date: Date
        let isEditable: Bool

        /// 构建一条已确定展示顺序和交互权限的阅读状态事件。
        init(
            id: String,
            status: Status,
            date: Date,
            isEditable: Bool = true
        ) {
            self.id = id
            self.status = status
            self.date = date
            self.isEditable = isEditable
        }
    }

    let items: [Item]
    let style: Style
    let calendar: Calendar
    let onSelectItem: ((Item) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// 注入已排序事件和可选编辑回调；组件不查询、排序或写入业务数据。
    init(
        items: [Item],
        style: Style = .default,
        calendar: Calendar = .autoupdatingCurrent,
        onSelectItem: ((Item) -> Void)? = nil
    ) {
        self.items = items
        self.style = style
        self.calendar = calendar
        self.onSelectItem = onSelectItem
    }

    var body: some View {
        Group {
            if items.isEmpty {
                ReadingStatusTimelineEmptyView(style: style)
            } else {
                LazyVStack(spacing: Spacing.none) {
                    ForEach(items.enumerated(), id: \.element.id) { index, item in
                        ReadingStatusTimelineEntry(
                            item: item,
                            nextItem: items[safe: index + 1],
                            isCurrent: index == 0,
                            usesAccessibilityLayout: usesExpandedLayout,
                            calendar: calendar,
                            style: style,
                            onSelectItem: onSelectItem
                        )
                        .transition(itemTransition)
                    }
                }
                .animation(itemAnimation, value: items)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var itemAnimation: Animation {
        accessibilityReduceMotion ? .easeOut(duration: 0.12) : .snappy
    }

    private var itemTransition: AnyTransition {
        if accessibilityReduceMotion {
            return .opacity
        }
        return .move(edge: .top).combined(with: .opacity)
    }

    private var usesExpandedLayout: Bool {
        dynamicTypeSize == .xxxLarge || dynamicTypeSize.isAccessibilitySize
    }
}

/// 将阅读历程核心嵌入标准内容卡片，并提供可选的新增状态入口。
struct ReadingStatusTimelineCard: View {
    let title: LocalizedStringResource
    let changeStatusTitle: LocalizedStringResource
    let items: [ReadingStatusTimeline.Item]
    let calendar: Calendar
    let onChangeStatus: (() -> Void)?
    let onSelectItem: ((ReadingStatusTimeline.Item) -> Void)?

    /// 组装标题、可选操作和时间线；操作闭包为空时自动形成只读卡片。
    init(
        title: LocalizedStringResource = "阅读历程",
        changeStatusTitle: LocalizedStringResource = "修改状态",
        items: [ReadingStatusTimeline.Item],
        calendar: Calendar = .autoupdatingCurrent,
        onChangeStatus: (() -> Void)? = nil,
        onSelectItem: ((ReadingStatusTimeline.Item) -> Void)? = nil
    ) {
        self.title = title
        self.changeStatusTitle = changeStatusTitle
        self.items = items
        self.calendar = calendar
        self.onChangeStatus = onChangeStatus
        self.onSelectItem = onSelectItem
    }

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                HStack(alignment: .center, spacing: Spacing.base) {
                    Text(title)
                        .font(AppTypography.headlineSemibold)
                        .foregroundStyle(Color.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let onChangeStatus {
                        Button(action: onChangeStatus) {
                            Text(changeStatusTitle)
                                .font(AppTypography.subheadlineMedium)
                                .foregroundStyle(Color.brand)
                                .frame(minHeight: Spacing.actionReserved)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                ReadingStatusTimeline(
                    items: items,
                    calendar: calendar,
                    onSelectItem: onSelectItem
                )
            }
            .padding(Spacing.contentEdge)
        }
    }
}

/// 集中维护时间线视觉尺寸及动态字体上限，避免装饰元素随文字无限放大。
private enum ReadingStatusTimelineMetrics {
    static let railColumnWidth: CGFloat = 20
    static let maximumRailColumnWidth: CGFloat = 24
    static let connectorSlotHeight: CGFloat = 72
    static let connectorLineHeight: CGFloat = 62
    static let connectorLineWidth: CGFloat = 2
    static let connectorDashLength: CGFloat = 4
    static let connectorDashGap: CGFloat = 4
    static let nodeDiameter: CGFloat = 16
    static let maximumNodeDiameter: CGFloat = 20
    static let nodeBorderWidth: CGFloat = 2
    static let maximumNodeBorderWidth: CGFloat = 2.5
}

/// 渲染单个状态节点及其后续间隔，隔离每条事件的布局和交互判断。
private struct ReadingStatusTimelineEntry: View {
    let item: ReadingStatusTimeline.Item
    let nextItem: ReadingStatusTimeline.Item?
    let isCurrent: Bool
    let usesAccessibilityLayout: Bool
    let calendar: Calendar
    let style: ReadingStatusTimeline.Style
    let onSelectItem: ((ReadingStatusTimeline.Item) -> Void)?

    @ScaledMetric(relativeTo: .body) private var scaledRailColumnWidth =
        ReadingStatusTimelineMetrics.railColumnWidth

    var body: some View {
        VStack(spacing: Spacing.none) {
            statusRow

            if let nextItem {
                connectorRow(to: nextItem)
            }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        if canEdit {
            Button(action: selectItem) {
                statusRowContent
            }
            .buttonStyle(ReadingStatusTimelineRowButtonStyle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: accessibilityLabel))
            .accessibilityHint("轻点编辑此状态")
        } else {
            statusRowContent
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: accessibilityLabel))
        }
    }

    @ViewBuilder
    private var statusRowContent: some View {
        if usesAccessibilityLayout {
            HStack(alignment: .center, spacing: Spacing.base) {
                nodeColumn
                    .frame(width: railColumnWidth)

                VStack(alignment: .leading, spacing: Spacing.compact) {
                    statusText
                    timestampText(alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        } else {
            HStack(alignment: .center, spacing: Spacing.base) {
                timestampText(alignment: .trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)

                nodeColumn
                    .frame(width: railColumnWidth)

                statusText
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
    }

    private var statusText: some View {
        Text(item.status.title)
            .font(isCurrent ? AppTypography.headlineSemibold : AppTypography.bodyMedium)
            .foregroundStyle(
                item.status == .addedToShelf
                    ? style.secondaryTextColor
                    : style.primaryTextColor
            )
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 输出日期与可选时间；本地零点事件不重复展示无信息量的“00:00”。
    private func timestampText(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: Spacing.hairline) {
            Text(item.date, format: .dateTime.year().month().day())
                .lineLimit(1)

            if !isMidnight(item.date) {
                Text(item.date, format: .dateTime.hour().minute())
            }
        }
        .font(AppTypography.caption)
        .foregroundStyle(style.secondaryTextColor)
        .monospacedDigit()
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 在常规和辅助功能布局间复用同一节点；连接边由相邻事件对独立持有。
    private var nodeColumn: some View {
        ReadingStatusTimelineNode(status: item.status)
            .accessibilityHidden(true)
    }

    /// 渲染两个状态之间的间隔和完整虚线轨道。
    private func connectorRow(to nextItem: ReadingStatusTimeline.Item) -> some View {
        let intervalText = intervalDescription(to: nextItem)

        return Group {
            if usesAccessibilityLayout {
                HStack(alignment: .center, spacing: Spacing.base) {
                    ReadingStatusTimelineConnector(tint: item.status.tint)
                        .frame(width: railColumnWidth)

                    Text(intervalText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(alignment: .center, spacing: Spacing.base) {
                    Text(intervalText)
                        .frame(maxWidth: .infinity, alignment: .trailing)

                    ReadingStatusTimelineConnector(tint: item.status.tint)
                        .frame(width: railColumnWidth)

                    Spacer(minLength: Spacing.none)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .font(AppTypography.captionMedium)
        .foregroundStyle(style.secondaryTextColor)
        .frame(height: ReadingStatusTimelineMetrics.connectorSlotHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var railColumnWidth: CGFloat {
        min(
            scaledRailColumnWidth,
            ReadingStatusTimelineMetrics.maximumRailColumnWidth
        )
    }

    private var canEdit: Bool {
        item.isEditable && item.status.allowsEditing && onSelectItem != nil
    }

    private var accessibilityLabel: String {
        let status = String(localized: item.status.title)
        let date = item.date.formatted(
            date: .long,
            time: isMidnight(item.date) ? .omitted : .shortened
        )
        if isCurrent {
            return "\(String(localized: "当前状态"))，\(status)，\(date)"
        }
        return "\(status)，\(date)"
    }

    /// 触发调用方注入的历史状态编辑动作。
    private func selectItem() {
        onSelectItem?(item)
    }

    /// 按 Android 的绝对毫秒差生成“同时 / 当日 / N天后”，不把跨零点但未满 24 小时误算为一天。
    private func intervalDescription(to nextItem: ReadingStatusTimeline.Item) -> String {
        let differenceMilliseconds = Int64(
            (abs(item.date.timeIntervalSince(nextItem.date)) * 1_000).rounded(.down)
        )
        if differenceMilliseconds == 0 {
            return String(localized: "同时")
        }

        let dayCount = differenceMilliseconds / 86_400_000
        if dayCount == 0 {
            return String(localized: "当日")
        }
        return String(localized: "\(dayCount)天后")
    }

    /// 判断事件是否落在用户本地时区的零点，决定是否隐藏时间行。
    private func isMidnight(_ date: Date) -> Bool {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return components.hour == 0 && components.minute == 0
    }
}

/// 以统一空心节点承载状态色，避免把最新记录误读为选中或完成标记。
private struct ReadingStatusTimelineNode: View {
    let status: ReadingStatusTimeline.Status

    @ScaledMetric(relativeTo: .body) private var scaledDiameter =
        ReadingStatusTimelineMetrics.nodeDiameter
    @ScaledMetric(relativeTo: .body) private var scaledBorderWidth =
        ReadingStatusTimelineMetrics.nodeBorderWidth

    var body: some View {
        Circle()
            .fill(Color.surfaceCard)
            .overlay {
                Circle()
                    .stroke(status.tint, lineWidth: borderWidth)
            }
            .frame(width: diameter, height: diameter)
    }

    private var diameter: CGFloat {
        min(
            scaledDiameter,
            ReadingStatusTimelineMetrics.maximumNodeDiameter
        )
    }

    private var borderWidth: CGFloat {
        min(
            scaledBorderWidth,
            ReadingStatusTimelineMetrics.maximumNodeBorderWidth
        )
    }
}

/// 由当前事件独占相邻连接边，使用固定几何保证虚线密度和端点稳定。
private struct ReadingStatusTimelineConnector: View {
    let tint: Color

    var body: some View {
        ReadingStatusTimelineConnectorShape()
            .stroke(
                tint,
                style: StrokeStyle(
                    lineWidth: ReadingStatusTimelineMetrics.connectorLineWidth,
                    lineCap: .butt,
                    dash: [
                        ReadingStatusTimelineMetrics.connectorDashLength,
                        ReadingStatusTimelineMetrics.connectorDashGap,
                    ],
                    dashPhase: 0
                )
            )
            .frame(height: ReadingStatusTimelineMetrics.connectorLineHeight)
            .frame(height: ReadingStatusTimelineMetrics.connectorSlotHeight)
            .accessibilityHidden(true)
    }
}

/// 生成不参与业务状态的单一竖向连接路径。
private struct ReadingStatusTimelineConnectorShape: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}

/// 为无箭头的历史行提供克制但可见的原生按压反馈。
private struct ReadingStatusTimelineRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.62 : 1)
            .animation(.smooth(duration: 0.14), value: configuration.isPressed)
    }
}

/// 在没有任何事件时保持卡片节奏稳定，并明确说明当前无阅读历程。
private struct ReadingStatusTimelineEmptyView: View {
    let style: ReadingStatusTimeline.Style

    var body: some View {
        HStack(spacing: Spacing.cozy) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(Color.iconSecondary)
                .accessibilityHidden(true)

            Text("暂无阅读历程")
                .font(AppTypography.subheadline)
                .foregroundStyle(style.secondaryTextColor)
        }
        .frame(maxWidth: .infinity, minHeight: Spacing.actionReserved, alignment: .center)
        .accessibilityElement(children: .combine)
    }
}

private extension Collection {
    /// 返回安全下标元素，避免动态输入变化期间发生越界访问。
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

#Preview("阅读历程卡片") {
    ReadingStatusTimelineCard(
        items: [
            .init(id: "reading", status: .reading, date: .now),
            .init(id: "shelf", status: .addedToShelf, date: .now, isEditable: false),
        ]
    )
    .padding()
    .background(Color.surfacePage)
}
