/**
 * [INPUT]: 依赖 RepositoryContainer 注入 ChapterManagement/OCR Repository，依赖 ChapterManagerViewModel、XMStarredAppearance、批量/远端目录 Sheet、InteractionMetrics 与页面私有布局刻度
 * [OUTPUT]: 对外提供 ChapterManagerView，覆盖五层目录展开、叶子章节书摘导航、手工/OCR/远端导入、搜索、定位、新增编辑、星标、可撤销移动重排、多选删除与清空子章节
 * [POS]: Views/Book 的书内目录管理页面壳层，由 BookRoute.chapterManager 在当前 Tab NavigationStack 中 push
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 目录管理底部 chrome 的稳定高度，确保选择栏与撤销栏切换时页面内容不跳动。
private enum ChapterManagerChromeMetrics {
    static let bottomBarMinimumHeight: CGFloat = 52
}

/// 书内目录管理入口，完成 Repository 依赖注入和首屏延迟加载反馈。
struct ChapterManagerView: View {
    let bookID: Int64
    let bookName: String
    let doubanID: Int?
    let focusChapterID: Int64?

    @Environment(RepositoryContainer.self) private var repositories
    @State private var viewModel: ChapterManagerViewModel?
    @State private var bootstrapLoadingGate = LoadingGate()

    /// 从书籍详情或星标章节定位入口创建管理页；focusChapterID 为空时从目录顶部开始。
    init(
        bookID: Int64,
        bookName: String,
        doubanID: Int?,
        focusChapterID: Int64? = nil
    ) {
        self.bookID = bookID
        self.bookName = bookName
        self.doubanID = doubanID
        self.focusChapterID = focusChapterID
    }

    var body: some View {
        ZStack {
            Color.surfacePage.ignoresSafeArea()
            if let viewModel {
                ChapterManagerContentView(viewModel: viewModel)
            } else if bootstrapLoadingGate.isVisible {
                LoadingStateView("正在加载目录…", style: .card)
            }
        }
        .navigationTitle("目录管理")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard viewModel == nil else { return }
            bootstrapLoadingGate.update(intent: .read)
            let model = ChapterManagerViewModel(
                bookID: bookID,
                bookName: bookName,
                doubanID: doubanID,
                focusChapterID: focusChapterID,
                repository: repositories.chapterManagementRepository
            )
            viewModel = model
            bootstrapLoadingGate.update(intent: .none)
            model.startObservation()
        }
        .onDisappear {
            bootstrapLoadingGate.hideImmediately()
        }
    }
}

/// 目录管理内容区，统一绑定 EditMode、Sheet、XMSystemAlert 和结构过渡。
private struct ChapterManagerContentView: View {
    @Bindable var viewModel: ChapterManagerViewModel

    @Environment(RepositoryContainer.self) private var repositories
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var editMode: EditMode = .inactive
    @State private var readLoadingGate = LoadingGate()

    private var isEditing: Bool { editMode.isEditing }

    var body: some View {
        ZStack(alignment: .top) {
            phaseContent
            if viewModel.isWriting {
                writeFeedback
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .environment(\.editMode, $editMode)
        .searchable(text: $viewModel.searchText, prompt: "搜索目录")
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomFeedback }
        .sheet(item: $viewModel.moveRequest) { request in
            ChapterMoveSheet(
                request: request,
                targets: viewModel.moveTargets,
                onSelect: viewModel.submitMove
            )
        }
        .sheet(item: $viewModel.siblingOrderRequest) { request in
            ChapterSiblingOrderSheet(request: request) { orderedIDs in
                viewModel.submitSiblingOrder(parentID: request.parentID, orderedIDs: orderedIDs)
            }
        }
        .sheet(item: $viewModel.remoteSyncViewModel) { remoteViewModel in
            ChapterRemoteSyncSheet(viewModel: remoteViewModel)
        }
        .sheet(item: $viewModel.batchImportViewModel) { batchViewModel in
            ChapterBatchImportSheet(viewModel: batchViewModel) { result in
                viewModel.completeBatchImport(result)
            }
        }
        .xmSystemAlert(item: $viewModel.titleEditorRequest) { request in
            titleEditorDescriptor(request)
        }
        .xmSystemAlert(item: $viewModel.deletionRequest) { request in
            deletionDescriptor(request)
        }
        .xmSystemAlert(
            isPresented: writeErrorBinding,
            descriptor: writeErrorDescriptor
        )
        .onAppear(perform: syncReadLoadingGate)
        .onChange(of: viewModel.contentState) { _, _ in syncReadLoadingGate() }
        .onChange(of: editMode) { _, mode in
            if !mode.isEditing { viewModel.clearSelection() }
        }
        .onChange(of: viewModel.editModeDismissalToken) { _, _ in
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) {
                editMode = .inactive
            }
        }
        .onDisappear {
            readLoadingGate.hideImmediately()
        }
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.28),
            value: viewModel.visibleItems.map(\.id)
        )
        .animation(
            reduceMotion ? nil : .snappy(duration: 0.18),
            value: editMode
        )
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.28),
            value: viewModel.structureUndoFeedback?.id
        )
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch viewModel.contentState {
        case .loading:
            if readLoadingGate.isVisible {
                LoadingStateView("正在加载目录…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
            }
        case .empty:
            ContentUnavailableView {
                Label("暂无目录", systemImage: "list.bullet.indent")
            } description: {
                Text("可以新增一级章节，再逐步整理书摘结构")
            } actions: {
                Button("新增章节", action: viewModel.presentCreateRoot)
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .error(let message):
            ContentUnavailableView {
                Label("目录暂时无法显示", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("重新读取", action: viewModel.retryObservation)
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .content:
            chapterList
        }
    }

    private var chapterList: some View {
        ScrollViewReader { proxy in
            List {
                if viewModel.snapshot.unassignedNoteCount > 0, viewModel.searchText.isEmpty {
                    Section {
                        Label {
                            Text("未分章节 · \(viewModel.snapshot.unassignedNoteCount) 条书摘")
                                .font(AppTypography.callout)
                                .foregroundStyle(Color.textSecondary)
                        } icon: {
                            Image(systemName: "tray")
                                .foregroundStyle(Color.textHint)
                        }
                    }
                }

                Section {
                    ForEach(viewModel.visibleItems) { visibleItem in
                        ChapterManagementRow(
                            visibleItem: visibleItem,
                            isEditing: isEditing,
                            isSelected: viewModel.selectedIDs.contains(visibleItem.id),
                            isWriting: viewModel.isWriting,
                            onToggleExpanded: { viewModel.toggleExpanded(chapterID: visibleItem.id) },
                            onToggleSelection: { viewModel.toggleSelection(chapterID: visibleItem.id) },
                            onAddChild: { viewModel.presentCreateChild(parentID: visibleItem.id) },
                            onRename: { viewModel.presentRename(chapterID: visibleItem.id) },
                            onToggleStarred: {
                                viewModel.setStarred(
                                    chapterID: visibleItem.id,
                                    isStarred: !visibleItem.item.isStarred
                                )
                            },
                            onMove: { viewModel.presentMove(chapterIDs: [visibleItem.id]) },
                            onReorder: { viewModel.presentSiblingOrder(chapterID: visibleItem.id) },
                            onDeleteDescendants: {
                                viewModel.presentDeleteDescendants(parentID: visibleItem.id)
                            },
                            onDelete: { viewModel.presentDelete(chapterIDs: [visibleItem.id]) }
                        )
                        .id(visibleItem.id)
                        .listRowBackground(Color.surfaceCard)
                    }
                } header: {
                    Text(viewModel.searchText.isEmpty ? "\(viewModel.snapshot.chapterCount) 个章节" : "搜索结果")
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.surfacePage)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: viewModel.pendingScrollTargetID, initial: true) { _, targetID in
                guard let targetID else { return }
                Task { @MainActor in
                    await Task.yield()
                    if reduceMotion {
                        proxy.scrollTo(targetID, anchor: .center)
                    } else {
                        withAnimation(.smooth(duration: 0.32)) {
                            proxy.scrollTo(targetID, anchor: .center)
                        }
                    }
                    viewModel.consumeScrollTarget(targetID)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if viewModel.snapshot.chapterCount > 0 {
            ToolbarItem(placement: .topBarLeading) {
                EditButton()
                    .disabled(viewModel.isWriting)
            }
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
            if !isEditing {
                Button(action: viewModel.presentCreateRoot) {
                    TopBarActionIcon(systemName: "plus")
                }
                .disabled(viewModel.isWriting)
                .accessibilityLabel("新增一级章节")

                Menu {
                    Button("批量录入目录", systemImage: "text.badge.plus") {
                        viewModel.presentBatchImport(ocrRepository: repositories.ocrRepository)
                    }
                    .disabled(viewModel.isWriting)

                    Button("远端同步目录", systemImage: "arrow.triangle.2.circlepath") {
                        viewModel.presentRemoteSync()
                    }
                    .disabled(viewModel.isWriting)
                } label: {
                    TopBarActionIcon(systemName: "ellipsis")
                }
                .accessibilityLabel("更多目录操作")
            }
        }
    }

    private var selectionBar: some View {
        HStack(spacing: Spacing.base) {
            Button(viewModel.isAllVisibleSelected ? "取消全选" : "全选") {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) {
                    viewModel.toggleSelectAllVisible()
                }
            }
            .font(AppTypography.callout)
            .disabled(viewModel.visibleItems.isEmpty || viewModel.isWriting)

            Spacer(minLength: Spacing.cozy)

            Text("已选 \(viewModel.selectionCount) 项")
                .font(AppTypography.caption)
                .foregroundStyle(Color.textSecondary)

            Spacer(minLength: Spacing.cozy)

            Button("移动", systemImage: "folder") {
                viewModel.presentMove(chapterIDs: viewModel.selectedIDs)
            }
            .font(AppTypography.callout)
            .disabled(viewModel.selectedIDs.isEmpty || viewModel.isWriting)

            Button("删除", systemImage: "trash", role: .destructive) {
                viewModel.presentDelete(chapterIDs: viewModel.selectedIDs)
            }
            .font(AppTypography.callout)
            .disabled(viewModel.selectedIDs.isEmpty || viewModel.isWriting)
        }
        .padding(.horizontal, Spacing.screenEdge)
        .frame(minHeight: ChapterManagerChromeMetrics.bottomBarMinimumHeight)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider().overlay(Color.surfaceBorderSubtle)
        }
    }

    @ViewBuilder
    private var bottomFeedback: some View {
        VStack(spacing: Spacing.none) {
            if let feedback = viewModel.structureUndoFeedback {
                ChapterStructureUndoBar(
                    message: feedback.message,
                    isWriting: viewModel.isWriting,
                    onUndo: viewModel.undoLastStructureChange,
                    onDismiss: viewModel.dismissStructureUndo
                )
                .transition(
                    reduceMotion
                        ? .opacity
                        : .move(edge: .bottom).combined(with: .opacity)
                )
            }

            if isEditing {
                selectionBar
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .bottom).combined(with: .opacity)
                    )
            }
        }
    }

    private var writeFeedback: some View {
        LoadingStateView(viewModel.activeWriteTitle, style: .card)
            .padding(.top, Spacing.cozy)
            .allowsHitTesting(false)
            .accessibilityAddTraits(.updatesFrequently)
    }

    private func syncReadLoadingGate() {
        readLoadingGate.update(intent: viewModel.contentState == .loading ? .read : .none)
    }

    private func titleEditorDescriptor(_ request: ChapterTitleEditorRequest) -> XMSystemAlertDescriptor {
        return XMSystemAlertDescriptor(
            title: request.title,
            message: request.isCreating ? "最多支持 \(ChapterManagementPolicy.maximumDepth) 级目录。" : nil,
            actions: [
                XMSystemAlertAction(title: "取消", role: .cancel) { },
                XMSystemAlertAction(title: request.isCreating ? "创建" : "完成") {
                    viewModel.submitTitleEditor()
                }
            ],
            textFields: [
                XMSystemAlertTextField(
                    text: Binding(
                        get: { viewModel.titleEditorText },
                        set: { viewModel.titleEditorText = $0 }
                    ),
                    placeholder: "章节标题"
                )
            ]
        )
    }

    private func deletionDescriptor(_ request: ChapterDeletionRequest) -> XMSystemAlertDescriptor {
        let destructiveActions: [XMSystemAlertAction]
        if request.affectedNoteCount > 0 {
            destructiveActions = [
                XMSystemAlertAction(title: "保留书摘并删除章节", role: .destructive) {
                    viewModel.confirmDeletion(noteDisposition: .detach)
                },
                XMSystemAlertAction(title: "连同书摘一起删除", role: .destructive) {
                    viewModel.confirmDeletion(noteDisposition: .delete)
                }
            ]
        } else {
            destructiveActions = [
                XMSystemAlertAction(title: "删除", role: .destructive) {
                    viewModel.confirmDeletion(noteDisposition: .detach)
                }
            ]
        }
        return XMSystemAlertDescriptor(
            title: request.title,
            message: request.message,
            actions: [XMSystemAlertAction(title: "取消", role: .cancel) { }] + destructiveActions,
            preferredActionID: nil
        )
    }

    private var writeErrorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.writeErrorMessage != nil },
            set: { isPresented in
                if !isPresented { viewModel.consumeWriteError() }
            }
        )
    }

    private var writeErrorDescriptor: XMSystemAlertDescriptor? {
        guard let message = viewModel.writeErrorMessage else { return nil }
        return XMSystemAlertDescriptor(
            title: "操作未完成",
            message: message,
            actions: [
                XMSystemAlertAction(title: "好", role: .cancel) {
                    viewModel.consumeWriteError()
                }
            ]
        )
    }
}

/// 结构写入后的可行动 Undo 反馈；复用底部 bar、语义色和 44pt 热区，不与全局 Toast 重复提示。
private struct ChapterStructureUndoBar: View {
    let message: String
    let isWriting: Bool
    let onUndo: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Spacing.cozy) {
            Image(systemName: "arrow.uturn.backward.circle.fill")
                .foregroundStyle(Color.appTint)
                .accessibilityHidden(true)

            Text(message)
                .font(AppTypography.callout)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button("撤销", action: onUndo)
                .font(AppTypography.subheadlineSemibold)
                .disabled(isWriting)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .foregroundStyle(Color.textSecondary)
                    .frame(
                        width: InteractionMetrics.minimumTouchTarget,
                        height: InteractionMetrics.minimumTouchTarget
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isWriting)
            .accessibilityLabel("关闭撤销提示")
        }
        .padding(.leading, Spacing.screenEdge)
        .padding(.trailing, Spacing.compact)
        .frame(minHeight: ChapterManagerChromeMetrics.bottomBarMinimumHeight)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider().overlay(Color.surfaceBorderSubtle)
        }
        .accessibilityElement(children: .contain)
    }
}

/// 目录行前导控件槽位保持统一宽高，使选择态与展开态切换时正文基线不漂移。
private enum ChapterManagementRowMetrics {
    static let leadingControlSlotSize: CGFloat = InteractionMetrics.minimumTouchTarget
}

/// 目录行以真实层级缩进，编辑态复用同一对象身份切换为多选反馈。
private struct ChapterManagementRow: View {
    let visibleItem: ChapterManagementVisibleItem
    let isEditing: Bool
    let isSelected: Bool
    let isWriting: Bool
    let onToggleExpanded: () -> Void
    let onToggleSelection: () -> Void
    let onAddChild: () -> Void
    let onRename: () -> Void
    let onToggleStarred: () -> Void
    let onMove: () -> Void
    let onReorder: () -> Void
    let onDeleteDescendants: () -> Void
    let onDelete: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var indentation: CGFloat {
        CGFloat(max(0, min(visibleItem.item.level - 1, 4))) * Spacing.base
    }

    var body: some View {
        HStack(spacing: Spacing.none) {
            primaryControl

            if visibleItem.hasChildren {
                NavigationLink(value: AppRoute.note(chapterNotesRoute)) {
                    Image(systemName: "note.text")
                        .foregroundStyle(Color.textSecondary)
                        .frame(
                            width: InteractionMetrics.minimumTouchTarget,
                            height: InteractionMetrics.minimumTouchTarget
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(isEditing ? 0 : 1)
                .disabled(isEditing || isWriting)
                .accessibilityHidden(isEditing)
                .accessibilityLabel("查看“\(visibleItem.item.displayTitle)”的章节书摘")
            }
        }
        .contextMenu { contextMenuContent }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button(action: onToggleStarred) {
                Label(visibleItem.item.isStarred ? "取消星标" : "星标", systemImage: visibleItem.item.isStarred ? "star.slash" : "star")
            }
            .tint(.orange)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("删除", systemImage: "trash", role: .destructive, action: onDelete)
            Button("编辑", systemImage: "pencil", action: onRename)
                .tint(Color.editActionFill)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var primaryControl: some View {
        if isEditing || visibleItem.hasChildren {
            Button(action: primaryAction) {
                rowLabel
            }
            .buttonStyle(.plain)
            .disabled(isWriting)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(visibleItem.item.displayTitle)
            .accessibilityValue(primaryAccessibilityValue)
            .accessibilityHint(primaryAccessibilityHint)
            .accessibilityAddTraits(isEditing && isSelected ? .isSelected : [])
        } else {
            NavigationLink(value: AppRoute.note(chapterNotesRoute)) {
                rowLabel
            }
            .buttonStyle(.plain)
            .disabled(isWriting)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(visibleItem.item.displayTitle)
            .accessibilityValue(primaryAccessibilityValue)
            .accessibilityHint("打开章节书摘")
        }
    }

    private var rowLabel: some View {
        HStack(spacing: Spacing.cozy) {
            selectionOrDisclosure

            VStack(alignment: .leading, spacing: Spacing.compact) {
                HStack(spacing: Spacing.compact) {
                    Text(visibleItem.item.displayTitle)
                        .font(visibleItem.item.level == 1 ? AppTypography.bodyMedium : AppTypography.body)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(2)

                    if visibleItem.item.isStarred {
                        Image(systemName: "star.fill")
                            .imageScale(.small)
                            .foregroundStyle(XMStarredAppearance.foreground)
                            .accessibilityHidden(true)
                    }
                }

                Text(metadataText)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Spacing.cozy)
        }
        .padding(.leading, indentation)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var chapterNotesRoute: NoteRoute {
        .chapterNotes(
            bookID: visibleItem.item.bookID,
            chapterID: visibleItem.id,
            includeDescendants: true
        )
    }

    @ViewBuilder
    private var selectionOrDisclosure: some View {
        if isEditing {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.selectionAccent : Color.textHint)
                .frame(
                    width: ChapterManagementRowMetrics.leadingControlSlotSize,
                    height: ChapterManagementRowMetrics.leadingControlSlotSize
                )
                .transition(.opacity)
                .accessibilityHidden(true)
        } else {
            Image(systemName: visibleItem.hasChildren ? "chevron.right" : "circle.fill")
                .font(visibleItem.hasChildren ? AppTypography.captionSemibold : AppTypography.caption2)
                .foregroundStyle(visibleItem.hasChildren ? Color.textSecondary : Color.textHint.opacity(0.45))
                .rotationEffect(.degrees(visibleItem.isExpanded && !reduceMotion ? 90 : 0))
                .frame(
                    width: ChapterManagementRowMetrics.leadingControlSlotSize,
                    height: ChapterManagementRowMetrics.leadingControlSlotSize
                )
                .animation(
                    reduceMotion ? nil : .snappy(duration: 0.18),
                    value: visibleItem.isExpanded
                )
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        Button("新增子章节", systemImage: "plus") { onAddChild() }
            .disabled(visibleItem.item.level >= ChapterManagementPolicy.maximumDepth)
        Button("编辑", systemImage: "pencil") { onRename() }
        Button(
            visibleItem.item.isStarred ? "取消星标" : "星标",
            systemImage: visibleItem.item.isStarred ? "star.slash" : "star"
        ) {
            onToggleStarred()
        }
        Button("移动", systemImage: "folder") { onMove() }
        Button("调整同级顺序", systemImage: "arrow.up.arrow.down") { onReorder() }
        if visibleItem.hasChildren {
            Divider()
            Button("删除子章节", systemImage: "rectangle.stack.badge.minus", role: .destructive) {
                onDeleteDescendants()
            }
        }
        Divider()
        Button("删除章节及后代", systemImage: "trash", role: .destructive) { onDelete() }
    }

    private var metadataText: String {
        if visibleItem.hasChildren {
            return "\(visibleItem.item.descendantNoteCount) 条书摘 · \(visibleItem.item.childCount) 个直接子章节"
        }
        return "\(visibleItem.item.directNoteCount) 条书摘"
    }

    private var primaryAccessibilityValue: String {
        if isEditing {
            return isSelected ? "已选择" : "未选择"
        }

        let starredDescription = visibleItem.item.isStarred ? "，已星标" : ""
        guard visibleItem.hasChildren else {
            return metadataText + starredDescription
        }
        let expansionDescription = visibleItem.isExpanded ? "，已展开" : "，已收起"
        return metadataText + starredDescription + expansionDescription
    }

    private var primaryAccessibilityHint: String {
        if isEditing {
            return "切换选择"
        }
        return visibleItem.isExpanded ? "收起子章节" : "展开子章节"
    }

    /// 普通态仅处理分支展开，编辑态切换选择；叶子节点由 NavigationLink 直接打开章节书摘。
    private func primaryAction() {
        if isEditing {
            onToggleSelection()
        } else if visibleItem.hasChildren {
            onToggleExpanded()
        }
    }
}
