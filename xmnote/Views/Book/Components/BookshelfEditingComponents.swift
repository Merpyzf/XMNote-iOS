/**
 * [INPUT]: 依赖 BookshelfPendingAction、BookshelfBookListEditAction 与 SwiftUI 按钮、菜单、图标、表层渲染能力
 * [OUTPUT]: 对外提供书架编辑态顶部栏、选择标识与底部操作栏，并展示移动、更多、删除入口与迁移状态反馈
 * [POS]: Book 模块页面私有编辑态组件集合，服务默认书架选择、置顶和移动入口
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 默认书架编辑态顶部栏，承载退出、已选数量和可见范围选择操作。
struct BookshelfEditHeader: View {
    let selectedCount: Int
    let isAllVisibleSelected: Bool
    let onCancel: () -> Void
    let onSelectAll: () -> Void
    let onInvertSelection: () -> Void

    var body: some View {
        HStack(spacing: Spacing.base) {
            Button("取消", action: onCancel)
                .font(AppTypography.body)
                .foregroundStyle(Color.brand)
                .frame(minHeight: 44)

            Spacer(minLength: Spacing.compact)

            Text("已选 \(selectedCount) 项")
                .font(AppTypography.body)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: Spacing.compact)

            HStack(spacing: Spacing.cozy) {
                Button("全选", action: onSelectAll)
                    .disabled(isAllVisibleSelected)
                Button("反选", action: onInvertSelection)
            }
            .font(AppTypography.body)
            .foregroundStyle(Color.brand)
            .frame(minHeight: 44)
        }
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.vertical, Spacing.compact)
        .background(Color.surfacePage)
        .accessibilityElement(children: .contain)
    }
}

/// 书架 item 选中态角标，用于网格与列表模式的统一视觉反馈。
struct BookshelfSelectionOverlay: View {
    let isSelected: Bool

    var body: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(AppTypography.title2)
            .fontWeight(.semibold)
            .symbolRenderingMode(.palette)
            .foregroundStyle(isSelected ? Color.white : Color.surfaceBorderDefault, isSelected ? Color.brand : Color.surfaceCard)
            .background(Color.surfaceCard.opacity(0.92), in: Circle())
            .shadow(color: Color.black.opacity(isSelected ? 0.16 : 0.08), radius: 4, y: 1)
            .padding(Spacing.half)
            .accessibilityHidden(true)
    }
}

/// 默认书架编辑态底部栏，承载已完成 Android 语义核对的置顶与移动入口。
struct BookshelfEditBottomBar: View {
    let selectedCount: Int
    let canPin: Bool
    let canMove: Bool
    let canMore: Bool
    let canDelete: Bool
    let moveDisabledReason: String?
    let activeAction: BookshelfPendingAction?
    let moreActions: [BookshelfBookListEditAction]
    let isLoadingOptions: Bool
    let notice: String?
    let onPin: () -> Void
    let onMove: () -> Void
    let onMoreAction: (BookshelfBookListEditAction) -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: Spacing.cozy) {
            HStack(spacing: Spacing.compact) {
                editActionButton(
                    action: .pin,
                    icon: "pin",
                    isEnabled: canPin,
                    onTap: onPin
                )

                moveActionButton

                moreActionButton

                editActionButton(
                    action: .delete,
                    icon: "trash",
                    isEnabled: canDelete,
                    onTap: onDelete
                )
            }

            Text(statusText)
                .font(AppTypography.caption)
                .foregroundStyle(Color.textSecondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .lineLimit(1)
        }
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.top, Spacing.base)
        .padding(.bottom, Spacing.cozy)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var moveActionButton: some View {
        Button(action: onMove) {
            editActionLabel(action: .move, icon: "folder", isEnabled: canMove)
        }
        .buttonStyle(.plain)
        .disabled(!canMove)
        .accessibilityLabel(canMove ? "移动选中项" : "移动，\(moveDisabledReason ?? "需至少选中一个普通项")")
    }

    private var moreActionButton: some View {
        Menu {
            ForEach(moreActions) { action in
                Button(role: action.isDestructive ? .destructive : nil) {
                    onMoreAction(action)
                } label: {
                    Label(action.title, systemImage: action.systemImage)
                }
                .disabled(isBusy)
            }
        } label: {
            editActionLabel(action: .more, icon: "ellipsis.circle", isEnabled: canMore)
        }
        .buttonStyle(.plain)
        .disabled(!canMore || isBusy)
        .accessibilityLabel(canMore ? "更多操作" : "更多操作，当前不可用")
    }

    private var statusText: String {
        if let notice, !notice.isEmpty {
            return notice
        }
        if let activeAction {
            return "正在\(activeAction.title)..."
        }
        if isLoadingOptions {
            return "正在加载批量编辑选项..."
        }
        if selectedCount == 0 {
            return "选择书籍或分组后可执行置顶、移动、批量管理与删除"
        }
        if let moveDisabledReason {
            return moveDisabledReason
        }
        return "已选 \(selectedCount) 项，更多管理仅作用于书籍；分组会被自动忽略"
    }

    private var isBusy: Bool {
        activeAction != nil || isLoadingOptions
    }

    private func editActionButton(
        action: BookshelfPendingAction,
        icon: String,
        isEnabled: Bool,
        onTap: @escaping () -> Void
    ) -> some View {
        Button(action: onTap) {
            editActionLabel(action: action, icon: icon, isEnabled: isEnabled)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isBusy)
        .accessibilityLabel(isEnabled ? action.title : "\(action.title)，当前不可用")
    }

    private func editActionLabel(
        action: BookshelfPendingAction,
        icon: String,
        isEnabled: Bool
    ) -> some View {
        VStack(spacing: Spacing.compact) {
            Image(systemName: icon)
                .font(AppTypography.headline)
                .fontWeight(.medium)
            Text(action.title)
                .font(AppTypography.caption2)
        }
        .foregroundStyle(foregroundColor(for: action, isEnabled: isEnabled))
        .frame(maxWidth: .infinity, minHeight: 48)
        .contentShape(Rectangle())
    }

    private func foregroundColor(
        for action: BookshelfPendingAction,
        isEnabled: Bool
    ) -> Color {
        guard isEnabled else {
            return action == .delete ? Color.feedbackError.opacity(0.55) : Color.textSecondary.opacity(0.55)
        }
        return action == .delete ? Color.feedbackError : Color.textPrimary
    }
}
