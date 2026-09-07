/**
 * [INPUT]: 依赖 RepositoryContainer 注入 BookRepositoryProtocol，依赖 BookContributorManagementViewModel、XMSystemAlert 与原生 Toolbar/安全区操作栏提供单项和批量管理交互
 * [OUTPUT]: 对外提供 BookContributorManagementView，承接作者/出版社资料编辑、删除及书籍字段批量修改入口，品牌操作前景随外观配对
 * [POS]: Book 模块作者/出版社管理页面壳层，被个人页路由与书籍 Tab 导航消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 作者/出版社管理页面，按 Android 聚合项菜单提供编辑与删除能力。
struct BookContributorManagementView: View {
    @Environment(RepositoryContainer.self) private var repositories
    @State private var viewModel: BookContributorManagementViewModel?
    @State private var loadingGate = LoadingGate()

    let kind: BookContributorKind

    var body: some View {
        ZStack {
            Color.surfacePage.ignoresSafeArea()
            if let viewModel {
                BookContributorManagementContentView(viewModel: viewModel)
            } else if loadingGate.isVisible {
                LoadingStateView("正在加载\(kind.title)…", style: .inline)
            }
        }
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard viewModel == nil else { return }
            loadingGate.update(intent: .read)
            viewModel = BookContributorManagementViewModel(
                kind: kind,
                repository: repositories.bookRepository
            )
            loadingGate.update(intent: .none)
        }
        .onDisappear {
            loadingGate.hideImmediately()
        }
    }
}

/// 作者/出版社管理内容区，负责绑定弹窗状态与渲染列表。
private struct BookContributorManagementContentView: View {
    @Bindable var viewModel: BookContributorManagementViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var readLoadingGate = LoadingGate()

    var body: some View {
        ZStack(alignment: .top) {
            content
            if let message = viewModel.writeError {
                notice(message, tone: .error)
            } else if let message = viewModel.observationErrorMessage {
                XMInlineStatusBanner(
                    message,
                    tone: .error,
                    action: XMStateAction("重试", perform: viewModel.retryObservation)
                )
                .padding(.horizontal, Spacing.screenEdge)
                .padding(.top, Spacing.tight)
            } else if let message = viewModel.actionNotice {
                notice(message, tone: .neutral)
            }
        }
        .xmSystemAlert(item: $viewModel.activeNameEdit) { nameEdit in
            nameEditDescriptor(for: nameEdit)
        }
        .xmSystemAlert(item: $viewModel.activeDeleteConfirmation) { confirmation in
            deleteDescriptor(for: confirmation)
        }
        .xmSystemAlert(item: $viewModel.activeBatchNameEdit) { edit in
            batchNameEditDescriptor(for: edit)
        }
        .xmSystemAlert(item: $viewModel.activeBatchConfirmation) { confirmation in
            batchConfirmationDescriptor(for: confirmation)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(viewModel.isSelectionMode ? "取消" : "选择") {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) {
                        if viewModel.isSelectionMode {
                            viewModel.cancelSelectionMode()
                        } else {
                            viewModel.enterSelectionMode()
                        }
                    }
                }
                .disabled(viewModel.activeWriteAction != nil || viewModel.groups.isEmpty)
                .accessibilityLabel(viewModel.isSelectionMode ? "退出选择" : "选择多个\(viewModel.kind.itemTitle)")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if viewModel.isSelectionMode {
                selectionBar
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onAppear {
            syncLoadingGate()
        }
        .onChange(of: viewModel.contentState) { _, _ in
            syncLoadingGate()
        }
        .onDisappear {
            readLoadingGate.hideImmediately()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.contentState {
        case .loading:
            if readLoadingGate.isVisible {
                LoadingStateView("正在加载\(viewModel.kind.title)…", style: .inline)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
            }
        case .empty:
            XMContentStateView(
                role: .empty,
                title: "暂无\(viewModel.kind.itemTitle)"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .error:
            XMContentStateView(
                role: .failure,
                title: "暂时无法加载\(viewModel.kind.title)",
                action: XMStateAction("重试", perform: viewModel.retryObservation)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .content:
            ScrollView {
                LazyVStack(spacing: Spacing.cozy) {
                    ForEach(viewModel.groups) { group in
                        BookContributorManagementRow(
                            kind: viewModel.kind,
                            group: group,
                            isSelectionMode: viewModel.isSelectionMode,
                            isSelected: viewModel.selectedNames.contains(group.title),
                            isDisabled: viewModel.activeWriteAction != nil,
                            onToggleSelection: { viewModel.toggleSelection(for: group) },
                            onEdit: { viewModel.presentNameEdit(for: group) },
                            onDelete: { viewModel.presentDeleteConfirmation(for: group) }
                        )
                    }
                }
                .padding(.horizontal, Spacing.screenEdge)
                .padding(.top, Spacing.base)
                .padding(.bottom, Spacing.screenEdge)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func syncLoadingGate() {
        readLoadingGate.update(intent: viewModel.contentState == .loading ? .read : .none)
    }

    private func notice(_ message: String, tone: XMInlineStatusBanner.Tone) -> some View {
        XMInlineStatusBanner(message, tone: tone)
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.top, Spacing.tight)
            .transition(.opacity)
            .zIndex(2)
    }

    private var selectionBar: some View {
        HStack(spacing: Spacing.base) {
            Text("已选 \(viewModel.selectionCount) 项 · \(viewModel.selectedBookCount) 本书")
                .font(AppTypography.caption)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)

            Spacer(minLength: Spacing.cozy)

            Button(viewModel.batchActionTitle, systemImage: "pencil") {
                viewModel.presentBatchNameEdit()
            }
            .font(AppTypography.callout)
            .foregroundStyle(Color.primaryActionForeground)
            .buttonStyle(.borderedProminent)
            .tint(Color.primaryActionFill)
            .disabled(viewModel.selectedNames.isEmpty || viewModel.activeWriteAction != nil)
            .accessibilityValue("已选择 \(viewModel.selectionCount) 个\(viewModel.kind.itemTitle)，共 \(viewModel.selectedBookCount) 本书")
        }
        .padding(.horizontal, Spacing.screenEdge)
        .frame(minHeight: 56)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider().overlay(Color.surfaceBorderSubtle)
        }
    }

    private func nameEditDescriptor(for nameEdit: BookContributorNameEdit) -> XMSystemAlertDescriptor {
        XMSystemAlertDescriptor(
            title: "编辑\(nameEdit.kind.itemTitle)",
            message: "将同步更新 \(nameEdit.bookCount) 本书的\(nameEdit.kind.itemTitle)名称。",
            actions: [
                XMSystemAlertAction(title: "取消", role: .cancel) { },
                XMSystemAlertAction(title: "完成") {
                    viewModel.submitNameEdit()
                }
            ],
            textFields: [
                XMSystemAlertTextField(
                    text: Binding(
                        get: { viewModel.nameEditText },
                        set: { viewModel.nameEditText = $0 }
                    ),
                    placeholder: nameEdit.currentName,
                    autocorrectionDisabled: true
                )
            ]
        )
    }

    private func deleteDescriptor(for confirmation: BookContributorDeleteConfirmation) -> XMSystemAlertDescriptor {
        XMSystemAlertDescriptor(
            title: "删除\(confirmation.kind.itemTitle)",
            message: "将删除“\(confirmation.name)”下的 \(confirmation.bookCount) 本书，并移除对应\(confirmation.kind.itemTitle)资料。此操作不可撤销。",
            actions: [
                XMSystemAlertAction(title: "取消", role: .cancel) { },
                XMSystemAlertAction(title: "删除", role: .destructive) {
                    viewModel.submitDelete()
                }
            ],
            preferredActionID: nil
        )
    }

    private func batchNameEditDescriptor(for edit: BookContributorBatchNameEdit) -> XMSystemAlertDescriptor {
        XMSystemAlertDescriptor(
            title: viewModel.batchActionTitle,
            message: "将修改所选 \(edit.sourceNames.count) 个\(edit.kind.itemTitle)维度下的 \(edit.bookCount) 本有效书籍，资料记录不会改变。",
            actions: [
                XMSystemAlertAction(title: "取消", role: .cancel) { },
                XMSystemAlertAction(title: "下一步") {
                    viewModel.confirmBatchNameInput()
                }
            ],
            textFields: [
                XMSystemAlertTextField(
                    text: Binding(
                        get: { viewModel.batchNameText },
                        set: { viewModel.batchNameText = $0 }
                    ),
                    placeholder: "新的\(edit.kind.itemTitle)名称",
                    autocorrectionDisabled: true
                )
            ]
        )
    }

    private func batchConfirmationDescriptor(
        for confirmation: BookContributorBatchConfirmation
    ) -> XMSystemAlertDescriptor {
        XMSystemAlertDescriptor(
            title: "确认修改书籍\(confirmation.kind.itemTitle)",
            message: "将把 \(confirmation.bookCount) 本有效书籍的\(confirmation.kind.itemTitle)改为“\(confirmation.targetName)”。作者或出版社资料记录不会合并，此操作确认后立即生效。",
            actions: [
                XMSystemAlertAction(title: "取消", role: .cancel) { },
                XMSystemAlertAction(title: "确认修改") {
                    viewModel.submitBatchModification()
                }
            ]
        )
    }
}

/// 作者/出版社管理行，提供与 Android 聚合卡一致的编辑、删除菜单。
private struct BookContributorManagementRow: View {
    let kind: BookContributorKind
    let group: BookshelfAggregateGroup
    let isSelectionMode: Bool
    let isSelected: Bool
    let isDisabled: Bool
    let onToggleSelection: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @ViewBuilder
    var body: some View {
        if isSelectionMode {
            Button(action: onToggleSelection) {
                rowContent
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .accessibilityLabel("\(group.title)，\(group.subtitle)")
            .accessibilityValue(isSelected ? "已选择" : "未选择")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            rowContent
                .contextMenu {
                    Button(action: onEdit) {
                        XMMenuLabel("编辑", systemImage: "pencil")
                    }
                    Button(role: .destructive, action: onDelete) {
                        Label("删除", systemImage: "trash")
                    }
                }
                .xmMenuNeutralTint()
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(group.title)，\(group.subtitle)")
        }
    }

    private var rowContent: some View {
        HStack(spacing: Spacing.base) {
            BookshelfGridGroupCoverView(
                covers: group.representativeCovers,
                count: group.count
            )
            .frame(width: 58)

            VStack(alignment: .leading, spacing: Spacing.tiny) {
                Text(group.title)
                    .font(AppTypography.bodyMedium)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)
                Text(group.subtitle)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Spacing.compact)

            if isSelectionMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.primaryActionFill : Color.textHint)
                    .frame(
                        width: InteractionMetrics.minimumTouchTarget,
                        height: InteractionMetrics.minimumTouchTarget
                    )
                    .accessibilityHidden(true)
            } else {
                Menu {
                    Button(action: onEdit) {
                        XMMenuLabel("编辑", systemImage: "pencil")
                    }
                    Button(role: .destructive, action: onDelete) {
                        Label("删除", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(AppTypography.bodyMedium)
                        .foregroundStyle(Color.textSecondary)
                        .frame(width: 36, height: 36)
                        .xmMinimumHitTarget()
                }
                .disabled(isDisabled)
                .xmMenuNeutralTint()
                .accessibilityLabel("\(kind.itemTitle)操作")
            }
        }
        .padding(Spacing.base)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                .stroke(Color.surfaceBorderSubtle, lineWidth: StrokeWidth.hairline)
        }
    }
}

#Preview {
    NavigationStack {
        BookContributorManagementView(kind: .author)
            .environment(RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty())))
    }
}
