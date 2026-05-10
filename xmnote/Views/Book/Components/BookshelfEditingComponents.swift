/**
 * [INPUT]: 依赖 BookshelfPendingAction、BookshelfBookListEditAction 与 SwiftUI 按钮、图标、横向滚动、ImmersiveBottomChrome、TabBar snapshot 交接和动画能力
 * [OUTPUT]: 对外提供书架编辑态顶部栏、选择标识、底部浮动玻璃操作栏、管理模式转场与 TabBar snapshot 恢复交接参数
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

/// 书架玻璃底栏的局部尺寸令牌，统一默认书架与二级书籍列表的触控密度。
enum BookshelfGlassEditBarMetrics {
    static let clusterHeight: CGFloat = 56
    static let destructiveButtonSize: CGFloat = 56
    static let actionWidth: CGFloat = 58
    static let bookListActionWidth: CGFloat = 64
    static let actionMinHeight: CGFloat = 44
    static let horizontalPadding: CGFloat = 14
    static let verticalPadding: CGFloat = 5
    static let itemSpacing: CGFloat = 10
    static let iconTextSpacing: CGFloat = 3
    static let actionIconFont: Font = AppTypography.fixed(
        baseSize: 15,
        relativeTo: .caption,
        weight: .medium
    )
}

/// 玻璃底栏状态提示，承接写入中、加载中与操作反馈，不参与常态说明占位。
struct BookshelfGlassEditStatusText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(AppTypography.caption)
            .foregroundStyle(Color.textSecondary)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Spacing.base)
            .padding(.vertical, Spacing.tiny)
            .background(Color.surfaceCard.opacity(0.92), in: Capsule())
            .accessibilityLabel(text)
    }
}

/// 玻璃底栏内的图标加短标题按钮内容，保持批量操作可发现性。
struct BookshelfGlassEditActionLabel: View {
    let title: String
    let systemImage: String
    let foregroundStyle: Color
    var width: CGFloat = BookshelfGlassEditBarMetrics.actionWidth

    var body: some View {
        VStack(spacing: BookshelfGlassEditBarMetrics.iconTextSpacing) {
            Image(systemName: systemImage)
                .font(BookshelfGlassEditBarMetrics.actionIconFont)

            Text(title)
                .font(AppTypography.caption2Medium)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .foregroundStyle(foregroundStyle)
        .frame(width: width)
        .frame(minHeight: BookshelfGlassEditBarMetrics.actionMinHeight)
        .padding(.vertical, BookshelfGlassEditBarMetrics.verticalPadding)
        .contentShape(Rectangle())
    }
}

/// 书架底部玻璃操作组，负责横向滚动内容的胶囊裁切与统一玻璃材质。
struct BookshelfGlassEditActionCluster<Content: View>: View {
    private let content: Content

    /// 注入横向排列的批量操作内容；裁切和玻璃材质由组件统一处理。
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            content
                .padding(.horizontal, BookshelfGlassEditBarMetrics.horizontalPadding)
                .padding(.vertical, BookshelfGlassEditBarMetrics.verticalPadding)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .frame(maxWidth: .infinity)
        .frame(height: BookshelfGlassEditBarMetrics.clusterHeight)
        .compositingGroup()
        .clipShape(Capsule())
        .contentShape(Capsule())
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

/// 默认书架编辑态底部浮动操作栏，承载与 Android 横向工具栏对齐的平铺批量操作入口。
struct BookshelfEditBottomBar: View {
    let selectedCount: Int
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
            if let statusText {
                BookshelfGlassEditStatusText(text: statusText)
            }

            GlassEffectContainer(spacing: Spacing.base) {
                HStack(spacing: Spacing.base) {
                    actionCluster
                        .layoutPriority(1)

                    deleteActionButton
                }
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .preference(key: ImmersiveBottomChromeHeightPreferenceKey.self, value: proxy.size.height)
            }
        }
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

    private var actionCluster: some View {
        BookshelfGlassEditActionCluster {
            HStack(spacing: BookshelfGlassEditBarMetrics.itemSpacing) {
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
            }
        }
    }

    private var deleteActionButton: some View {
        Button(role: .destructive, action: onDelete) {
            ImmersiveBottomChromeIcon(
                systemName: "trash",
                foregroundStyle: foregroundColor(for: .delete, isEnabled: canDelete && !isBusy)
            )
        }
        .buttonStyle(.plain)
        .disabled(!canDelete || isBusy)
        .frame(
            width: BookshelfGlassEditBarMetrics.destructiveButtonSize,
            height: BookshelfGlassEditBarMetrics.destructiveButtonSize
        )
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(canDelete && !isBusy ? "删除" : "删除，当前不可用")
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
            editActionLabel(action: action, icon: icon, isEnabled: isEnabled && !isBusy)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isBusy)
        .accessibilityLabel(isEnabled && !isBusy ? action.title : "\(action.title)，当前不可用")
    }

    private func editActionButton(
        action: BookshelfBookListEditAction,
        isEnabled: Bool,
        onTap: @escaping () -> Void
    ) -> some View {
        Button(action: onTap) {
            editActionLabel(action: action, isEnabled: isEnabled && !isBusy)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isBusy)
        .accessibilityLabel(isEnabled && !isBusy ? action.title : "\(action.title)，当前不可用")
    }

    private func editActionLabel(
        action: BookshelfPendingAction,
        icon: String,
        isEnabled: Bool
    ) -> some View {
        BookshelfGlassEditActionLabel(
            title: action.title,
            systemImage: icon,
            foregroundStyle: foregroundColor(for: action, isEnabled: isEnabled)
        )
    }

    private func editActionLabel(
        action: BookshelfBookListEditAction,
        isEnabled: Bool
    ) -> some View {
        BookshelfGlassEditActionLabel(
            title: action.title,
            systemImage: action.systemImage,
            foregroundStyle: foregroundColor(for: action, isEnabled: isEnabled)
        )
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
