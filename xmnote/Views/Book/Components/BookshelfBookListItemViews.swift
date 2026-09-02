/**
 * [INPUT]: 依赖 BookshelfBookListItem、BookshelfBookListEditAction、BookshelfBookContextAction、Reicon 菜单图标与 XMBookCover 渲染书籍条目
 * [OUTPUT]: 对外提供带 Reicon 整理/删除菜单的 BookshelfBookListGridItemView 与 BookshelfBookListRowView，供二级书籍列表 collection 单元格复用
 * [POS]: Book 模块二级书籍列表页面私有条目子视图，隔离封面、长按菜单与可访问性描述
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 二级列表整理态书籍视觉参数，避免未选项被误读为禁用内容。
private enum BookshelfBookListSelectionVisualStyle {
    static let editingContentOpacity = 0.92
}

/// 仅在浏览态挂载书籍长按菜单，避免整理/排序态的空菜单手势拦截 collection 原生拖拽。
private struct BookshelfBookContextMenuModifier<MenuContent: View>: ViewModifier {
    let isEnabled: Bool
    @ViewBuilder let menuContent: () -> MenuContent

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .contextMenu {
                    menuContent()
                }
                .xmMenuNeutralTint()
        } else {
            content
        }
    }
}

private extension View {
    /// 按页面模式按需挂载书籍长按菜单，保证排序态长按优先进入 collection drag。
    func bookshelfBookContextMenu<MenuContent: View>(
        isEnabled: Bool,
        @ViewBuilder content: @escaping () -> MenuContent
    ) -> some View {
        modifier(BookshelfBookContextMenuModifier(isEnabled: isEnabled, menuContent: content))
    }
}

/// 二级列表 grid 模式书籍卡片，复用书架封面角标与长按菜单语义。
struct BookshelfBookListGridItemView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let book: BookshelfBookListItem
    let showsNoteCount: Bool
    let sortCriteria: BookshelfSortCriteria
    let titleDisplayMode: BookshelfTitleDisplayMode
    let searchKeyword: String
    let isEditing: Bool
    let isSelected: Bool
    let supportsContextPin: Bool
    let activeWriteAction: BookshelfBookListEditAction?
    let onContextAction: (BookshelfBookContextAction, Int64) -> Void

    private let coverCornerRadius = CornerRadius.inlaySmall

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            cover

            VStack(alignment: .leading, spacing: Spacing.tiny) {
                BookshelfTitleText(
                    text: book.title,
                    mode: titleDisplayMode,
                    style: .captionMedium,
                    color: .textPrimary,
                    highlightKeyword: searchKeyword
                )

                XMKeywordHighlighting.text(
                    metadataText(separator: "，", emptyAuthorFallback: " ", includesNoteCount: false),
                    keyword: searchKeyword,
                    baseFont: AppTypography.caption2,
                    highlightFont: AppTypography.caption2,
                    baseColor: Color.textSecondary
                )
                    .lineLimit(1)

                if let sortAuxiliaryText {
                    Text(sortAuxiliaryText)
                        .font(BookshelfTypography.gridSubtitle)
                        .foregroundStyle(Color.textHint)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(isEditing ? BookshelfBookListSelectionVisualStyle.editingContentOpacity : 1)
        .animation(BookshelfManagementMotion.modeAnimation(reduceMotion: reduceMotion), value: isEditing)
        .contentShape(RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isEditing && isSelected ? .isSelected : [])
        .accessibilityIdentifier("bookshelf.book-list.book.\(book.id)")
        .bookshelfBookContextMenu(isEnabled: !isEditing) {
            contextMenu
        }
    }

    private var cover: some View {
        XMBookCover.responsive(
            urlString: book.cover,
            cornerRadius: coverCornerRadius,
            border: .init(color: .surfaceBorderSubtle, width: StrokeWidth.hairline),
            surfaceStyle: .spine
        )
        .overlay {
            ZStack {
                if book.pinned {
                    BookshelfCoverPinBadge(cornerRadius: coverCornerRadius)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }

                if showsNoteCount, book.noteCount > 0 {
                    BookshelfCoverTextBadge(
                        text: "\(book.noteCount)",
                        placement: .bottomTrailing,
                        tone: .dark,
                        cornerRadius: coverCornerRadius,
                        accessibilityLabel: "\(book.noteCount)条书摘"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
        }
        .overlay {
            BookshelfSelectionCoverOverlay(
                isSelected: isEditing && isSelected,
                cornerRadius: coverCornerRadius
            )
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button {
            onContextAction(.addNote, book.id)
        } label: {
            XMMenuLabel("添加笔记", systemImage: "square.and.pencil")
        }

        if supportsContextPin {
            if book.pinned {
                Button {
                    onContextAction(.unpin, book.id)
                } label: {
                    XMMenuLabel("取消置顶", systemImage: "pin.slash")
                }
                .disabled(activeWriteAction != nil)
            } else {
                Button {
                    onContextAction(.pin, book.id)
                } label: {
                    XMMenuLabel("置顶", systemImage: "pin")
                }
                .disabled(activeWriteAction != nil)
            }
        }

        Button {
            onContextAction(.editBook, book.id)
        } label: {
            XMMenuLabel("编辑书籍", systemImage: "pencil")
        }

        Button {
            onContextAction(.organizeBooks, book.id)
        } label: {
            BookshelfEditingMenuLabel(title: "整理书籍", icon: .checklist)
        }

        Button(role: .destructive) {
            onContextAction(.delete, book.id)
        } label: {
            BookshelfEditingMenuLabel(
                title: "删除书籍",
                icon: .trash,
                foregroundColor: .feedbackError
            )
        }
        .disabled(activeWriteAction != nil)
    }

    private var metadata: String {
        let parts = [
            metadataText(separator: "，", emptyAuthorFallback: "未知作者", includesNoteCount: true),
            sortAuxiliaryText ?? ""
        ]
            .filter { !$0.isEmpty }
        return parts.joined(separator: "，")
    }

    private func metadataText(separator: String, emptyAuthorFallback: String, includesNoteCount: Bool) -> String {
        let authorText = book.author.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = []
        if let searchContextText {
            parts.append(searchContextText)
        }
        if !authorText.isEmpty {
            parts.append(authorText)
        } else if searchContextText == nil {
            parts.append(emptyAuthorFallback)
        }
        if includesNoteCount, showsNoteCount, book.noteCount > 0 {
            parts.append("\(book.noteCount)条书摘")
        }
        return parts.joined(separator: separator)
    }

    private var searchContextText: String? {
        guard hasSearchKeyword,
              !XMKeywordHighlighting.contains(book.title, keyword: searchKeyword),
              !XMKeywordHighlighting.contains(book.author, keyword: searchKeyword) else {
            return nil
        }
        return nil
    }

    private var hasSearchKeyword: Bool {
        !searchKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sortAuxiliaryText: String? {
        book.sortAuxiliaryText(for: sortCriteria)
    }

    private var accessibilityLabel: String {
        if isEditing {
            return "\(book.title)，\(metadata)，\(isSelected ? "已选中" : "未选中")"
        }
        return "\(book.title)，\(metadata)"
    }
}

/// 二级列表书籍行视觉。
struct BookshelfBookListRowView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let book: BookshelfBookListItem
    let showsNoteCount: Bool
    let sortCriteria: BookshelfSortCriteria
    let titleDisplayMode: BookshelfTitleDisplayMode
    let searchKeyword: String
    let isEditing: Bool
    let isSelected: Bool
    let supportsContextPin: Bool
    let activeWriteAction: BookshelfBookListEditAction?
    let onContextAction: (BookshelfBookContextAction, Int64) -> Void

    var body: some View {
        BookshelfBookListRowContent(
            book: book,
            showsNoteCount: showsNoteCount,
            sortCriteria: sortCriteria,
            titleDisplayMode: titleDisplayMode,
            searchKeyword: searchKeyword,
            showsChevron: !isEditing
        )
        .opacity(isEditing ? BookshelfBookListSelectionVisualStyle.editingContentOpacity : 1)
        .overlay {
            if isEditing {
                BookshelfSelectionRowOverlay(isSelected: isSelected)
            }
        }
        .animation(BookshelfManagementMotion.modeAnimation(reduceMotion: reduceMotion), value: isEditing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isEditing && isSelected ? .isSelected : [])
        .accessibilityIdentifier("bookshelf.book-list.book.\(book.id)")
        .bookshelfBookContextMenu(isEnabled: !isEditing) {
            contextMenu
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button {
            onContextAction(.addNote, book.id)
        } label: {
            XMMenuLabel("添加笔记", systemImage: "square.and.pencil")
        }

        if supportsContextPin {
            if book.pinned {
                Button {
                    onContextAction(.unpin, book.id)
                } label: {
                    XMMenuLabel("取消置顶", systemImage: "pin.slash")
                }
                .disabled(activeWriteAction != nil)
            } else {
                Button {
                    onContextAction(.pin, book.id)
                } label: {
                    XMMenuLabel("置顶", systemImage: "pin")
                }
                .disabled(activeWriteAction != nil)
            }
        }

        Button {
            onContextAction(.editBook, book.id)
        } label: {
            XMMenuLabel("编辑书籍", systemImage: "pencil")
        }

        Button {
            onContextAction(.organizeBooks, book.id)
        } label: {
            BookshelfEditingMenuLabel(title: "整理书籍", icon: .checklist)
        }

        Button(role: .destructive) {
            onContextAction(.delete, book.id)
        } label: {
            BookshelfEditingMenuLabel(
                title: "删除书籍",
                icon: .trash,
                foregroundColor: .feedbackError
            )
        }
        .disabled(activeWriteAction != nil)
    }

    private var sortAuxiliaryText: String? {
        book.sortAuxiliaryText(for: sortCriteria)
    }

    private var accessibilityLabel: String {
        let visibleMetadata = [
            book.bookListBasicMetadataText,
            book.bookListRatingAccessibilityText,
            book.bookListReadingAccessibilityText,
            sortAuxiliaryText ?? ""
        ]
            .filter { !$0.isEmpty }
            .joined(separator: "，")
        if isEditing {
            return "\(book.title)，\(visibleMetadata)，\(isSelected ? "已选中" : "未选中")"
        }
        return visibleMetadata.isEmpty ? book.title : "\(book.title)，\(visibleMetadata)"
    }
}
