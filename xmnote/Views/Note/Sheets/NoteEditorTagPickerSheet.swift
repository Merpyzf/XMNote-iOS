/**
 * [INPUT]: 依赖 RepositoryContainer、NoteEditorTagOption、XMTagSelectionSheet 与标签目录动作
 * [OUTPUT]: 对外提供 NoteEditorTagPickerSheet，承载书摘标签选择、创建、重命名和删除
 * [POS]: Views/Note/Sheets 的书摘编辑标签业务 Sheet；Repository 仍由 Feature 层注入
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 把书摘编辑器标签模型适配到公共标签选择 Sheet，并在 Feature 层持有 Repository 编排。
struct NoteEditorTagPickerSheet: View {
    @Environment(RepositoryContainer.self) private var repositories

    let availableTags: [NoteEditorTagOption]
    let selectedTags: [NoteEditorTagOption]
    let onCreate: @MainActor @Sendable (String) async throws -> NoteEditorTagOption
    let onTagCatalogMutation: @MainActor @Sendable (TagCatalogMutation) -> Void
    let onSave: @MainActor @Sendable ([NoteEditorTagOption]) async -> Bool

    var body: some View {
        XMTagSelectionSheet(
            title: "编辑标签",
            items: availableTags.map { XMTagSelectionItem(id: $0.id, title: $0.title) },
            initialSelectedIDs: Set(selectedTags.map(\.id)),
            layout: XMTagSelectionLayoutConfiguration(
                initialMode: repositories.tagSelectionLayoutPreferenceRepository.fetchLayoutMode(),
                onChange: { mode in
                    repositories.tagSelectionLayoutPreferenceRepository.saveLayoutMode(mode)
                }
            ),
            management: XMTagSelectionManagementConfiguration(
                scope: .note,
                onRename: { tagID, name in
                    try await repositories.tagManagementRepository.updateTag(
                        tagID: tagID,
                        name: name,
                        scope: .note
                    )
                },
                onDelete: { tagIDs in
                    try await repositories.tagManagementRepository.deleteTags(
                        tagIDs: tagIDs,
                        scope: .note
                    )
                },
                onMutation: onTagCatalogMutation
            ),
            onCreate: { name in
                let tag = try await onCreate(name)
                return XMTagSelectionItem(id: tag.id, title: tag.title)
            },
            onSave: { items in
                await onSave(items.map { NoteEditorTagOption(id: $0.id, title: $0.title) })
            }
        )
    }
}
