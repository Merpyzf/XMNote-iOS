/**
 * [INPUT]: 依赖书架编辑动作快照、Reicon 模板矢量资源、SwiftUI TabView 底部 accessory/scroll-edge 环境与项目交互令牌
 * [OUTPUT]: 对外提供书架整理 accessory 展示状态机、稳定宿主、业务动作图标、菜单标签与底部操作视图
 * [POS]: Book 模块整理模式的页面级 accessory 契约与私有视觉实现，由 MainTabView 统一托管并隔离高频动作快照
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Observation
import SwiftUI

/// 书架整理业务动作使用的 Reicon 语义，避免业务状态依赖 SF Symbols 名称。
enum BookshelfEditingIcon: Hashable, Sendable {
    case checklist
    case thumbtack
    case unpin
    case alignTop
    case alignBottom
    case folderMove
    case bookSaved
    case folderRemove
    case tag
    case archiveBox
    case export
    case edit
    case trash
    case sortVertical

    fileprivate var assetName: String {
        switch self {
        case .checklist:
            return "ReiconBookshelfChecklist"
        case .thumbtack, .unpin:
            return "ReiconBookshelfThumbtack"
        case .alignTop:
            return "ReiconBookshelfAlignTop"
        case .alignBottom:
            return "ReiconBookshelfAlignBottom"
        case .folderMove:
            return "ReiconBookshelfFolderMove"
        case .bookSaved:
            return "ReiconBookshelfBookSaved"
        case .folderRemove:
            return "ReiconBookshelfFolderRemove"
        case .tag:
            return "ReiconBookshelfTag"
        case .archiveBox:
            return "ReiconBookshelfArchiveBox"
        case .export:
            return "ReiconBookshelfExport"
        case .edit:
            return "ReiconBookshelfEdit"
        case .trash:
            return "ReiconBookshelfTrash"
        case .sortVertical:
            return "ReiconBookshelfSortVertical"
        }
    }
}

extension BookshelfBookListEditAction {
    /// 将领域动作映射为统一 Reicon 语义，页面无需知道具体资源名称。
    var editingIcon: BookshelfEditingIcon {
        switch self {
        case .pin:
            return .thumbtack
        case .unpin:
            return .unpin
        case .reorder:
            return .sortVertical
        case .moveToStart:
            return .alignTop
        case .moveToEnd:
            return .alignBottom
        case .moveToGroup:
            return .folderMove
        case .addToBookList:
            return .bookSaved
        case .moveOut:
            return .folderRemove
        case .setTag:
            return .tag
        case .setSource:
            return .archiveBox
        case .setReadStatus:
            return .checklist
        case .exportNote, .exportBook:
            return .export
        case .renameGroup, .renameTag, .renameSource:
            return .edit
        case .deleteGroup, .deleteTag, .deleteSource, .deleteBooks:
            return .trash
        }
    }
}

/// 统一渲染 Reicon 模板资源；缺失资源时保持空白，避免业务图标静默回退为 SF Symbols。
struct BookshelfEditingActionIcon: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let icon: BookshelfEditingIcon
    var foregroundColor: Color = .iconPrimary

    var body: some View {
        ZStack {
            Image(icon.assetName)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()

            if icon == .unpin {
                Capsule()
                    .fill(foregroundColor)
                    .frame(width: iconSize + 4, height: 1.5)
                    .rotationEffect(.degrees(-45))
            }
        }
        .foregroundStyle(foregroundColor)
        .frame(width: iconSize, height: iconSize)
        .accessibilityHidden(true)
    }

    private var iconSize: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 20 : 18
    }
}

/// 在系统菜单中复用 Reicon 业务图标与项目文字样式。
struct BookshelfEditingMenuLabel: View {
    let title: String
    let icon: BookshelfEditingIcon
    var foregroundColor: Color = .textPrimary

    var body: some View {
        Label {
            Text(title)
        } icon: {
            BookshelfEditingActionIcon(icon: icon, foregroundColor: foregroundColor)
        }
        .foregroundStyle(foregroundColor)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}

/// 区分一级与二级书架的紧凑动作宽度，同时保持同一 accessory 结构。
enum BookshelfEditingAccessorySource: Hashable, Sendable {
    case mainBookshelf
    case bookList

    fileprivate var actionWidth: CGFloat {
        switch self {
        case .mainBookshelf:
            return 58
        case .bookList:
            return 64
        }
    }
}

/// 页面发布给根 Tab 宿主的纯值快照，不持有业务对象或执行闭包。
struct BookshelfEditingAccessorySnapshot: Equatable, Sendable {
    let ownerID: UUID
    let source: BookshelfEditingAccessorySource
    let bookshelfTitle: String
    let actions: [BookshelfBookListEditAction]
    let enabledActions: Set<BookshelfBookListEditAction>
    let selectedCount: Int
    let isBusy: Bool
}

/// 描述底部整理 accessory 的单次展示生命周期，与页面顶部 chrome 及高频选择快照相互独立。
enum BookshelfEditingAccessoryPresentationPhase: Equatable, Sendable {
    case inactive
    case entering
    case editing
    case exiting

    /// 当前 presentation 是否仍占用系统 Bottom Accessory 宿主。
    var isActive: Bool {
        self != .inactive
    }

    /// 当前阶段是否允许把业务动作发送回页面 owner。
    var isInteractive: Bool {
        self == .editing
    }
}

/// 根 accessory 产生的瞬时命令，通过 owner 与 request ID 精确回传原页面。
struct BookshelfEditingAccessoryCommand: Equatable, Sendable {
    let requestID: UUID
    let ownerID: UUID
    let presentationID: UUID
    let action: BookshelfBookListEditAction
}

/// 协调根 Tab accessory 的展示快照和瞬时命令，不接管任何书架业务状态。
@MainActor
@Observable
final class BookshelfEditingAccessoryCoordinator {
    private(set) var snapshot: BookshelfEditingAccessorySnapshot?
    private(set) var pendingCommand: BookshelfEditingAccessoryCommand?
    private(set) var presentationID: UUID?
    private(set) var presentationPhase: BookshelfEditingAccessoryPresentationPhase = .inactive
    private(set) var interactionReadyPresentationID: UUID?
    private var exitTransitionID: UUID?

    /// 当前是否存在尚未清理的书架整理 presentation；退场阶段仍保留它以校验异步 completion。
    var hasActivePresentation: Bool {
        presentationID != nil && presentationPhase.isActive
    }

    /// 当前展示是否已经完成入场并可安全接收点击与辅助功能焦点。
    var isInteractionReady: Bool {
        presentationPhase == .editing
            && interactionReadyPresentationID == presentationID
    }

    /// 激活页面的单次 accessory presentation；同 owner 的后续调用只更新 payload，不会重置展示身份。
    /// - Note: 所有状态均受 MainActor 隔离；新 owner 或显式重进会生成新 ID，使旧动画 completion 自动失效。
    func activatePresentation(with snapshot: BookshelfEditingAccessorySnapshot) {
        if self.snapshot?.ownerID == snapshot.ownerID,
           presentationPhase == .entering || presentationPhase == .editing {
            updatePayload(snapshot)
            return
        }

        if let previousOwnerID = self.snapshot?.ownerID,
           pendingCommand?.ownerID == previousOwnerID {
            pendingCommand = nil
        }
        self.snapshot = snapshot
        presentationID = UUID()
        presentationPhase = .entering
        interactionReadyPresentationID = nil
        exitTransitionID = nil
    }

    /// 替换当前 owner 的高频动作 payload；完全相同的快照不会触发 Observation 写入。
    func updatePayload(_ snapshot: BookshelfEditingAccessorySnapshot) {
        guard self.snapshot?.ownerID == snapshot.ownerID,
              presentationPhase == .entering || presentationPhase == .editing,
              self.snapshot != snapshot else {
            return
        }
        self.snapshot = snapshot
    }

    /// 在系统 accessory 已恢复展开形态后完成本次唯一入场门闩。
    func confirmExpanded(ownerID: UUID, presentationID: UUID) {
        guard snapshot?.ownerID == ownerID,
              self.presentationID == presentationID,
              presentationPhase == .entering else {
            return
        }
        presentationPhase = .editing
    }

    /// 入场动画完成后才开放当前 presentation 的点击与辅助功能焦点。
    func completeEntry(ownerID: UUID, presentationID: UUID) {
        guard snapshot?.ownerID == ownerID,
              self.presentationID == presentationID,
              presentationPhase == .editing else {
            return
        }
        interactionReadyPresentationID = presentationID
    }

    /// 返回指定页面当前拥有的稳定 presentation ID，供退出 completion 捕获并校验。
    func presentationID(ownedBy ownerID: UUID) -> UUID? {
        guard snapshot?.ownerID == ownerID else { return nil }
        return presentationID
    }

    /// 开始可打断退场并立即关闭动作请求；调用方以独立动画事务驱动视觉变化。
    func beginExit(ownerID: UUID, presentationID: UUID, transitionID: UUID) {
        guard snapshot?.ownerID == ownerID,
              self.presentationID == presentationID,
              presentationPhase == .entering || presentationPhase == .editing else {
            return
        }
        if pendingCommand?.ownerID == ownerID {
            pendingCommand = nil
        }
        interactionReadyPresentationID = nil
        exitTransitionID = transitionID
        presentationPhase = .exiting
    }

    /// 仅当 owner、presentation 与 transition 三重身份仍匹配时清理退场快照。
    func completeExit(ownerID: UUID, presentationID: UUID, transitionID: UUID) {
        guard snapshot?.ownerID == ownerID,
              self.presentationID == presentationID,
              exitTransitionID == transitionID,
              presentationPhase == .exiting else {
            return
        }
        clearPresentation(ownerID: ownerID)
    }

    /// 页面离开或上下文切换时立即撤销自己的 presentation，不播放可能污染新页面的残留动画。
    func revokeImmediately(ownerID: UUID) {
        guard snapshot?.ownerID == ownerID || pendingCommand?.ownerID == ownerID else { return }
        clearPresentation(ownerID: ownerID)
    }

    /// 把有效点击转换为一次性请求；仅稳定编辑阶段、非忙碌且可用的动作能够进入业务层。
    func request(_ action: BookshelfBookListEditAction) {
        guard let snapshot,
              let presentationID,
              presentationPhase.isInteractive,
              isInteractionReady,
              !snapshot.isBusy,
              pendingCommand == nil,
              snapshot.enabledActions.contains(action) else {
            return
        }
        pendingCommand = BookshelfEditingAccessoryCommand(
            requestID: UUID(),
            ownerID: snapshot.ownerID,
            presentationID: presentationID,
            action: action
        )
    }

    /// 原子认领当前 presentation 的命令；页面仅在返回 true 时执行对应业务动作。
    func consume(
        requestID: UUID,
        ownerID: UUID,
        presentationID: UUID
    ) -> Bool {
        guard pendingCommand?.requestID == requestID,
              pendingCommand?.ownerID == ownerID,
              pendingCommand?.presentationID == presentationID,
              self.presentationID == presentationID,
              isInteractionReady else {
            return false
        }
        pendingCommand = nil
        return true
    }

    private func clearPresentation(ownerID: UUID) {
        if snapshot?.ownerID == ownerID {
            snapshot = nil
            presentationID = nil
            presentationPhase = .inactive
            interactionReadyPresentationID = nil
            exitTransitionID = nil
        }
        if pendingCommand?.ownerID == ownerID {
            pendingCommand = nil
        }
    }
}

/// 读取系统 Bottom Accessory 形态并以稳定 presentation ID 承载高频书架动作快照。
struct BookshelfEditingAccessoryHost: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    let coordinator: BookshelfEditingAccessoryCoordinator
    let presentationID: UUID

    var body: some View {
        if let snapshot = coordinator.snapshot,
           coordinator.presentationID == presentationID {
            BookshelfEditingAccessoryView(
                snapshot: snapshot,
                presentationPhase: coordinator.presentationPhase,
                isExpanded: placement != .inline,
                isInteractionReady: coordinator.isInteractionReady,
                onAction: coordinator.request
            )
            .onChange(of: placement, initial: true) {
                confirmExpandedIfNeeded(ownerID: snapshot.ownerID)
            }
        }
    }

    /// 系统壳层展开后只推进一次 entering 门闩；重新挂载时 editing 阶段直接保持最终视觉状态。
    private func confirmExpandedIfNeeded(ownerID: UUID) {
        guard placement != .inline,
              coordinator.presentationPhase == .entering else {
            return
        }
        let animation = reduceMotion
            ? Animation.easeInOut(duration: 0.16)
            : Animation.smooth(duration: 0.26).delay(0.05)
        withAnimation(animation, completionCriteria: .logicallyComplete) {
            coordinator.confirmExpanded(ownerID: ownerID, presentationID: presentationID)
        } completion: {
            coordinator.completeEntry(ownerID: ownerID, presentationID: presentationID)
        }
    }
}

/// iOS 26 TabView 底部 accessory 的业务内容；系统负责 Liquid Glass 表层与相邻 TabBar 关系。
struct BookshelfEditingAccessoryView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let snapshot: BookshelfEditingAccessorySnapshot
    let presentationPhase: BookshelfEditingAccessoryPresentationPhase
    let isExpanded: Bool
    let isInteractionReady: Bool
    let onAction: (BookshelfBookListEditAction) -> Void

    var body: some View {
        HStack(spacing: Spacing.none) {
            ScrollView(.horizontal) {
                HStack(spacing: Spacing.none) {
                    ForEach(standardActions) { action in
                        actionButton(action)
                    }
                }
                .padding(.horizontal, Spacing.tight)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled(false)
            .scrollEdgeEffectHidden(true, for: .trailing)
            .frame(maxWidth: .infinity)

            if !destructiveActions.isEmpty {
                destructiveControl
                    .padding(.horizontal, Spacing.tight)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: accessoryHeight)
        .opacity(isVisuallyPresented ? 1 : 0)
        .offset(y: reduceMotion || isVisuallyPresented ? 0 : 8)
        .scaleEffect(reduceMotion || isVisuallyPresented ? 1 : 0.98, anchor: .bottom)
        .allowsHitTesting(isVisuallyPresented && isInteractionReady && !snapshot.isBusy)
        .accessibilityElement(children: .contain)
        .accessibilityHidden(!isVisuallyPresented || !isInteractionReady)
    }

    private var standardActions: [BookshelfBookListEditAction] {
        snapshot.actions.filter { !$0.isDestructive }
    }

    private var destructiveActions: [BookshelfBookListEditAction] {
        snapshot.actions.filter(\.isDestructive)
    }

    private var accessoryHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 64 : 56
    }

    private var isVisuallyPresented: Bool {
        isExpanded && presentationPhase == .editing
    }

    /// 集中定义整理动作的可用与危险语义，保证图标和文字在系统底部玻璃上保持一致层级。
    private struct ActionAppearance {
        let iconColor: Color
        let textColor: Color
        let opacity: Double

        init(isEnabled: Bool, isDestructive: Bool) {
            if isDestructive {
                iconColor = .feedbackError
                textColor = .feedbackError
            } else if isEnabled {
                iconColor = .iconPrimary
                textColor = .textPrimary
            } else {
                iconColor = .iconSecondary
                textColor = .textSecondary
            }
            opacity = isEnabled ? 1 : 0.46
        }
    }

    @ViewBuilder
    private var destructiveControl: some View {
        if destructiveActions.count == 1, let action = destructiveActions.first {
            actionButton(action)
        } else {
            let isEnabled = destructiveActions.contains(where: snapshot.enabledActions.contains)
            let appearance = ActionAppearance(isEnabled: isEnabled, isDestructive: true)

            Menu {
                ForEach(destructiveActions) { action in
                    Button(role: .destructive) {
                        onAction(action)
                    } label: {
                        BookshelfEditingMenuLabel(
                            title: action.title,
                            icon: action.editingIcon,
                            foregroundColor: .feedbackError
                        )
                    }
                    .disabled(!snapshot.enabledActions.contains(action))
                }
            } label: {
                actionLabel(
                    title: "删除",
                    icon: .trash,
                    iconColor: appearance.iconColor,
                    textColor: appearance.textColor
                )
            }
            .buttonStyle(BookshelfAccessoryActionButtonStyle(reduceMotion: reduceMotion))
            .disabled(!isEnabled)
            .opacity(appearance.opacity)
            .accessibilityLabel("删除操作")
        }
    }

    /// 以统一命中区域承载动作，并以独立图标与文字层级清楚区分可用、禁用和危险语义。
    private func actionButton(_ action: BookshelfBookListEditAction) -> some View {
        let isEnabled = snapshot.enabledActions.contains(action)
        let appearance = ActionAppearance(
            isEnabled: isEnabled,
            isDestructive: action.isDestructive
        )

        return Button {
            onAction(action)
        } label: {
            actionLabel(
                title: action.title,
                icon: action.editingIcon,
                iconColor: appearance.iconColor,
                textColor: appearance.textColor
            )
        }
        .buttonStyle(BookshelfAccessoryActionButtonStyle(reduceMotion: reduceMotion))
        .disabled(!isEnabled)
        .opacity(appearance.opacity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: isEnabled)
        .accessibilityLabel(action.title)
        .accessibilityHint(snapshot.selectedCount == 0 && action.requiresSelection ? "请先选择书籍" : "")
    }

    private func actionLabel(
        title: String,
        icon: BookshelfEditingIcon,
        iconColor: Color,
        textColor: Color
    ) -> some View {
        VStack(spacing: Spacing.tiny) {
            BookshelfEditingActionIcon(icon: icon, foregroundColor: iconColor)

            Text(title)
                .font(AppTypography.caption2)
                .foregroundStyle(textColor)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .frame(width: snapshot.source.actionWidth)
        .frame(minHeight: InteractionMetrics.minimumTouchTarget)
        .contentShape(Rectangle())
    }

}

/// accessory 动作的轻量按压反馈，Reduce Motion 下仅保留透明度变化。
private struct BookshelfAccessoryActionButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : 0.96)
            .animation(.smooth(duration: 0.12), value: configuration.isPressed)
    }
}
