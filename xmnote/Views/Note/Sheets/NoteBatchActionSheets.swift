/**
 * [INPUT]: 依赖 RepositoryContainer、NoteEditorChapterOption/NoteEditorTagOption 批量候选模型与 DesignTokens
 * [OUTPUT]: 对外提供带层级/路径消歧的 NoteChapterSelectionSheet，以及支持可选批量上下文的 NoteTagSelectionSheet
 * [POS]: Note/Sheets 的批量编辑辅助页面，由 NoteExcerptListView 和 NoteMergeView 以系统 Sheet 呈现
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 章节单选 Sheet，自行处理选择和 dismiss，调用方只接收最终章节 ID。
struct NoteChapterSelectionSheet: View {
    let title: String
    let allowsRootSelection: Bool
    let onSelect: (Int64) -> Void
    let onCreate: @MainActor @Sendable (Int64, String) async throws -> NoteEditorChapterOption

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var currentOptions: [NoteEditorChapterOption]
    @State private var chapterName = ""
    @State private var parentID: Int64 = 0
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var searchText = ""

    init(
        title: String = "移动到章节",
        allowsRootSelection: Bool = false,
        options: [NoteEditorChapterOption],
        onSelect: @escaping (Int64) -> Void,
        onCreate: @escaping @MainActor @Sendable (Int64, String) async throws -> NoteEditorChapterOption
    ) {
        self.title = title
        self.allowsRootSelection = allowsRootSelection
        self.onSelect = onSelect
        self.onCreate = onCreate
        _currentOptions = State(initialValue: options)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("已有章节") {
                    if allowsRootSelection {
                        Button {
                            onSelect(0)
                            dismiss()
                        } label: {
                            HStack(spacing: Spacing.base) {
                                Image(systemName: "tray")
                                    .font(AppTypography.subheadline)
                                    .foregroundStyle(Color.brand)
                                    .frame(width: Spacing.section)
                                Text("未分章节")
                                    .font(AppTypography.body)
                                    .foregroundStyle(Color.textPrimary)
                                Spacer(minLength: Spacing.compact)
                            }
                            .frame(minHeight: Spacing.actionReserved)
                        }
                        .buttonStyle(.plain)
                    }
                    if visibleOptions.isEmpty {
                        if searchText.isEmpty {
                            Text("当前书籍还没有章节")
                                .font(AppTypography.callout)
                                .foregroundStyle(Color.textHint)
                        } else {
                            ContentUnavailableView.search(text: searchText)
                        }
                    } else {
                        ForEach(visibleOptions) { option in
                            Button {
                                onSelect(option.id)
                                dismiss()
                            } label: {
                                NoteChapterSelectionRow(
                                    option: option,
                                    showsParentPath: !searchText.isEmpty
                                )
                                .frame(minHeight: Spacing.actionReserved)
                            }
                            .buttonStyle(.plain)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(option.pathText ?? option.title)
                            .accessibilityHint("移动到此章节")
                        }
                    }
                }

                Section {
                    Picker("父章节", selection: $parentID) {
                        Text("根章节").tag(Int64(0))
                        ForEach(eligibleParentOptions) { option in
                            Text(option.pathText ?? option.title).tag(option.id)
                        }
                    }
                    TextField("章节名称", text: $chapterName)
                        .textInputAutocapitalization(.sentences)
                    Button(isCreating ? "创建中…" : "创建并移动") {
                        createChapter()
                    }
                    .disabled(chapterName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCreating)
                    if let errorMessage {
                        Text(errorMessage)
                            .font(AppTypography.caption)
                            .foregroundStyle(Color.feedbackError)
                    }
                } header: {
                    Text("新建章节")
                } footer: {
                    Text("最多支持 \(ChapterManagementPolicy.maximumDepth) 级，已到最深层的章节不再作为父章节候选")
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                }
            }
            .listStyle(.plain)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "搜索章节")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private var visibleOptions: [NoteEditorChapterOption] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return currentOptions }
        return currentOptions.filter { $0.title.localizedCaseInsensitiveContains(keyword) }
    }

    private var eligibleParentOptions: [NoteEditorChapterOption] {
        currentOptions.filter { $0.displayLevel < ChapterManagementPolicy.maximumDepth }
    }

    /// 创建任务由 Sheet 生命周期托管；取消页面会自动取消 Task，成功后立即使用真实 ID 完成移动。
    private func createChapter() {
        let name = chapterName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !isCreating else { return }
        isCreating = true
        errorMessage = nil
        Task {
            do {
                let option = try await onCreate(parentID, name)
                try Task.checkCancellation()
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.28)) {
                    currentOptions.append(option)
                }
                onSelect(option.id)
                dismiss()
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                isCreating = false
            }
        }
    }
}

/// 章节单选行用真实层级缩进保留树结构，搜索时补充父路径消除同名歧义。
private struct NoteChapterSelectionRow: View {
    let option: NoteEditorChapterOption
    let showsParentPath: Bool

    var body: some View {
        HStack(spacing: Spacing.base) {
            Image(systemName: option.displayLevel == 1 ? "text.book.closed" : "text.page")
                .font(AppTypography.subheadline)
                .foregroundStyle(option.displayLevel == 1 ? Color.brand : Color.textSecondary)
                .frame(width: Spacing.section)

            VStack(alignment: .leading, spacing: Spacing.compact) {
                HStack(spacing: Spacing.compact) {
                    Text(option.title)
                        .font(option.displayLevel == 1 ? AppTypography.bodyMedium : AppTypography.body)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(2)
                    if option.isStarred == true {
                        Image(systemName: "star.fill")
                            .imageScale(.small)
                            .foregroundStyle(Color.ratingActive)
                            .accessibilityHidden(true)
                    }
                }
                if showsParentPath, !option.parentPathText.isEmpty {
                    Text(option.parentPathText)
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: Spacing.compact)
            Image(systemName: "chevron.right")
                .font(AppTypography.caption)
                .foregroundStyle(Color.textHint)
        }
        .padding(.leading, CGFloat(option.displayLevel - 1) * Spacing.base)
        .contentShape(Rectangle())
    }
}

/// 标签多选 Sheet 适配层，确认后以完整 ID 集替换每条所选书摘的标签关系。
struct NoteTagSelectionSheet: View {
    @Environment(RepositoryContainer.self) private var repositories

    let title: String
    let contextText: String?
    let onCreate: @MainActor @Sendable (String) async throws -> NoteEditorTagOption
    let onTagCatalogMutation: @MainActor @Sendable (TagCatalogMutation) -> Void
    let onSave: @MainActor @Sendable ([NoteEditorTagOption]) async -> Bool
    private let options: [NoteEditorTagOption]
    private let initialIDs: Set<Int64>

    /// 初始 ID 用于单条编辑或合并草稿回显；批量多条可传空集合表达统一重选。
    init(
        title: String = "设置标签",
        contextText: String? = nil,
        options: [NoteEditorTagOption],
        initialIDs: Set<Int64> = [],
        onCreate: @escaping @MainActor @Sendable (String) async throws -> NoteEditorTagOption,
        onTagCatalogMutation: @escaping @MainActor @Sendable (TagCatalogMutation) -> Void,
        onSave: @escaping @MainActor @Sendable ([NoteEditorTagOption]) async -> Bool
    ) {
        self.title = title
        self.contextText = contextText
        self.options = options
        self.initialIDs = initialIDs
        self.onCreate = onCreate
        self.onTagCatalogMutation = onTagCatalogMutation
        self.onSave = onSave
    }

    var body: some View {
        XMTagSelectionSheet(
            title: title,
            contextText: contextText,
            items: options.map { XMTagSelectionItem(id: $0.id, title: $0.title) },
            initialSelectedIDs: initialIDs,
            layoutPreferenceRepository: repositories.tagSelectionLayoutPreferenceRepository,
            management: XMTagSelectionManagementConfiguration(
                scope: .note,
                repository: repositories.tagManagementRepository,
                onMutation: onTagCatalogMutation
            ),
            onCreate: { name in
                let option = try await onCreate(name)
                return XMTagSelectionItem(id: option.id, title: option.title)
            },
            onSave: { selectedItems in
                await onSave(
                    selectedItems.map { NoteEditorTagOption(id: $0.id, title: $0.title) }
                )
            }
        )
    }
}
