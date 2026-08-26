/**
 * [INPUT]: 依赖 NoteEditorChapterOption、XMSelectionIndicator 与章节选择动作
 * [OUTPUT]: 对外提供 NoteEditorChapterPickerSheet，承载章节搜索与单选
 * [POS]: Views/Note/Sheets 的书摘编辑章节选择业务 Sheet
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 为书摘编辑器提供可搜索的章节单选，并支持清空章节关系。
struct NoteEditorChapterPickerSheet: View {
    let chapters: [NoteEditorChapterOption]
    let selectedChapterID: Int64
    let onSelect: (NoteEditorChapterOption?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var visibleChapters: [NoteEditorChapterOption] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return chapters }
        return chapters.filter { $0.title.localizedCaseInsensitiveContains(keyword) }
    }

    var body: some View {
        NavigationStack {
            List {
                if searchText.isEmpty {
                    Button {
                        onSelect(nil)
                    } label: {
                        HStack {
                            Text("不设置章节")
                                .font(AppTypography.body)
                                .foregroundStyle(Color.textPrimary)
                            Spacer()
                            if selectedChapterID == 0 {
                                XMSelectionIndicator(
                                    style: .checkmarkOnly,
                                    isSelected: true,
                                    font: AppTypography.body,
                                    showsUnselectedBase: false
                                )
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(selectedChapterID == 0 ? "已选择" : "未选择")
                }

                if visibleChapters.isEmpty {
                    if searchText.isEmpty {
                        ContentUnavailableView(
                            "暂无章节",
                            systemImage: "text.book.closed",
                            description: Text("可以先不设置章节，或到目录管理中新增")
                        )
                    } else {
                        ContentUnavailableView.search(text: searchText)
                    }
                } else {
                    ForEach(visibleChapters) { chapter in
                        Button {
                            onSelect(chapter)
                        } label: {
                            HStack(spacing: Spacing.base) {
                                VStack(alignment: .leading, spacing: Spacing.compact) {
                                    HStack(spacing: Spacing.compact) {
                                        Text(chapter.title)
                                            .font(
                                                chapter.displayLevel == 1
                                                    ? AppTypography.bodyMedium
                                                    : AppTypography.body
                                            )
                                            .foregroundStyle(Color.textPrimary)
                                            .lineLimit(2)
                                        if chapter.isStarred == true {
                                            Image(systemName: "star.fill")
                                                .imageScale(.small)
                                                .foregroundStyle(XMStarredAppearance.foreground)
                                                .accessibilityHidden(true)
                                        }
                                    }
                                    if !searchText.isEmpty, !chapter.parentPathText.isEmpty {
                                        Text(chapter.parentPathText)
                                            .font(AppTypography.caption)
                                            .foregroundStyle(Color.textSecondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: Spacing.compact)
                                if selectedChapterID == chapter.id {
                                    XMSelectionIndicator(
                                        style: .checkmarkOnly,
                                        isSelected: true,
                                        font: AppTypography.body,
                                        showsUnselectedBase: false
                                    )
                                }
                            }
                            .padding(.leading, CGFloat(chapter.displayLevel - 1) * Spacing.base)
                            .frame(minHeight: InteractionMetrics.minimumTouchTarget)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(chapter.pathText ?? chapter.title)
                        .accessibilityValue(selectedChapterID == chapter.id ? "已选择" : "未选择")
                        .accessibilityAddTraits(selectedChapterID == chapter.id ? .isSelected : [])
                    }
                }
            }
            .navigationTitle("章节")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "搜索章节")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
            }
        }
    }
}
