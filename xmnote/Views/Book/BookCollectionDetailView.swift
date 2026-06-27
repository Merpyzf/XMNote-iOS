/**
 * [INPUT]: 依赖 RepositoryContainer 注入书架与封面上传仓储，依赖 BookCollectionDetailViewModel 驱动书单详情、添加书籍、移除、排序、relation 文本编辑、书籍元信息编辑、导出占位与删除确认
 * [OUTPUT]: 对外提供 BookCollectionDetailView，承载手动书单与年度书单详情、自动同步边界、导出入口、书籍行操作、书籍元信息编辑、收藏理由/年度点评编辑和系统弹窗
 * [POS]: Views/Book 的书单详情页面壳层，被 BookRoute.collectionDetail 导航目标消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书单详情页，手动书单提供整理能力，年度书单保持成员自动同步并允许编辑年度点评。
struct BookCollectionDetailView: View {
    @Environment(RepositoryContainer.self) private var repositories
    let collectionID: Int64
    let onOpenRoute: (BookRoute) -> Void
    @State private var viewModel: BookCollectionDetailViewModel?

    /// 注入书单 ID 与书籍路由回调，保持详情页内操作与主导航解耦。
    init(
        collectionID: Int64,
        onOpenRoute: @escaping (BookRoute) -> Void = { _ in }
    ) {
        self.collectionID = collectionID
        self.onOpenRoute = onOpenRoute
    }

    var body: some View {
        Group {
            if let viewModel {
                BookCollectionDetailContentView(
                    viewModel: viewModel,
                    onOpenRoute: onOpenRoute
                )
            } else {
                BookCollectionDetailLoadingScaffold()
            }
        }
        .task(id: collectionID) {
            viewModel = BookCollectionDetailViewModel(
                collectionID: collectionID,
                repository: repositories.bookRepository,
                s3UploadRepository: repositories.s3UploadRepository,
                coverImageLoader: repositories.coverImageLoader
            )
        }
    }
}

/// 书单详情启动占位，等待详情数据加载时保留系统导航与内容骨架。
private struct BookCollectionDetailLoadingScaffold: View {
    var body: some View {
        BookCollectionDetailSkeletonContent()
        .background(Color.surfacePage.ignoresSafeArea())
        .navigationTitle("书单")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 书单详情内容视图，集中承载系统工具栏入口、详情头、书籍列表和业务弹窗。
private struct BookCollectionDetailContentView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var viewModel: BookCollectionDetailViewModel
    let onOpenRoute: (BookRoute) -> Void
    @State private var editMode: EditMode = .inactive
    @State private var loadingGate = LoadingGate()
    @State private var showsBookPicker = false
    @State private var showsCollectionSummary = false
    @State private var contentTrayTop: CGFloat = .nan
    @State private var floatingAddBookOrnamentHeight: CGFloat = .zero
    @State private var floatingAddBookContentInset: CGFloat = .zero
    #if DEBUG
    @State private var headerVisualStyle: BookCollectionHeaderVisualStyle = .editorialDesk
    #endif

    private var isReordering: Bool {
        editMode.isEditing
    }

    var body: some View {
        content
        .background(Color.surfacePage.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if shouldShowMoreMenu {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        moreMenuContent
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundStyle(Color.textPrimary)
                            .accessibilityLabel("书单更多操作")
                    }
                    .accessibilityIdentifier("book.collection.detail.more")
                }
            }
        }
        .onAppear {
            syncLoadingGate()
        }
        .onDisappear {
            loadingGate.hideImmediately()
        }
        .onChange(of: viewModel.contentState) { _, _ in
            syncLoadingGate()
        }
        .onChange(of: viewModel.shouldDismissAfterDelete) { _, shouldDismiss in
            guard shouldDismiss else { return }
            dismiss()
        }
        .sheet(isPresented: $showsBookPicker) {
            BookPickerView(configuration: pickerConfiguration) { result in
                showsBookPicker = false
                viewModel.addPickerResult(result)
            }
        }
        .sheet(isPresented: $showsCollectionSummary) {
            if let detail = viewModel.detail {
                BookCollectionSummarySheet(detail: detail)
            }
        }
        .sheet(item: $viewModel.activeForm) { presentation in
            BookCollectionFormSheet(
                presentation: presentation,
                isSaving: viewModel.activeAction != nil
            ) { title, description in
                viewModel.submitForm(presentation, title: title, description: description)
            }
        }
        .sheet(item: $viewModel.annualDescriptionEdit) { edit in
            BookCollectionAnnualDescriptionSheet(
                edit: edit,
                isSaving: viewModel.activeAction != nil
            ) { description in
                viewModel.submitAnnualDescription(edit, description: description)
            }
        }
        .sheet(item: $viewModel.recommendEdit) { edit in
            let presentation = relationNotePresentation
            BookCollectionRecommendSheet(
                edit: edit,
                isSaving: viewModel.activeAction != nil,
                presentation: presentation
            ) { recommend in
                viewModel.submitRecommend(
                    edit,
                    recommend: recommend,
                    savingMessage: presentation.savingMessage,
                    savedMessage: presentation.savedMessage
                )
            }
        }
        .sheet(item: $viewModel.metadataEdit) { edit in
            let presentation = relationNotePresentation
            BookCollectionBookMetadataEditSheet(
                edit: edit,
                isSaving: viewModel.activeAction != nil,
                presentation: presentation
            ) { draft in
                viewModel.submitBookMetadata(edit, draft: draft)
            }
        }
        .sheet(item: $viewModel.generatedFile) { file in
            ActivityShareSheet(activityItems: file.urls)
                .presentationDetents([.medium, .large])
        }
        .xmSystemAlert(item: $viewModel.removeConfirmation) { confirmation in
            removeDescriptor(for: confirmation)
        }
        .xmSystemAlert(item: $viewModel.deleteConfirmation) { confirmation in
            deleteDescriptor(for: confirmation)
        }
        .accessibilityIdentifier("book.collection.detail")
    }

    @ViewBuilder
    private var content: some View {
        LoadPhaseHost(
            phase: loadPhase,
            content: {
                bookList
            },
            placeholder: {
                BookCollectionDetailSkeletonContent()
            },
            loading: {
                LoadingStateView("正在加载书单…", style: .card)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            },
            empty: { message in
                if viewModel.detail != nil {
                    bookList
                } else {
                    BookshelfContextualEmptyStateView(
                        icon: viewModel.isManual ? "book.badge.plus" : "calendar",
                        title: message,
                        message: viewModel.isManual ? "添加书籍后会显示在这里。" : "读完记录会显示在这里。"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            },
            failure: { message in
                BookshelfContextualEmptyStateView(
                    icon: "exclamationmark.triangle",
                    title: "书单加载失败",
                    message: message.isEmpty ? "请稍后重试" : message,
                    iconColor: Color.feedbackWarning.opacity(0.42)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        )
        .overlay(alignment: .top) {
            if let feedback = viewModel.actionFeedback {
                BookCollectionFeedbackBanner(feedback: feedback)
                    .padding(.horizontal, Spacing.screenEdge)
                    .padding(.top, Spacing.tight)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var bookList: some View {
        ZStack(alignment: .topLeading) {
            BookCollectionFullHeightTrayBackground(topOffset: contentTrayTop)
                .ignoresSafeArea(.container, edges: .bottom)

            List {
                Section {
                    header
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                if let detail = viewModel.detail {
                    Section {
                        BookCollectionContentHeader(
                            title: contentHeaderTitle(for: detail),
                            status: contentHeaderStatus(for: detail)
                        )
                        .padding(.horizontal, Spacing.screenEdge)
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.frame(in: .named(BookCollectionContentTrayCoordinateSpace.name)).minY
                        } action: { newTop in
                            updateContentTrayTop(newTop)
                        }
                        .listRowSeparator(.hidden)
                        .listRowInsets(contentSectionInsets)
                        .listRowBackground(BookCollectionContentRowBackground(position: .top))

                        if isReordering {
                            reorderStatusRow
                                .padding(.horizontal, Spacing.screenEdge)
                                .listRowSeparator(.hidden)
                                .listRowInsets(contentSectionInsets)
                                .listRowBackground(BookCollectionContentRowBackground(position: .middle))
                        }

                        if detail.books.isEmpty {
                            BookCollectionEmptyBooksRow(isManual: viewModel.isManual)
                                .padding(.horizontal, Spacing.screenEdge)
                                .listRowSeparator(.hidden)
                                .listRowInsets(contentSectionInsets)
                                .listRowBackground(BookCollectionContentRowBackground(position: .middle))
                        } else {
                            ForEach(detail.books) { item in
                                BookCollectionBookCard(
                                    item: item,
                                    canEditStructure: canEditBookStructure,
                                    canEditRelationNote: canEditRelationNote,
                                    canEditMetadata: canEditBookMetadata,
                                    relationNotePresentation: relationNotePresentation,
                                    showsSeparator: item.id != detail.books.last?.id,
                                    onOpen: {
                                        if item.isPlaceholder {
                                            viewModel.restorePlaceholderBook(item)
                                        } else {
                                            onOpenRoute(.detail(bookId: item.book.id))
                                        }
                                    },
                                    onEditBook: {
                                        onOpenRoute(.edit(bookId: item.book.id))
                                    },
                                    onEditMetadata: {
                                        viewModel.presentMetadataEdit(for: item)
                                    },
                                    onRestorePlaceholder: {
                                        viewModel.restorePlaceholderBook(item)
                                    },
                                    onEditRecommend: {
                                        viewModel.presentRecommendEdit(for: item)
                                    },
                                    onRemove: {
                                        viewModel.presentRemoveConfirmation(for: item)
                                    }
                                )
                                .padding(.horizontal, Spacing.screenEdge)
                                .listRowSeparator(.hidden)
                                .listRowInsets(contentSectionInsets)
                                .listRowBackground(BookCollectionContentRowBackground(position: .middle))
                                .accessibilityIdentifier("book.collection.detail.book.\(item.id)")
                            }
                            .onMove { offsets, destination in
                                guard viewModel.isManual else { return }
                                var items = viewModel.detail?.books ?? []
                                items.move(fromOffsets: offsets, toOffset: destination)
                                viewModel.submitBookOrder(items.map(\.id))
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, Spacing.none, for: .scrollContent)
            .contentMargins(.bottom, floatingAddBookContentInset, for: .scrollContent)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .environment(\.defaultMinListRowHeight, 1)
            .environment(\.editMode, $editMode)
            .coordinateSpace(.named(BookCollectionContentTrayCoordinateSpace.name))
            .accessibilityIdentifier("book.collection.detail.list")
        }
        .overlay(alignment: .bottom) {
            floatingAddBookOverlay
        }
        .onPreferenceChange(BookCollectionFloatingAddBookContentInsetPreferenceKey.self) { inset in
            updateFloatingAddBookContentInset(inset)
        }
        .onPreferenceChange(ImmersiveBottomChromeHeightPreferenceKey.self) { height in
            updateFloatingAddBookOrnamentHeight(height)
        }
        .onChange(of: showsFloatingAddBookButton) { _, isVisible in
            guard !isVisible else { return }
            updateFloatingAddBookOrnamentHeight(.zero)
            updateFloatingAddBookContentInset(.zero)
        }
    }

    private func updateContentTrayTop(_ newTop: CGFloat) {
        guard newTop.isFinite else { return }
        if !contentTrayTop.isFinite || abs(contentTrayTop - newTop) > 0.5 {
            contentTrayTop = newTop
        }
    }

    /// 同步底部悬浮添加入口的滚动避让高度，避免长书单最后一项被遮挡。
    private func updateFloatingAddBookContentInset(_ inset: CGFloat) {
        guard inset.isFinite, abs(floatingAddBookContentInset - inset) > 0.5 else { return }
        floatingAddBookContentInset = inset
    }

    /// 同步底部悬浮按钮实测高度，用于下一帧计算沉浸托底尺寸。
    private func updateFloatingAddBookOrnamentHeight(_ height: CGFloat) {
        guard height.isFinite, abs(floatingAddBookOrnamentHeight - height) > 0.5 else { return }
        floatingAddBookOrnamentHeight = height
    }

    @ViewBuilder
    private var floatingAddBookOverlay: some View {
        GeometryReader { proxy in
            let metrics = floatingAddBookMetrics(safeAreaBottomInset: proxy.safeAreaInsets.bottom)
            let ornamentWidth = max(proxy.size.width - Spacing.screenEdge * 2, .zero)

            if showsFloatingAddBookButton {
                ImmersiveBottomChromeOverlay(
                    metrics: metrics,
                    surfaceColor: Color.surfaceCard.opacity(0.78),
                    horizontalPadding: Spacing.screenEdge
                ) {
                    HStack {
                        Spacer(minLength: Spacing.none)

                        BookCollectionFloatingAddBookButton(
                            isEnabled: canUseFloatingAddBookButton,
                            action: presentBookPicker
                        )
                    }
                    .frame(width: ornamentWidth, alignment: .trailing)
                    .background {
                        GeometryReader { ornamentProxy in
                            Color.clear
                                .preference(
                                    key: ImmersiveBottomChromeHeightPreferenceKey.self,
                                    value: ornamentProxy.size.height
                                )
                        }
                    }
                }
                .preference(
                    key: BookCollectionFloatingAddBookContentInsetPreferenceKey.self,
                    value: metrics.readableInset
                )
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else {
                Color.clear
                    .preference(key: BookCollectionFloatingAddBookContentInsetPreferenceKey.self, value: .zero)
            }
        }
        .allowsHitTesting(showsFloatingAddBookButton)
        .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: showsFloatingAddBookButton)
    }

    /// 依据安全区和按钮实测高度计算底部浮层的渐变托底与滚动补偿。
    private func floatingAddBookMetrics(safeAreaBottomInset: CGFloat) -> ImmersiveBottomChromeMetrics {
        ImmersiveBottomChromeMetrics.make(
            measuredOrnamentHeight: floatingAddBookOrnamentHeight,
            safeAreaBottomInset: safeAreaBottomInset,
            ornamentMinimumTouchHeight: ImmersiveBottomChromeStyle.controlHeight,
            ornamentTopPadding: Spacing.tight,
            readableInsetExtra: Spacing.double
        )
    }

    private var showsFloatingAddBookButton: Bool {
        viewModel.isManual && viewModel.detail != nil && !isReordering
    }

    private var canUseFloatingAddBookButton: Bool {
        viewModel.activeAction == nil
    }

    /// 展示现有书籍选择器，保持添加入口和业务流程解耦。
    private func presentBookPicker() {
        guard canUseFloatingAddBookButton else { return }
        showsBookPicker = true
    }

    @ViewBuilder
    private var header: some View {
        if let detail = viewModel.detail {
            BookCollectionDetailHero(
                detail: detail,
                visualStyle: activeHeaderVisualStyle,
                onShowFullSummary: {
                    showsCollectionSummary = true
                }
            )
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.top, Spacing.base)
            .padding(.bottom, Spacing.double)
        }
    }

    @ViewBuilder
    private var moreMenuContent: some View {
        Section {
            // TODO(book-collection-batch-export, review-skip): Android 详情页支持“批量导出书籍”；本次按用户要求暂缓实现，迁移审查请跳过此项。
            Button {
                guard canUseCollectionExportAction else { return }
                viewModel.shareCurrentCollectionImage()
            } label: {
                Label("分享书单", systemImage: "photo.on.rectangle")
            }
            .disabled(!canUseCollectionExportAction)
        }

        #if DEBUG
        Section("Header 方案") {
            ForEach(BookCollectionHeaderVisualStyle.allCases) { style in
                Button {
                    selectHeaderVisualStyle(style)
                } label: {
                    Label(
                        style.menuTitle,
                        systemImage: isSelectedHeaderVisualStyle(style) ? "checkmark" : "circle"
                    )
                }
            }
        }
        #endif

        Section {
            if viewModel.isManual {
                Button {
                    viewModel.presentEditForm()
                } label: {
                    Label("编辑书单信息", systemImage: "pencil")
                }
                .disabled(viewModel.activeAction != nil)

                if canReorderCurrentDetail {
                    Button {
                        toggleReordering()
                    } label: {
                        Label(isReordering ? "完成排序" : "调整排序", systemImage: isReordering ? "checkmark" : "arrow.up.arrow.down")
                    }
                    .disabled(viewModel.activeAction != nil)
                }

                Button(role: .destructive) {
                    viewModel.presentDeleteConfirmation()
                } label: {
                    Label("删除书单", systemImage: "trash")
                }
                .disabled(viewModel.activeAction != nil)
            } else {
                Button {
                    viewModel.presentAnnualDescriptionEdit()
                } label: {
                    Label("编辑年度说明", systemImage: "text.badge.star")
                }
                .disabled(viewModel.activeAction != nil)
            }
        }
    }

    private var contentSectionInsets: EdgeInsets {
        EdgeInsets()
    }

    private var detailTitle: String {
        guard let detail = viewModel.detail else { return "书单" }
        let trimmedTitle = detail.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.kind == .annual, let year = detail.year, trimmedTitle.isEmpty {
            return "\(year) 年阅读"
        }
        return trimmedTitle.isEmpty ? "未命名书单" : trimmedTitle
    }

    private func contentHeaderTitle(for detail: BookCollectionDetail) -> String {
        if detail.kind == .annual {
            return "年度书籍"
        }
        return "书单书籍"
    }

    private func contentHeaderStatus(for detail: BookCollectionDetail) -> BookCollectionContentHeader.Status? {
        detail.kind == .annual ? .autoSynced : nil
    }

    private var relationNotePresentation: BookCollectionRelationNotePresentation {
        BookCollectionRelationNotePresentation.make(kind: viewModel.detail?.kind ?? .manual)
    }

    private var canEditRelationNote: Bool {
        viewModel.detail != nil && viewModel.activeAction == nil && !isReordering
    }

    private var canEditBookStructure: Bool {
        viewModel.isManual && viewModel.activeAction == nil && !isReordering
    }

    private var canEditBookMetadata: Bool {
        viewModel.detail != nil && viewModel.activeAction == nil && !isReordering
    }

    private var activeHeaderVisualStyle: BookCollectionHeaderVisualStyle {
        #if DEBUG
        headerVisualStyle
        #else
        .editorialDesk
        #endif
    }

    private var shouldShowMoreMenu: Bool {
        #if DEBUG
        true
        #else
        viewModel.detail != nil
        #endif
    }

    private var canUseCollectionExportAction: Bool {
        viewModel.detail != nil && viewModel.activeAction == nil && !isReordering
    }

    private func isSelectedHeaderVisualStyle(_ style: BookCollectionHeaderVisualStyle) -> Bool {
        activeHeaderVisualStyle == style
    }

    private func selectHeaderVisualStyle(_ style: BookCollectionHeaderVisualStyle) {
        #if DEBUG
        guard style != headerVisualStyle else { return }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) {
            headerVisualStyle = style
        }
        #endif
    }

    private var canReorderCurrentDetail: Bool {
        guard let detail = viewModel.detail else { return false }
        return detail.kind == .manual && (detail.books.count >= 2 || isReordering)
    }

    private var reorderStatusRow: some View {
        HStack(spacing: Spacing.cozy) {
            Image(systemName: "arrow.up.arrow.down")
                .font(AppTypography.caption)
                .foregroundStyle(Color.textHint)

            Text("拖动右侧把手调整顺序。")
                .font(AppTypography.caption)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: Spacing.compact)
        }
        .padding(.horizontal, Spacing.tight)
        .padding(.vertical, Spacing.cozy)
        .background(Color.surfaceNested, in: RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous))
    }

    private var loadPhase: LoadPhase {
        switch viewModel.contentState {
        case .loading:
            return loadingGate.isVisible ? .loading : .placeholder
        case .content:
            return .content
        case .empty:
            return viewModel.detail == nil ? .empty(message: "书单里还没有书") : .content
        case .error(let message):
            return .error(message: message)
        }
    }

    private var pickerConfiguration: BookPickerConfiguration {
        let preselected = (viewModel.detail?.books ?? []).map { item in
            BookPickerBook(
                id: item.book.id,
                title: item.book.title,
                author: item.book.author,
                coverURL: item.book.cover
            )
        }
        return BookPickerConfiguration(
            title: "添加书籍",
            scope: .both,
            selectionMode: .multiple,
            allowsCreationFlow: true,
            creationAction: .inlineManualEditor,
            onlineSelectionPolicy: .returnRemoteSelection,
            multipleConfirmationPolicy: .requiresSelection,
            multipleConfirmationTitle: "加入书单",
            preselectedBooks: preselected,
            onlineSources: BookSearchSource.productionCases,
            preferredOnlineSource: .wenqu
        )
    }

    private func syncLoadingGate() {
        if case .loading = viewModel.contentState {
            loadingGate.update(intent: .read)
        } else {
            loadingGate.update(intent: .none)
        }
    }

    private func toggleReordering() {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.18)) {
            editMode = isReordering ? .inactive : .active
        }
    }

    private func removeDescriptor(for confirmation: BookCollectionBookRemoveConfirmation) -> XMSystemAlertDescriptor {
        XMSystemAlertDescriptor(
            title: "移出“\(confirmation.item.book.title)”？",
            message: "这本书会从当前书单中移出，书籍本身不会被删除。",
            actions: [
                XMSystemAlertAction(title: "取消", role: .cancel) {},
                XMSystemAlertAction(title: "移出", role: .destructive) {
                    viewModel.confirmRemove(confirmation)
                }
            ]
        )
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

private enum BookCollectionContentTrayCoordinateSpace {
    static let name = "book.collection.detail.contentTray"
}

/// 书单详情底部悬浮添加入口的可读底距偏好，驱动 `List` 底部内容避让。
private struct BookCollectionFloatingAddBookContentInsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = .zero

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private enum BookCollectionContentRowPosition {
    case top
    case middle
}

private struct BookCollectionContentRowBackground: View {
    let position: BookCollectionContentRowPosition

    var body: some View {
        BookCollectionContentRowShape(position: position)
            .fill(Color.surfaceCard)
    }
}

private struct BookCollectionContentRowShape: Shape {
    let position: BookCollectionContentRowPosition

    func path(in rect: CGRect) -> Path {
        let topRadius: CGFloat = switch position {
        case .top:
            CornerRadius.containerMedium
        case .middle:
            0
        }
        if topRadius == 0 {
            return Path(rect)
        }

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + topRadius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - topRadius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + topRadius),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topRadius, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

private struct BookCollectionFullHeightTrayBackground: View {
    let topOffset: CGFloat

    var body: some View {
        GeometryReader { proxy in
            if topOffset.isFinite {
                let trayTop = max(topOffset, 0)
                let trayWidth = proxy.size.width
                let trayHeight = max(proxy.size.height - trayTop + CornerRadius.containerMedium, 0)
                let topRadius = topOffset > 0 ? CornerRadius.containerMedium : 0

                BookCollectionFullHeightTrayShape(topRadius: topRadius)
                    .fill(Color.surfaceCard)
                    .frame(width: trayWidth, height: trayHeight)
                    .offset(y: trayTop)
                    .ignoresSafeArea(.container, edges: .bottom)
                    .accessibilityHidden(true)
            }
        }
    }
}

private struct BookCollectionFullHeightTrayShape: Shape {
    let topRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = min(max(topRadius, 0), min(rect.width, rect.height) / 2)
        if radius == 0 {
            return Path(rect)
        }

        var path = Path()

        path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + radius),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + radius, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}
