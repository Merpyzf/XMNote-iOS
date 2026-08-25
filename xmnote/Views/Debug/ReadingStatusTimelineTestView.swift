#if DEBUG
import SwiftUI

/**
 * [INPUT]: 依赖 ReadingStatusTimeline/ReadingStatusTimelineCard、DesignTokens 与五组本地固定数据
 * [OUTPUT]: 对外提供 ReadingStatusTimelineTestView（阅读历程组件验收页）
 * [POS]: Debug 测试页，集中验证时间线双层接口、时间文案、动态字体、配色与编辑权限
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 阅读历程组件验收页，以确定性数据覆盖核心布局、边界状态和可选回调。
struct ReadingStatusTimelineTestView: View {
    @Environment(\.colorScheme) private var systemColorScheme

    @State private var selectedScenario: ReadingTimelineDemoScenario = .androidReference
    @State private var selectedAppearance: ReadingTimelineDemoAppearance = .system
    @State private var selectedTextSize: ReadingTimelineDemoTextSize = .standard
    @State private var showsTopAction = true
    @State private var allowsHistoryEditing = true
    @State private var latestInteraction = "尚未触发操作"

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.base) {
                controlsCard
                previewSurface
                interactionCard
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
            .safeAreaPadding(.bottom)
        }
        .background(Color.surfacePage)
        .navigationTitle("阅读历程组件")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private extension ReadingStatusTimelineTestView {
    var controlsCard: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("验收控制")
                    .font(AppTypography.headlineSemibold)
                    .foregroundStyle(Color.textPrimary)

                controlGroup("测试场景") {
                    Picker("测试场景", selection: $selectedScenario) {
                        ForEach(ReadingTimelineDemoScenario.allCases) { scenario in
                            Text(scenario.title).tag(scenario)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                controlGroup("预览背景") {
                    Picker("预览背景", selection: $selectedAppearance) {
                        ForEach(ReadingTimelineDemoAppearance.allCases) { appearance in
                            Text(appearance.title).tag(appearance)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                controlGroup("动态字体") {
                    Picker("动态字体", selection: $selectedTextSize) {
                        ForEach(ReadingTimelineDemoTextSize.allCases) { textSize in
                            Text(textSize.title).tag(textSize)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Toggle("显示顶部“修改状态”", isOn: $showsTopAction)
                    .font(AppTypography.body)
                    .tint(Color.brand)

                Toggle("允许编辑真实历史状态", isOn: $allowsHistoryEditing)
                    .font(AppTypography.body)
                    .tint(Color.brand)

                Text(selectedScenario.detail)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Spacing.contentEdge)
        }
    }

    var previewSurface: some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            ReadingStatusTimelineCard(
                items: selectedScenario.items,
                calendar: ReadingTimelineDemoData.calendar,
                onChangeStatus: changeStatusAction,
                onSelectItem: selectItemAction
            )

            CardContainer {
                VStack(alignment: .leading, spacing: Spacing.base) {
                    Text("纯核心时间线")
                        .font(AppTypography.headlineSemibold)
                        .foregroundStyle(Color.textPrimary)

                    ReadingStatusTimeline(
                        items: selectedScenario.items,
                        calendar: ReadingTimelineDemoData.calendar,
                        onSelectItem: selectItemAction
                    )
                }
                .padding(Spacing.contentEdge)
            }
        }
        .padding(Spacing.base)
        .background(Color.surfacePage)
        .environment(\.colorScheme, resolvedPreviewColorScheme)
        .dynamicTypeSize(selectedTextSize.dynamicTypeSize)
        .clipShape(
            RoundedRectangle(
                cornerRadius: CornerRadius.containerMedium,
                style: .continuous
            )
        )
    }

    var interactionCard: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.half) {
                Text("最近一次交互")
                    .font(AppTypography.headlineSemibold)
                    .foregroundStyle(Color.textPrimary)

                Text(latestInteraction)
                    .font(AppTypography.body)
                    .foregroundStyle(Color.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)

                Text("提示：即使测试数据声明可编辑，“加入书架”和“未知状态”也不应触发回调")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textHint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Spacing.contentEdge)
        }
    }

    var resolvedPreviewColorScheme: ColorScheme {
        selectedAppearance.colorScheme ?? systemColorScheme
    }

    var changeStatusAction: (() -> Void)? {
        guard showsTopAction else { return nil }
        return {
            latestInteraction = "点击了“修改状态”"
        }
    }

    var selectItemAction: ((ReadingStatusTimeline.Item) -> Void)? {
        guard allowsHistoryEditing else { return nil }
        return { item in
            latestInteraction = "点击历史状态：\(String(localized: item.status.title))（ID：\(item.id)）"
        }
    }

    /// 统一测试控制项的标题层级，避免 Picker 标签重复抢占信息焦点。
    func controlGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            Text(title)
                .font(AppTypography.captionMedium)
                .foregroundStyle(Color.textSecondary)
            content()
        }
    }
}

/// 测试中心提供的五组确定性阅读历程场景。
private enum ReadingTimelineDemoScenario: String, CaseIterable, Identifiable {
    case androidReference
    case fullHistory
    case singleItem
    case empty
    case unknown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .androidReference: "截图同款"
        case .fullHistory: "完整历程"
        case .singleItem: "单节点"
        case .empty: "空数据"
        case .unknown: "未知状态"
        }
    }

    var detail: String {
        switch self {
        case .androidReference:
            "Android 三节点同款，用于验收“13天后”“同时”和不可编辑起点"
        case .fullHistory:
            "覆盖五种真实状态、同日不同时间、零点时间与跨自然日间隔"
        case .singleItem:
            "只有一个零点状态，用于验收无连接线和仅显示日期"
        case .empty:
            "没有任何事件，用于验收紧凑空态"
        case .unknown:
            "未知状态显式降级为中性色，并始终拒绝编辑"
        }
    }

    var items: [ReadingStatusTimeline.Item] {
        switch self {
        case .androidReference:
            [
                .init(
                    id: "android-read-done",
                    status: .readDone,
                    date: ReadingTimelineDemoData.date(2026, 7, 22, 4, 49)
                ),
                .init(
                    id: "android-reading",
                    status: .reading,
                    date: ReadingTimelineDemoData.date(2026, 7, 9, 2, 6)
                ),
                .init(
                    id: "android-shelf",
                    status: .addedToShelf,
                    date: ReadingTimelineDemoData.date(2026, 7, 9, 2, 6)
                ),
            ]
        case .fullHistory:
            [
                .init(
                    id: "full-on-hold",
                    status: .onHold,
                    date: ReadingTimelineDemoData.date(2026, 3, 18, 20, 30)
                ),
                .init(
                    id: "full-abandoned",
                    status: .abandoned,
                    date: ReadingTimelineDemoData.date(2026, 3, 18, 8, 10)
                ),
                .init(
                    id: "full-read-done",
                    status: .readDone,
                    date: ReadingTimelineDemoData.date(2026, 3, 12)
                ),
                .init(
                    id: "full-reading",
                    status: .reading,
                    date: ReadingTimelineDemoData.date(2026, 3, 10, 9, 5)
                ),
                .init(
                    id: "full-want-read",
                    status: .wantRead,
                    date: ReadingTimelineDemoData.date(2026, 3, 10, 8)
                ),
                .init(
                    id: "full-shelf",
                    status: .addedToShelf,
                    date: ReadingTimelineDemoData.date(2026, 1, 19)
                ),
            ]
        case .singleItem:
            [
                .init(
                    id: "single-read-done",
                    status: .readDone,
                    date: ReadingTimelineDemoData.date(2026, 2, 8)
                ),
            ]
        case .empty:
            []
        case .unknown:
            [
                .init(
                    id: "unknown-current",
                    status: .unknown,
                    date: ReadingTimelineDemoData.date(2026, 4, 7, 18, 45)
                ),
                .init(
                    id: "unknown-shelf",
                    status: .addedToShelf,
                    date: ReadingTimelineDemoData.date(2026, 4, 1)
                ),
            ]
        }
    }
}

/// 预览表层模式，仅改变验收区域而不覆盖测试中心自身的系统外观。
private enum ReadingTimelineDemoAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// 预览字体档位用于稳定切换常规三列布局和辅助功能两列布局。
private enum ReadingTimelineDemoTextSize: String, CaseIterable, Identifiable {
    case standard
    case extraLarge
    case accessibility

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: "标准字号"
        case .extraLarge: "特大字号"
        case .accessibility: "辅助字号"
        }
    }

    var dynamicTypeSize: DynamicTypeSize {
        switch self {
        case .standard: .large
        case .extraLarge: .xxxLarge
        case .accessibility: .accessibility3
        }
    }
}

/// 固定使用上海时区构造截图数据，避免开发机和模拟器时区差异破坏验收基线。
private enum ReadingTimelineDemoData {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_Hans_CN")
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .autoupdatingCurrent
        return calendar
    }

    /// 将明确的本地日期分量转换为测试日期；异常时回退到稳定参考时间。
    static func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int = 0,
        _ minute: Int = 0
    ) -> Date {
        calendar.date(
            from: DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute
            )
        ) ?? Date(timeIntervalSince1970: 0)
    }
}

#Preview {
    NavigationStack {
        ReadingStatusTimelineTestView()
    }
}
#endif
