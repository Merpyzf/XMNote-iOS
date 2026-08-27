/**
 * [INPUT]: 依赖 BookGroupManagementItem、XMBookGroupCover、XMSelectionIndicator 与 DesignTokens，接收页面传入的选择态、搜索关键字、导航提示与管理动作
 * [OUTPUT]: 对外提供 BookGroupManagementRowView，以自适应分组封面、中性长按菜单和搜索高亮渲染书籍分组管理页的一项分组信息
 * [POS]: Views/Personal/Components 的书籍分组管理页面私有子视图，被 BookGroupManagementView 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书籍分组管理行，展示自适应代表封面、名称、书籍数量与管理入口。
struct BookGroupManagementRowView: View {
    let item: BookGroupManagementItem
    let isSelectionMode: Bool
    let isSelected: Bool
    let isDisabled: Bool
    let showsDisclosureIndicator: Bool
    var searchKeyword = ""
    var onPrimaryAction: (() -> Void)?
    var onRename: (() -> Void)?
    var onDelete: (() -> Void)?

    var body: some View {
        primaryArea
        .modifier(BookGroupManagementRowAccessibilityActions(
            isEnabled: shouldShowManagementMenu,
            onRename: onRename,
            onDelete: onDelete
        ))
    }

    @ViewBuilder
    private var primaryArea: some View {
        if let onPrimaryAction {
            Button(action: onPrimaryAction) {
                cardContent
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .accessibilityLabel(primaryAccessibilityLabel)
            .accessibilityHint(primaryAccessibilityHint)
            .accessibilityAddTraits(primaryAccessibilityTraits)
        } else {
            cardContent
                .accessibilityElement(children: .combine)
                .accessibilityLabel(primaryAccessibilityLabel)
                .accessibilityAddTraits(primaryAccessibilityTraits)
        }
    }

    private var cardContent: some View {
        return primaryContent
            .padding(.vertical, Layout.verticalPadding)
            .frame(minHeight: Layout.cardHeight)
            .contentShape(.interaction, Rectangle())
            .contentShape(.contextMenuPreview, Rectangle())
            .contextMenu {
                if shouldShowManagementMenu {
                    managementMenuItems
                }
            }
    }

    private var primaryContent: some View {
        HStack(spacing: Spacing.tight) {
            if isSelectionMode {
                XMSelectionIndicator(
                    style: .checkbox,
                    isSelected: isSelected,
                    font: AppTypography.title3
                )
                .frame(width: Layout.selectionWidth, height: Layout.minimumHitArea)
                .accessibilityHidden(true)
                .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }

            XMBookGroupCover(covers: item.representativeCovers, style: .adaptiveManagementCompact)
                .frame(width: Layout.coverWidth, height: Layout.coverHeight)

            VStack(alignment: .leading, spacing: Spacing.tiny) {
                XMKeywordHighlighting.text(
                    item.name,
                    keyword: searchKeyword,
                    baseFont: AppTypography.bodyMedium,
                    highlightFont: AppTypography.bodyMedium,
                    baseColor: Color.textPrimary
                )
                .lineLimit(1)
                .truncationMode(.tail)

                Text(item.subtitle)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsDisclosureIndicator {
                Image(systemName: "chevron.right")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.iconSecondary.opacity(isDisabled ? 0 : 0.30))
                    .frame(width: Layout.disclosureWidth, height: Layout.minimumHitArea)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Layout.minimumHitArea, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var managementMenuItems: some View {
        if let onRename {
            Button(action: onRename) {
                XMMenuLabel("重命名分组", systemImage: "pencil")
            }
            .xmMenuNeutralTint()
        }

        if let onDelete {
            Button(role: .destructive, action: onDelete) {
                Label("删除分组", systemImage: "trash")
            }
        }
    }

    private var shouldShowManagementMenu: Bool {
        !isSelectionMode && !isDisabled && onRename != nil && onDelete != nil
    }

    private var primaryAccessibilityLabel: String {
        "\(item.name)，\(item.bookCount) 本"
    }

    private var primaryAccessibilityHint: String {
        if isSelectionMode {
            return "切换分组选择状态"
        }
        if showsDisclosureIndicator {
            return "打开分组书籍列表"
        }
        return ""
    }

    private var primaryAccessibilityTraits: AccessibilityTraits {
        var traits: AccessibilityTraits = []
        if onPrimaryAction != nil {
            traits.formUnion(.isButton)
        }
        if isSelectionMode && isSelected {
            traits.formUnion(.isSelected)
        }
        return traits
    }
}

private enum Layout {
    static let cardHeight: CGFloat = 72
    static let coverWidth: CGFloat = 48
    static let coverHeight: CGFloat = 56
    static let selectionWidth: CGFloat = 34
    static let disclosureWidth: CGFloat = 16
    static let minimumHitArea: CGFloat = InteractionMetrics.minimumTouchTarget
    static let verticalPadding: CGFloat = Spacing.tight
}

private struct BookGroupManagementRowAccessibilityActions: ViewModifier {
    let isEnabled: Bool
    let onRename: (() -> Void)?
    let onDelete: (() -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled, let onRename, let onDelete {
            content
                .accessibilityAction(named: "重命名分组", onRename)
                .accessibilityAction(named: "删除分组", onDelete)
        } else {
            content
        }
    }
}
