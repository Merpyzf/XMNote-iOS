/**
 * [INPUT]: 依赖微信读书导入偏好、系统 PresentationDetent/Menu/Toggle 与导入专用交互式玻璃按钮
 * [OUTPUT]: 对外提供微信读书授权页的可折叠导入操作面板，Regular 设置标签、标题对齐的说明开关、自适应数字进度与紧凑/展开 Detent
 * [POS]: Views/Personal/DataImport 的业务私有浮动控制层，不持有授权、获取或持久化逻辑
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 微信读书授权页的伴随式操作面板，保持设置、主操作与系统 Sheet 高度语义集中。
struct WereadImportActionPanel: View {
    static let compactDetent = PresentationDetent.custom(WereadImportCompactDetent.self)
    static let expandedDetent = PresentationDetent.custom(WereadImportExpandedDetent.self)
    static let detents: Set<PresentationDetent> = [compactDetent, expandedDetent]

    @Binding var selectedDetent: PresentationDetent
    let bottomSafeAreaInset: CGFloat
    let recentBookCount: Int
    let importsReadingTime: Bool
    let onlyBooksWithNotes: Bool
    let primaryTitle: String
    var primaryProgress: WereadImportAuthViewModel.WorkProgress? = nil
    let showsPrimaryProgress: Bool
    let isPrimaryDisabled: Bool
    let areSettingsDisabled: Bool
    let onRecentBookCountChange: (Int) -> Void
    let onImportsReadingTimeChange: (Bool) -> Void
    let onOnlyBooksWithNotesChange: (Bool) -> Void
    let onPrimaryAction: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let recentBookOptions = [-1, 5, 10, 20, 30, 60, 100]

    private enum Layout {
        static let settingsRowMinimumHeight: CGFloat = 50
        static let collapsedContentOffset: CGFloat = 8
    }

    /// 让原生开关对齐左列标题中心，说明换行不会改变开关相对标题的位置。
    private enum SettingTitleAlignment: AlignmentID {
        nonisolated static func defaultValue(in context: ViewDimensions) -> CGFloat {
            context[VerticalAlignment.center]
        }
    }

    private static let settingTitleAlignment = VerticalAlignment(SettingTitleAlignment.self)

    private var isExpanded: Bool {
        selectedDetent == Self.expandedDetent
    }

    var body: some View {
        GeometryReader { geometry in
            let expansionProgress = expansionProgress(for: geometry)

            Color.clear
                .frame(width: geometry.size.width, height: max(visibleContentHeight(for: geometry), 0))
                .overlay(alignment: .top) {
                    settingsContent
                        .disabled(areSettingsDisabled)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.horizontal, Spacing.double)
                        .padding(.top, Spacing.screenEdge)
                        .padding(.bottom, WereadImportPanelLayout.compactHeight(for: dynamicTypeSize) - Spacing.screenEdge + Spacing.base)
                        .opacity(expansionProgress)
                        .offset(
                            y: reduceMotion
                                ? Spacing.none
                                : Layout.collapsedContentOffset * (1 - expansionProgress)
                        )
                        .allowsHitTesting(expansionProgress > 0.98)
                        .accessibilityHidden(expansionProgress < 0.5)
                }
                .overlay(alignment: .bottom) {
                    primaryButton
                        .padding(.horizontal, Spacing.double)
                        .padding(.vertical, Spacing.screenEdge)
                }
                .clipped()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isExpanded ? "导入选项" : "导入操作")
        .accessibilityAction(named: Text(isExpanded ? "收起导入面板" : "展开导入选项")) {
            selectedDetent = isExpanded ? Self.compactDetent : Self.expandedDetent
        }
    }

    @ViewBuilder
    private var settingsContent: some View {
        if dynamicTypeSize.isAccessibilitySize {
            ScrollView {
                settingsRows
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.always)
        } else {
            settingsRows
        }
    }

    private var settingsRows: some View {
        VStack(alignment: .leading, spacing: Spacing.none) {
            bookRangeRow

            materialToggleRow(
                title: "仅获取有笔记的书",
                isOn: Binding(
                    get: { onlyBooksWithNotes },
                    set: onOnlyBooksWithNotesChange
                )
            )

            readingTimeRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var bookRangeRow: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Spacing.cozy) {
                    materialRowTitle("书籍范围")
                    bookRangeMenu
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.vertical, Spacing.cozy)
            } else {
                HStack(spacing: Spacing.base) {
                    materialRowTitle("书籍范围")
                    Spacer(minLength: Spacing.base)
                    bookRangeMenu
                }
            }
        }
        .frame(minHeight: Layout.settingsRowMinimumHeight)
    }

    private var bookRangeMenu: some View {
        Menu {
            Picker("书籍范围", selection: bookRangeSelection) {
                ForEach(Self.recentBookOptions, id: \.self) { option in
                    Text(Self.bookRangeTitle(option))
                        .tag(option)
                }
            }
        } label: {
            HStack(spacing: Spacing.half) {
                Text(bookRangeTitle)
                    .font(SettingsTypography.rowValue)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .multilineTextAlignment(.trailing)

                Image(systemName: "chevron.down")
                    .font(AppTypography.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(
                minWidth: 88,
                minHeight: InteractionMetrics.minimumTouchTarget,
                alignment: .trailing
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .xmMenuNeutralTint()
        .accessibilityLabel("书籍范围，当前\(bookRangeTitle)")
        .accessibilityHint("打开选项菜单")
    }

    private var bookRangeSelection: Binding<Int> {
        Binding(
            get: { recentBookCount },
            set: { value in
                guard value != recentBookCount else { return }
                onRecentBookCountChange(value)
            }
        )
    }

    private func materialToggleRow(title: LocalizedStringResource, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            materialRowTitle(title)
        }
        .tint(Color.appTint)
        .frame(minHeight: Layout.settingsRowMinimumHeight)
    }

    private func materialRowTitle(_ title: LocalizedStringResource) -> some View {
        Text(title)
            .font(AppTypography.body)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 说明仅属于阅读时长选项；独立原生 Toggle 保留名称、状态与辅助说明。
    private var readingTimeRow: some View {
        HStack(alignment: Self.settingTitleAlignment, spacing: Spacing.base) {
            Button {
                onImportsReadingTimeChange(!importsReadingTime)
            } label: {
                VStack(alignment: .leading, spacing: Spacing.half) {
                    materialRowTitle("同步阅读时长")
                        .alignmentGuide(Self.settingTitleAlignment) { $0[VerticalAlignment.center] }

                    if importsReadingTime {
                        Text("同步微信读书时长，保留手动计时记录")
                            .font(SettingsTypography.rowDescription)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: InteractionMetrics.minimumTouchTarget, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)

            Toggle("同步阅读时长", isOn: Binding(
                get: { importsReadingTime },
                set: onImportsReadingTimeChange
            ))
            .labelsHidden()
            .tint(Color.appTint)
            .fixedSize()
            .frame(minHeight: InteractionMetrics.minimumTouchTarget)
            .alignmentGuide(Self.settingTitleAlignment) { $0[VerticalAlignment.center] }
            .accessibilityHint(importsReadingTime ? "同步微信读书时长，保留手动计时记录" : "")
        }
        .frame(minHeight: Layout.settingsRowMinimumHeight)
    }

    private var primaryButton: some View {
        Button(action: onPrimaryAction) {
            HStack(spacing: Spacing.cozy) {
                if showsPrimaryProgress {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.primaryActionForeground)
                }

                ViewThatFits(in: .horizontal) {
                    if let progress = primaryProgress {
                        HStack(spacing: Spacing.half) {
                            Text(primaryTitle)
                            progressNumbers(progress)
                                .id(progress.id)
                                .id(progress.total)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    Text(shortPrimaryTitle)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .font(AppTypography.headline)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(NoteImportPrimaryButtonStyle())
        .disabled(isPrimaryDisabled)
        .accessibilityLabel(shortPrimaryTitle)
        .accessibilityValue(primaryProgress.map { "第\($0.current)本，共\($0.total)本" } ?? "")
    }

    private var shortPrimaryTitle: String {
        showsPrimaryProgress && !primaryTitle.hasSuffix("…") ? "\(primaryTitle)…" : primaryTitle
    }

    /// 用总数宽度预留当前数字空间，只有数字值变化参与过渡，不推动按钮和状态词。
    private func progressNumbers(_ progress: WereadImportAuthViewModel.WorkProgress) -> some View {
        HStack(spacing: Spacing.none) {
            Text(progress.total, format: .number.grouping(.never))
                .hidden()
                .overlay(alignment: .trailing) {
                    Text(progress.current, format: .number.grouping(.never))
                        .contentTransition(reduceMotion ? .identity : .numericText(value: Double(progress.current)))
                        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: progress.current)
                }
            Text("/")
            Text(progress.total, format: .number.grouping(.never))
        }
        .monospacedDigit()
        .accessibilityHidden(true)
    }

    private var bookRangeTitle: String {
        Self.bookRangeTitle(recentBookCount)
    }

    /// 将系统 Sheet 的实时拖拽高度映射为内容展开进度，使内容与 Detent 位移保持同一手势节奏。
    private func expansionProgress(for geometry: GeometryProxy) -> CGFloat {
        let compactHeight = WereadImportPanelLayout.compactHeight(for: dynamicTypeSize)
        let contentHeight = visibleContentHeight(for: geometry)
        let travel = WereadImportPanelLayout.expandedHeight - compactHeight
        guard travel > 0 else { return 1 }
        return min(max((contentHeight - compactHeight) / travel, 0), 1)
    }

    /// 以系统拖拽期间持续变化的安全区反推出当前真正可见的面板内容高度。
    private func visibleContentHeight(for geometry: GeometryProxy) -> CGFloat {
        let collapseInset = max(geometry.safeAreaInsets.bottom - bottomSafeAreaInset, 0)
        return geometry.size.height - collapseInset
    }

    nonisolated private static func bookRangeTitle(_ count: Int) -> String {
        count < 0 ? "全部书籍" : "最近 \(count) 本"
    }
}

private enum WereadImportPanelLayout {
    static let expandedHeight: CGFloat = 272

    /// 保留已验证的系统高度档位，设置内容不参与紧凑面板的尺寸计算。
    static func compactHeight(for size: DynamicTypeSize) -> CGFloat {
        size.isAccessibilitySize ? 152 : 108
    }
}

private struct WereadImportCompactDetent: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? {
        let preferredHeight = WereadImportPanelLayout.compactHeight(for: context.dynamicTypeSize)
        return min(preferredHeight, context.maxDetentValue)
    }
}

private struct WereadImportExpandedDetent: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? {
        guard !context.dynamicTypeSize.isAccessibilitySize else {
            return context.maxDetentValue
        }
        return min(WereadImportPanelLayout.expandedHeight, context.maxDetentValue)
    }
}

#if DEBUG
/// 用独立本地状态验证短文案、进位过渡与系统 Sheet，不访问授权或导入数据。
private struct WereadImportActionPanelPreview: View {
    @State private var selectedDetent = WereadImportActionPanel.expandedDetent
    @State private var isPresented = true
    @State private var importsTime = true
    @State private var onlyNotes = false
    @State private var progress: WereadImportAuthViewModel.WorkProgress?
    @State private var title = "获取书籍"
    @State private var isLoading = false
    @State private var isCompact = false
    @State private var isLargeType = false
    @State private var replayID = UUID()
    private let titles = ["获取书籍", "保存二维码", "刷新二维码", "重新加载", "加载中…", "保存中…", "获取中", "关联中"]

    var body: some View {
        VStack(spacing: Spacing.base) {
            Picker("按钮状态", selection: $title) {
                ForEach(titles, id: \.self) { Text($0).tag($0) }
            }
            .onChange(of: title) { _, value in
                progress = nil
                isLoading = value.contains("中")
            }
            Button("演示进度") { replayID = UUID() }
            Toggle("320pt 宽度", isOn: $isCompact)
            Toggle("最大辅助字号", isOn: $isLargeType)
            Spacer()
        }
        .padding(Spacing.screenEdge)
        .sheet(isPresented: $isPresented) {
            WereadImportActionPanel(
                selectedDetent: $selectedDetent,
                bottomSafeAreaInset: 34,
                recentBookCount: 100,
                importsReadingTime: importsTime,
                onlyBooksWithNotes: onlyNotes,
                primaryTitle: title,
                primaryProgress: progress,
                showsPrimaryProgress: isLoading,
                isPrimaryDisabled: isLoading,
                areSettingsDisabled: isLoading,
                onRecentBookCountChange: { _ in },
                onImportsReadingTimeChange: { importsTime = $0 },
                onOnlyBooksWithNotesChange: { onlyNotes = $0 },
                onPrimaryAction: {}
            )
            .frame(maxWidth: isCompact ? 320 : .infinity)
            .presentationDetents(WereadImportActionPanel.detents, selection: $selectedDetent)
            .presentationDragIndicator(.visible)
            .presentationBackgroundInteraction(.enabled)
            .interactiveDismissDisabled()
            .environment(\.dynamicTypeSize, isLargeType ? .accessibility5 : .large)
        }
        .task(id: replayID) { await replay() }
    }

    /// 主线程按受控节奏回放；视图退出或再次点击会取消旧回放，下一次使用新的数字身份。
    @MainActor private func replay() async {
        do {
            progress = nil
            title = "获取中"
            isLoading = true
            try await Task.sleep(for: .seconds(2))
            let sequence = UUID()
            for current in [8, 9, 10, 98, 99, 100] {
                try Task.checkCancellation()
                progress = .init(id: sequence, current: current, total: 100)
                try await Task.sleep(for: .seconds(1))
            }
            progress = nil
            title = "获取书籍"
            isLoading = false
        } catch { }
    }
}

#Preview("微信读书操作面板与进度") {
    WereadImportActionPanelPreview()
}

#endif
