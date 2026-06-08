#if DEBUG
/**
 * [INPUT]: 依赖 XMScopeSelector、SwiftUI 原生 segmented Picker、DesignTokens 与 Debug 导航环境，提供范围选择控件的样式、Dynamic Type 与场景样本
 * [OUTPUT]: 对外提供 XMScopeSelectorTestView，集中验证 2-5 项等宽、6+ 横向滚动、原生 segmented 对照、数量、长文案、浅深色、Dynamic Type 与 Liquid Glass 浮层样式
 * [POS]: Debug 测试页，仅用于 XMScopeSelector 产品级基建接入真实页面前的可视化验证
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 范围选择控件测试页，隔离验证公共组件的样式、交互、动态字体与无障碍语义。
struct XMScopeSelectorTestView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visualStyle: XMScopeSelectorDemoStyle = .content
    @State private var countFormat: XMScopeSelectorCountFormat = .plain
    @State private var schemeMode: XMScopeSelectorDemoScheme = .system
    @State private var dynamicTypeMode: XMScopeSelectorDynamicTypeMode = .system
    @State private var showsInvalidSamples = false
    @State private var searchScope: XMScopeSelectorSearchScope = .book
    @State private var pickerScope: XMScopeSelectorPickerScope = .local
    @State private var screenshotScope: XMScopeSelectorScreenshotScope = .book
    @State private var mixedScope: XMScopeSelectorMixedScope = .all
    @State private var technicalScope: XMScopeSelectorTechnicalScope = .all
    @State private var longScope: XMScopeSelectorLongScope = .all
    @State private var overflowScope: XMScopeSelectorOverflowScope = .all
    @State private var invalidScope = "missing"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.base) {
                settingsSection
                reduceMotionStatus
                scenarioSections
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
        }
        .background(Color.surfacePage)
        .preferredColorScheme(schemeMode.colorScheme)
        .navigationTitle("范围选择控件")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var settingsSection: some View {
        XMScopeSelectorDebugCard(title: "调试设置") {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Picker("控件样式", selection: $visualStyle) {
                    ForEach(XMScopeSelectorDemoStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)

                Picker("数字格式", selection: $countFormat) {
                    ForEach(XMScopeSelectorCountFormat.allCases) { format in
                        Text(format.debugTitle).tag(format)
                    }
                }
                .pickerStyle(.segmented)

                Picker("配色", selection: $schemeMode) {
                    ForEach(XMScopeSelectorDemoScheme.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Picker("字号", selection: $dynamicTypeMode) {
                    ForEach(XMScopeSelectorDynamicTypeMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("非法输入断言样例", isOn: $showsInvalidSamples)
                    .font(AppTypography.captionMedium)
                    .foregroundStyle(Color.textSecondary)
            }
        }
    }

    private var reduceMotionStatus: some View {
        HStack(spacing: Spacing.cozy) {
            Image(systemName: reduceMotion ? "figure.walk.motion.trianglebadge.exclamationmark" : "figure.walk.motion")
                .font(AppTypography.body)
                .foregroundStyle(reduceMotion ? Color.textSecondary : Color.brand)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: Spacing.tiny) {
                Text(reduceMotion ? "减少动态效果：已开启" : "减少动态效果：未开启")
                    .font(AppTypography.subheadlineSemibold)
                    .foregroundStyle(Color.textPrimary)
                Text(reduceMotion ? "选中态即时切换，不依赖滑移动画。" : "选中态使用 0.22s snappy 滑动反馈。")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
            }
        }
        .padding(Spacing.contentEdge)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
    }

    private var scenarioSections: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            scenarioMatrix
                .modifier(XMScopeSelectorDynamicTypePreviewModifier(mode: dynamicTypeMode))

            invalidInputSection
        }
    }

    private var scenarioMatrix: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            XMScopeSelectorScenarioSection(
                title: "全局搜索范围",
                subtitle: "4 项单选范围，模拟搜索结果主分类。",
                items: XMScopeSelectorSearchScope.items,
                selection: $searchScope,
                demoStyle: visualStyle,
                countFormat: countFormat
            )

            XMScopeSelectorScenarioSection(
                title: "BookPicker 来源",
                subtitle: "2 项结果来源，验证短分段下的平衡感。",
                items: XMScopeSelectorPickerScope.items,
                selection: $pickerScope,
                demoStyle: visualStyle,
                countFormat: countFormat
            )

            XMScopeSelectorScenarioSection(
                title: "截图场景复刻",
                subtitle: "3 项短中文范围，替代平铺圆形按钮。",
                items: XMScopeSelectorScreenshotScope.items,
                selection: $screenshotScope,
                demoStyle: visualStyle,
                countFormat: countFormat
            )

            XMScopeSelectorScenarioSection(
                title: "混合数量",
                subtitle: "4 项混合 count，验证有无数量时的对齐稳定性。",
                items: XMScopeSelectorMixedScope.items,
                selection: $mixedScope,
                demoStyle: visualStyle,
                countFormat: countFormat
            )

            XMScopeSelectorScenarioSection(
                title: "英文与 ISBN",
                subtitle: "5 项英文、数字和 ISBN 长串，验证截断与 count 保留。",
                items: XMScopeSelectorTechnicalScope.items,
                selection: $technicalScope,
                demoStyle: visualStyle,
                countFormat: countFormat
            )

            XMScopeSelectorScenarioSection(
                title: "长文案与数量",
                subtitle: "5 项上限、长标题和数量徽标的拥挤验证。",
                items: XMScopeSelectorLongScope.items,
                selection: $longScope,
                demoStyle: visualStyle,
                countFormat: countFormat
            )

            XMScopeSelectorScenarioSection(
                title: "6+ 横向滚动",
                subtitle: "7 项搜索范围，验证固定外壳内横向滚动、自动定位与标题优先级。",
                items: XMScopeSelectorOverflowScope.items,
                selection: $overflowScope,
                demoStyle: visualStyle,
                countFormat: countFormat
            )
        }
    }

    @ViewBuilder
    private var invalidInputSection: some View {
        if showsInvalidSamples {
            XMScopeSelectorDebugCard(title: "非法输入") {
                VStack(alignment: .leading, spacing: Spacing.base) {
                    Text("开启后 Debug 构建会触发断言；Release 构建应空渲染。")
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)

                    XMScopeSelector(
                        items: XMScopeSelectorInvalidScope.items,
                        selection: $invalidScope,
                        style: visualStyle.selectorStyle,
                        countFormat: countFormat,
                        accessibilityLabel: "非法输入样例"
                    )
                }
            }
        }
    }
}

/// 测试页卡片容器，保持 Debug 页面各验证区块的结构一致。
private struct XMScopeSelectorDebugCard<Content: View>: View {
    let title: String
    let content: Content

    /// 注入区块标题与内容，用统一卡片节奏承载测试控件。
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            Text(title)
                .font(AppTypography.footnoteSemibold)
                .foregroundStyle(Color.textSecondary)
                .padding(.horizontal, Spacing.compact)

            CardContainer {
                content
                    .padding(Spacing.contentEdge)
            }
        }
    }
}

/// 单个测试场景区块，绑定一个样本 selection 并展示当前选中结果。
private struct XMScopeSelectorScenarioSection<ID: Hashable>: View {
    let title: String
    let subtitle: String
    let items: [XMScopeSelectorItem<ID>]
    @Binding private var selection: ID
    let demoStyle: XMScopeSelectorDemoStyle
    let countFormat: XMScopeSelectorCountFormat

    private var selectedTitle: String {
        items.first { $0.id == selection }?.title ?? "未选中"
    }

    /// 注入测试标题、样本选项、选中状态与样式，生成单个验证场景。
    init(
        title: String,
        subtitle: String,
        items: [XMScopeSelectorItem<ID>],
        selection: Binding<ID>,
        demoStyle: XMScopeSelectorDemoStyle,
        countFormat: XMScopeSelectorCountFormat
    ) {
        self.title = title
        self.subtitle = subtitle
        self.items = items
        self._selection = selection
        self.demoStyle = demoStyle
        self.countFormat = countFormat
    }

    var body: some View {
        XMScopeSelectorDebugCard(title: title) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text(subtitle)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)

                selectorStage

                Text("当前：\(selectedTitle)")
                    .font(AppTypography.captionMedium)
                    .foregroundStyle(Color.textSecondary)
            }
        }
    }

    private var selectorStage: some View {
        ZStack {
            if demoStyle == .floatingGlass {
                XMScopeSelectorGlassBackdrop()
            }

            VStack(alignment: .leading, spacing: Spacing.cozy) {
                comparisonRow(title: "XMScopeSelector") {
                    XMScopeSelector(
                        items: items,
                        selection: $selection,
                        style: demoStyle.selectorStyle,
                        countFormat: countFormat,
                        accessibilityLabel: title
                    )
                }

                Divider()
                    .overlay(Color.surfaceBorderSubtle.opacity(0.56))

                comparisonRow(title: "原生 Picker(.segmented)") {
                    XMScopeSelectorNativeSegmentedComparison(
                        items: items,
                        selection: $selection,
                        countFormat: countFormat,
                        accessibilityLabel: "\(title)原生对照"
                    )
                }
            }
            .padding(.horizontal, Spacing.base)
            .padding(.vertical, Spacing.cozy)
        }
        .frame(maxWidth: .infinity, minHeight: 176)
        .background(stageFill, in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                .stroke(Color.surfaceBorderSubtle.opacity(0.5), lineWidth: CardStyle.borderWidth)
        }
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
    }

    private func comparisonRow<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tiny) {
            Text(title)
                .font(AppTypography.caption2Medium)
                .foregroundStyle(Color.textHint)
                .padding(.horizontal, Spacing.compact)

            content()
        }
    }

    private var stageFill: Color {
        switch demoStyle {
        case .content:
            return Color.surfaceNested
        case .floatingGlass:
            return Color.surfaceNested.opacity(0.72)
        }
    }
}

/// 原生 segmented Picker 对照组，只用系统控件承载相同选项与纯文本数量。
private struct XMScopeSelectorNativeSegmentedComparison<ID: Hashable>: View {
    let items: [XMScopeSelectorItem<ID>]
    @Binding private var selection: ID
    let countFormat: XMScopeSelectorCountFormat
    let accessibilityLabel: String

    /// 注入同源样本与选中绑定，生成不带自定义外观的系统 segmented 对照。
    init(
        items: [XMScopeSelectorItem<ID>],
        selection: Binding<ID>,
        countFormat: XMScopeSelectorCountFormat,
        accessibilityLabel: String
    ) {
        self.items = items
        self._selection = selection
        self.countFormat = countFormat
        self.accessibilityLabel = accessibilityLabel
    }

    var body: some View {
        Picker(accessibilityLabel, selection: $selection) {
            ForEach(items) { item in
                Text(verbatim: displayTitle(for: item))
                    .tag(item.id)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel(accessibilityLabel)
    }

    private func displayTitle(for item: XMScopeSelectorItem<ID>) -> String {
        if let count = item.count {
            return "\(item.title) \(countFormat.displayText(for: count))"
        }
        return item.title
    }
}

/// 测试页 Dynamic Type 模式，用于集中验证控件拥挤降级策略。
private enum XMScopeSelectorDynamicTypeMode: String, CaseIterable, Identifiable {
    case system
    case accessibility

    var id: Self { self }

    var title: String {
        switch self {
        case .system:
            return "系统"
        case .accessibility:
            return "大字"
        }
    }
}

private struct XMScopeSelectorDynamicTypePreviewModifier: ViewModifier {
    let mode: XMScopeSelectorDynamicTypeMode

    /// 仅在测试矩阵中模拟大字号，不影响调试设置本身的可操作性。
    @ViewBuilder
    func body(content: Content) -> some View {
        switch mode {
        case .system:
            content
        case .accessibility:
            content
                .dynamicTypeSize(.accessibility2)
        }
    }
}

/// 浮层玻璃样式的背景采样区，用简单内容行验证玻璃可读性。
private struct XMScopeSelectorGlassBackdrop: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            ForEach(0..<3, id: \.self) { index in
                HStack(spacing: Spacing.cozy) {
                    RoundedRectangle(cornerRadius: CornerRadius.inlayMedium, style: .continuous)
                        .fill(Color.surfaceBorderSubtle.opacity(index == 1 ? 0.16 : 0.10))
                        .frame(width: 48, height: 10)

                    RoundedRectangle(cornerRadius: CornerRadius.inlayMedium, style: .continuous)
                        .fill(Color.textHint.opacity(index == 1 ? 0.10 : 0.07))
                        .frame(height: 10)
                }
            }
        }
        .padding(Spacing.contentEdge)
        .opacity(0.36)
        .accessibilityHidden(true)
    }
}

/// 测试页样式枚举，将调试选项映射到真实控件视觉层级。
private enum XMScopeSelectorDemoStyle: String, CaseIterable, Identifiable {
    case content
    case floatingGlass

    var id: Self { self }

    var title: String {
        switch self {
        case .content:
            return "内容流"
        case .floatingGlass:
            return "浮层玻璃"
        }
    }

    var selectorStyle: XMScopeSelectorVisualStyle {
        switch self {
        case .content:
            return .content
        case .floatingGlass:
            return .floatingGlass
        }
    }
}

private extension XMScopeSelectorCountFormat {
    var debugTitle: String {
        switch self {
        case .plain:
            return "原始"
        case .grouped:
            return "分组"
        }
    }
}

/// 测试页配色枚举，用于快速切换浅色、深色与系统跟随。
private enum XMScopeSelectorDemoScheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system:
            return "系统"
        case .light:
            return "浅色"
        case .dark:
            return "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}

/// 全局搜索范围样本，覆盖四个搜索结果主分类。
private enum XMScopeSelectorSearchScope: Hashable, CaseIterable {
    case all
    case book
    case note
    case relevant

    static let items: [XMScopeSelectorItem<Self>] = allCases.map {
        XMScopeSelectorItem(id: $0, title: $0.title, count: $0.count)
    }

    var title: String {
        switch self {
        case .all:
            return "全部"
        case .book:
            return "书籍"
        case .note:
            return "书摘"
        case .relevant:
            return "相关"
        }
    }

    var count: Int {
        switch self {
        case .all:
            return 4203
        case .book:
            return 13
        case .note:
            return 4169
        case .relevant:
            return 21
        }
    }
}

/// BookPicker 来源样本，验证两个互斥来源的等宽分段表现。
private enum XMScopeSelectorPickerScope: Hashable, CaseIterable {
    case local
    case online

    static let items: [XMScopeSelectorItem<Self>] = allCases.map {
        XMScopeSelectorItem(id: $0, title: $0.title, count: $0.count)
    }

    var title: String {
        switch self {
        case .local:
            return "本地"
        case .online:
            return "在线"
        }
    }

    var count: Int {
        switch self {
        case .local:
            return 36
        case .online:
            return 124
        }
    }
}

/// 截图红框范围样本，验证三个短中文选项替代圆形按钮后的视觉节奏。
private enum XMScopeSelectorScreenshotScope: Hashable, CaseIterable {
    case book
    case excerpt
    case relevant

    static let items: [XMScopeSelectorItem<Self>] = allCases.map {
        XMScopeSelectorItem(id: $0, title: $0.title)
    }

    var title: String {
        switch self {
        case .book:
            return "书籍"
        case .excerpt:
            return "书摘"
        case .relevant:
            return "相关"
        }
    }
}

/// 混合数量样本，验证有数量与无数量项目共存时的 baseline 和宽度稳定性。
private enum XMScopeSelectorMixedScope: Hashable, CaseIterable {
    case all
    case local
    case online
    case archived

    static let items: [XMScopeSelectorItem<Self>] = [
        XMScopeSelectorItem(id: .all, title: "全部", count: 86),
        XMScopeSelectorItem(id: .local, title: "本地"),
        XMScopeSelectorItem(id: .online, title: "在线", count: 21),
        XMScopeSelectorItem(id: .archived, title: "归档")
    ]
}

/// 英文与编号样本，验证五项上限下标题截断、数字保留与无障碍标题。
private enum XMScopeSelectorTechnicalScope: Hashable, CaseIterable {
    case all
    case title
    case author
    case isbn
    case source

    static let items: [XMScopeSelectorItem<Self>] = [
        XMScopeSelectorItem(id: .all, title: "All", count: 128, accessibilityTitle: "All results"),
        XMScopeSelectorItem(id: .title, title: "Title Match", count: 54, accessibilityTitle: "Title match"),
        XMScopeSelectorItem(id: .author, title: "Author", count: 31),
        XMScopeSelectorItem(id: .isbn, title: "ISBN 9787501400614", count: 6, accessibilityTitle: "ISBN 9787501400614"),
        XMScopeSelectorItem(id: .source, title: "Douban ID", count: 3, accessibilityTitle: "Douban ID")
    ]
}

/// 长文案范围样本，验证五项上限、数量徽标与截断策略。
private enum XMScopeSelectorLongScope: Hashable, CaseIterable {
    case all
    case title
    case author
    case tag
    case isbn

    static let items: [XMScopeSelectorItem<Self>] = allCases.map {
        XMScopeSelectorItem(id: $0, title: $0.title, count: $0.count, accessibilityTitle: $0.accessibilityTitle)
    }

    var title: String {
        switch self {
        case .all:
            return "全部结果"
        case .title:
            return "书名与副标题"
        case .author:
            return "作者译者"
        case .tag:
            return "标签分组"
        case .isbn:
            return "ISBN"
        }
    }

    var accessibilityTitle: String {
        switch self {
        case .all:
            return "全部结果"
        case .title:
            return "书名与副标题"
        case .author:
            return "作者译者"
        case .tag:
            return "标签分组"
        case .isbn:
            return "ISBN"
        }
    }

    var count: Int {
        switch self {
        case .all:
            return 128
        case .title:
            return 54
        case .author:
            return 31
        case .tag:
            return 17
        case .isbn:
            return 6
        }
    }
}

/// 横向滚动范围样本，验证 6 项以上时不再压缩同屏。
private enum XMScopeSelectorOverflowScope: Hashable, CaseIterable {
    case all
    case book
    case note
    case relevant
    case review
    case tag
    case chapter

    static let items: [XMScopeSelectorItem<Self>] = allCases.map {
        XMScopeSelectorItem(id: $0, title: $0.title, count: $0.count)
    }

    var title: String {
        switch self {
        case .all:
            return "全部"
        case .book:
            return "书籍"
        case .note:
            return "书摘"
        case .relevant:
            return "相关"
        case .review:
            return "书评"
        case .tag:
            return "标签"
        case .chapter:
            return "章节"
        }
    }

    var count: Int {
        switch self {
        case .all:
            return 4203
        case .book:
            return 13
        case .note:
            return 4169
        case .relevant:
            return 21
        case .review:
            return 5
        case .tag:
            return 128
        case .chapter:
            return 76
        }
    }
}

/// 非法输入样本，验证 Debug 断言与 Release 空渲染路径。
private enum XMScopeSelectorInvalidScope {
    static let items: [XMScopeSelectorItem<String>] = [
        XMScopeSelectorItem(id: "one", title: "一"),
        XMScopeSelectorItem(id: "two", title: "二"),
        XMScopeSelectorItem(id: "three", title: "三")
    ]
}

#Preview {
    NavigationStack {
        XMScopeSelectorTestView()
    }
}
#endif
