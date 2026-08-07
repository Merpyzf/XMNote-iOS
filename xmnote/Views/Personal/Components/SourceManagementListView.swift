/**
 * [INPUT]: 依赖 SourceManagementItem/SourceManagementScope、XMKeywordHighlighting 与页面传入的搜索关键词和来源操作回调，承接书籍来源管理页的一列展示与本地拖拽排序
 * [OUTPUT]: 对外提供 SourceManagementListView，封装页面私有来源列表、只读默认来源、上下文菜单与排序提交
 * [POS]: Views/Personal/Components 的书籍来源管理页面私有列表组件，被 SourceManagementView 用作来源主体内容区
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书籍来源管理列表，负责普通态、默认来源只读态和排序态的布局与本地拖拽预览。
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
        List {
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
                        top: Spacing.cozy,
                        leading: Spacing.screenEdge,
                        bottom: Spacing.cozy,
                        trailing: Spacing.screenEdge
                    )
                )
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            .onMove { offsets, destination in
                guard canReorder else { return }
                var nextItems = items
                nextItems.move(fromOffsets: offsets, toOffset: destination)
                onCommitOrder(nextItems.map(\.id))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.surfacePage)
        .environment(\.editMode, .constant(isReordering ? EditMode.active : EditMode.inactive))
        .disabled(isDisabled && !isReordering)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
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
        .xmMenuNeutralTint()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
        .accessibilityAddTraits(shouldActAsButton ? .isButton : AccessibilityTraits())
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
        .padding(.horizontal, Spacing.base)
        .padding(.vertical, Spacing.tight)
        .frame(minHeight: SourceManagementRowMetrics.minHeight, alignment: .center)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous)
                .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
        }
        .contentShape(RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous))
        .opacity(isDisabled && !isReordering ? 0.58 : 1)
    }

    private var sourceIcon: some View {
        Image(systemName: item.isAppDefault ? "building.columns" : "books.vertical")
            .font(AppTypography.subheadlineSemibold)
            .foregroundStyle(item.isAppDefault ? Color.textSecondary : Color.brand)
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
                .frame(width: Spacing.actionReserved, height: Spacing.actionReserved)
                .accessibilityHidden(true)
        } else if !item.isAppDefault {
            Image(systemName: "chevron.right")
                .font(AppTypography.captionSemibold)
                .foregroundStyle(Color.iconSecondary)
                .frame(width: Spacing.actionReserved, height: Spacing.actionReserved)
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

private enum SourceManagementRowMetrics {
    static let minHeight: CGFloat = 64
    static let iconBoxSize: CGFloat = 34
}
