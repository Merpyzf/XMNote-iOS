/**
 * [INPUT]: 依赖 RepositoryContainer 注入书架仓储，依赖 BookCollectionListViewModel、LoadingGate 与 XMScopeSelector 驱动手动书单、年度书单、创建、删除、排序和稳定 List 视口加载占位
 * [OUTPUT]: 对外提供 BookCollectionListView，承载首页书单 Tab 的范围切换、集合卡片、空态、错误态、写操作反馈与书单详情入口
 * [POS]: Views/Book 的书单首页页面壳层，被 BookContainerView 的书单二级页消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 首页书单列表页，按 iOS 分段结构表达 Android “我的书单 / 年度书单”业务分组。
struct BookCollectionListView: View {
    @Environment(RepositoryContainer.self) private var repositories
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onOpenCollection: (Int64) -> Void
    @State private var viewModel: BookCollectionListViewModel?
    @State private var editMode: EditMode = .inactive
    @State private var loadingGate = LoadingGate()

    private var isReordering: Bool {
        editMode.isEditing
    }

    /// 注入书单打开回调，保持列表页只负责发出导航意图。
    init(onOpenCollection: @escaping (Int64) -> Void = { _ in }) {
        self.onOpenCollection = onOpenCollection
    }

    var body: some View {
        VStack(spacing: Spacing.none) {
            controls
            content
        }
        .background(Color.surfacePage.ignoresSafeArea())
        .transaction(value: viewModel == nil) { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
        .onAppear {
            syncLoadingGate()
        }
        .onDisappear {
            loadingGate.hideImmediately()
        }
        .onChange(of: viewModel?.contentState) { _, _ in
            syncLoadingGate()
        }
        .onChange(of: viewModel?.selectedKind) { _, _ in
            guard editMode.isEditing else { return }
            editMode = .inactive
        }
        .sheet(item: activeFormBinding) { presentation in
            BookCollectionFormSheet(
                presentation: presentation,
                isSaving: viewModel?.activeAction != nil
            ) { title, description in
                viewModel?.submitForm(presentation, title: title, description: description)
            }
        }
        .xmSystemAlert(item: deleteConfirmationBinding) { confirmation in
            deleteDescriptor(for: confirmation)
        }
        .task {
            guard viewModel == nil else { return }
            let nextViewModel = BookCollectionListViewModel(repository: repositories.bookRepository)
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                viewModel = nextViewModel
            }
            syncLoadingGate()
        }
    }

    private var activeFormBinding: Binding<BookCollectionFormPresentation?> {
        Binding(
            get: { viewModel?.activeForm },
            set: { viewModel?.activeForm = $0 }
        )
    }

    private var deleteConfirmationBinding: Binding<BookCollectionDeleteConfirmation?> {
        Binding(
            get: { viewModel?.deleteConfirmation },
            set: { viewModel?.deleteConfirmation = $0 }
        )
    }

    @ViewBuilder
    private var controls: some View {
        if let viewModel {
            BookCollectionScopeHeader(
                selectedKind: Binding(
                    get: { viewModel.selectedKind },
                    set: { viewModel.selectedKind = $0 }
                ),
                manualCount: viewModel.snapshot.manualCollections.count,
                annualCount: viewModel.snapshot.annualCollections.count,
                visibleCount: viewModel.visibleCollections.count,
                isReordering: isReordering,
                canCreate: viewModel.canCreateManualCollection,
                canReorder: viewModel.selectedKind == .manual
                    && viewModel.visibleCollections.count >= 2
                    && viewModel.activeAction == nil,
                onCreate: viewModel.presentCreateForm,
                onToggleReorder: toggleReordering
            )
        } else {
            BookCollectionScopeHeader(
                selectedKind: .constant(.manual),
                manualCount: 0,
                annualCount: 0,
                visibleCount: 0,
                isReordering: false,
                canCreate: false,
                canReorder: false,
                isPlaceholder: true,
                reservesReorderAction: true,
                onCreate: {},
                onToggleReorder: {}
            )
        }
    }

    private var content: some View {
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
            if let feedback = viewModel?.actionFeedback {
                BookCollectionFeedbackBanner(feedback: feedback)
                    .padding(.horizontal, Spacing.screenEdge)
                    .padding(.top, Spacing.tight)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
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
        if let viewModel {
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
    }

    private func collectionRow(
        for item: BookCollectionListItem,
        viewModel: BookCollectionListViewModel
    ) -> some View {
        Button {
            onOpenCollection(item.id)
        } label: {
            BookCollectionListCard(item: item)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("book.collection.row.\(item.id)")
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if item.kind == .manual {
                Button {
                    viewModel.presentEditForm(for: item)
                } label: {
                    Label("编辑", systemImage: "pencil")
                }
                .tint(.blue)

                Button(role: .destructive) {
                    viewModel.presentDeleteConfirmation(for: item)
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
        }
        .contextMenu {
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
        .modifier(BookCollectionListRowChrome())
    }

    private var loadPhase: LoadPhase {
        guard let viewModel else {
            return .placeholder
        }
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
        selectedKind == .manual ? "还没有手动书单" : "暂无年度书单"
    }

    private var emptyMessage: String {
        switch selectedKind {
        case .manual:
            return "新建后可从书架加入书籍。"
        case .annual:
            return "读完记录会生成年度书单。"
        }
    }

    private var selectedKind: BookCollectionKind {
        viewModel?.selectedKind ?? .manual
    }

    private func syncLoadingGate() {
        if case .loading = viewModel?.contentState {
            loadingGate.update(intent: .read)
        } else {
            loadingGate.update(intent: .none)
        }
    }

    private func toggleReordering() {
        guard viewModel != nil else { return }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.18)) {
            editMode = isReordering ? .inactive : .active
        }
    }

    private func emptyState(title: String) -> some View {
        VStack(spacing: Spacing.section) {
            BookshelfContextualEmptyStateView(
                icon: selectedKind == .manual ? "rectangle.stack.badge.plus" : "calendar",
                title: title,
                message: emptyMessage
            )
            .frame(maxHeight: 260)

            if selectedKind == .manual {
                Button {
                    viewModel?.presentCreateForm()
                } label: {
                    Label("新建第一份书单", systemImage: "plus")
                        .font(AppTypography.subheadlineMedium)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel?.canCreateManualCollection != true)
                .accessibilityIdentifier("book.collection.empty.create")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Spacing.screenEdge)
    }

    private func failureState(message: String) -> some View {
        BookshelfContextualEmptyStateView(
            icon: "exclamationmark.triangle",
            title: "书单加载失败",
            message: message.isEmpty ? "请稍后重试" : message,
            iconColor: Color.feedbackWarning.opacity(0.42)
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
                    viewModel?.confirmDelete(confirmation)
                }
            ]
        )
    }
}

/// 书单列表顶部范围说明，负责把类型切换、数量和当前可用动作组织在同一区域。
private struct BookCollectionScopeHeader: View {
    @Binding var selectedKind: BookCollectionKind
    let manualCount: Int
    let annualCount: Int
    let visibleCount: Int
    let isReordering: Bool
    let canCreate: Bool
    let canReorder: Bool
    var isPlaceholder: Bool = false
    var reservesReorderAction: Bool = false
    let onCreate: () -> Void
    let onToggleReorder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            XMScopeSelector(
                items: scopeItems,
                selection: $selectedKind,
                style: .content,
                countFormat: .plain,
                accessibilityLabel: "书单范围"
            )
            .accessibilityIdentifier("book.collection.kind.picker")

            HStack(alignment: .center, spacing: Spacing.base) {
                VStack(alignment: .leading, spacing: Spacing.compact) {
                    Text(selectedKind.title)
                        .font(AppTypography.headlineSemibold)
                        .foregroundStyle(Color.textPrimary)

                    Text(subtitle)
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                manualActions
            }

            if isReordering {
                Label("拖动右侧把手调整顺序。", systemImage: "arrow.up.arrow.down")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .padding(.horizontal, Spacing.tight)
                    .padding(.vertical, Spacing.cozy)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.surfaceNested, in: RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
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

    private var manualActions: some View {
        HStack(spacing: Spacing.cozy) {
            Button(action: onCreate) {
                Label("新建", systemImage: "plus")
                    .font(AppTypography.subheadlineMedium)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canCreate)
            .accessibilityIdentifier("book.collection.create")

            Button(action: onToggleReorder) {
                Label(isReordering ? "完成" : "排序", systemImage: isReordering ? "checkmark" : "arrow.up.arrow.down")
                    .font(AppTypography.subheadlineMedium)
            }
            .buttonStyle(.bordered)
            .opacity(shouldShowReorderAction ? 1 : 0)
            .disabled(!canUseReorderAction)
            .accessibilityLabel(isReordering ? "完成排序" : "调整排序")
            .accessibilityHidden(!canUseReorderAction)
            .accessibilityIdentifier("book.collection.reorder")
        }
        .opacity(selectedKind == .manual ? 1 : 0)
        .allowsHitTesting(selectedKind == .manual && !isPlaceholder)
        .accessibilityHidden(selectedKind != .manual || isPlaceholder)
    }

    private var canUseReorderAction: Bool {
        canReorder || isReordering
    }

    private var shouldShowReorderAction: Bool {
        canUseReorderAction || isPlaceholder || reservesReorderAction
    }

    private var subtitle: String {
        switch selectedKind {
        case .manual:
            if visibleCount == 0 {
                return "按主题整理你的书架。"
            }
            return "\(visibleCount) 份书单"
        case .annual:
            if visibleCount == 0 {
                return "读完记录会自动沉淀为年份书单。"
            }
            return "\(visibleCount) 个年份"
        }
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
            return Color.brand
        case .success:
            return Color.feedbackSuccess
        case .warning:
            return Color.feedbackWarning
        case .error:
            return Color.feedbackError
        }
    }
}
