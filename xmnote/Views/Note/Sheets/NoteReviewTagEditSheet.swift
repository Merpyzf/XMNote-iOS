/**
 * [INPUT]: 依赖 NoteReviewCardItem、NoteReviewTagEditSnapshot 与外部异步闭包完成标签创建和保存
 * [OUTPUT]: 对外提供 NoteReviewTagEditSheet，承接书摘回顾卡片的当前书摘标签编辑
 * [POS]: Note 模块业务 Sheet，服务回顾卡片操作菜单，不直接访问数据库
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 回顾卡片标签编辑 Sheet，负责本地草稿选择、新建标签与保存反馈。
struct NoteReviewTagEditSheet: View {
    let item: NoteReviewCardItem
    let snapshot: NoteReviewTagEditSnapshot
    let onCreateTag: (String) async -> NoteEditorTagOption?
    let onSave: ([NoteEditorTagOption]) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var availableTags: [NoteEditorTagOption]
    @State private var selectedTags: [NoteEditorTagOption]
    @State private var inputText = ""
    @State private var isCreating = false
    @State private var isSaving = false

    /// 使用仓储快照初始化标签草稿；后续创建和勾选只修改 Sheet 本地状态。
    init(
        item: NoteReviewCardItem,
        snapshot: NoteReviewTagEditSnapshot,
        onCreateTag: @escaping (String) async -> NoteEditorTagOption?,
        onSave: @escaping ([NoteEditorTagOption]) async -> Bool
    ) {
        self.item = item
        self.snapshot = snapshot
        self.onCreateTag = onCreateTag
        self.onSave = onSave
        _availableTags = State(initialValue: snapshot.availableTags)
        _selectedTags = State(initialValue: snapshot.selectedTags)
    }

    var body: some View {
        XMSettingsPageScaffold(
            title: "编辑标签",
            subtitle: subtitle,
            onClose: { dismiss() }
        ) {
            VStack(spacing: Spacing.comfortable) {
                createTagGroup
                tagSelectionGroup
                actionBar
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.bottom, Spacing.contentEdge)
        }
        .interactiveDismissDisabled(isSaving || isCreating)
    }

    private var createTagGroup: some View {
        XMSettingsGroupCard {
            VStack(alignment: .leading, spacing: Spacing.cozy) {
                Text("新增标签")
                    .font(AppTypography.subheadlineSemibold)
                    .foregroundStyle(Color.textPrimary)

                HStack(spacing: Spacing.cozy) {
                    TextField("输入标签名称", text: $inputText)
                        .font(AppTypography.subheadline)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .disabled(isCreating || isSaving)
                        .onSubmit(createTag)

                    Button(action: createTag) {
                        if isCreating {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "plus")
                                .font(AppTypography.subheadlineSemibold)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(trimmedInput.isEmpty || isCreating || isSaving)
                    .accessibilityLabel("创建标签")
                }
            }
            .padding(.vertical, Spacing.half)
        }
    }

    private var tagSelectionGroup: some View {
        XMSettingsGroupCard {
            VStack(spacing: Spacing.none) {
                if availableTags.isEmpty {
                    Text("暂无可选标签")
                        .font(AppTypography.subheadline)
                        .foregroundStyle(Color.textHint)
                        .frame(maxWidth: .infinity, minHeight: 96)
                } else {
                    ForEach(availableTags) { tag in
                        Button {
                            toggle(tag)
                        } label: {
                            HStack(spacing: Spacing.base) {
                                Text(tag.title)
                                    .font(AppTypography.subheadlineSemibold)
                                    .foregroundStyle(Color.textPrimary)
                                    .lineLimit(1)

                                Spacer(minLength: Spacing.base)

                                Image(systemName: isSelected(tag) ? "checkmark.circle.fill" : "circle")
                                    .font(AppTypography.title3)
                                    .foregroundStyle(isSelected(tag) ? Color.brand : Color.textHint)
                            }
                            .frame(minHeight: 52)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isSaving || isCreating)
                        .accessibilityLabel("\(tag.title)，\(isSelected(tag) ? "已选择" : "未选择")")
                    }
                }
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: Spacing.base) {
            Button {
                dismiss()
            } label: {
                Text("取消")
                    .font(AppTypography.subheadlineSemibold)
                    .frame(maxWidth: .infinity)
                    .frame(height: Spacing.actionReserved)
            }
            .buttonStyle(.bordered)
            .disabled(isSaving || isCreating)

            Button(action: saveTags) {
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .frame(height: Spacing.actionReserved)
                } else {
                    Text("保存")
                        .font(AppTypography.subheadlineSemibold)
                        .frame(maxWidth: .infinity)
                        .frame(height: Spacing.actionReserved)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.brand)
            .disabled(isSaving || isCreating || !hasChanges)
        }
    }

    private var subtitle: String {
        let title = item.bookTitle.isEmpty ? "当前书摘" : item.bookTitle
        guard !selectedTags.isEmpty else { return "\(title) · 未选择标签" }
        return "\(title) · \(selectedTags.count) 个标签"
    }

    private var trimmedInput: String {
        inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasChanges: Bool {
        Set(selectedTags.map(\.id)) != Set(snapshot.selectedTags.map(\.id))
    }

    private func isSelected(_ tag: NoteEditorTagOption) -> Bool {
        selectedTags.contains(where: { $0.id == tag.id })
    }

    private func toggle(_ tag: NoteEditorTagOption) {
        if let index = selectedTags.firstIndex(where: { $0.id == tag.id }) {
            selectedTags.remove(at: index)
        } else {
            selectedTags.append(tag)
        }
    }

    private func createTag() {
        let name = trimmedInput
        guard !name.isEmpty, !isCreating, !isSaving else { return }
        Task {
            isCreating = true
            defer { isCreating = false }
            guard let tag = await onCreateTag(name) else { return }
            if !availableTags.contains(where: { $0.id == tag.id }) {
                availableTags.append(tag)
            }
            if !selectedTags.contains(where: { $0.id == tag.id }) {
                selectedTags.append(tag)
            }
            inputText = ""
        }
    }

    private func saveTags() {
        guard !isSaving, !isCreating else { return }
        Task {
            isSaving = true
            defer { isSaving = false }
            let didSave = await onSave(selectedTags)
            if didSave {
                dismiss()
            }
        }
    }
}
