/**
 * [INPUT]: 依赖 BookshelfPendingAction、BookshelfBookListEditAction 与 SwiftUI 按钮、图标、横向滚动、表层渲染、TabBar snapshot 交接和动画能力
 * [OUTPUT]: 对外提供书架编辑态顶部栏、选择标识、底部操作面板、管理模式转场与 TabBar snapshot 恢复交接参数
 * [POS]: Book 模块页面私有编辑态组件集合，服务默认书架选择、置顶、移动、横向平铺批量操作与删除入口
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书架退出管理模式时通知根 Tab 容器进行真实 TabBar 快照交接的事件。
enum BookshelfTabBarSnapshotHandoffEvent: Equatable {
    case prepareSnapshot
    case showSnapshot
    case hideSnapshot
}

/// 书架管理模式的统一动效参数，保证顶部 chrome、内容 inset 与底部面板按同一语义节奏切换。
enum BookshelfManagementMotion {
    static let modeTransition: Animation = .smooth(duration: 0.26)
    static let panelTransition: Animation = .smooth(duration: 0.24)
    static let restoreTransition: Animation = .smooth(duration: 0.22)

    static func modeAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.16) : modeTransition
    }

    static func panelAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.14) : panelTransition
    }

    static func restoreAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.14) : restoreTransition
    }

    static func topChromeTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -4))
    }

    static func bottomPanelTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .asymmetric(
            insertion: .opacity.combined(with: .offset(x: 0, y: 8)),
            removal: .opacity.combined(with: .offset(x: 0, y: 6))
        )
    }

    static func browsingChromeTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(x: 0, y: -2))
    }

    static func editEntryPreparationDelay(reduceMotion: Bool) -> Duration {
        reduceMotion ? .milliseconds(0) : .milliseconds(60)
    }

    static func editPanelDelay(reduceMotion: Bool) -> Duration {
        reduceMotion ? .milliseconds(40) : .milliseconds(90)
    }

    /// 退出编辑态后到 TabBar 快照接住底部视觉之间的延迟，让编辑底栏先完成一小段退场。
    static func tabBarSnapshotShowDelay(reduceMotion: Bool) -> Duration {
        reduceMotion ? .milliseconds(0) : .milliseconds(75)
    }

    /// 快照显示后到系统 TabBar 恢复之间的延迟，给底部视觉接力留出呼吸感。
    static func tabBarSnapshotRestoreDelay(reduceMotion: Bool) -> Duration {
        reduceMotion ? .milliseconds(40) : .milliseconds(130)
    }

    /// 系统 TabBar 恢复后保留快照的时间，等真实 TabBar 稳定后再淡出快照层。
    static func tabBarSnapshotRevealHoldDelay(reduceMotion: Bool) -> Duration {
        reduceMotion ? .milliseconds(60) : .milliseconds(105)
    }

    /// UIKit 快照层淡入使用的时长，辅助编辑底栏退场与 TabBar 回归形成短交叠。
    static func tabBarSnapshotFadeInDuration(reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 0.04 : 0.12
    }

    /// UIKit 快照层淡出使用的时长，保持短促，避免真实 TabBar 与快照重影被感知。
    static func tabBarSnapshotFadeOutDuration(reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 0.06 : 0.10
    }
}

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
        XMSelectionIndicator(
            style: .checkbox,
            isSelected: isSelected,
            font: AppTypography.title3
        )
            .background(Color.surfaceCard.opacity(isSelected ? 0.90 : 0.48), in: Circle())
            .shadow(color: Color.black.opacity(isSelected ? 0.12 : 0.04), radius: isSelected ? 3 : 2, y: 1)
            .padding(Spacing.half)
            .accessibilityHidden(true)
    }
}

/// 默认书架编辑态底部操作面板，承载与 Android 横向工具栏对齐的平铺批量操作入口。
struct BookshelfEditBottomBar: View {
    let selectedCount: Int
    let bottomSafeAreaInset: CGFloat
    let canPin: Bool
    let canMoveBoundary: Bool
    let canBatchAction: Bool
    let canDelete: Bool
    let activeAction: BookshelfPendingAction?
    let actions: [BookshelfBookListEditAction]
    let isLoadingOptions: Bool
    let notice: String?
    let onPin: () -> Void
    let onAction: (BookshelfBookListEditAction) -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: statusText == nil ? Spacing.none : Spacing.tight) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.base) {
                    editActionButton(
                        action: .pin,
                        icon: "pin",
                        isEnabled: canPin,
                        onTap: onPin
                    )

                    ForEach(actions) { action in
                        editActionButton(
                            action: action,
                            isEnabled: isEnabled(action),
                            onTap: { onAction(action) }
                        )
                    }

                    editActionButton(
                        action: .delete,
                        icon: "trash",
                        isEnabled: canDelete,
                        onTap: onDelete
                    )
                }
                .padding(.horizontal, Spacing.screenEdge)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)

            if let statusText {
                Text(statusText)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .lineLimit(1)
                    .transition(.opacity)
            }
        }
        .padding(.top, Spacing.cozy)
        .padding(.bottom, bottomToolbarPadding)
        .background {
            Color.surfaceCard
                .ignoresSafeArea(.container, edges: .bottom)
        }
        .overlay(alignment: .top) {
            Divider()
                .overlay(Color.surfaceBorderDefault.opacity(0.65))
        }
        .shadow(color: Color.black.opacity(0.08), radius: 10, y: -2)
    }

    private var bottomToolbarPadding: CGFloat {
        max(Spacing.cozy, bottomSafeAreaInset - Spacing.section)
    }

    private var statusText: String? {
        if let notice, !notice.isEmpty {
            return notice
        }
        if let activeAction {
            return "正在\(activeAction.title)"
        }
        if isLoadingOptions {
            return "正在加载选项"
        }
        return nil
    }

    private var isBusy: Bool {
        activeAction != nil || isLoadingOptions
    }

    private func isEnabled(_ action: BookshelfBookListEditAction) -> Bool {
        switch action {
        case .moveToStart, .moveToEnd:
            return canMoveBoundary
        case .moveToGroup, .addToBookList, .setTag, .setSource, .setReadStatus, .exportNote, .exportBook:
            return canBatchAction
        case .pin, .unpin, .reorder, .moveOut, .renameGroup, .deleteGroup, .renameTag, .deleteTag, .renameSource, .deleteSource, .deleteBooks:
            return canBatchAction
        }
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

    private func editActionButton(
        action: BookshelfBookListEditAction,
        isEnabled: Bool,
        onTap: @escaping () -> Void
    ) -> some View {
        Button(action: onTap) {
            editActionLabel(action: action, isEnabled: isEnabled)
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
        .frame(minWidth: 56, minHeight: 48)
        .contentShape(Rectangle())
    }

    private func editActionLabel(
        action: BookshelfBookListEditAction,
        isEnabled: Bool
    ) -> some View {
        VStack(spacing: Spacing.compact) {
            Image(systemName: action.systemImage)
                .font(AppTypography.headline)
                .fontWeight(.medium)
            Text(action.title)
                .font(AppTypography.caption2)
        }
        .foregroundStyle(foregroundColor(for: action, isEnabled: isEnabled))
        .frame(minWidth: 56, minHeight: 48)
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

    private func foregroundColor(
        for action: BookshelfBookListEditAction,
        isEnabled: Bool
    ) -> Color {
        guard isEnabled else {
            return action.isDestructive ? Color.feedbackError.opacity(0.55) : Color.textSecondary.opacity(0.55)
        }
        return action.isDestructive ? Color.feedbackError : Color.textPrimary
    }
}
