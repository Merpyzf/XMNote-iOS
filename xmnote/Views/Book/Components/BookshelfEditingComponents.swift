/**
 * [INPUT]: 依赖 BookshelfPendingAction、BookshelfBookListEditAction 与 SwiftUI 按钮、图标、横向滚动、ImmersiveBottomChrome 和动画能力
 * [OUTPUT]: 对外提供书架编辑态顶部 chrome、整理态双态上下文检索入口、选择标识、底部浮动玻璃操作栏与管理模式转场参数
 * [POS]: Book 模块页面私有编辑态组件集合，服务默认书架与二级书籍列表的整理模式选择、检索、置顶、移动、横向平铺批量操作与删除入口
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书架管理模式的统一动效参数，保证顶部 chrome、内容 inset 与底部面板按同一语义节奏切换。
enum BookshelfManagementMotion {
    static let modeTransition: Animation = .smooth(duration: 0.26)
    static let editBarRevealTransitionAnimation: Animation = .smooth(duration: 0.26)
    static let editBarExitTransitionAnimation: Animation = .smooth(duration: 0.20)
    static let restoreTransition: Animation = .smooth(duration: 0.22)

    static func modeAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.16) : modeTransition
    }

    static func restoreAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.14) : restoreTransition
    }

    static func editBarRevealAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.12) : editBarRevealTransitionAnimation
    }

    static func editBarExitAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.10) : editBarExitTransitionAnimation
    }

    static func topChromeTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -4))
    }

    static func editBarRevealTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .asymmetric(
            insertion: .opacity
                .combined(with: .offset(x: 0, y: 44))
                .combined(with: .scale(scale: 0.985, anchor: .bottom)),
            removal: .opacity
                .combined(with: .offset(x: 0, y: 48))
                .combined(with: .scale(scale: 0.985, anchor: .bottom))
        )
    }

    static func browsingChromeTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(x: 0, y: -2))
    }

    static func editSearchTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity
            .combined(with: .scale(scale: 0.96, anchor: .top))
            .combined(with: .offset(y: -4))
    }

    /// 系统 TabBar 隐藏后，到编辑工具栏抬起之间的短延迟。
    static func editBarRevealDelay(reduceMotion: Bool) -> Duration {
        reduceMotion ? .milliseconds(16) : .milliseconds(70)
    }

    /// 编辑工具栏退出后，到系统 TabBar 恢复之间的延迟。
    static func editExitRestoreDelay(reduceMotion: Bool) -> Duration {
        reduceMotion ? .milliseconds(40) : .milliseconds(200)
    }

    /// 系统 TabBar 恢复后释放编辑底栏滚动避让的延迟。
    static func editBottomInsetReleaseDelay(reduceMotion: Bool) -> Duration {
        reduceMotion ? .milliseconds(40) : .milliseconds(100)
    }
}

/// 书架整理态顶部 chrome 的统一高度，保证一级书架与二级列表拥有同一顶部节奏。
enum BookshelfEditChromeMetrics {
    static let topBarHeight: CGFloat = 56
    static let accessibilityTopBarHeight: CGFloat = 60
    static let sideSlotWidth: CGFloat = 112
    static let accessibilitySideSlotWidth: CGFloat = 128
    static let searchContextHeight: CGFloat = 52

    /// 按动态字体等级返回顶部整理栏高度，避免大字号下按钮压缩标题。
    static func topBarHeight(for dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        dynamicTypeSize >= .accessibility1 ? accessibilityTopBarHeight : topBarHeight
    }

    /// 按动态字体等级返回左右操作槽宽度，保证中间状态标题保持视觉居中。
    static func sideSlotWidth(for dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        dynamicTypeSize >= .accessibility1 ? accessibilitySideSlotWidth : sideSlotWidth
    }
}

/// 整理态顶部摘要的对象范围，区分一级书架可同时选择书籍/分组和二级列表仅选择书籍。
enum BookshelfEditChromeSelectionScope {
    case booksOnly
    case booksAndGroups
}

/// 整理态顶部检索状态，区分未检索、检索有结果与检索无匹配结果。
enum BookshelfEditChromeSearchState: Equatable {
    case inactive
    case active(resultCount: Int)

    var resultCount: Int? {
        switch self {
        case .inactive:
            return nil
        case .active(let resultCount):
            return resultCount
        }
    }

    var isFiltering: Bool {
        resultCount != nil
    }

    var hasEmptyResult: Bool {
        resultCount == 0
    }
}

/// 书架编辑态顶部 chrome，复用浏览态顶部高度表达当前批量管理上下文。
struct BookshelfEditChrome: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let selectedBookCount: Int
    let selectedGroupCount: Int
    let selectionScope: BookshelfEditChromeSelectionScope
    let isAllVisibleSelected: Bool
    let isSelectionToggleEnabled: Bool
    let searchState: BookshelfEditChromeSearchState
    let onToggleSelectAll: () -> Void
    let onCancel: () -> Void

    /// 创建整理态顶部 chrome，并按使用场景决定选择摘要是否包含分组。
    init(
        selectedBookCount: Int,
        selectedGroupCount: Int = 0,
        selectionScope: BookshelfEditChromeSelectionScope = .booksAndGroups,
        isAllVisibleSelected: Bool,
        isSelectionToggleEnabled: Bool = true,
        searchState: BookshelfEditChromeSearchState = .inactive,
        onToggleSelectAll: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.selectedBookCount = selectedBookCount
        self.selectedGroupCount = selectedGroupCount
        self.selectionScope = selectionScope
        self.isAllVisibleSelected = isAllVisibleSelected
        self.isSelectionToggleEnabled = isSelectionToggleEnabled
        self.searchState = searchState
        self.onToggleSelectAll = onToggleSelectAll
        self.onCancel = onCancel
    }

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.base) {
            Button(selectionToggleTitle, action: onToggleSelectAll)
                .font(AppTypography.body)
                .foregroundStyle(selectionToggleForegroundStyle)
                .lineLimit(1)
                .minimumScaleFactor(0.86)
                .frame(width: sideSlotWidth, alignment: .leading)
                .frame(minHeight: Spacing.actionReserved)
                .accessibilityLabel(selectionToggleTitle)
                .disabled(!effectiveSelectionToggleEnabled)

            Spacer(minLength: Spacing.compact)

            VStack(spacing: Spacing.tiny) {
                Text("选择书籍")
                    .font(AppTypography.bodyMedium)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.90)

                Text(selectionSummaryText)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.86)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)

            Spacer(minLength: Spacing.compact)

            rightActions
                .frame(width: sideSlotWidth, alignment: .trailing)
                .frame(minHeight: Spacing.actionReserved)
        }
        .padding(.horizontal, Spacing.screenEdge)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background {
            Color.surfacePage
                .ignoresSafeArea(.container, edges: .top)
        }
        .overlay(alignment: .bottom) {
            Divider()
                .overlay(Color.surfaceBorderSubtle.opacity(0.38))
        }
        .accessibilityElement(children: .contain)
    }

    private var sideSlotWidth: CGFloat {
        BookshelfEditChromeMetrics.sideSlotWidth(for: dynamicTypeSize)
    }

    private var effectiveSelectionToggleEnabled: Bool {
        isSelectionToggleEnabled && !searchState.hasEmptyResult
    }

    private var selectionToggleForegroundStyle: Color {
        effectiveSelectionToggleEnabled ? Color.textPrimary : Color.textSecondary.opacity(0.56)
    }

    private var rightActions: some View {
        Button("取消", action: onCancel)
            .font(AppTypography.body)
            .foregroundStyle(Color.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.86)
            .frame(minWidth: 50, minHeight: Spacing.actionReserved, alignment: .trailing)
            .accessibilityLabel("退出整理模式")
    }

    private var selectionToggleTitle: String {
        if searchState.hasEmptyResult {
            return "无结果"
        }
        if searchState.isFiltering {
            return isAllVisibleSelected ? "取消结果选择" : "全选结果"
        }
        return isAllVisibleSelected ? "取消全选" : "全选"
    }

    private var selectionSummaryText: String {
        let baseText: String
        switch selectionScope {
        case .booksOnly:
            if searchState.isFiltering {
                baseText = selectedBookCount == 0 ? "未选择" : "已选择 \(selectedBookCount) 本"
            } else {
                baseText = selectedBookCount == 0 ? "未选择书籍" : "已选择 \(selectedBookCount) 本书籍"
            }
        case .booksAndGroups:
            if searchState.isFiltering {
                let totalCount = selectedBookCount + selectedGroupCount
                baseText = totalCount == 0 ? "未选择" : "已选择 \(totalCount) 项"
            } else {
                switch (selectedBookCount, selectedGroupCount) {
                case (0, 0):
                    baseText = "未选择书籍或分组"
                case (let bookCount, 0):
                    baseText = "已选择 \(bookCount) 本书籍"
                case (0, let groupCount):
                    baseText = "已选择 \(groupCount) 个分组"
                case (let bookCount, let groupCount):
                    baseText = "已选择 \(bookCount) 本书籍和 \(groupCount) 个分组"
                }
            }
        }

        guard let searchResultCount = searchState.resultCount else { return baseText }
        let resultText: String
        if searchResultCount == 0 {
            resultText = "无匹配结果"
        } else {
            switch selectionScope {
            case .booksOnly:
                resultText = "\(searchResultCount) 本结果"
            case .booksAndGroups:
                resultText = "\(searchResultCount) 项结果"
            }
        }
        return "\(baseText) · \(resultText)"
    }
}

/// 整理态上下文检索条，作为顶部 chrome 的局部扩展，避免遮挡书籍内容。
struct BookshelfEditSearchContextBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var isPresented: Bool
    @Binding var text: String
    let placeholder: String
    let onCollapse: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: Spacing.none) {
            if isSearchActive {
                expandedSearchField
                    .transition(searchModeTransition)
            } else {
                Spacer(minLength: Spacing.none)
                collapsedSearchButton
                    .transition(searchModeTransition)
                Spacer(minLength: Spacing.none)
            }
        }
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.top, Spacing.tiny)
        .padding(.bottom, Spacing.compact)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .animation(BookshelfManagementMotion.modeAnimation(reduceMotion: reduceMotion), value: isSearchActive)
        .animation(BookshelfManagementMotion.modeAnimation(reduceMotion: reduceMotion), value: text.isEmpty)
        .onAppear {
            syncFocusWithSearchState()
        }
        .onChange(of: isSearchActive) { _, _ in
            syncFocusWithSearchState()
        }
        .onChange(of: placeholder) { _, _ in
            syncFocusWithSearchState()
        }
    }

    private var isSearchActive: Bool {
        isPresented || !text.isEmpty
    }

    private var searchModeTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity
            .combined(with: .scale(scale: 0.97, anchor: .center))
    }

    private var collapsedSearchButton: some View {
        Button(action: presentSearch) {
            HStack(spacing: Spacing.tight) {
                Image(systemName: "magnifyingglass")
                    .font(AppTypography.subheadlineMedium)
                    .foregroundStyle(Color.iconSecondary)

                Text("搜索整理结果")
                    .font(AppTypography.subheadline)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.88)
            }
            .padding(.horizontal, Spacing.base)
            .frame(height: 38)
            .background(Color.surfaceCard.opacity(0.76), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(Color.surfaceBorderSubtle.opacity(0.34), lineWidth: CardStyle.borderWidth)
            }
            .glassEffect(.regular.interactive(), in: .capsule)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(minHeight: Spacing.actionReserved)
        .accessibilityLabel("搜索整理结果")
    }

    private var expandedSearchField: some View {
        HStack(spacing: Spacing.compact) {
            Image(systemName: "magnifyingglass")
                .font(AppTypography.body)
                .foregroundStyle(Color.iconSecondary)

            TextField(placeholder, text: $text)
                .font(BookshelfTypography.searchField)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .submitLabel(.search)
                .focused($isFocused)

            Button(action: trailingAction) {
                Image(systemName: text.isEmpty ? "xmark" : "xmark.circle.fill")
                    .font(AppTypography.body)
                    .foregroundStyle(text.isEmpty ? Color.iconPrimary : Color.iconSecondary)
                    .frame(width: Spacing.actionReserved, height: Spacing.actionReserved)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(text.isEmpty ? "收起整理搜索" : "清除整理搜索")
        }
        .padding(.leading, Spacing.base)
        .padding(.trailing, Spacing.tiny)
        .frame(height: 40)
        .background(Color.surfaceCard.opacity(0.84), in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color.surfaceBorderSubtle.opacity(0.42), lineWidth: CardStyle.borderWidth)
        }
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private func trailingAction() {
        if text.isEmpty {
            collapseSearch()
        } else {
            isPresented = true
            text = ""
        }
    }

    private func presentSearch() {
        withAnimation(BookshelfManagementMotion.modeAnimation(reduceMotion: reduceMotion)) {
            isPresented = true
        }
        focusSearchField()
    }

    private func collapseSearch() {
        withAnimation(BookshelfManagementMotion.modeAnimation(reduceMotion: reduceMotion)) {
            isPresented = false
            isFocused = false
            onCollapse()
        }
    }

    private func syncFocusWithSearchState() {
        if isSearchActive {
            focusSearchField()
        } else {
            isFocused = false
        }
    }

    /// 下一轮 MainActor 聚焦，避免 TextField 尚未进入层级时丢焦；任务只写本地 FocusState，视图消失后无外部副作用。
    private func focusSearchField() {
        Task { @MainActor in
            guard isSearchActive else { return }
            isFocused = true
        }
    }
}

/// 书架整理与检索上下文里的说明型空态，支持补充状态说明以避免搜索空态被误读为真实空书架。
struct BookshelfContextualEmptyStateView: View {
    let icon: String
    let title: String
    let message: String?
    var iconColor: Color = Color.brand.opacity(0.30)

    var body: some View {
        VStack(spacing: Spacing.base) {
            Image(systemName: icon)
                .font(AppTypography.fixed(baseSize: 48, relativeTo: .title, weight: .regular))
                .foregroundStyle(iconColor)

            VStack(spacing: Spacing.tiny) {
                Text(title)
                    .font(AppTypography.title3)
                    .foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(.center)

                if let message, !message.isEmpty {
                    Text(message)
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textHint)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, Spacing.contentEdge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
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
                        .opacity(waitingForSelection ? 0.72 : 1)

                    deleteActionButton
                        .opacity(deleteActionOpacity)
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

    private var waitingForSelection: Bool {
        selectedCount == 0 && !isBusy
    }

    private var deleteActionOpacity: Double {
        if canDelete && !isBusy {
            return 1
        }
        return waitingForSelection ? 0.42 : 0.72
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
            if action == .delete, selectedCount > 0 {
                return Color.feedbackError.opacity(0.55)
            }
            return Color.textSecondary.opacity(waitingForSelection ? 0.42 : 0.55)
        }
        return action == .delete ? Color.feedbackError : Color.textPrimary
    }

    private func foregroundColor(
        for action: BookshelfBookListEditAction,
        isEnabled: Bool
    ) -> Color {
        guard isEnabled else {
            if action.isDestructive, selectedCount > 0 {
                return Color.feedbackError.opacity(0.55)
            }
            return Color.textSecondary.opacity(waitingForSelection ? 0.42 : 0.55)
        }
        return action.isDestructive ? Color.feedbackError : Color.textPrimary
    }
}
