#if DEBUG
/**
 * [INPUT]: 依赖 SearchHistoryTestViewModel 提供测试场景与日志，依赖 XMSearchHistorySection 渲染搜索历史组件
 * [OUTPUT]: 对外提供 SearchHistoryTestView，覆盖搜索历史空态、短词、长词、删除、清空、展开与 iOS 26 样式验证
 * [POS]: Debug 测试页，用于在测试中心集中验收 XMSearchHistorySection 的视觉、交互、动态字体与 Liquid Glass 边界
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

struct SearchHistoryTestView: View {
    @State private var viewModel = SearchHistoryTestViewModel()

    var body: some View {
        SearchHistoryTestContentView(viewModel: viewModel)
    }
}

private struct SearchHistoryTestContentView: View {
    @Bindable var viewModel: SearchHistoryTestViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var style: XMSearchHistoryStyle = .content
    @State private var schemeMode: SearchHistoryTestSchemeMode = .system
    @State private var dynamicTypeMode: SearchHistoryTestDynamicTypeMode = .standard
    @State private var isClearHistoryConfirmationPresented = false

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.double) {
                controlsSection
                previewSection
                eventLogSection
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
            .safeAreaPadding(.bottom)
        }
        .background(Color.surfacePage)
        .navigationTitle("搜索历史组件")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(schemeMode.colorScheme)
        .onChange(of: viewModel.isEditing) { _, newValue in
            viewModel.recordEditingChange(newValue)
        }
        .xmSystemAlert(
            isPresented: $isClearHistoryConfirmationPresented,
            descriptor: clearHistoryDescriptor
        )
    }
}

private extension SearchHistoryTestContentView {
    var controlsSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("测试配置")
                    .font(AppTypography.subheadlineSemibold)
                    .foregroundStyle(Color.textPrimary)

                pickerRow("场景") {
                    Picker("场景", selection: $viewModel.scenario) {
                        ForEach(SearchHistoryTestScenario.allCases) { scenario in
                            Text(scenario.title).tag(scenario)
                        }
                    }
                    .pickerStyle(.menu)
                }

                pickerRow("样式") {
                    Picker("样式", selection: $style) {
                        ForEach(XMSearchHistoryStyle.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                pickerRow("外观") {
                    Picker("外观", selection: $schemeMode) {
                        ForEach(SearchHistoryTestSchemeMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                pickerRow("字号") {
                    Picker("字号", selection: $dynamicTypeMode) {
                        ForEach(SearchHistoryTestDynamicTypeMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Toggle("编辑模式", isOn: $viewModel.isEditing)
                    .font(AppTypography.captionMedium)
                    .foregroundStyle(Color.textSecondary)

                HStack(spacing: Spacing.half) {
                    statusBadge(viewModel.scenario.subtitle)
                    statusBadge(viewModel.isEditing ? "编辑中" : "浏览中")
                    statusBadge(reduceMotion ? "Reduce Motion 开" : "Reduce Motion 关")
                }

                Button {
                    withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .snappy(duration: 0.18)) {
                        viewModel.resetScenario()
                    }
                } label: {
                    Label("恢复样本", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .font(AppTypography.captionMedium)
            }
            .padding(Spacing.contentEdge)
        }
    }

    var previewSection: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            sectionHeader("组件预览", subtitle: viewModel.selectedQuery.map { "最近点击：\($0)" } ?? "等待交互")

            XMSearchHistorySection(
                queries: viewModel.queries,
                isExpanded: $viewModel.isExpanded,
                isEditing: $viewModel.isEditing,
                style: style,
                title: "最近搜索",
                emptyPresentation: previewEmptyPresentation,
                onSelect: viewModel.select,
                onRemove: viewModel.remove,
                onClearAll: {
                    isClearHistoryConfirmationPresented = true
                }
            )
            .padding(Spacing.contentEdge)
            .background(
                Color.surfaceCard.opacity(style == .glass ? 0.42 : 0.72),
                in: RoundedRectangle(cornerRadius: CornerRadius.containerMedium, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: CornerRadius.containerMedium, style: .continuous)
                    .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
            }
            .dynamicTypeSize(dynamicTypeMode.dynamicTypeSize)
        }
    }

    var previewEmptyPresentation: XMSearchHistoryEmptyPresentation {
        switch viewModel.scenario {
        case .emptyHidden:
            return .hidden
        default:
            return .message(
                title: "暂无搜索历史",
                subtitle: "确认搜索后会在这里保留最近关键词"
            )
        }
    }

    var eventLogSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("事件日志")
                    .font(AppTypography.subheadlineSemibold)
                    .foregroundStyle(Color.textPrimary)

                if viewModel.eventLog.isEmpty {
                    Text("暂无事件")
                        .font(AppTypography.body)
                        .foregroundStyle(Color.textSecondary)
                } else {
                    ForEach(Array(viewModel.eventLog.enumerated()), id: \.offset) { _, event in
                        Text(event)
                            .font(AppTypography.caption)
                            .foregroundStyle(Color.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    func pickerRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: Spacing.base) {
            Text(title)
                .font(AppTypography.captionMedium)
                .foregroundStyle(Color.textSecondary)
                .frame(width: 44, alignment: .leading)

            content()
        }
    }

    func sectionHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tiny) {
            Text(title)
                .font(AppTypography.subheadlineSemibold)
                .foregroundStyle(Color.textPrimary)

            Text(subtitle)
                .font(AppTypography.caption)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func statusBadge(_ text: String) -> some View {
        Text(text)
            .font(AppTypography.caption)
            .foregroundStyle(Color.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, Spacing.cozy)
            .frame(minHeight: 28)
            .background(Color.controlFillSecondary.opacity(0.58), in: Capsule())
    }

    var clearHistoryDescriptor: XMSystemAlertDescriptor {
        XMSystemAlertDescriptor(
            title: "清空测试历史？",
            message: "这只会清空当前测试页的内存样本，不影响真实搜索历史。",
            actions: [
                XMSystemAlertAction(title: "取消", role: .cancel) { },
                XMSystemAlertAction(title: "清空", role: .destructive) {
                    viewModel.clearAll()
                }
            ]
        )
    }
}

private enum SearchHistoryTestSchemeMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

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

private enum SearchHistoryTestDynamicTypeMode: String, CaseIterable, Identifiable {
    case standard
    case large
    case accessibility

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard:
            return "标准"
        case .large:
            return "较大"
        case .accessibility:
            return "无障碍"
        }
    }

    var dynamicTypeSize: DynamicTypeSize {
        switch self {
        case .standard:
            return .medium
        case .large:
            return .xxxLarge
        case .accessibility:
            return .accessibility2
        }
    }
}

#Preview {
    NavigationStack {
        SearchHistoryTestView()
    }
}
#endif
