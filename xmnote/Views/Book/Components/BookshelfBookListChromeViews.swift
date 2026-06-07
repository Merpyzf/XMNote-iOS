/**
 * [INPUT]: 依赖 BookshelfBookListEditAction、BookshelfBookListChromeMetrics 与书架编辑玻璃栏组件
 * [OUTPUT]: 对外提供 BookshelfBookListBrowsingChrome 与 BookshelfBookListEditBottomBar，供二级书籍列表页组合顶部与底部 chrome
 * [POS]: Book 模块二级书籍列表页面私有 chrome 子视图，降低 BookshelfBookListView 文件职责密度
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 二级列表普通态本地顶部 chrome，承载返回、标题、显示设置与整理入口。
struct BookshelfBookListBrowsingChrome: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let canEnterEditing: Bool
    let topBarHeight: CGFloat
    let onBack: () -> Void
    let onShowDisplaySettings: () -> Void
    let onEnterEditing: () -> Void

    var body: some View {
        ZStack {
            Text(title)
                .font(AppTypography.bodyMedium)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, BookshelfBookListChromeMetrics.titleHorizontalInset)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)

            GlassEffectContainer(spacing: Spacing.double) {
                HStack(spacing: Spacing.cozy) {
                    TopBarBackButton(action: onBack, foregroundColor: Color.textPrimary)
                        .topBarGlassButtonStyle(true)

                    Spacer(minLength: Spacing.compact)

                    actionCluster
                }
            }
        }
        .padding(.horizontal, Spacing.screenEdge)
        .frame(height: topBarHeight)
        .frame(maxWidth: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
    }

    private var actionCluster: some View {
        HStack(spacing: Spacing.none) {
            Button(action: onShowDisplaySettings) {
                TopBarActionIcon(
                    systemName: "slider.horizontal.3",
                    foregroundColor: Color.iconPrimary
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("显示设置")

            Divider()
                .frame(height: Spacing.double)
                .overlay(Color.surfaceBorderSubtle.opacity(canEnterEditing ? 0.58 : 0.18))
                .animation(BookshelfManagementMotion.bookListTopActionAnimation(reduceMotion: reduceMotion), value: canEnterEditing)

            Button(action: onEnterEditing) {
                TopBarActionIcon(
                    systemName: "checklist",
                    foregroundColor: canEnterEditing ? Color.iconPrimary : Color.textHint
                )
            }
            .buttonStyle(.plain)
            .disabled(!canEnterEditing)
            .opacity(canEnterEditing ? 1 : 0.42)
            .scaleEffect(canEnterEditing ? 1 : 0.96)
            .animation(BookshelfManagementMotion.bookListTopActionAnimation(reduceMotion: reduceMotion), value: canEnterEditing)
            .accessibilityLabel(canEnterEditing ? "整理书籍" : "整理书籍，当前不可用")
            .accessibilityHint(canEnterEditing ? "进入书籍整理模式" : "当前没有可整理的书籍")
        }
        .topBarGlassCapsuleStyle(true)
    }
}

/// 二级列表编辑态底部玻璃栏，提供批量管理动作、破坏性操作入口与写入反馈。
struct BookshelfBookListEditBottomBar: View {
    let selectedCount: Int
    let actions: [BookshelfBookListEditAction]
    let activeAction: BookshelfBookListEditAction?
    let isLoadingOptions: Bool
    let notice: String?
    let onAction: (BookshelfBookListEditAction) -> Void

    var body: some View {
        GlassEffectContainer(spacing: Spacing.base) {
            HStack(spacing: Spacing.base) {
                actionCluster
                    .layoutPriority(1)
                    .opacity(waitingForSelection ? 0.72 : 1)

                if !destructiveActions.isEmpty {
                    destructiveActionControl
                        .opacity(destructiveActionOpacity)
                }
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .preference(key: ImmersiveBottomChromeHeightPreferenceKey.self, value: proxy.size.height)
            }
        }
        .overlay(alignment: .bottom) {
            if let statusText {
                BookshelfGlassEditStatusText(text: statusText)
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(y: -(BookshelfGlassEditBarMetrics.clusterHeight + Spacing.tight))
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
    }

    private var statusText: String? {
        if let notice, !notice.isEmpty {
            return notice
        }
        if let activeAction {
            return "\(activeAction.title)处理中..."
        }
        if isLoadingOptions {
            return "正在加载批量编辑选项..."
        }
        return nil
    }

    private var isBusy: Bool {
        activeAction != nil || isLoadingOptions
    }

    private var waitingForSelection: Bool {
        selectedCount == 0 && !isBusy
    }

    private var destructiveActionOpacity: Double {
        hasEnabledDestructiveAction ? 1 : (waitingForSelection ? 0.42 : 0.72)
    }

    private var nonDestructiveActions: [BookshelfBookListEditAction] {
        actions.filter { !$0.isDestructive }
    }

    private var destructiveActions: [BookshelfBookListEditAction] {
        actions.filter(\.isDestructive)
    }

    private var actionCluster: some View {
        BookshelfGlassEditActionCluster {
            HStack(spacing: BookshelfGlassEditBarMetrics.itemSpacing) {
                ForEach(nonDestructiveActions) { action in
                    Button {
                        onAction(action)
                    } label: {
                        actionLabel(action)
                    }
                    .buttonStyle(.plain)
                    .disabled(!isEnabled(action))
                    .accessibilityLabel(accessibilityLabel(for: action))
                }
            }
        }
    }

    @ViewBuilder
    private var destructiveActionControl: some View {
        if destructiveActions.count == 1, let action = destructiveActions.first {
            Button(role: .destructive) {
                onAction(action)
            } label: {
                destructiveActionLabel(isEnabled: isEnabled(action))
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled(action))
            .frame(
                width: BookshelfGlassEditBarMetrics.destructiveButtonSize,
                height: BookshelfGlassEditBarMetrics.destructiveButtonSize
            )
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel(accessibilityLabel(for: action))
        } else {
            Menu {
                ForEach(destructiveActions) { action in
                    Button(role: .destructive) {
                        onAction(action)
                    } label: {
                        Label(action.title, systemImage: action.systemImage)
                    }
                    .disabled(!isEnabled(action))
                }
            } label: {
                destructiveActionLabel(isEnabled: hasEnabledDestructiveAction)
            }
            .buttonStyle(.plain)
            .disabled(!hasEnabledDestructiveAction)
            .frame(
                width: BookshelfGlassEditBarMetrics.destructiveButtonSize,
                height: BookshelfGlassEditBarMetrics.destructiveButtonSize
            )
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("删除操作")
        }
    }

    private var hasEnabledDestructiveAction: Bool {
        destructiveActions.contains { isEnabled($0) }
    }

    private func actionLabel(_ action: BookshelfBookListEditAction) -> some View {
        BookshelfGlassEditActionLabel(
            title: action.title,
            systemImage: action.systemImage,
            foregroundStyle: foregroundColor(for: action),
            width: BookshelfGlassEditBarMetrics.bookListActionWidth
        )
    }

    private func destructiveActionLabel(isEnabled: Bool) -> some View {
        ImmersiveBottomChromeIcon(
            systemName: "trash",
            foregroundStyle: destructiveForegroundColor(isEnabled: isEnabled)
        )
    }

    private func foregroundColor(for action: BookshelfBookListEditAction) -> Color {
        if !isEnabled(action) {
            return Color.textSecondary.opacity(waitingForSelection ? 0.42 : 0.55)
        }
        return Color.textPrimary
    }

    private func destructiveForegroundColor(isEnabled: Bool) -> Color {
        if isEnabled {
            return Color.feedbackError
        }
        return Color.textSecondary.opacity(waitingForSelection ? 0.42 : 0.55)
    }

    private func isEnabled(_ action: BookshelfBookListEditAction) -> Bool {
        guard !isBusy else { return false }
        guard action.requiresSelection else { return true }
        return selectedCount > 0
    }

    private func accessibilityLabel(for action: BookshelfBookListEditAction) -> String {
        isEnabled(action) ? action.title : "\(action.title)，当前不可用"
    }
}
