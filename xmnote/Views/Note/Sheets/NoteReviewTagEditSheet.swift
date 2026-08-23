/**
 * [INPUT]: 依赖 RepositoryContainer、NoteReviewTagEditSnapshot、XMTagSelectionSheet 与外部异步闭包完成标签创建和保存
 * [OUTPUT]: 对外提供 NoteReviewTagEditSheet，以无冗余副标题的单条编辑体验接入统一标签选择基础组件
 * [POS]: Note 模块业务 Sheet 适配层，服务多处书摘操作菜单，不直接访问数据库
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书摘标签编辑 Sheet 适配层，把业务标签模型映射到统一标签选择基础组件。
struct NoteReviewTagEditSheet: View {
    @Environment(RepositoryContainer.self) private var repositories

    let snapshot: NoteReviewTagEditSnapshot
    let onCreateTag: @MainActor @Sendable (String) async throws -> NoteEditorTagOption
    let onTagCatalogMutation: @MainActor @Sendable (TagCatalogMutation) -> Void
    let onSave: @MainActor @Sendable ([NoteEditorTagOption]) async -> Bool

    /// 使用仓储快照初始化单条书摘标签草稿；后续创建和勾选只修改 Sheet 本地状态。
    init(
        snapshot: NoteReviewTagEditSnapshot,
        onCreateTag: @escaping @MainActor @Sendable (String) async throws -> NoteEditorTagOption,
        onTagCatalogMutation: @escaping @MainActor @Sendable (TagCatalogMutation) -> Void,
        onSave: @escaping @MainActor @Sendable ([NoteEditorTagOption]) async -> Bool
    ) {
        self.snapshot = snapshot
        self.onCreateTag = onCreateTag
        self.onTagCatalogMutation = onTagCatalogMutation
        self.onSave = onSave
    }

    var body: some View {
        XMTagSelectionSheet(
            title: "编辑标签",
            items: snapshot.availableTags.map(\.selectionItem),
            initialSelectedIDs: Set(snapshot.selectedTags.map(\.id)),
            layoutPreferenceRepository: repositories.tagSelectionLayoutPreferenceRepository,
            management: XMTagSelectionManagementConfiguration(
                scope: .note,
                repository: repositories.tagManagementRepository,
                onMutation: onTagCatalogMutation
            ),
            onCreate: { name in
                try await onCreateTag(name).selectionItem
            },
            onSave: { selectedItems in
                await onSave(selectedItems.map(\.noteTagOption))
            }
        )
    }
}

private extension NoteEditorTagOption {
    var selectionItem: XMTagSelectionItem {
        XMTagSelectionItem(id: id, title: title)
    }
}

private extension XMTagSelectionItem {
    var noteTagOption: NoteEditorTagOption {
        NoteEditorTagOption(id: id, title: title)
    }
}
