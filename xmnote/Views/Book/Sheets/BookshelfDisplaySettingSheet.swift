/**
 * [INPUT]: 依赖 BookshelfDisplaySetting 持久化配置、BookshelfDimension、BookshelfDisplaySettingScope 与 SwiftUI Sheet 展示能力
 * [OUTPUT]: 对外提供 BookshelfDisplaySettingSheet，按书架作用域调整布局、排序、分区、置顶与标题展示偏好
 * [POS]: Book 模块业务 Sheet，服务首页书架与二级列表显示设置入口，不直接承担数据库读写
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书架显示设置 Sheet，按当前作用域过滤可用设置项，写入动作由外层 ViewModel 持久化。
struct BookshelfDisplaySettingSheet: View {
    let dimension: BookshelfDimension
    let scope: BookshelfDisplaySettingScope
    let availableCriteria: [BookshelfSortCriteria]
    let showsPinnedInAllSortsSetting: Bool
    @Binding var setting: BookshelfDisplaySetting
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 构建书架显示设置 Sheet；二级列表可注入独立排序依据与置顶设置开关。
    init(
        dimension: BookshelfDimension,
        scope: BookshelfDisplaySettingScope = .main,
        setting: Binding<BookshelfDisplaySetting>,
        availableCriteria: [BookshelfSortCriteria]? = nil,
        showsPinnedInAllSortsSetting: Bool? = nil
    ) {
        self.dimension = dimension
        self.scope = scope
        self.availableCriteria = availableCriteria ?? BookshelfSortCriteria.available(for: dimension)
        self.showsPinnedInAllSortsSetting = showsPinnedInAllSortsSetting ?? (dimension == .default)
        self._setting = setting
    }

    var body: some View {
        rootPage
        .background(Color.surfaceSheet.ignoresSafeArea())
        .onAppear(perform: sanitizeSetting)
        .onChange(of: setting.sortCriteria) { _, _ in
            sanitizeSetting()
        }
        .onChange(of: setting.columnCount) { _, _ in
            sanitizeColumnCount()
        }
    }

    private var capabilities: BookshelfDisplaySettingCapabilities {
        BookshelfDisplaySettingCapabilities(
            scope: scope,
            dimension: dimension,
            availableCriteria: availableCriteria,
            showsPinnedInAllSortsSetting: showsPinnedInAllSortsSetting
        )
    }

    private var rootPage: some View {
        XMSheetScaffold(
            title: "显示设置",
            subtitle: scopeSummary,
            onClose: { dismiss() }
        ) {
            VStack(spacing: Spacing.comfortable) {
                displayGroup
                sortGroup
                if showsAdvancedSection {
                    advancedGroup
                        .transition(settingsRowTransition)
                }
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.bottom, Spacing.contentEdge)
            .animation(settingsReflowAnimation, value: setting.layoutMode)
            .animation(settingsReflowAnimation, value: setting.sortCriteria)
            .animation(settingsReflowAnimation, value: showsAdvancedSection)
        }
    }

    private var displayGroup: some View {
        XMSettingsGroup {
            VStack(spacing: Spacing.none) {
                XMSettingsValueMenuRow(
                    title: "布局",
                    value: setting.layoutMode.title,
                    options: BookshelfLayoutMode.allCases,
                    selection: setting.layoutMode,
                    optionTitle: { $0.title },
                    optionImage: { $0.systemImage },
                    onSelect: { setting.layoutMode = $0 }
                )

                if setting.layoutMode == .grid, !capabilities.columnOptions.isEmpty {
                    XMSettingsValueMenuRow(
                        title: "每行数量",
                        value: "\(effectiveColumnCount)列",
                        options: capabilities.columnOptions,
                        selection: effectiveColumnCount,
                        optionTitle: { "\($0)列" },
                        optionImage: { _ in nil },
                        onSelect: { setting.columnCount = $0 }
                    )
                    .transition(settingsRowTransition)
                }

                XMSettingsToggleRow(
                    title: "显示书摘数量",
                    isOn: $setting.showsNoteCount
                )

                XMSettingsValueMenuRow(
                    title: "书名展示",
                    value: setting.titleDisplayMode.title,
                    options: BookshelfTitleDisplayMode.allCases,
                    selection: setting.titleDisplayMode,
                    optionTitle: { $0.title },
                    optionImage: { _ in nil },
                    onSelect: { setting.titleDisplayMode = $0 }
                )
            }
        }
    }

    private var sortGroup: some View {
        XMSettingsGroup {
            VStack(spacing: Spacing.none) {
                XMSettingsValueMenuRow(
                    title: "排序依据",
                    value: setting.sortCriteria.title,
                    options: capabilities.sortCriteria,
                    selection: setting.sortCriteria,
                    optionTitle: { $0.title },
                    optionImage: { $0.systemImage },
                    onSelect: handleSortCriteriaSelection
                )

                if setting.sortCriteria != .custom {
                    XMSettingsValueMenuRow(
                        title: "排序方向",
                        value: sortOrderTitle(setting.sortOrder),
                        options: BookshelfSortOrder.allCases,
                        selection: setting.sortOrder,
                        optionTitle: sortOrderTitle,
                        optionImage: { _ in nil },
                        onSelect: { setting.sortOrder = $0 }
                    )
                    .transition(settingsRowTransition)
                }

                if setting.sortCriteria.supportsSection {
                    XMSettingsToggleRow(
                        title: "分区显示",
                        isOn: $setting.isSectionEnabled
                    )
                    .transition(settingsRowTransition)
                }
            }
        }
    }

    private var advancedGroup: some View {
        XMSettingsGroup {
            XMSettingsToggleRow(
                title: "置顶项保持在顶部",
                isOn: $setting.pinnedInAllSorts
            )
        }
    }

    private var scopeSummary: String {
        let scopeTitle: String
        switch scope {
        case .main:
            scopeTitle = "首页书架"
        case .bookList:
            scopeTitle = "二级列表"
        }
        return "\(scopeTitle) · \(dimension.title)"
    }

    private var effectiveColumnCount: Int {
        guard !capabilities.columnOptions.isEmpty else {
            return setting.columnCount
        }
        if capabilities.columnOptions.contains(setting.columnCount) {
            return setting.columnCount
        }
        return closestColumnCount(to: setting.columnCount)
    }

    private var showsAdvancedSection: Bool {
        capabilities.showsPinnedInAllSorts && setting.sortCriteria != .custom
    }

    private var settingsReflowAnimation: Animation {
        reduceMotion ? .smooth(duration: 0.10) : .smooth(duration: 0.22)
    }

    private var settingsRowTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: -Spacing.tiny)),
            removal: .opacity
        )
    }

    private func sanitizeSetting() {
        if !capabilities.sortCriteria.contains(setting.sortCriteria),
           let fallback = capabilities.sortCriteria.first {
            setting.sortCriteria = fallback
        }
        if !setting.sortCriteria.supportsSection {
            setting.isSectionEnabled = false
        }
        sanitizeColumnCount()
    }

    private func sanitizeColumnCount() {
        guard !capabilities.columnOptions.isEmpty else { return }
        let nextColumnCount = closestColumnCount(to: setting.columnCount)
        if setting.columnCount != nextColumnCount {
            setting.columnCount = nextColumnCount
        }
    }

    private func closestColumnCount(to value: Int) -> Int {
        capabilities.columnOptions.min { lhs, rhs in
            abs(lhs - value) < abs(rhs - value)
        } ?? value
    }

    private func sortOrderTitle(_ sortOrder: BookshelfSortOrder) -> String {
        switch sortOrder {
        case .ascending:
            return setting.sortCriteria.ascendingTitle
        case .descending:
            return setting.sortCriteria.descendingTitle
        }
    }

    private func handleSortCriteriaSelection(_ criteria: BookshelfSortCriteria) {
        setting.sortCriteria = criteria
        if !criteria.supportsSection {
            setting.isSectionEnabled = false
        }
    }
}

/// 显示设置能力模型，统一约束当前作用域真实可渲染的控件与排序项。
private struct BookshelfDisplaySettingCapabilities {
    let scope: BookshelfDisplaySettingScope
    let dimension: BookshelfDimension
    let availableCriteria: [BookshelfSortCriteria]
    let showsPinnedInAllSortsSetting: Bool

    var columnOptions: [Int] {
        switch scope {
        case .main:
            switch dimension {
            case .default:
                return [2, 3, 4]
            case .status, .tag, .source, .rating:
                return [2, 3]
            case .author, .press:
                return []
            }
        case .bookList:
            return [2, 3, 4]
        }
    }

    var sortCriteria: [BookshelfSortCriteria] {
        availableCriteria
    }

    var showsPinnedInAllSorts: Bool {
        showsPinnedInAllSortsSetting
    }
}

private extension BookshelfLayoutMode {
    var systemImage: String {
        switch self {
        case .grid:
            return "square.grid.2x2"
        case .list:
            return "list.bullet"
        }
    }
}
