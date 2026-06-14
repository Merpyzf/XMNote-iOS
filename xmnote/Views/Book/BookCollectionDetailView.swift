/**
 * [INPUT]: 依赖 RepositoryContainer 注入书架仓储，依赖 BookCollectionDetailViewModel 驱动书单详情、加入书籍、移除、排序、推荐语编辑与删除确认
 * [OUTPUT]: 对外提供 BookCollectionDetailView，承载手动书单与年度书单详情、只读边界、书籍行操作和系统弹窗
 * [POS]: Views/Book 的书单详情页面壳层，被 BookRoute.collectionDetail 导航目标消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书单详情页，手动书单提供整理能力，年度书单保持系统同步只读展示。
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
                repository: repositories.bookRepository
            )
        }
    }
}

/// 书单详情启动占位，确保导航转场期间已有顶部返回与内容骨架。
private struct BookCollectionDetailLoadingScaffold: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: Spacing.none) {
            HStack(spacing: Spacing.tight) {
                TopBarBackButton {
                    dismiss()
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("书单")
                        .font(AppTypography.headlineSemibold)
                        .foregroundStyle(Color.textPrimary)

                    Text("正在整理内容")
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                }

                Spacer(minLength: Spacing.tight)
            }
            .padding(.horizontal, Spacing.screenEdge)
            .frame(height: 56)
            .background(Color.surfacePage)

            BookCollectionDetailSkeletonContent()
        }
        .background(Color.surfacePage.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// 书单详情内容视图，集中承载本地顶部栏、详情头、书籍列表和业务弹窗。
private struct BookCollectionDetailContentView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var viewModel: BookCollectionDetailViewModel
    let onOpenRoute: (BookRoute) -> Void
    @State private var editMode: EditMode = .inactive
    @State private var loadingGate = LoadingGate()
    @State private var showsBookPicker = false

    private var isReordering: Bool {
        editMode.isEditing
    }

    var body: some View {
        VStack(spacing: Spacing.none) {
            topChrome
            content
        }
        .background(Color.surfacePage.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
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
        .sheet(item: $viewModel.activeForm) { presentation in
            BookCollectionFormSheet(
                presentation: presentation,
                isSaving: viewModel.activeAction != nil
            ) { title, description in
                viewModel.submitForm(presentation, title: title, description: description)
            }
        }
        .sheet(item: $viewModel.recommendEdit) { edit in
            BookCollectionRecommendSheet(
                edit: edit,
                isSaving: viewModel.activeAction != nil
            ) { recommend in
                viewModel.submitRecommend(edit, recommend: recommend)
            }
        }
        .xmSystemAlert(item: $viewModel.removeConfirmation) { confirmation in
            removeDescriptor(for: confirmation)
        }
        .xmSystemAlert(item: $viewModel.deleteConfirmation) { confirmation in
            deleteDescriptor(for: confirmation)
        }
        .accessibilityIdentifier("book.collection.detail")
    }

    private var topChrome: some View {
        HStack(spacing: Spacing.tight) {
            TopBarBackButton {
                dismiss()
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.detail?.title ?? "书单")
                    .font(AppTypography.headlineSemibold)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)

                if let detail = viewModel.detail {
                    Text(detail.kind == .annual ? "年度书单 · 系统同步" : "我的书单")
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                }
            }

            Spacer(minLength: Spacing.tight)

            if viewModel.isManual {
                Menu {
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
                } label: {
                    TopBarActionIcon(systemName: "ellipsis.circle", foregroundColor: Color.textPrimary)
                }
                .disabled(viewModel.activeAction != nil)
                .accessibilityLabel("书单更多操作")
                .accessibilityIdentifier("book.collection.detail.more")
            }
        }
        .padding(.horizontal, Spacing.screenEdge)
        .frame(height: 56)
        .background(Color.surfacePage)
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
                VStack(spacing: Spacing.base) {
                    header
                    BookshelfContextualEmptyStateView(
                        icon: viewModel.isManual ? "book.badge.plus" : "calendar",
                        title: message,
                        message: viewModel.isManual ? "加入书籍后会显示在这里。" : "读完记录会显示在这里。"
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
        List {
            Section {
                header
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)

                if isReordering {
                    reorderStatusRow
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(
                            top: Spacing.half,
                            leading: Spacing.screenEdge,
                            bottom: Spacing.base,
                            trailing: Spacing.screenEdge
                        ))
                        .listRowBackground(Color.clear)
                }
            }

            ForEach(viewModel.detail?.books ?? []) { item in
                BookCollectionBookCard(
                    item: item,
                    isEditable: viewModel.isManual,
                    onOpen: {
                        onOpenRoute(.detail(bookId: item.book.id))
                    },
                    onEditBook: {
                        onOpenRoute(.edit(bookId: item.book.id))
                    },
                    onEditRecommend: {
                        viewModel.presentRecommendEdit(for: item)
                    },
                    onRemove: {
                        viewModel.presentRemoveConfirmation(for: item)
                    }
                )
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(
                    top: Spacing.half,
                    leading: Spacing.screenEdge,
                    bottom: Spacing.half,
                    trailing: Spacing.screenEdge
                ))
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("book.collection.detail.book.\(item.id)")
            }
            .onMove { offsets, destination in
                guard viewModel.isManual else { return }
                var items = viewModel.detail?.books ?? []
                items.move(fromOffsets: offsets, toOffset: destination)
                viewModel.submitBookOrder(items.map(\.id))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, $editMode)
        .accessibilityIdentifier("book.collection.detail.list")
    }

    @ViewBuilder
    private var header: some View {
        if let detail = viewModel.detail {
            BookCollectionDetailHero(
                detail: detail,
                canPerformAction: viewModel.activeAction == nil,
                onAddBook: {
                    showsBookPicker = true
                }
            )
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
        }
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
            return .empty(message: "书单里还没有书")
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
            title: "加入书单",
            scope: .local,
            selectionMode: .multiple,
            allowsCreationFlow: false,
            multipleConfirmationPolicy: .requiresSelection,
            multipleConfirmationTitle: "加入书单",
            preselectedBooks: preselected
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
