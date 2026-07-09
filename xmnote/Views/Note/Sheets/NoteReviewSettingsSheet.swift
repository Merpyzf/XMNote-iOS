/**
 * [INPUT]: 依赖 NoteReviewViewModel 提供回顾设置、标签选项与已选书籍回显，依赖 BookPickerView 承接书籍范围选择
 * [OUTPUT]: 对外提供 NoteReviewSettingsSheet 与标签多选 Sheet，完成书摘回顾设置编辑
 * [POS]: Note 模块业务 Sheet，服务回顾 Tab 顶部设置入口，不直接访问数据库
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书摘回顾设置 Sheet，复用项目设置页分组风格并将写入动作委托给 ViewModel。
struct NoteReviewSettingsSheet: View {
    @Bindable var viewModel: NoteReviewViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var activeSheet: ActiveSheet?

    private enum ActiveSheet: Identifiable {
        case books
        case tags

        var id: String {
            switch self {
            case .books:
                return "books"
            case .tags:
                return "tags"
            }
        }
    }

    var body: some View {
        XMSettingsPageScaffold(
            title: "回顾设置",
            subtitle: "书摘范围与卡片样式",
            onClose: { dismiss() }
        ) {
            VStack(spacing: Spacing.comfortable) {
                scopeGroup
                displayGroup
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.bottom, Spacing.contentEdge)
            .animation(settingsReflowAnimation, value: viewModel.settings.selectedTagIDs)
            .animation(settingsReflowAnimation, value: viewModel.settings.palette)
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .books:
                BookPickerView(
                    configuration: bookPickerConfiguration,
                    onComplete: handleBookPickerResult
                )
            case .tags:
                NoteReviewTagSelectionSheet(
                    options: viewModel.tagOptions,
                    selectedIDs: viewModel.settings.selectedTagIDs,
                    onComplete: handleTagSelection
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
    }

    private var scopeGroup: some View {
        XMSettingsGroupCard {
            VStack(spacing: Spacing.none) {
                XMSettingsNavigationRow(
                    title: "书籍范围",
                    value: viewModel.bookScopeSummary,
                    action: { activeSheet = .books }
                )

                XMSettingsNavigationRow(
                    title: "标签范围",
                    value: viewModel.tagScopeSummary,
                    action: { activeSheet = .tags }
                )

                if !viewModel.settings.selectedTagIDs.isEmpty {
                    XMSettingsValueMenuRow(
                        title: "标签规则",
                        value: viewModel.settings.tagMatchRule.title,
                        options: NoteReviewTagMatchRule.allCases,
                        selection: viewModel.settings.tagMatchRule,
                        optionTitle: { $0.title },
                        optionImage: { _ in nil },
                        onSelect: updateTagMatchRule
                    )
                    .transition(settingsRowTransition)
                }
            }
        }
    }

    private var displayGroup: some View {
        XMSettingsGroupCard {
            VStack(spacing: Spacing.none) {
                XMSettingsValueMenuRow(
                    title: "显示顺序",
                    value: viewModel.settings.sortRule.title,
                    options: NoteReviewSortRule.allCases,
                    selection: viewModel.settings.sortRule,
                    optionTitle: { $0.title },
                    optionImage: { $0.systemImage },
                    onSelect: updateSortRule
                )

                NoteReviewPalettePickerRow(
                    selection: viewModel.settings.palette,
                    onSelect: updatePalette
                )

                XMSettingsValueMenuRow(
                    title: "文本对齐",
                    value: viewModel.settings.textAlignment.title,
                    options: NoteReviewTextAlignment.allCases,
                    selection: viewModel.settings.textAlignment,
                    optionTitle: { $0.title },
                    optionImage: { _ in nil },
                    onSelect: updateTextAlignment
                )
            }
        }
    }

    private var bookPickerConfiguration: BookPickerConfiguration {
        BookPickerConfiguration(
            title: "选择回顾书籍",
            scope: .local,
            selectionMode: .multiple,
            allowsCreationFlow: false,
            multipleConfirmationPolicy: .allowsEmptyResult,
            multipleConfirmationTitle: "确认范围",
            preselectedBooks: viewModel.selectedBooks
        )
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

    private func updateSortRule(_ sortRule: NoteReviewSortRule) {
        var next = viewModel.settings
        next.sortRule = sortRule
        Task { await viewModel.updateSettings(next) }
    }

    private func updateTagMatchRule(_ rule: NoteReviewTagMatchRule) {
        var next = viewModel.settings
        next.tagMatchRule = rule
        Task { await viewModel.updateSettings(next) }
    }

    private func updatePalette(_ palette: NoteReviewPalette) {
        var next = viewModel.settings
        next.palette = palette
        Task { await viewModel.updateSettings(next) }
    }

    private func updateTextAlignment(_ alignment: NoteReviewTextAlignment) {
        var next = viewModel.settings
        next.textAlignment = alignment
        Task { await viewModel.updateSettings(next) }
    }

    private func handleBookPickerResult(_ result: BookPickerResult) {
        guard case .multiple(let selections) = result else { return }
        let books = selections.compactMap { selection -> BookPickerBook? in
            guard case .local(let book) = selection else { return nil }
            return book
        }
        Task { await viewModel.updateSelectedBooks(books) }
    }

    private func handleTagSelection(_ ids: [Int64]) {
        Task { await viewModel.updateSelectedTagIDs(ids) }
    }
}

private struct NoteReviewPalettePickerRow: View {
    let selection: NoteReviewPalette
    let onSelect: (NoteReviewPalette) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            HStack(spacing: Spacing.base) {
                Text("卡片配色")
                    .font(AppTypography.subheadlineSemibold)
                    .foregroundStyle(Color.textPrimary)

                Spacer(minLength: Spacing.base)

                Text(selection.title)
                    .font(AppTypography.subheadlineMedium)
                    .foregroundStyle(Color.textHint)
                    .contentTransition(.opacity)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.cozy) {
                    ForEach(NoteReviewPalette.allCases, id: \.self) { palette in
                        Button {
                            guard palette != selection else { return }
                            onSelect(palette)
                        } label: {
                            RoundedRectangle(cornerRadius: CornerRadius.inlayMedium, style: .continuous)
                                .fill(palette.swatchStyle)
                                .frame(width: 34, height: 34)
                                .overlay {
                                    RoundedRectangle(cornerRadius: CornerRadius.inlayMedium, style: .continuous)
                                        .stroke(
                                            palette == selection ? Color.brand : Color.surfaceBorderSubtle,
                                            lineWidth: palette == selection ? 2 : CardStyle.borderWidth
                                        )
                                }
                                .overlay {
                                    if palette == selection {
                                        Image(systemName: "checkmark")
                                            .font(AppTypography.captionSemibold)
                                            .foregroundStyle(palette.textColor)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(palette.title)
                        .accessibilityAddTraits(palette == selection ? .isSelected : [])
                    }
                }
                .padding(.vertical, Spacing.micro)
            }
        }
        .frame(minHeight: 78)
    }
}

private struct NoteReviewTagSelectionSheet: View {
    let options: [NoteReviewTagOption]
    let selectedIDs: [Int64]
    let onComplete: ([Int64]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draftIDs: Set<Int64>

    init(
        options: [NoteReviewTagOption],
        selectedIDs: [Int64],
        onComplete: @escaping ([Int64]) -> Void
    ) {
        self.options = options
        self.selectedIDs = selectedIDs
        self.onComplete = onComplete
        self._draftIDs = State(initialValue: Set(selectedIDs))
    }

    var body: some View {
        XMSettingsPageScaffold(
            title: "选择标签",
            subtitle: draftSummary,
            onClose: { dismiss() }
        ) {
            VStack(spacing: Spacing.comfortable) {
                if options.isEmpty {
                    EmptyStateView(icon: "tag", message: "暂无书摘标签")
                        .frame(minHeight: 220)
                } else {
                    tagGroup
                    actionBar
                }
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.bottom, Spacing.contentEdge)
        }
    }

    private var tagGroup: some View {
        XMSettingsGroupCard {
            VStack(spacing: Spacing.none) {
                ForEach(options) { option in
                    Button {
                        toggle(option.id)
                    } label: {
                        HStack(spacing: Spacing.base) {
                            VStack(alignment: .leading, spacing: Spacing.micro) {
                                Text(option.title)
                                    .font(AppTypography.subheadlineSemibold)
                                    .foregroundStyle(Color.textPrimary)
                                    .lineLimit(1)

                                Text("\(option.noteCount) 条书摘")
                                    .font(AppTypography.caption2)
                                    .foregroundStyle(Color.textSecondary)
                            }

                            Spacer(minLength: Spacing.base)

                            Image(systemName: draftIDs.contains(option.id) ? "checkmark.circle.fill" : "circle")
                                .font(AppTypography.title3)
                                .foregroundStyle(draftIDs.contains(option.id) ? Color.brand : Color.textHint)
                        }
                        .frame(minHeight: 52)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(option.title)，\(draftIDs.contains(option.id) ? "已选择" : "未选择")")
                }
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: Spacing.base) {
            Button {
                draftIDs.removeAll()
            } label: {
                Text("清空")
                    .font(AppTypography.subheadlineSemibold)
                    .frame(maxWidth: .infinity)
                    .frame(height: Spacing.actionReserved)
            }
            .buttonStyle(.bordered)
            .disabled(draftIDs.isEmpty)

            Button {
                onComplete(options.map(\.id).filter { draftIDs.contains($0) })
                dismiss()
            } label: {
                Text("完成")
                    .font(AppTypography.subheadlineSemibold)
                    .frame(maxWidth: .infinity)
                    .frame(height: Spacing.actionReserved)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.brand)
        }
    }

    private var draftSummary: String {
        draftIDs.isEmpty ? "不限标签" : "已选择 \(draftIDs.count) 个标签"
    }

    private func toggle(_ id: Int64) {
        if draftIDs.contains(id) {
            draftIDs.remove(id)
        } else {
            draftIDs.insert(id)
        }
    }
}
