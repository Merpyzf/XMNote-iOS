/**
 * [INPUT]: 依赖 XMSheetScaffold、XMSystemSearchBar、XMKeywordHighlighting、XMSelectionIndicator、XMSystemAlert、LoadingGate，以及外部注入的布局偏好与标签创建/改名/删除/保存动作
 * [OUTPUT]: 对外提供 XMTagSelectionItem、XMTagSelectionLayoutConfiguration、XMTagSelectionManagementConfiguration 与 iOS 26 系统工具栏风格的 XMTagSelectionSheet
 * [POS]: UIComponents/Business/Tag 的跨模块标签选择组件，被书摘、回顾、详情、每日阅读与书架批量编辑 Sheet 复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 标签选择组件内部能力与当前展示状态不一致时使用的防御性错误。
private enum XMTagSelectionSheetError: LocalizedError {
    case managementUnavailable

    var errorDescription: String? {
        switch self {
        case .managementUnavailable:
            return "标签已不存在，请刷新后重试"
        }
    }
}

/// 跨业务标签选择器使用的最小展示模型，只保留稳定身份与可搜索标题。
struct XMTagSelectionItem: Identifiable, Hashable, Sendable {
    let id: Int64
    let title: String

    /// 使用业务真实 ID 与展示标题创建稳定标签项。
    init(id: Int64, title: String) {
        self.id = id
        self.title = title
    }
}

/// 标签选择器的布局偏好快照与写回动作；持久化 owner 由调用方保留。
struct XMTagSelectionLayoutConfiguration {
    let initialMode: TagSelectionLayoutMode
    let onChange: @MainActor @Sendable (TagSelectionLayoutMode) -> Void

    /// 注入初始布局和后续变更动作，使 UI 组件无需认识偏好 Repository。
    init(
        initialMode: TagSelectionLayoutMode,
        onChange: @escaping @MainActor @Sendable (TagSelectionLayoutMode) -> Void
    ) {
        self.initialMode = initialMode
        self.onChange = onChange
    }
}

/// 标签选择器的可选目录管理能力，以动作闭包隔离真实写入 owner。
struct XMTagSelectionManagementConfiguration {
    let scope: TagManagementScope
    let onRename: @MainActor @Sendable (Int64, String) async throws -> Void
    let onDelete: @MainActor @Sendable ([Int64]) async throws -> Void
    let onMutation: @MainActor @Sendable (TagCatalogMutation) -> Void

    /// 为指定标签范围启用编辑和删除；调用方持有 Repository 并注入最小动作边界。
    init(
        scope: TagManagementScope,
        onRename: @escaping @MainActor @Sendable (Int64, String) async throws -> Void,
        onDelete: @escaping @MainActor @Sendable ([Int64]) async throws -> Void,
        onMutation: @escaping @MainActor @Sendable (TagCatalogMutation) -> Void = { _ in }
    ) {
        self.scope = scope
        self.onRename = onRename
        self.onDelete = onDelete
        self.onMutation = onMutation
    }
}

/// 通用标签选择 Sheet，统一管理本地选择草稿、搜索、创建和最终异步提交。
struct XMTagSelectionSheet: View {
    let title: String
    let contextText: String?
    let items: [XMTagSelectionItem]
    let initialSelectedIDs: Set<Int64>
    let allowsEmptySelection: Bool
    let isLoading: Bool
    let loadErrorMessage: String?
    let layout: XMTagSelectionLayoutConfiguration
    let management: XMTagSelectionManagementConfiguration?
    let onCreate: @MainActor @Sendable (String) async throws -> XMTagSelectionItem
    let onSave: @MainActor @Sendable ([XMTagSelectionItem]) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(XMToastCenter.self) private var toastCenter
    @State private var loadingGate = LoadingGate()
    @State private var currentItems: [XMTagSelectionItem]
    @State private var baselineSelectedIDs: Set<Int64>
    @State private var draftSelectedIDs: Set<Int64>
    @State private var locallyCreatedIDs: Set<Int64> = []
    @State private var locallyRenamedTitles: [Int64: String] = [:]
    @State private var locallyDeletedIDs: Set<Int64> = []
    @State private var hasEditedSelection = false
    @State private var searchText = ""
    @State private var isSearchActive = false
    @State private var layoutMode: TagSelectionLayoutMode
    @State private var nameSheetPresentation: XMTagNameSheetPresentation?
    @State private var deleteConfirmationItem: XMTagSelectionItem?
    @State private var deletingItemID: Int64?
    @State private var createdItemToRevealID: Int64?
    @State private var pendingScrollItemID: Int64?
    @State private var isSaving = false
    @State private var saveErrorMessage: String?
    @State private var saveTask: Task<Void, Never>?
    @State private var deleteTask: Task<Void, Never>?

    /// 使用外部候选项与初始关系集合创建本地草稿；创建和保存均由调用方通过异步闭包落库。
    init(
        title: String = "编辑标签",
        contextText: String? = nil,
        items: [XMTagSelectionItem],
        initialSelectedIDs: Set<Int64>,
        allowsEmptySelection: Bool = true,
        isLoading: Bool = false,
        loadErrorMessage: String? = nil,
        layout: XMTagSelectionLayoutConfiguration,
        management: XMTagSelectionManagementConfiguration? = nil,
        onCreate: @escaping @MainActor @Sendable (String) async throws -> XMTagSelectionItem,
        onSave: @escaping @MainActor @Sendable ([XMTagSelectionItem]) async -> Bool
    ) {
        self.title = title
        self.contextText = contextText
        self.items = items
        self.initialSelectedIDs = initialSelectedIDs
        self.allowsEmptySelection = allowsEmptySelection
        self.isLoading = isLoading
        self.loadErrorMessage = loadErrorMessage
        self.layout = layout
        self.management = management
        self.onCreate = onCreate
        self.onSave = onSave

        let validIDs = Set(items.map(\.id))
        let initialDraft = isLoading
            ? initialSelectedIDs
            : initialSelectedIDs.intersection(validIDs)
        _currentItems = State(initialValue: items)
        _baselineSelectedIDs = State(initialValue: initialDraft)
        _draftSelectedIDs = State(initialValue: initialDraft)
        _layoutMode = State(initialValue: layout.initialMode)
    }

    var body: some View {
        XMSheetScaffold(
            title: title,
            onClose: closeSheet,
            isInteractionLocked: deletingItemID != nil,
            scrollEdgePresentation: .overlaySoft,
            isConfirmationDisabled: !canSave,
            isConfirming: isSaving,
            confirmationAction: saveSelection,
            titleSubtitle: {
                Text(selectionSummary)
            },
            contentTopBar: {
                selectionToolbar
            }
        ) {
            ScrollViewReader { proxy in
                selectionPanel
                    .padding(.horizontal, Spacing.screenEdge)
                    .padding(.bottom, Spacing.contentEdge)
                    .onChange(of: pendingScrollItemID) { _, itemID in
                        revealPendingItem(itemID, using: proxy)
                    }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .interactiveDismissDisabled(isSaving || deletingItemID != nil)
        .sheet(item: $nameSheetPresentation, onDismiss: revealCreatedItemAfterDismissal) { presentation in
            tagNameSheet(for: presentation)
        }
        .xmSystemAlert(item: $deleteConfirmationItem, descriptor: deleteDescriptor)
        .onAppear(perform: synchronizeLoadingGate)
        .onChange(of: items) { _, newItems in
            synchronizeExternalItems(newItems)
        }
        .onChange(of: initialSelectedIDs) { _, newSelection in
            synchronizeExternalSelection(newSelection)
        }
        .onChange(of: isLoading) { _, _ in
            synchronizeLoadingGate()
        }
        .onChange(of: loadErrorMessage) { _, _ in
            synchronizeLoadingGate()
        }
        .onDisappear(perform: cancelOwnedWork)
    }

    private var selectionSummary: String {
        let countSummary = "已选 \(draftSelectedIDs.count) 个标签"
        guard let contextText else { return countSummary }
        let normalizedContext = contextText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedContext.isEmpty else { return countSummary }
        return "\(normalizedContext) · \(countSummary)"
    }

    private var selectionToolbar: some View {
        VStack(spacing: Spacing.cozy) {
            XMSystemSearchBar(
                text: $searchText,
                isActive: $isSearchActive,
                prompt: "搜索标签",
                accessibilityIdentifier: "tag.selection.search",
                isEnabled: !isTagInteractionDisabled
            )
            .frame(maxWidth: .infinity)
            .layoutPriority(1)

            toolbarUtilityControls

            if let saveErrorMessage, !saveErrorMessage.isEmpty {
                Text(saveErrorMessage)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.feedbackError)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
                    .accessibilityLabel("保存失败，\(saveErrorMessage)")
            }
        }
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.bottom, Spacing.section)
    }

    @ViewBuilder
    private var toolbarUtilityControls: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: Spacing.cozy) {
                layoutModePicker
                createTagButton
            }
        } else {
            HStack(spacing: Spacing.base) {
                layoutModePicker

                Spacer(minLength: Spacing.base)

                createTagButton
            }
        }
    }

    private var layoutModePicker: some View {
        Picker("标签展示方式", selection: layoutModeBinding) {
            ForEach(TagSelectionLayoutMode.allCases, id: \.self) { mode in
                Label(mode.title, systemImage: mode.systemImage)
                    .labelStyle(.titleAndIcon)
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(
            width: dynamicTypeSize.isAccessibilitySize
                ? nil
                : XMTagSelectionLayout.layoutPickerWidth,
            height: XMTagSelectionLayout.minimumHitSize
        )
        .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil)
        .disabled(isTagInteractionDisabled)
        .accessibilityLabel("标签展示方式")
        .accessibilityValue(layoutMode.title)
        .accessibilityHint("在列表和双列网格之间切换")
    }

    private var createTagButton: some View {
        Button(action: presentCreateSheet) {
            Label("新建标签", systemImage: "plus")
                .labelStyle(.titleAndIcon)
                .font(AppTypography.subheadline)
                .foregroundStyle(Color.textPrimary)
                .padding(.horizontal, Spacing.base)
                .frame(
                    maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil,
                    minHeight: dynamicTypeSize.isAccessibilitySize
                        ? XMTagSelectionLayout.minimumHitSize
                        : XMTagSelectionLayout.secondaryActionVisualHeight
                )
                .background(
                    Color.surfaceCard.opacity(XMTagSelectionLayout.gridItemSurfaceOpacity),
                    in: RoundedRectangle(
                        cornerRadius: CornerRadius.blockMedium,
                        style: .continuous
                    )
                )
                .overlay {
                    RoundedRectangle(
                        cornerRadius: CornerRadius.blockMedium,
                        style: .continuous
                    )
                    .stroke(
                        Color.surfaceBorderSubtle,
                        lineWidth: XMTagSelectionLayout.secondaryActionBorderWidth
                    )
                }
                .frame(
                    maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil,
                    minHeight: XMTagSelectionLayout.minimumHitSize
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(XMTagSelectionCreateButtonStyle())
        .disabled(isTagInteractionDisabled)
        .opacity(isTagInteractionDisabled ? 0.46 : 1)
        .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil)
        .accessibilityLabel("新建标签")
        .accessibilityHint("打开新建标签页面，创建成功后自动选中")
    }

    private var selectionPanel: some View {
        Group {
            if hasLoadError {
                statusRow(
                    icon: "exclamationmark.triangle",
                    message: loadErrorMessage ?? "标签加载失败",
                    color: .feedbackError
                )
            } else if isLoading {
                loadingRow
            } else if visibleItems.isEmpty {
                statusRow(
                    icon: normalizedSearchText.isEmpty ? "tag" : "magnifyingglass",
                    message: normalizedSearchText.isEmpty ? "暂无可选标签" : "没有匹配的标签",
                    color: .textSecondary
                )
                .transition(statusTransition)
            } else {
                tagRows
                    .transition(statusTransition)
            }
        }
        .animation(structuralAnimation, value: visibleItemIDs)
        .animation(structuralAnimation, value: panelState)
    }

    @ViewBuilder
    private func tagNameSheet(for presentation: XMTagNameSheetPresentation) -> some View {
        switch presentation {
        case .create:
            XMTagNameSheet(
                mode: .create,
                existingTitles: currentItems.map(\.title),
                onSubmit: onCreate,
                onSubmitted: acceptCreatedItem
            )
        case .rename(let item):
            XMTagNameSheet(
                mode: .rename(item),
                existingTitles: currentItems
                    .filter { $0.id != item.id }
                    .map(\.title),
                onSubmit: { name in
                    guard let management else {
                        throw XMTagSelectionSheetError.managementUnavailable
                    }
                    try await management.onRename(item.id, name)
                    return XMTagSelectionItem(id: item.id, title: name)
                },
                onSubmitted: acceptRenamedItem
            )
        }
    }

    @ViewBuilder
    private var loadingRow: some View {
        if loadingGate.isVisible {
            LoadingStateView("正在加载标签…", style: .inline)
                .frame(maxWidth: .infinity, minHeight: XMTagSelectionLayout.statusMinHeight)
                .padding(.horizontal, Spacing.contentEdge)
                .transition(.opacity)
        } else {
            Color.clear
                .frame(maxWidth: .infinity, minHeight: XMTagSelectionLayout.statusMinHeight)
                .padding(.horizontal, Spacing.contentEdge)
                .accessibilityHidden(true)
        }
    }

    private var tagRows: some View {
        LazyVGrid(
            columns: tagGridColumns,
            alignment: .leading,
            spacing: tagGridSpacing
        ) {
            ForEach(visibleItems) { item in
                tagRow(for: item)
            }
        }
        .padding(.leading, layoutMode == .list ? Spacing.contentEdge : Spacing.none)
    }

    private func tagRow(for item: XMTagSelectionItem) -> some View {
        XMTagSelectionRow(
            item: item,
            keyword: normalizedSearchText,
            isSelected: draftSelectedIDs.contains(item.id),
            isDisabled: isTagInteractionDisabled,
            isDeleting: deletingItemID == item.id,
            layoutMode: layoutMode,
            showsListDivider: layoutMode == .list && item.id != visibleItems.last?.id,
            onToggle: toggleItem,
            allowsManagement: management != nil,
            onRename: presentRenameSheet,
            onDelete: presentDeleteConfirmation
        )
        .id(item.id)
        .transition(rowTransition)
    }

    private func statusRow(icon: String, message: String, color: Color) -> some View {
        VStack(spacing: Spacing.cozy) {
            Image(systemName: icon)
                .font(AppTypography.title3)
                .foregroundStyle(color)
                .accessibilityHidden(true)

            Text(message)
                .font(AppTypography.subheadline)
                .foregroundStyle(color)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: XMTagSelectionLayout.statusMinHeight)
        .padding(.horizontal, Spacing.contentEdge)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(message)
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var layoutModeBinding: Binding<TagSelectionLayoutMode> {
        Binding(
            get: { layoutMode },
            set: updateLayoutMode
        )
    }

    private var tagGridColumns: [GridItem] {
        switch layoutMode {
        case .list:
            return [GridItem(.flexible(), spacing: Spacing.none, alignment: .top)]
        case .grid:
            return [
                GridItem(.flexible(), spacing: Spacing.base, alignment: .top),
                GridItem(.flexible(), spacing: Spacing.none, alignment: .top)
            ]
        }
    }

    private var tagGridSpacing: CGFloat {
        layoutMode == .grid ? Spacing.half : Spacing.none
    }

    private var visibleItems: [XMTagSelectionItem] {
        guard !normalizedSearchText.isEmpty else { return currentItems }
        return currentItems.filter {
            XMKeywordHighlighting.contains($0.title, keyword: normalizedSearchText)
        }
    }

    private var visibleItemIDs: [Int64] {
        visibleItems.map(\.id)
    }

    private var selectedItems: [XMTagSelectionItem] {
        currentItems.filter { draftSelectedIDs.contains($0.id) }
    }

    private var hasChanges: Bool {
        draftSelectedIDs != baselineSelectedIDs
    }

    private var hasLoadError: Bool {
        guard let loadErrorMessage else { return false }
        return !loadErrorMessage.isEmpty
    }

    private var isTagInteractionDisabled: Bool {
        isLoading || hasLoadError || isSaving || deletingItemID != nil
    }

    private var satisfiesSelectionRule: Bool {
        allowsEmptySelection || !draftSelectedIDs.isEmpty
    }

    private var canSave: Bool {
        hasChanges
            && satisfiesSelectionRule
            && !isLoading
            && !hasLoadError
            && !isSaving
            && deletingItemID == nil
    }

    private var saveAccessibilityHint: String {
        if isLoading {
            return "标签仍在加载"
        }
        if hasLoadError {
            return "标签加载失败，暂时无法保存"
        }
        if deletingItemID != nil {
            return "正在删除标签"
        }
        if !satisfiesSelectionRule {
            return "请至少选择一个标签"
        }
        if !hasChanges {
            return "当前选择没有变化"
        }
        return "保存当前标签选择"
    }

    private var structuralAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: 0.28)
    }

    private var panelState: XMTagSelectionPanelState {
        if hasLoadError {
            return .error
        }
        if isLoading {
            return loadingGate.isVisible ? .loadingVisible : .loadingDelayed
        }
        if visibleItems.isEmpty {
            return normalizedSearchText.isEmpty ? .empty : .noSearchResults
        }
        return .content
    }

    private var rowTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .opacity.combined(with: .offset(y: Spacing.half))
    }

    private var statusTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: Spacing.compact))
    }

    private func closeSheet() {
        guard !isSaving, deletingItemID == nil else { return }
        dismiss()
    }

    private func presentCreateSheet() {
        guard !isTagInteractionDisabled else { return }
        isSearchActive = false
        nameSheetPresentation = .create
    }

    private func presentRenameSheet(_ item: XMTagSelectionItem) {
        guard management != nil, !isTagInteractionDisabled else { return }
        isSearchActive = false
        nameSheetPresentation = .rename(item)
    }

    private func presentDeleteConfirmation(_ item: XMTagSelectionItem) {
        guard management != nil, !isTagInteractionDisabled else { return }
        deleteConfirmationItem = item
    }

    private func deleteDescriptor(for item: XMTagSelectionItem) -> XMSystemAlertDescriptor {
        XMSystemAlertDescriptor(
            title: "删除标签",
            message: management?.scope.deleteMessage,
            actions: [
                XMSystemAlertAction(title: "取消", role: .cancel) { },
                XMSystemAlertAction(title: "删除", role: .destructive) {
                    deleteItem(item)
                }
            ],
            preferredActionID: nil
        )
    }

    private func updateLayoutMode(_ newLayoutMode: TagSelectionLayoutMode) {
        guard newLayoutMode != layoutMode else { return }
        layout.onChange(newLayoutMode)

        if reduceMotion {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                layoutMode = newLayoutMode
            }
        } else {
            withAnimation(.smooth(duration: 0.28)) {
                layoutMode = newLayoutMode
            }
        }
    }

    private func toggleItem(_ item: XMTagSelectionItem) {
        guard !isTagInteractionDisabled else { return }
        saveErrorMessage = nil
        hasEditedSelection = true
        if draftSelectedIDs.contains(item.id) {
            draftSelectedIDs.remove(item.id)
        } else {
            draftSelectedIDs.insert(item.id)
        }
    }

    private func acceptCreatedItem(_ item: XMTagSelectionItem) {
        if let index = currentItems.firstIndex(where: { $0.id == item.id }) {
            currentItems[index] = item
        } else {
            currentItems.append(item)
        }
        locallyCreatedIDs.insert(item.id)
        draftSelectedIDs.insert(item.id)
        hasEditedSelection = true
        searchText = ""
        isSearchActive = false
        saveErrorMessage = nil
        createdItemToRevealID = item.id
    }

    private func acceptRenamedItem(_ item: XMTagSelectionItem) {
        guard let management else { return }
        if let index = currentItems.firstIndex(where: { $0.id == item.id }) {
            currentItems[index] = item
        }
        locallyRenamedTitles[item.id] = item.title
        saveErrorMessage = nil
        management.onMutation(
            .renamed(scope: management.scope, id: item.id, title: item.title)
        )
    }

    /// 删除任务由当前 Sheet 生命周期持有；确认后先进入局部写入态，成功才移除 Item 并广播目录事件。
    private func deleteItem(_ item: XMTagSelectionItem) {
        guard let management, deletingItemID == nil, !isSaving else { return }
        deletingItemID = item.id
        saveErrorMessage = nil
        deleteTask?.cancel()
        deleteTask = Task {
            do {
                try await management.onDelete([item.id])
                try Task.checkCancellation()
                acceptDeletedItem(item)
                management.onMutation(.deleted(scope: management.scope, id: item.id))
                deletingItemID = nil
            } catch is CancellationError {
                return
            } catch {
                deletingItemID = nil
                toastCenter.error(error.localizedDescription)
            }
        }
    }

    private func acceptDeletedItem(_ item: XMTagSelectionItem) {
        currentItems.removeAll { $0.id == item.id }
        baselineSelectedIDs.remove(item.id)
        draftSelectedIDs.remove(item.id)
        locallyCreatedIDs.remove(item.id)
        locallyRenamedTitles.removeValue(forKey: item.id)
        locallyDeletedIDs.insert(item.id)
        if createdItemToRevealID == item.id {
            createdItemToRevealID = nil
        }
        if pendingScrollItemID == item.id {
            pendingScrollItemID = nil
        }
    }

    private func revealCreatedItemAfterDismissal() {
        guard let createdItemToRevealID else { return }
        self.createdItemToRevealID = nil
        pendingScrollItemID = createdItemToRevealID
    }

    private func revealPendingItem(_ itemID: Int64?, using proxy: ScrollViewProxy) {
        guard let itemID else { return }
        pendingScrollItemID = nil
        if reduceMotion {
            proxy.scrollTo(itemID, anchor: .center)
        } else {
            withAnimation(.smooth(duration: 0.28)) {
                proxy.scrollTo(itemID, anchor: .center)
            }
        }
    }

    /// 写任务由当前 Sheet 生命周期持有；关闭时取消，成功前禁止重复提交，失败只回写当前页面的行内错误。
    private func saveSelection() {
        guard canSave else { return }
        isSaving = true
        saveErrorMessage = nil
        let selection = selectedItems
        saveTask?.cancel()
        saveTask = Task {
            let didSave = await onSave(selection)
            guard !Task.isCancelled else { return }
            if didSave {
                dismiss()
            } else {
                saveErrorMessage = "保存失败，请检查后重试"
                isSaving = false
            }
        }
    }

    private func synchronizeExternalItems(_ newItems: [XMTagSelectionItem]) {
        let reconciledItems = newItems.compactMap { item -> XMTagSelectionItem? in
            guard !locallyDeletedIDs.contains(item.id) else { return nil }
            guard let renamedTitle = locallyRenamedTitles[item.id] else { return item }
            return XMTagSelectionItem(id: item.id, title: renamedTitle)
        }
        let newIDs = Set(reconciledItems.map(\.id))
        let localOnlyItems = currentItems.filter {
            locallyCreatedIDs.contains($0.id)
                && !locallyDeletedIDs.contains($0.id)
                && !newIDs.contains($0.id)
        }
        currentItems = reconciledItems + localOnlyItems

        let validIDs = Set(currentItems.map(\.id))
        baselineSelectedIDs = initialSelectedIDs
            .subtracting(locallyDeletedIDs)
            .intersection(validIDs)
        if hasEditedSelection {
            draftSelectedIDs.formIntersection(validIDs)
        } else {
            draftSelectedIDs = baselineSelectedIDs
        }
    }

    private func synchronizeExternalSelection(_ newSelection: Set<Int64>) {
        let validIDs = Set(currentItems.map(\.id))
        baselineSelectedIDs = newSelection
            .subtracting(locallyDeletedIDs)
            .intersection(validIDs)
        guard !hasEditedSelection else { return }
        draftSelectedIDs = baselineSelectedIDs
    }

    private func synchronizeLoadingGate() {
        let shouldShowLoading = isLoading && !hasLoadError
        loadingGate.update(intent: shouldShowLoading ? .read : .none)
    }

    private func cancelOwnedWork() {
        loadingGate.hideImmediately()
        saveTask?.cancel()
        saveTask = nil
        deleteTask?.cancel()
        deleteTask = nil
    }
}

/// 通用标签选择项，列表与网格仅改变排版表面，关键字高亮、选择与 VoiceOver 语义保持共用。
private struct XMTagSelectionRow: View {
    let item: XMTagSelectionItem
    let keyword: String
    let isSelected: Bool
    let isDisabled: Bool
    let isDeleting: Bool
    let layoutMode: TagSelectionLayoutMode
    let showsListDivider: Bool
    let onToggle: (XMTagSelectionItem) -> Void
    let allowsManagement: Bool
    let onRename: (XMTagSelectionItem) -> Void
    let onDelete: (XMTagSelectionItem) -> Void

    var body: some View {
        VStack(spacing: Spacing.none) {
            Button(action: toggle) {
                HStack(spacing: Spacing.base) {
                    XMKeywordHighlighting.text(
                        item.title,
                        keyword: keyword,
                        baseFont: AppTypography.subheadline,
                        highlightFont: AppTypography.subheadlineSemibold,
                        baseColor: .textPrimary
                    )
                    .lineLimit(layoutMode == .grid ? 1 : 2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: layoutMode == .list)
                    .layoutPriority(1)

                    Spacer(minLength: Spacing.base)

                    Group {
                        if isDeleting {
                            ProgressView()
                                .controlSize(.small)
                                .tint(Color.textSecondary)
                                .accessibilityLabel("正在删除标签")
                        } else {
                            XMSelectionIndicator(
                                style: .checkbox,
                                isSelected: isSelected,
                                font: AppTypography.title3
                            )
                        }
                    }
                    .frame(
                        width: XMTagSelectionLayout.minimumHitSize,
                        height: XMTagSelectionLayout.minimumHitSize
                    )
                }
                .padding(.horizontal, layoutMode == .grid ? Spacing.base : Spacing.none)
                .frame(maxWidth: .infinity)
                .frame(minHeight: itemMinHeight)
                .background(
                    Color.surfaceCard.opacity(
                        layoutMode == .grid ? XMTagSelectionLayout.gridItemSurfaceOpacity : 0
                    ),
                    in: RoundedRectangle(
                        cornerRadius: layoutMode == .grid
                            ? CornerRadius.blockMedium
                            : CornerRadius.none,
                        style: .continuous
                    )
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(
                XMTagSelectionRowButtonStyle(
                    showsPressedFeedback: layoutMode == .grid
                )
            )
            .modifier(
                XMTagSelectionItemManagementModifier(
                    isEnabled: isManagementEnabled && !isDisabled,
                    layoutMode: layoutMode,
                    onRename: rename,
                    onDelete: delete
                )
            )
            .xmMenuNeutralTint()
            .disabled(isDisabled)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.title)
            .accessibilityValue(
                isDeleting ? "正在删除" : isSelected ? "已选择" : "未选择"
            )
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityHint(accessibilityHint)

            if layoutMode == .list {
                XMSettingsDivider()
                    .padding(.trailing, XMTagSelectionLayout.minimumHitSize)
                    .opacity(showsListDivider ? 1 : 0)
            }
        }
    }

    private func toggle() {
        onToggle(item)
    }

    private func rename() {
        onRename(item)
    }

    private func delete() {
        onDelete(item)
    }

    private var isManagementEnabled: Bool {
        allowsManagement
    }

    private var accessibilityHint: String {
        guard !isDeleting else { return "" }
        let selectionHint = isSelected ? "轻点取消选择" : "轻点选择"
        guard isManagementEnabled else { return selectionHint }
        return "\(selectionHint)，长按显示更多操作"
    }

    private var itemMinHeight: CGFloat {
        layoutMode == .grid
            ? XMTagSelectionLayout.gridItemMinHeight
            : XMTagSelectionLayout.rowMinHeight
    }
}

/// 仅在业务范围允许且当前可交互时，为标签选择项增加原生长按菜单与等价 VoiceOver 操作。
private struct XMTagSelectionItemManagementModifier: ViewModifier {
    let isEnabled: Bool
    let layoutMode: TagSelectionLayoutMode
    let onRename: () -> Void
    let onDelete: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content
                .contentShape(
                    .contextMenuPreview,
                    RoundedRectangle(
                        cornerRadius: layoutMode == .grid
                            ? CornerRadius.blockMedium
                            : CornerRadius.containerMedium,
                        style: .continuous
                    )
                )
                .contextMenu {
                    Button(action: onRename) {
                        XMMenuLabel("编辑标签", systemImage: "pencil")
                    }
                    Button(role: .destructive, action: onDelete) {
                        Label("删除标签", systemImage: "trash")
                    }
                }
                .accessibilityAction(named: "编辑标签", onRename)
                .accessibilityAction(named: "删除标签", onDelete)
        } else {
            content
        }
    }
}

/// 父 Sheet 同一时间只承载一种命名任务，Item 身份用于稳定区分创建与具体标签编辑会话。
private enum XMTagNameSheetPresentation: Identifiable {
    case create
    case rename(XMTagSelectionItem)

    var id: String {
        switch self {
        case .create:
            return "create"
        case .rename(let item):
            return "rename-\(item.id)"
        }
    }
}

/// 标签命名页面的文案与初始草稿模式，避免创建和编辑分叉重复实现校验及写入反馈。
private enum XMTagNameSheetMode {
    case create
    case rename(XMTagSelectionItem)

    var title: String {
        switch self {
        case .create:
            return "新建标签"
        case .rename:
            return "编辑标签"
        }
    }

    var initialName: String {
        switch self {
        case .create:
            return ""
        case .rename(let item):
            return item.title
        }
    }

    var originalName: String? {
        switch self {
        case .create:
            return nil
        case .rename(let item):
            return item.title
        }
    }

    var actionTitle: String {
        switch self {
        case .create:
            return "创建并选中"
        case .rename:
            return "保存"
        }
    }

    var progressTitle: String {
        switch self {
        case .create:
            return "创建中…"
        case .rename:
            return "保存中…"
        }
    }
}

/// 标签命名子 Sheet，把创建/编辑共用的校验、异步写入与失败反馈隔离在独立任务层级。
private struct XMTagNameSheet: View {
    let mode: XMTagNameSheetMode
    let existingTitles: [String]
    let onSubmit: @MainActor @Sendable (String) async throws -> XMTagSelectionItem
    let onSubmitted: (XMTagSelectionItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var name: String
    @State private var isSubmitting = false
    @State private var didExceedLimit = false
    @State private var submissionErrorMessage: String?
    @State private var submitTask: Task<Void, Never>?
    @FocusState private var isNameFocused: Bool

    /// 以创建或编辑模式建立独立命名草稿；Item 驱动的 Sheet 身份保证初始名称只在本次会话写入一次。
    init(
        mode: XMTagNameSheetMode,
        existingTitles: [String],
        onSubmit: @escaping @MainActor @Sendable (String) async throws -> XMTagSelectionItem,
        onSubmitted: @escaping (XMTagSelectionItem) -> Void
    ) {
        self.mode = mode
        self.existingTitles = existingTitles
        self.onSubmit = onSubmit
        self.onSubmitted = onSubmitted
        _name = State(initialValue: mode.initialName)
    }

    var body: some View {
        XMSheetScaffold(
            title: mode.title,
            onClose: closeSheet,
            isConfirmationDisabled: !canSubmit,
            isConfirming: isSubmitting,
            confirmationAction: submitName
        ) {
            XMSettingsGroup {
                VStack(alignment: .leading, spacing: Spacing.cozy) {
                    TextField("输入标签名称", text: $name)
                        .font(AppTypography.body)
                        .foregroundStyle(Color.textPrimary)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($isNameFocused)
                        .disabled(isSubmitting)
                        .onSubmit(submitName)

                    HStack(alignment: .firstTextBaseline, spacing: Spacing.cozy) {
                        if let validationMessage {
                            Text(validationMessage)
                                .font(AppTypography.caption)
                                .foregroundStyle(Color.feedbackError)
                                .fixedSize(horizontal: false, vertical: true)
                                .transition(.opacity)
                        }

                        Spacer(minLength: Spacing.cozy)

                        Text("\(name.count)/\(XMTagSelectionLayout.maximumNameLength)")
                            .font(AppTypography.caption2)
                            .foregroundStyle(didExceedLimit ? Color.feedbackError : Color.textHint)
                            .monospacedDigit()
                    }
                }
                .padding(.vertical, Spacing.half)
                .animation(structureAnimation, value: validationMessage)
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.bottom, Spacing.contentEdge)
        }
        .interactiveDismissDisabled(isSubmitting)
        .presentationDetents(
            dynamicTypeSize.isAccessibilitySize
                ? [.large]
                : [.height(XMTagSelectionLayout.nameSheetCompactHeight), .medium]
        )
        .presentationDragIndicator(.visible)
        .onAppear {
            isNameFocused = true
        }
        .onChange(of: name, handleNameChange)
        .onDisappear {
            submitTask?.cancel()
            submitTask = nil
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isDuplicate: Bool {
        guard !trimmedName.isEmpty else { return false }
        return existingTitles.contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare(trimmedName) == .orderedSame
        }
    }

    private var validationMessage: String? {
        if didExceedLimit {
            return "标签名称最多 \(XMTagSelectionLayout.maximumNameLength) 个字符"
        }
        if isDuplicate {
            return "已存在同名标签"
        }
        return submissionErrorMessage
    }

    private var isUnchanged: Bool {
        guard let originalName = mode.originalName else { return false }
        return originalName.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedName
    }

    private var canSubmit: Bool {
        !trimmedName.isEmpty
            && !didExceedLimit
            && !isDuplicate
            && !isUnchanged
            && !isSubmitting
    }

    private var structureAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: 0.28)
    }

    private func closeSheet() {
        guard !isSubmitting else { return }
        dismiss()
    }

    private func handleNameChange(_ oldValue: String, _ newValue: String) {
        submissionErrorMessage = nil
        if newValue.count > XMTagSelectionLayout.maximumNameLength {
            didExceedLimit = true
            name = String(newValue.prefix(XMTagSelectionLayout.maximumNameLength))
        } else if newValue.count < XMTagSelectionLayout.maximumNameLength {
            didExceedLimit = false
        } else if oldValue.count < XMTagSelectionLayout.maximumNameLength {
            didExceedLimit = false
        }
    }

    /// 命名任务由子 Sheet 生命周期持有；关闭时取消，成功后先回传真实标签，再使用系统 Sheet 转场退出。
    private func submitName() {
        guard canSubmit else { return }
        isSubmitting = true
        isNameFocused = false
        submissionErrorMessage = nil
        let submittedName = trimmedName
        submitTask?.cancel()
        submitTask = Task {
            do {
                let item = try await onSubmit(submittedName)
                try Task.checkCancellation()
                onSubmitted(item)
                dismiss()
            } catch is CancellationError {
                return
            } catch {
                submissionErrorMessage = error.localizedDescription
                isSubmitting = false
                isNameFocused = true
            }
        }
    }
}

/// 标签选择父子 Sheet 共用的局部主操作样式，以稳定矩形轮廓表达唯一提交动作。
private struct XMTagSelectionPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    /// 将按钮标签扩展到可用宽度，并根据可用性与按压状态呈现稳定的提交表面。
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? Color.primaryActionForeground : Color.buttonDisabledForeground)
            .frame(maxWidth: .infinity, minHeight: XMTagSelectionLayout.primaryActionHeight)
            .background(
                isEnabled ? Color.primaryActionFill : Color.buttonDisabled,
                in: RoundedRectangle(
                    cornerRadius: XMTagSelectionLayout.primaryActionCornerRadius,
                    style: .continuous
                )
            )
            .opacity(configuration.isPressed ? 0.86 : 1)
            .contentShape(
                RoundedRectangle(
                    cornerRadius: XMTagSelectionLayout.primaryActionCornerRadius,
                    style: .continuous
                )
            )
    }
}

/// 新建标签入口的局部按压样式，只通过短透明度变化反馈触控，不改变按钮尺寸或位置。
private struct XMTagSelectionCreateButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 在保持 44pt 热区稳定的前提下提供可中断的轻量按压反馈。
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.76 : 1)
            .animation(
                reduceMotion ? nil : .smooth(duration: 0.12),
                value: configuration.isPressed
            )
    }
}

/// 网格标签项使用与首页索引一致的轻量透明度反馈，列表态保持现有即时点击表现。
private struct XMTagSelectionRowButtonStyle: ButtonStyle {
    let showsPressedFeedback: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 仅在网格按压期间降低整体透明度；Reduce Motion 下直接切换视觉端点。
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(
                showsPressedFeedback && configuration.isPressed
                    ? XMTagSelectionLayout.gridItemPressedOpacity
                    : 1
            )
            .animation(
                reduceMotion || !showsPressedFeedback
                    ? nil
                    : configuration.isPressed
                        ? nil
                        : .smooth(duration: XMTagSelectionLayout.pressFeedbackDuration),
                value: configuration.isPressed
            )
    }
}

#if DEBUG
/// 复用私有生产命名 Sheet 的校准入口，供测试中心分别观察创建与重命名状态。
struct XMTagNameSheetPreview: View {
    enum Mode {
        case create
        case rename
    }

    let mode: Mode

    var body: some View {
        XMTagNameSheet(
            mode: mode == .create
                ? .create
                : .rename(XMTagSelectionItem(id: 1, title: "设计系统")),
            existingTitles: ["用户体验", "交互设计", "知识管理"],
            onSubmit: { name in
                try await Task.sleep(for: .milliseconds(650))
                return XMTagSelectionItem(id: 99, title: name)
            },
            onSubmitted: { _ in }
        )
    }
}
#endif

/// 标签选择 Sheet 的局部尺寸约束，避免把单一场景数值扩散为全局设计令牌。
private enum XMTagSelectionLayout {
    static let minimumHitSize: CGFloat = InteractionMetrics.minimumTouchTarget
    static let closeButtonVisualSize: CGFloat = 36
    static let layoutPickerWidth: CGFloat = 176
    static let secondaryActionVisualHeight: CGFloat = 32
    static let gridItemMinHeight: CGFloat = 48
    static let gridItemSurfaceOpacity = 0.72
    static let gridItemPressedOpacity = 0.72
    static let secondaryActionBorderWidth: CGFloat = 0.5
    static let pressFeedbackDuration = 0.12
    static let nameSheetCompactHeight: CGFloat = 228
    static let primaryActionHeight: CGFloat = 48
    static let primaryActionCornerRadius: CGFloat = 14
    static let rowMinHeight: CGFloat = 52
    static let statusMinHeight: CGFloat = 104
    static let maximumNameLength = 100
}

/// 标签面板的结构状态，仅用于把加载、错误、空态与内容切换限制在面板内部执行过渡。
private enum XMTagSelectionPanelState: Hashable {
    case loadingDelayed
    case loadingVisible
    case error
    case empty
    case noSearchResults
    case content
}
