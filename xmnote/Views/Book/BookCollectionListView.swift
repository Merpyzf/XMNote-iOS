/**
 * [INPUT]: 依赖外部注入的 BookCollectionListViewModel、EditMode 与页面私有视口锚点绑定，依赖书单显示设置、分组切换保存入口、BookCollectionImportRouter、LoadingGate 与 XMScopeSelector 驱动手动书单、年度书单、删除确认、排序和稳定加载占位
 * [OUTPUT]: 对外提供 BookCollectionListView，承载首页书单 Tab 的范围切换、列表/网格集合卡片、跨排序模式的语义视口保持、中性上下文操作、写入反馈、系统分享导入、表单弹层与书单详情入口
 * [POS]: Views/Book 的书单首页页面壳层，被 BookContainerView 的书单二级页消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Dispatch
import SwiftUI

/// 首页书单列表页，按 iOS 分段结构表达 Android “我的书单 / 年度书单”业务分组。
struct BookCollectionListView: View {
    @Environment(BookCollectionImportRouter.self) private var importRouter
    @Bindable var viewModel: BookCollectionListViewModel
    @Binding var editMode: EditMode
    @Binding var gridScrollPositionID: Int64?
    let onOpenCollection: (Int64) -> Void
    @State private var loadingGate = LoadingGate()
    @State private var visibleGridCollectionIDs: Set<Int64> = []
    @State private var visibleListCollectionIDs: Set<Int64> = []
    @State private var lastLeadingGridCollectionID: Int64?
    @State private var lastLeadingListCollectionID: Int64?
    @State private var pendingGridReturnCollectionID: Int64?
    @State private var viewportRestoreRequest: BookCollectionViewportRestoreRequest?

    /// 注入书单状态与打开回调，保持列表页只负责范围、列表与弹层渲染。
    init(
        viewModel: BookCollectionListViewModel,
        editMode: Binding<EditMode>,
        viewportAnchorID: Binding<Int64?>,
        onOpenCollection: @escaping (Int64) -> Void = { _ in }
    ) {
        self.viewModel = viewModel
        self._editMode = editMode
        self._gridScrollPositionID = viewportAnchorID
        self.onOpenCollection = onOpenCollection
    }

    var body: some View {
        VStack(spacing: Spacing.none) {
            controls
            content
        }
        .background(Color.surfacePage.ignoresSafeArea())
        .onAppear {
            syncLoadingGate()
            consumePendingWereadImport()
        }
        .onDisappear {
            loadingGate.hideImmediately()
        }
        .onChange(of: viewModel.contentState) { _, _ in
            syncLoadingGate()
        }
        .onChange(of: viewModel.selectedKind) { _, _ in
            resetViewportTracking()
            guard editMode.isEditing else { return }
            editMode = .inactive
        }
        .onChange(of: editMode.isEditing) { wasEditing, isEditing in
            prepareViewportRestore(wasEditing: wasEditing, isEditing: isEditing)
        }
        .onChange(of: viewModel.visibleCollections.map(\.id)) { _, visibleIDs in
            pruneViewportTracking(validIDs: Set(visibleIDs))
        }
        .onChange(of: importRouter.pendingImport) { _, _ in
            consumePendingWereadImport()
        }
        .onChange(of: viewModel.activeAction) { _, action in
            guard action == nil else { return }
            consumePendingWereadImport()
        }
        .onChange(of: viewModel.importedCollectionID) { _, collectionID in
            guard let collectionID else { return }
            onOpenCollection(collectionID)
            viewModel.consumeImportedCollectionID()
        }
        .sheet(item: activeFormBinding) { presentation in
            BookCollectionFormSheet(
                presentation: presentation,
                isSaving: viewModel.activeAction != nil
            ) { title, description in
                viewModel.submitForm(presentation, title: title, description: description)
            }
        }
        .sheet(item: $viewModel.wereadImportRequest) { _ in
            BookCollectionWereadImportSheet(
                isLoading: viewModel.activeAction == .import,
                errorMessage: viewModel.wereadImportErrorMessage,
                onParse: viewModel.parseWereadImportLink
            )
        }
        .sheet(item: $viewModel.importPreview) { preview in
            BookCollectionWereadImportPreviewSheet(
                preview: preview,
                isSaving: viewModel.activeAction == .import,
                errorMessage: viewModel.wereadImportErrorMessage,
                onConfirm: viewModel.confirmWereadImport
            )
        }
        .xmSystemAlert(item: deleteConfirmationBinding) { confirmation in
            deleteDescriptor(for: confirmation)
        }
    }

    private var activeFormBinding: Binding<BookCollectionFormPresentation?> {
        Binding(
            get: { viewModel.activeForm },
            set: { viewModel.activeForm = $0 }
        )
    }

    private var deleteConfirmationBinding: Binding<BookCollectionDeleteConfirmation?> {
        Binding(
            get: { viewModel.deleteConfirmation },
            set: { viewModel.deleteConfirmation = $0 }
        )
    }

    private var controls: some View {
        BookCollectionScopeHeader(
            selectedKind: Binding(
                get: { viewModel.selectedKind },
                set: { viewModel.selectKind($0) }
            ),
            manualCount: viewModel.snapshot.manualCollections.count,
            annualCount: viewModel.snapshot.annualCollections.count
        )
    }

    @ViewBuilder
    private var content: some View {
        if shouldKeepGridAlive {
            ZStack {
                gridContent
                    .opacity(editMode.isEditing ? 0 : 1)
                    .allowsHitTesting(!editMode.isEditing)
                    .accessibilityHidden(editMode.isEditing)

                if editMode.isEditing {
                    listContent
                }
            }
            .transaction(value: editMode.isEditing) { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        } else {
            listContent
        }
    }

    private var listContent: some View {
        ScrollViewReader { proxy in
            List {
                phaseRows
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 1)
            .environment(\.editMode, $editMode)
            .accessibilityIdentifier("book.collection.list")
            .transaction(value: loadPhase) { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
            .overlay(alignment: .top) {
                feedbackBanner
            }
            .onScrollTargetVisibilityChange(idType: Int64.self, threshold: 0.5) { visibleIDs in
                recordCollectionVisibility(visibleIDs, on: .list)
            }
            .task(id: viewportRestoreRequest?.requestID) {
                await restoreViewportIfNeeded(on: .list, proxy: proxy)
            }
        }
    }

    private var shouldKeepGridAlive: Bool {
        viewModel.displaySetting.displayMode == .grid
            && loadPhase == .content
            && !viewModel.visibleCollections.isEmpty
    }

    private var gridContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: Spacing.base) {
                    ForEach(viewModel.visibleCollections) { item in
                        Button {
                            onOpenCollection(item.id)
                        } label: {
                            BookCollectionListCard(
                                item: item,
                                displayMode: .grid,
                                coverArrangement: viewModel.displaySetting.coverArrangement,
                                showsStatistics: viewModel.displaySetting.showsStatistics
                            )
                        }
                        .buttonStyle(BookCollectionListCardButtonStyle())
                        .contextMenu {
                            collectionContextMenu(for: item)
                        }
                        .xmMenuNeutralTint()
                        .id(item.id)
                        .accessibilityIdentifier("book.collection.grid.\(item.id)")
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, Spacing.screenEdge)
                .padding(.top, Spacing.half)
                .padding(.bottom, Spacing.contentEdge)
            }
            .scrollIndicators(.hidden)
            .scrollPosition(id: $gridScrollPositionID, anchor: .top)
            .background(Color.surfacePage)
            .accessibilityIdentifier("book.collection.grid")
            .overlay(alignment: .top) {
                feedbackBanner
            }
            .onScrollTargetVisibilityChange(idType: Int64.self, threshold: 0.5) { visibleIDs in
                recordCollectionVisibility(visibleIDs, on: .grid)
            }
            .task(id: viewportRestoreRequest?.requestID) {
                await restoreViewportIfNeeded(on: .grid, proxy: proxy)
            }
        }
    }

    private var gridColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: Spacing.base),
            GridItem(.flexible(), spacing: Spacing.base)
        ]
    }

    @ViewBuilder
    private var feedbackBanner: some View {
        if let feedback = viewModel.actionFeedback {
            BookCollectionFeedbackBanner(feedback: feedback)
                .padding(.horizontal, Spacing.screenEdge)
                .padding(.top, Spacing.tight)
                .transition(.opacity.combined(with: .move(edge: .top)))
        } else if let message = viewModel.observationErrorMessage {
            XMInlineStatusBanner(
                message,
                tone: .error,
                action: XMStateAction("重试", perform: viewModel.retryObservation)
            )
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.top, Spacing.tight)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    @ViewBuilder
    private var phaseRows: some View {
        switch loadPhase {
        case .placeholder:
            placeholderRows
        case .content:
            collectionRows
        case .loading, .empty, .error:
            LoadPhaseHost(
                phase: loadPhase,
                content: {
                    EmptyView()
                },
                placeholder: {
                    EmptyView()
                },
                loading: {
                    stateRow {
                        LoadingStateView("正在加载书单…", style: .card)
                    }
                },
                empty: { message in
                    stateRow {
                        emptyState(title: message)
                    }
                },
                failure: { _ in
                    stateRow {
                        failureState
                    }
                }
            )
        }
    }

    @ViewBuilder
    private var placeholderRows: some View {
        ForEach(0..<3, id: \.self) { _ in
            BookCollectionListSkeletonCard()
                .redacted(reason: .placeholder)
                .allowsHitTesting(false)
                .modifier(BookCollectionListRowChrome())
        }
    }

    @ViewBuilder
    private var collectionRows: some View {
        ForEach(viewModel.visibleCollections) { item in
            collectionRow(for: item, viewModel: viewModel)
        }
        .onMove { offsets, destination in
            guard viewModel.selectedKind == .manual else { return }
            var items = viewModel.visibleCollections
            items.move(fromOffsets: offsets, toOffset: destination)
            viewModel.submitManualOrder(items.map(\.id))
        }
    }

    private func collectionRow(
        for item: BookCollectionListItem,
        viewModel: BookCollectionListViewModel
    ) -> some View {
        Button {
            onOpenCollection(item.id)
        } label: {
            BookCollectionListCard(
                item: item,
                displayMode: .list,
                coverArrangement: viewModel.displaySetting.coverArrangement,
                showsStatistics: viewModel.displaySetting.showsStatistics
            )
        }
        .buttonStyle(BookCollectionListCardButtonStyle())
        .id(item.id)
        .accessibilityIdentifier("book.collection.row.\(item.id)")
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if item.kind == .manual {
                Button {
                    viewModel.presentEditForm(for: item)
                } label: {
                    Label("编辑", systemImage: "pencil")
                }
                .tint(Color.editActionFill)

                Button(role: .destructive) {
                    viewModel.presentDeleteConfirmation(for: item)
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
        }
        .contextMenu {
            collectionContextMenu(for: item)
        }
        .xmMenuNeutralTint()
        .modifier(BookCollectionListRowChrome())
    }

    /// 以容器级原子快照记录当前可见书单，避免逐行出现/消失事件乱序留下过期锚点。
    private func recordCollectionVisibility(
        _ collectionIDs: [Int64],
        on surface: BookCollectionViewportSurface
    ) {
        let validIDs = Set(viewModel.visibleCollections.map(\.id))
        let visibleIDs = Set(collectionIDs).intersection(validIDs)
        let leadingID = viewModel.visibleCollections
            .lazy
            .map(\.id)
            .first(where: visibleIDs.contains)
        switch surface {
        case .grid:
            visibleGridCollectionIDs = visibleIDs
            if let leadingID, leadingID != lastLeadingGridCollectionID {
                lastLeadingGridCollectionID = leadingID
            }
        case .list:
            visibleListCollectionIDs = visibleIDs
            if let leadingID, leadingID != lastLeadingListCollectionID {
                lastLeadingListCollectionID = leadingID
            }
            if editMode.isEditing, let leadingID {
                pendingGridReturnCollectionID = leadingID
                gridScrollPositionID = leadingID
            }
        }
    }

    /// 在网格与排序列表真正互换容器时捕获业务锚点；普通列表排序不制造滚动请求。
    private func prepareViewportRestore(wasEditing: Bool, isEditing: Bool) {
        guard wasEditing != isEditing,
              viewModel.selectedKind == .manual,
              viewModel.displaySetting.displayMode == .grid else {
            return
        }
        let sourceSurface: BookCollectionViewportSurface = isEditing ? .grid : .list
        let destinationSurface: BookCollectionViewportSurface = isEditing ? .list : .grid
        guard let collectionID = leadingCollectionID(on: sourceSurface),
              viewModel.visibleCollections.contains(where: { $0.id == collectionID }) else {
            viewportRestoreRequest = nil
            return
        }
        pendingGridReturnCollectionID = collectionID
        if destinationSurface == .grid {
            gridScrollPositionID = collectionID
        }
        viewportRestoreRequest = BookCollectionViewportRestoreRequest(
            collectionID: collectionID,
            destination: destinationSurface
        )
    }

    /// 优先沿用尚未完成的反向恢复目标，避免快速重复切换从新容器的临时首屏重新取锚点。
    private func leadingCollectionID(on surface: BookCollectionViewportSurface) -> Int64? {
        if viewportRestoreRequest?.destination == surface {
            return viewportRestoreRequest?.collectionID
        }
        switch surface {
        case .grid:
            return lastLeadingGridCollectionID
        case .list:
            return lastLeadingListCollectionID
        }
    }

    /// 新容器完成首轮布局后无动画恢复同一书单；SwiftUI task 会在容器消失或请求替换时自动取消。
    @MainActor
    private func restoreViewportIfNeeded(
        on surface: BookCollectionViewportSurface,
        proxy: ScrollViewProxy
    ) async {
        if viewportRestoreRequest == nil,
           surface == .grid,
           !editMode.isEditing,
           let pendingGridReturnCollectionID,
           viewModel.visibleCollections.contains(where: { $0.id == pendingGridReturnCollectionID }) {
            viewportRestoreRequest = BookCollectionViewportRestoreRequest(
                collectionID: pendingGridReturnCollectionID,
                destination: .grid
            )
            return
        }
        guard let request = viewportRestoreRequest,
              request.destination == surface else {
            return
        }
        await Task.yield()
        await waitForNextMainRunLoopTurn()
        guard !Task.isCancelled,
              viewportRestoreRequest == request,
              viewModel.selectedKind == .manual,
              viewModel.displaySetting.displayMode == .grid,
              editMode.isEditing == (surface == .list),
              viewModel.visibleCollections.contains(where: { $0.id == request.collectionID }) else {
            if viewportRestoreRequest == request {
                viewportRestoreRequest = nil
            }
            if surface == .grid {
                pendingGridReturnCollectionID = nil
            }
            return
        }

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(request.collectionID, anchor: .top)
        }
        if viewportRestoreRequest == request {
            viewportRestoreRequest = nil
        }
        if surface == .grid {
            pendingGridReturnCollectionID = nil
        }
    }

    /// 将滚动恢复推迟到新容器完成首轮布局登记；恢复任务取消后仍会在下一次校验处退出，不会写回过期视口。
    @MainActor
    private func waitForNextMainRunLoopTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    /// 切换手动/年度范围时清空旧容器锚点，阻止不同数据集合之间错误定位。
    private func resetViewportTracking() {
        visibleGridCollectionIDs.removeAll()
        visibleListCollectionIDs.removeAll()
        lastLeadingGridCollectionID = nil
        lastLeadingListCollectionID = nil
        gridScrollPositionID = nil
        pendingGridReturnCollectionID = nil
        viewportRestoreRequest = nil
    }

    /// 数据变化后仅保留仍有效的可见身份，并取消已经失效的待恢复目标。
    private func pruneViewportTracking(validIDs: Set<Int64>) {
        visibleGridCollectionIDs.formIntersection(validIDs)
        visibleListCollectionIDs.formIntersection(validIDs)
        if let lastLeadingGridCollectionID,
           !validIDs.contains(lastLeadingGridCollectionID) {
            self.lastLeadingGridCollectionID = nil
        }
        if let lastLeadingListCollectionID,
           !validIDs.contains(lastLeadingListCollectionID) {
            self.lastLeadingListCollectionID = nil
        }
        if let viewportRestoreRequest,
           !validIDs.contains(viewportRestoreRequest.collectionID) {
            self.viewportRestoreRequest = nil
        }
        if let pendingGridReturnCollectionID,
           !validIDs.contains(pendingGridReturnCollectionID) {
            self.pendingGridReturnCollectionID = nil
        }
        if let gridScrollPositionID,
           !validIDs.contains(gridScrollPositionID) {
            self.gridScrollPositionID = nil
        }
    }

    @ViewBuilder
    private func collectionContextMenu(for item: BookCollectionListItem) -> some View {
        Button {
            onOpenCollection(item.id)
        } label: {
            XMMenuLabel("查看书单", systemImage: "book.pages")
        }
        if item.kind == .manual {
            Button {
                viewModel.presentEditForm(for: item)
            } label: {
                XMMenuLabel("编辑书单", systemImage: "pencil")
            }
            Button(role: .destructive) {
                viewModel.presentDeleteConfirmation(for: item)
            } label: {
                Label("删除书单", systemImage: "trash")
            }
        }
    }

    private var loadPhase: LoadPhase {
        switch viewModel.contentState {
        case .loading:
            return loadingGate.isVisible ? .loading : .placeholder
        case .content:
            return viewModel.visibleCollections.isEmpty ? .empty(message: emptyTitle) : .content
        case .empty:
            return .empty(message: emptyTitle)
        case .error(let message):
            return .error(message: message)
        }
    }

    private var emptyTitle: String {
        selectedKind == .manual ? "暂无书单" : "今年还没有读完的书"
    }

    private var selectedKind: BookCollectionKind {
        viewModel.selectedKind
    }

    private func syncLoadingGate() {
        if case .loading = viewModel.contentState {
            loadingGate.update(intent: .read)
        } else {
            loadingGate.update(intent: .none)
        }
    }

    private func consumePendingWereadImport() {
        guard viewModel.activeAction == nil,
              let request = importRouter.pendingImport else {
            return
        }
        switch request.source {
        case .deepLink:
            viewModel.parseWereadImportLink(request.link)
        case .systemShare:
            viewModel.importWereadLinkDirectly(request.link)
        }
        importRouter.consumePendingImport(request)
    }

    private func emptyState(title: String) -> some View {
        XMContentStateView(role: .empty, title: title)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var failureState: some View {
        XMContentStateView(
            role: .failure,
            title: "暂时无法加载书单",
            action: XMStateAction("重试", perform: viewModel.retryObservation)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func stateRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .frame(minHeight: 420)
            .modifier(BookCollectionListRowChrome(top: Spacing.half, bottom: Spacing.half))
    }

    private func deleteDescriptor(for confirmation: BookCollectionDeleteConfirmation) -> XMSystemAlertDescriptor {
        XMSystemAlertDescriptor(
            title: "删除“\(confirmation.item.title)”？",
            message: "书单会从列表中移除，书籍本身不会被删除。",
            actions: [
                XMSystemAlertAction(title: "取消", role: .cancel) {},
                XMSystemAlertAction(title: "删除", role: .destructive) {
                    viewModel.confirmDelete(confirmation)
                }
            ]
        )
    }
}

/// 区分书单首页浏览网格与系统排序列表，避免把不同布局的像素偏移直接互相复制。
private enum BookCollectionViewportSurface: Hashable {
    case grid
    case list
}

/// 一次性语义视口恢复请求，以稳定书单 ID 和目标容器约束快速反向切换。
private struct BookCollectionViewportRestoreRequest: Equatable {
    let requestID = UUID()
    let collectionID: Int64
    let destination: BookCollectionViewportSurface
}

/// 书单列表顶部范围切换，帮助用户在手动书单和年度书单之间快速定位。
private struct BookCollectionScopeHeader: View {
    @Binding var selectedKind: BookCollectionKind
    let manualCount: Int
    let annualCount: Int
    var isPlaceholder: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.none) {
            XMScopeSelector(
                items: scopeItems,
                selection: $selectedKind,
                style: .content,
                countFormat: .plain,
                accessibilityLabel: "书单范围"
            )
            .accessibilityIdentifier("book.collection.kind.picker")
        }
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.top, Spacing.tight)
        .padding(.bottom, Spacing.base)
        .redacted(reason: isPlaceholder ? .placeholder : [])
        .allowsHitTesting(!isPlaceholder)
        .accessibilityHidden(isPlaceholder)
    }

    private var scopeItems: [XMScopeSelectorItem<BookCollectionKind>] {
        [
            XMScopeSelectorItem(
                id: .manual,
                title: "我的书单",
                count: manualCount,
                accessibilityTitle: "我的书单"
            ),
            XMScopeSelectorItem(
                id: .annual,
                title: "年度书单",
                count: annualCount,
                accessibilityTitle: "年度书单"
            )
        ]
    }

}

private struct BookCollectionListRowChrome: ViewModifier {
    var top: CGFloat = Spacing.half
    var bottom: CGFloat = Spacing.half

    func body(content: Content) -> some View {
        content
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(
                top: top,
                leading: Spacing.screenEdge,
                bottom: bottom,
                trailing: Spacing.screenEdge
            ))
            .listRowBackground(Color.clear)
    }
}

private struct BookCollectionListCardButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 提供卡片级轻量按压反馈，避免改变列表布局和滑动操作语义。
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.94 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .snappy(duration: 0.12), value: configuration.isPressed)
    }
}

/// 书单写操作内联反馈，沿用 processing / success / warning / error 的语义色。
struct BookCollectionFeedbackBanner: View {
    let feedback: BookshelfActionFeedback

    var body: some View {
        HStack(spacing: Spacing.tight) {
            if feedback.kind == .processing {
                LoadingStateView(nil, style: .inline)
            } else {
                Image(systemName: iconName)
                    .font(AppTypography.caption)
                    .foregroundStyle(tint)
            }

            Text(feedback.message)
                .font(AppTypography.caption)
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Spacing.base)
        .padding(.vertical, Spacing.tight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous))
    }

    private var iconName: String {
        switch feedback.kind {
        case .processing:
            return "clock"
        case .success:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .error:
            return "xmark.circle.fill"
        }
    }

    private var tint: Color {
        switch feedback.kind {
        case .processing:
            return Color.appTint
        case .success:
            return Color.feedbackSuccess
        case .warning:
            return Color.feedbackWarning
        case .error:
            return Color.feedbackError
        }
    }
}
