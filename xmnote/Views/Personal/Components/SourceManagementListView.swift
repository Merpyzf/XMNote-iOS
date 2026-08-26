/**
 * [INPUT]: 依赖 SourceManagementItem/SourceManagementScope、XMKeywordHighlighting 与页面传入的搜索关键词和来源操作回调，承接书籍来源管理页的一列展示与本地拖拽排序
 * [OUTPUT]: 对外提供 SourceManagementListView，向页面的系统分组 List 输出无显式编辑附件的来源行、只读默认来源、滑动/上下文/无障碍操作与排序提交
 * [POS]: Views/Personal/Components 的书籍来源管理页面私有行集合，被 SourceManagementView 的单一分组容器消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书籍来源管理行集合，由页面持有唯一 List，以便搜索、空态和数据行共享同一滚动上下文。
struct SourceManagementListView: View {
    let items: [SourceManagementItem]
    let scope: SourceManagementScope
    let searchKeyword: String
    let isReordering: Bool
    let isDisabled: Bool
    let onPrimaryAction: (SourceManagementItem) -> Void
    let onRename: (SourceManagementItem) -> Void
    let onDelete: (SourceManagementItem) -> Void
    let onCommitOrder: ([Int64]) -> Void

    var body: some View {
        ForEach(items) { item in
            SourceManagementRowView(
                item: item,
                scope: scope,
                searchKeyword: searchKeyword,
                isReordering: isReordering,
                isDisabled: isDisabled,
                onPrimaryAction: { onPrimaryAction(item) },
                onRename: { onRename(item) },
                onDelete: { onDelete(item) }
            )
            .listRowInsets(
                EdgeInsets(
                    top: 0,
                    leading: Spacing.base,
                    bottom: 0,
                    trailing: Spacing.cozy
                )
            )
            .listRowBackground(Color.surfaceCard)
        }
        .onMove { offsets, destination in
            guard canReorder else { return }
            var nextItems = items
            nextItems.move(fromOffsets: offsets, toOffset: destination)
            onCommitOrder(nextItems.map(\.id))
        }
    }

    private var canReorder: Bool {
        scope == .mine && isReordering && !isDisabled
    }
}

private struct SourceManagementRowView: View {
    let item: SourceManagementItem
    let scope: SourceManagementScope
    let searchKeyword: String
    let isReordering: Bool
    let isDisabled: Bool
    let onPrimaryAction: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Group {
            if shouldActAsButton {
                Button(action: onPrimaryAction) {
                    rowContent
                }
                .buttonStyle(.plain)
            } else {
                rowContent
            }
        }
        .contextMenu {
            if shouldShowContextMenu {
                Button(action: onRename) {
                    XMMenuLabel("编辑", systemImage: "pencil")
                }
                Button(role: .destructive, action: onDelete) {
                    Label("删除", systemImage: "trash")
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if shouldShowContextMenu {
                Button(role: .destructive, action: onDelete) {
                    Label("删除", systemImage: "trash")
                }
                Button(action: onRename) {
                    Label("编辑", systemImage: "pencil")
                }
                .tint(Color.iconSecondary)
            }
        }
        .xmMenuNeutralTint()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
        .accessibilityAddTraits(shouldActAsButton ? .isButton : AccessibilityTraits())
        .modifier(
            SourceManagementRowAccessibilityActions(
                isEnabled: shouldShowContextMenu,
                onRename: onRename,
                onDelete: onDelete
            )
        )
    }

    private var rowContent: some View {
        HStack(alignment: .center, spacing: Spacing.base) {
            sourceIcon

            VStack(alignment: .leading, spacing: Spacing.compact) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.cozy) {
                    XMKeywordHighlighting.text(
                        displayName,
                        keyword: searchKeyword,
                        baseFont: AppTypography.subheadlineMedium,
                        highlightFont: AppTypography.subheadlineSemibold,
                        baseColor: Color.textPrimary
                    )
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if item.isAppDefault {
                        Image(systemName: "checkmark.seal")
                            .font(AppTypography.caption)
                            .foregroundStyle(Color.textHint)
                            .accessibilityHidden(true)
                    }
                }

                HStack(spacing: Spacing.cozy) {
                    Text(associationText)
                    if item.isHidden {
                        Text("已隐藏")
                    }
                }
                .font(AppTypography.caption)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailingAccessory
        }
        .padding(.vertical, Spacing.tight)
        .frame(minHeight: SourceManagementRowMetrics.minHeight, alignment: .center)
        .contentShape(Rectangle())
        .opacity(isDisabled && !isReordering ? 0.58 : 1)
    }

    private var sourceIcon: some View {
        Image(systemName: item.isAppDefault ? "building.columns" : "books.vertical")
            .font(AppTypography.subheadlineSemibold)
            .foregroundStyle(Color.iconSecondary)
            .frame(width: SourceManagementRowMetrics.iconBoxSize, height: SourceManagementRowMetrics.iconBoxSize)
            .background(Color.surfaceNested, in: RoundedRectangle(cornerRadius: CornerRadius.inlayMedium, style: .continuous))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var trailingAccessory: some View {
        if isReordering && scope == .mine {
            Image(systemName: "line.3.horizontal")
                .font(AppTypography.subheadlineSemibold)
                .foregroundStyle(Color.iconSecondary)
                .frame(
                    width: SourceManagementRowMetrics.reorderHandleSlotSize,
                    height: SourceManagementRowMetrics.reorderHandleSlotSize
                )
                .accessibilityHidden(true)
        }
    }

    private var shouldActAsButton: Bool {
        !isDisabled && !isReordering && !item.isAppDefault
    }

    private var shouldShowContextMenu: Bool {
        !isDisabled && !isReordering && !item.isAppDefault
    }

    private var displayName: String {
        item.name.isEmpty ? "未命名来源" : item.name
    }

    private var associationText: String {
        item.associatedBookCount > 0 ? "关联 \(item.associatedBookCount) 本书" : "未关联书籍"
    }

    private var accessibilityLabel: String {
        var parts = [displayName, associationText]
        if item.isAppDefault {
            parts.append("默认来源")
        }
        if item.isHidden {
            parts.append("已隐藏")
        }
        return parts.joined(separator: "，")
    }

    private var accessibilityHint: String {
        if item.isAppDefault {
            return "默认来源只读"
        }
        if isReordering {
            return "可拖动调整顺序"
        }
        return "轻点编辑，长按查看更多操作"
    }
}

private struct SourceManagementRowAccessibilityActions: ViewModifier {
    let isEnabled: Bool
    let onRename: () -> Void
    let onDelete: () -> Void

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .accessibilityAction(named: "编辑来源", onRename)
                .accessibilityAction(named: "删除来源", onDelete)
        } else {
            content
        }
    }
}

private enum SourceManagementRowMetrics {
    static let minHeight: CGFloat = 64
    static let iconBoxSize: CGFloat = 34
    static let reorderHandleSlotSize: CGFloat = InteractionMetrics.minimumTouchTarget
}
