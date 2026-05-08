/**
 * [INPUT]: 依赖 BookshelfBatchEditOptions 中的标签、来源、阅读状态候选项，依赖外层 ViewModel 闭包提交批量写入意图
 * [OUTPUT]: 对外提供移组、书单、标签、来源、阅读状态与导出入口等批量编辑 Sheet
 * [POS]: Book 模块业务 Sheet，被 BookshelfBookListView 的编辑态批量操作入口唤起
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 二级列表移入分组 Sheet，单选目标分组后提交批量移动意图。
struct BookshelfMoveGroupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: Int64

    let options: [BookEditorNamedOption]
    let selectedCount: Int
    let onConfirm: (Int64) -> Void

    /// 构建移入分组 Sheet，默认选中第一个有效分组。
    init(
        options: [BookEditorNamedOption],
        selectedCount: Int,
        onConfirm: @escaping (Int64) -> Void
    ) {
        self.options = options
        self.selectedCount = selectedCount
        self.onConfirm = onConfirm
        self._selectedID = State(initialValue: options.first?.id ?? 0)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(options) { option in
                        Button {
                            selectedID = option.id
                        } label: {
                            BookshelfBatchOptionRow(
                                title: option.title,
                                isSelected: selectedID == option.id
                            )
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("将 \(selectedCount) 本书移入所选分组；书籍会取消置顶并从原分组关系中移除。")
                        .font(AppTypography.caption)
                }
            }
            .navigationTitle("移入分组")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        onConfirm(selectedID)
                        dismiss()
                    }
                    .disabled(selectedID == 0)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// 默认书架批量加入书单 Sheet，支持选择已有手动书单或输入名称创建新书单。
struct BookshelfAddToBookListSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: Int64?
    @State private var newTitle = ""

    let options: [BookEditorNamedOption]
    let selectedCount: Int
    let onConfirm: (Int64?, String?) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("新书单名称", text: $newTitle)
                        .textInputAutocapitalization(.never)
                } footer: {
                    Text("填写名称会创建新书单，并将 \(selectedCount) 本书加入其中。")
                        .font(AppTypography.caption)
                }

                Section {
                    if options.isEmpty {
                        Text("暂无手动书单，可直接创建新书单。")
                            .font(AppTypography.body)
                            .foregroundStyle(Color.textSecondary)
                    } else {
                        ForEach(options) { option in
                            Button {
                                newTitle = ""
                                selectedID = option.id
                            } label: {
                                BookshelfBatchOptionRow(
                                    title: option.title,
                                    isSelected: selectedID == option.id
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text("已有书单")
                } footer: {
                    Text("已存在于书单中的书籍会保持原关系，不会重复添加。")
                        .font(AppTypography.caption)
                }
            }
            .navigationTitle("加入书单")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: newTitle) { _, value in
                if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    selectedID = nil
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        onConfirm(selectedID, trimmedNewTitle.isEmpty ? nil : trimmedNewTitle)
                        dismiss()
                    }
                    .disabled(!canSubmit)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var trimmedNewTitle: String {
        newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        selectedID != nil || !trimmedNewTitle.isEmpty
    }
}

/// 默认书架批量导出配置壳层，承接 Android 底部导出入口的导航语义。
struct BookshelfBatchExportSheet: View {
    @Environment(\.dismiss) private var dismiss

    let kind: BookshelfBatchExportKind
    let bookIDs: [Int64]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("导出范围", value: "\(bookIDs.count) 本书")
                    LabeledContent("导出类型", value: kind.title)
                } footer: {
                    Text("导出配置页已按 Android 入口接入；文件格式、目标位置与分享能力将在导出模块迁移时在此继续补齐。")
                        .font(AppTypography.caption)
                }
            }
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

/// 二级列表批量标签 Sheet，支持空选择并由 Repository 区分单本替换与多本追加。
struct BookshelfBatchTagsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIDs: Set<Int64>

    let options: [BookEditorNamedOption]
    let selectedCount: Int
    let allowsEmptySelection: Bool
    let onConfirm: ([Int64]) -> Void

    /// 构建批量标签 Sheet；单本书预选已有标签，多本书默认不预选且不允许空提交。
    init(
        options: [BookEditorNamedOption],
        selectedCount: Int,
        initialSelectedIDs: [Int64],
        allowsEmptySelection: Bool,
        onConfirm: @escaping ([Int64]) -> Void
    ) {
        self.options = options
        self.selectedCount = selectedCount
        self.allowsEmptySelection = allowsEmptySelection
        self.onConfirm = onConfirm
        let validIDs = Set(options.map(\.id))
        self._selectedIDs = State(initialValue: Set(initialSelectedIDs.filter { validIDs.contains($0) }))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if options.isEmpty {
                        Text("暂无可用标签，确认后会清空单本书标签；多本书空选择不会改动现有标签。")
                            .font(AppTypography.body)
                            .foregroundStyle(Color.textSecondary)
                    } else {
                        ForEach(options) { option in
                            Button {
                                toggle(option.id)
                            } label: {
                                BookshelfBatchOptionRow(
                                    title: option.title,
                                    isSelected: selectedIDs.contains(option.id)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } footer: {
                    Text(footerText)
                        .font(AppTypography.caption)
                }
            }
            .navigationTitle("设置标签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        onConfirm(orderedSelectedIDs)
                        dismiss()
                    }
                    .disabled(!canSubmit)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var orderedSelectedIDs: [Int64] {
        options.map(\.id).filter { selectedIDs.contains($0) }
    }

    private var footerText: String {
        if allowsEmptySelection {
            return "单本书会替换为当前选中的标签，允许提交空标签。"
        }
        if orderedSelectedIDs.isEmpty {
            return "多本书只追加选中的缺失标签，请至少选择一个标签。"
        }
        return "多本书只会追加选中的缺失标签，不会删除已有标签。"
    }

    private var canSubmit: Bool {
        allowsEmptySelection || !orderedSelectedIDs.isEmpty
    }

    /// 切换单个标签选中状态。
    private func toggle(_ id: Int64) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }
}

/// 二级列表批量来源 Sheet，单选一个有效来源后提交。
struct BookshelfBatchSourceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: Int64

    let options: [BookEditorNamedOption]
    let selectedCount: Int
    let onConfirm: (Int64) -> Void

    /// 构建批量来源 Sheet，默认选中第一个有效来源。
    init(
        options: [BookEditorNamedOption],
        selectedCount: Int,
        initialSelectedID: Int64?,
        onConfirm: @escaping (Int64) -> Void
    ) {
        self.options = options
        self.selectedCount = selectedCount
        self.onConfirm = onConfirm
        let optionIDs = Set(options.map(\.id))
        let initialID = initialSelectedID.flatMap { optionIDs.contains($0) ? $0 : nil }
            ?? options.first?.id
            ?? 0
        self._selectedID = State(initialValue: initialID)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(options) { option in
                        Button {
                            selectedID = option.id
                        } label: {
                            BookshelfBatchOptionRow(
                                title: option.title,
                                isSelected: selectedID == option.id
                            )
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("将 \(selectedCount) 本书的来源更新为所选来源。")
                        .font(AppTypography.caption)
                }
            }
            .navigationTitle("设置来源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        onConfirm(selectedID)
                        dismiss()
                    }
                    .disabled(selectedID == 0)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// 二级列表批量阅读状态 Sheet，读完状态要求选择评分。
struct BookshelfBatchReadStatusSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedStatusID: Int64
    @State private var changedAt = Date()
    @State private var ratingValue: Double = 0

    let options: [BookEditorNamedOption]
    let selectedCount: Int
    let onConfirm: (Int64, Date, Int64?) -> Void

    /// 构建批量阅读状态 Sheet，优先使用单本或上下文状态，否则回退到“在读”。
    init(
        options: [BookEditorNamedOption],
        selectedCount: Int,
        initialStatusID: Int64?,
        initialChangedAt: Date?,
        initialRatingScore: Int64?,
        onConfirm: @escaping (Int64, Date, Int64?) -> Void
    ) {
        self.options = options
        self.selectedCount = selectedCount
        self.onConfirm = onConfirm
        let optionIDs = Set(options.map(\.id))
        let preferredID = initialStatusID.flatMap { optionIDs.contains($0) ? $0 : nil }
            ?? options.first(where: { $0.id == BookEntryReadingStatus.reading.rawValue })?.id
            ?? options.first?.id
            ?? 0
        self._selectedStatusID = State(initialValue: preferredID)
        self._changedAt = State(initialValue: initialChangedAt ?? Date())
        let initialRating = min(max(Double(initialRatingScore ?? 0) / 10.0, 0), 5)
        self._ratingValue = State(initialValue: initialRating)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("阅读状态") {
                    ForEach(options) { option in
                        Button {
                            selectedStatusID = option.id
                        } label: {
                            BookshelfBatchOptionRow(
                                title: option.title,
                                isSelected: selectedStatusID == option.id
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section("状态时间") {
                    DatePicker(
                        "变更时间",
                        selection: $changedAt,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                }

                if isFinished {
                    Section {
                        VStack(alignment: .leading, spacing: Spacing.compact) {
                            HStack {
                                Text("评分")
                                    .font(AppTypography.body)
                                    .foregroundStyle(Color.textPrimary)
                                Spacer()
                                Text(ratingTitle)
                                    .font(AppTypography.body)
                                    .foregroundStyle(ratingValue > 0 ? Color.textPrimary : Color.feedbackError)
                            }

                            Slider(value: $ratingValue, in: 0...5, step: 0.5)
                                .accessibilityLabel("评分")
                        }
                    } footer: {
                        Text("读完状态会同步评分，并把阅读进度推进到终点。")
                            .font(AppTypography.caption)
                    }
                }
            }
            .navigationTitle("设置状态")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        onConfirm(selectedStatusID, changedAt, ratingScore)
                        dismiss()
                    }
                    .disabled(!canSubmit)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var isFinished: Bool {
        selectedStatusID == BookEntryReadingStatus.finished.rawValue
    }

    private var canSubmit: Bool {
        selectedStatusID != 0 && (!isFinished || ratingScore != nil)
    }

    private var ratingScore: Int64? {
        guard isFinished else { return nil }
        let score = Int64((ratingValue * 10).rounded())
        return score > 0 ? score : nil
    }

    private var ratingTitle: String {
        guard ratingValue > 0 else { return "未评分" }
        return String(format: "%.1f 星", ratingValue)
    }
}

/// 批量编辑 Sheet 中的统一单选/多选行视觉。
private struct BookshelfBatchOptionRow: View {
    let title: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: Spacing.base) {
            Text(title)
                .font(AppTypography.body)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(2)

            Spacer(minLength: Spacing.compact)

            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(AppTypography.body)
                .foregroundStyle(isSelected ? Color.brand : Color.textHint)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)，\(isSelected ? "已选中" : "未选中")")
    }
}
