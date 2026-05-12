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
        BookshelfDisplaySettingPageScaffold(
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
        BookshelfSettingsGroupCard {
            VStack(spacing: Spacing.none) {
                BookshelfSettingsValueMenuRow(
                    title: "布局",
                    value: setting.layoutMode.title,
                    options: BookshelfLayoutMode.allCases,
                    selection: setting.layoutMode,
                    optionTitle: { $0.title },
                    optionImage: { $0.systemImage },
                    onSelect: { setting.layoutMode = $0 }
                )

                if setting.layoutMode == .grid, !capabilities.columnOptions.isEmpty {
                    BookshelfSettingsValueMenuRow(
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

                BookshelfSettingsToggleRow(
                    title: "显示书摘数量",
                    isOn: $setting.showsNoteCount
                )

                BookshelfSettingsValueMenuRow(
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
        BookshelfSettingsGroupCard {
            VStack(spacing: Spacing.none) {
                BookshelfSettingsValueMenuRow(
                    title: "排序依据",
                    value: setting.sortCriteria.title,
                    options: capabilities.sortCriteria,
                    selection: setting.sortCriteria,
                    optionTitle: { $0.title },
                    optionImage: { $0.systemImage },
                    onSelect: handleSortCriteriaSelection
                )

                if setting.sortCriteria != .custom {
                    BookshelfSettingsValueMenuRow(
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
                    BookshelfSettingsToggleRow(
                        title: "分区显示",
                        isOn: $setting.isSectionEnabled
                    )
                    .transition(settingsRowTransition)
                }
            }
        }
    }

    private var advancedGroup: some View {
        BookshelfSettingsGroupCard {
            BookshelfSettingsToggleRow(
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

/// 显示设置 Sheet 视觉收敛尺寸，统一顶部 chrome 和设置行体量。
private enum BookshelfDisplaySettingSheetLayout {
    static let titleHorizontalReserve: CGFloat = Spacing.actionReserved + Spacing.base
    static let closeVisualSize: CGFloat = 32
    static let chromeMinHeight: CGFloat = Spacing.actionReserved
    static let menuValueMinWidth: CGFloat = Spacing.actionReserved * 2
}

/// 设置 Sheet 的页面骨架，提供轻量居中标题与右侧关闭入口。
private struct BookshelfDisplaySettingPageScaffold<Content: View>: View {
    let title: String
    let subtitle: String?
    let onClose: () -> Void
    let content: Content

    /// 注入标题、关闭按钮语义与页面内容。
    init(
        title: String,
        subtitle: String?,
        onClose: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.onClose = onClose
        self.content = content()
    }

    var body: some View {
        VStack(spacing: Spacing.none) {
            topChrome

            ScrollView {
                content
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.surfaceSheet.ignoresSafeArea())
    }

    private var topChrome: some View {
        ZStack {
            HStack {
                Color.clear
                    .frame(width: Spacing.actionReserved, height: Spacing.actionReserved)
                Spacer(minLength: Spacing.none)
                closeButton
            }
            .frame(minHeight: BookshelfDisplaySettingSheetLayout.chromeMinHeight)

            VStack(spacing: Spacing.micro) {
                Text(title)
                    .font(AppTypography.headlineSemibold)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(AppTypography.caption2)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, BookshelfDisplaySettingSheetLayout.titleHorizontalReserve)
        }
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.top, Spacing.base)
        .padding(.bottom, Spacing.comfortable)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            TopBarActionIcon(
                systemName: "xmark",
                iconSize: 13,
                containerSize: BookshelfDisplaySettingSheetLayout.closeVisualSize,
                weight: .bold,
                foregroundColor: .textSecondary
            )
            .background(Color.controlFillSecondary.opacity(0.82), in: Circle())
            .frame(width: Spacing.actionReserved, height: Spacing.actionReserved)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("关闭")
    }
}

/// 设置分组卡片，使用圆角表层和紧凑内部行距承载设置项。
private struct BookshelfSettingsGroupCard<Content: View>: View {
    let content: Content

    /// 注入设置行内容，构造无描边分组卡片。
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.contentEdge)
            .padding(.vertical, Spacing.half)
            .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.containerMedium, style: .continuous))
    }
}

/// 行内值菜单设置项，适合布局、标题展示、排序依据和排序方向等离散选择。
private struct BookshelfSettingsValueMenuRow<Option: Hashable>: View {
    let title: String
    let value: String
    let options: [Option]
    let selection: Option
    let optionTitle: (Option) -> String
    let optionImage: (Option) -> String?
    let onSelect: (Option) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Spacing.base) {
            Text(title)
                .font(AppTypography.subheadlineSemibold)
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: Spacing.base)

            Menu {
                Picker(title, selection: selectionBinding) {
                    ForEach(options, id: \.self) { option in
                        menuItemLabel(for: option)
                            .tag(option)
                    }
                }
            } label: {
                valueControl
            }
            .buttonStyle(.plain)
            .xmMenuNeutralTint()
            .accessibilityLabel("\(title)，当前\(value)")
            .accessibilityHint("打开选项菜单")
        }
        .frame(minHeight: 52)
    }

    private var valueControl: some View {
        HStack(spacing: Spacing.half) {
            Text(value)
                .font(AppTypography.subheadlineMedium)
                .foregroundStyle(Color.textHint)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .contentTransition(.opacity)

            Image(systemName: "chevron.down")
                .font(AppTypography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(Color.textHint)
        }
        .padding(.leading, Spacing.base)
        .frame(
            minWidth: BookshelfDisplaySettingSheetLayout.menuValueMinWidth,
            minHeight: Spacing.actionReserved,
            alignment: .trailing
        )
        .contentShape(Rectangle())
        .animation(menuValueAnimation, value: value)
    }

    private var menuValueAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: 0.13)
    }

    private var selectionBinding: Binding<Option> {
        Binding(
            get: { selection },
            set: { newValue in
                guard newValue != selection else { return }
                onSelect(newValue)
            }
        )
    }

    @ViewBuilder
    private func menuItemLabel(for option: Option) -> some View {
        if let image = optionImage(option) {
            Label(optionTitle(option), systemImage: image)
        } else {
            Text(optionTitle(option))
        }
    }
}

/// 右侧开关设置行，保持偏好设置的紧凑行高。
private struct BookshelfSettingsToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
                .font(AppTypography.subheadlineSemibold)
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .tint(Color.brand)
        .frame(minHeight: 52)
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
