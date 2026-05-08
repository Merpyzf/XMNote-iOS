/**
 * [INPUT]: 依赖 RepositoryContainer 注入 BookRepositoryProtocol，依赖 BookContributorManagementViewModel 提供作者/出版社聚合列表与编辑删除状态
 * [OUTPUT]: 对外提供 BookContributorManagementView，承接“作者管理/出版社管理”入口的真实管理页
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
    @State private var readLoadingGate = LoadingGate()

    var body: some View {
        ZStack(alignment: .top) {
            content
            if let message = viewModel.writeError ?? viewModel.actionNotice {
                notice(message)
            }
        }
        .xmSystemAlert(item: $viewModel.activeNameEdit) { nameEdit in
            nameEditDescriptor(for: nameEdit)
        }
        .xmSystemAlert(item: $viewModel.activeDeleteConfirmation) { confirmation in
            deleteDescriptor(for: confirmation)
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
            ContentUnavailableView(
                "暂无\(viewModel.kind.itemTitle)",
                systemImage: viewModel.kind == .author ? "person.text.rectangle" : "building.2"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .error(let message):
            ContentUnavailableView(
                "\(viewModel.kind.title)加载失败",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .content:
            ScrollView {
                LazyVStack(spacing: Spacing.cozy) {
                    ForEach(viewModel.groups) { group in
                        BookContributorManagementRow(
                            kind: viewModel.kind,
                            group: group,
                            isDisabled: viewModel.activeWriteAction != nil,
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

    private func notice(_ message: String) -> some View {
        Text(message)
            .font(AppTypography.caption)
            .foregroundStyle(Color.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.tight)
            .background(Color.surfaceCard)
            .overlay(alignment: .bottom) {
                Divider()
                    .overlay(Color.surfaceBorderSubtle)
            }
            .transition(.opacity)
            .zIndex(2)
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
}

/// 作者/出版社管理行，提供与 Android 聚合卡一致的编辑、删除菜单。
private struct BookContributorManagementRow: View {
    let kind: BookContributorKind
    let group: BookshelfAggregateGroup
    let isDisabled: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
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

            Menu {
                Button(action: onEdit) {
                    Label("编辑", systemImage: "pencil")
                }
                Button(role: .destructive, action: onDelete) {
                    Label("删除", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(AppTypography.bodyMedium)
                    .foregroundStyle(Color.textSecondary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .disabled(isDisabled)
            .accessibilityLabel("\(kind.itemTitle)操作")
        }
        .padding(Spacing.base)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
        }
        .contextMenu {
            Button(action: onEdit) {
                Label("编辑", systemImage: "pencil")
            }
            Button(role: .destructive, action: onDelete) {
                Label("删除", systemImage: "trash")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.title)，\(group.subtitle)")
    }
}

#Preview {
    NavigationStack {
        BookContributorManagementView(kind: .author)
            .environment(RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty())))
    }
}
