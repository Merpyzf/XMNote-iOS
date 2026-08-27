/**
 * [INPUT]: 依赖外部注入的 BookCollectionListViewModel 与 EditMode，依赖书单显示设置、分组切换保存入口、BookCollectionImportRouter、LoadingGate 与 XMScopeSelector 驱动手动书单、年度书单、删除确认、排序和稳定加载占位
 * [OUTPUT]: 对外提供 BookCollectionListView，承载首页书单 Tab 的范围切换、列表/网格集合卡片、中性上下文操作、写入反馈、系统分享导入、表单弹层与书单详情入口
 * [POS]: Views/Book 的书单首页页面壳层，被 BookContainerView 的书单二级页消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 首页书单列表页，按 iOS 分段结构表达 Android “我的书单 / 年度书单”业务分组。
struct BookCollectionListView: View {
    @Environment(BookCollectionImportRouter.self) private var importRouter
    @Bindable var viewModel: BookCollectionListViewModel
    @Binding var editMode: EditMode
    let onOpenCollection: (Int64) -> Void
    @State private var loadingGate = LoadingGate()

    /// 注入书单状态与打开回调，保持列表页只负责范围、列表与弹层渲染。
    init(
        viewModel: BookCollectionListViewModel,
        editMode: Binding<EditMode>,
        onOpenCollection: @escaping (Int64) -> Void = { _ in }
    ) {
        self.viewModel = viewModel
        self._editMode = editMode
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
            guard editMode.isEditing else { return }
            editMode = .inactive
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
        if shouldUseGridContent {
            gridContent
        } else {
            listContent
        }
    }

    private var listContent: some View {
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
    }

    private var shouldUseGridContent: Bool {
        viewModel.displaySetting.displayMode == .grid
            && !editMode.isEditing
            && loadPhase == .content
            && !viewModel.visibleCollections.isEmpty
    }

    private var gridContent: some View {
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
                    .accessibilityIdentifier("book.collection.grid.\(item.id)")
                }
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.top, Spacing.half)
            .padding(.bottom, Spacing.contentEdge)
        }
        .scrollIndicators(.hidden)
        .background(Color.surfacePage)
        .accessibilityIdentifier("book.collection.grid")
        .overlay(alignment: .top) {
            feedbackBanner
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
                failure: { message in
                    stateRow {
                        failureState(message: message)
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
        selectedKind == .manual ? "还没有书单，点击右上角按钮创建" : "今年还没有读完的书"
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
        VStack(spacing: Spacing.section) {
            XMCompactStateView(
                role: .empty,
                title: title,
                systemImage: selectedKind == .manual ? "rectangle.stack.badge.plus" : "calendar"
            )
            .frame(maxHeight: 260)

            if selectedKind == .manual {
                Button {
                    viewModel.presentCreateForm()
                } label: {
                    Label("新建第一份书单", systemImage: "plus")
                        .font(AppTypography.subheadlineMedium)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canCreateManualCollection)
                .accessibilityIdentifier("book.collection.empty.create")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Spacing.screenEdge)
    }

    private func failureState(message: String) -> some View {
        XMContentStateView(
            role: .failure,
            title: "书单加载失败",
            message: message.isEmpty ? "请稍后重试" : message,
            systemImage: "exclamationmark.triangle"
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
