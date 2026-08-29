/**
 * [INPUT]: 依赖 RepositoryContainer 注入仓储，依赖 WebDAVServerViewModel 驱动状态
 * [OUTPUT]: 对外提供 WebDAVServerListView，备份服务器列表管理
 * [POS]: Backup 模块服务器列表页，通过导航从 DataBackupView 进入
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 备份服务器管理列表页，支持新增、编辑、删除与切换当前服务器。
struct WebDAVServerListView: View {
    @Environment(RepositoryContainer.self) private var repositories
    @State private var viewModel: WebDAVServerViewModel?
    @State private var bootstrapLoadingGate = LoadingGate()

    var body: some View {
        ZStack {
            if let viewModel {
                WebDAVServerListContentView(
                    viewModel: viewModel,
                    isLoadingVisible: bootstrapLoadingGate.isVisible,
                    onRetry: retryLoad
                )
            } else {
                Color.surfacePage.ignoresSafeArea()
                if bootstrapLoadingGate.isVisible {
                    LoadingStateView("正在加载服务器列表…", style: .card)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("备份服务器")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard viewModel == nil else { return }
            bootstrapLoadingGate.update(intent: .read)
            let vm = WebDAVServerViewModel(repository: repositories.backupServerRepository)
            viewModel = vm
            await vm.loadServers()
            bootstrapLoadingGate.update(intent: .none)
        }
        .onDisappear {
            bootstrapLoadingGate.hideImmediately()
        }
    }

    /// 重试首次读取并复用读取门闩，避免快速失败重试产生加载闪烁。
    private func retryLoad() {
        guard let viewModel else { return }
        bootstrapLoadingGate.update(intent: .read)
        Task {
            await viewModel.loadServers()
            bootstrapLoadingGate.update(intent: .none)
        }
    }
}

// MARK: - Content View

private struct WebDAVServerListContentView: View {
    @Bindable var viewModel: WebDAVServerViewModel
    let isLoadingVisible: Bool
    let onRetry: () -> Void

    var body: some View {
        Group {
            switch viewModel.loadPhase {
            case .idle, .loading:
                if isLoadingVisible {
                    LoadingStateView("正在加载服务器列表…", style: .card)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Color.clear
                }
            case .failure:
                XMContentStateView(
                    role: .failure,
                    title: "暂时无法加载服务器",
                    action: XMStateAction(
                        "重试",
                        perform: onRetry
                    )
                )
            case .content:
                if viewModel.servers.isEmpty {
                    XMContentStateView(
                        role: .empty,
                        title: "暂无备份服务器"
                    )
                } else {
                    serverList
                }
            }
        }
        .disabled(viewModel.isProcessing)
        .overlay {
            if viewModel.isProcessing {
                LoadingStateView("正在更新…", style: .card)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { viewModel.beginAdd() } label: {
                    Image(systemName: "plus")
                }
                .disabled(viewModel.isProcessing || viewModel.loadPhase == .loading)
                .accessibilityLabel("新增服务器")
            }
        }
        .sheet(isPresented: $viewModel.isShowingForm) {
            WebDAVServerFormView(viewModel: viewModel)
        }
    }

    private var serverList: some View {
        List {
            if let operationErrorMessage = viewModel.operationErrorMessage {
                XMInlineStatusBanner(
                    operationErrorMessage,
                    tone: .error,
                    action: XMStateAction("关闭") {
                        viewModel.operationErrorMessage = nil
                    }
                )
                .listRowInsets(
                    EdgeInsets(
                        top: Spacing.cozy,
                        leading: Spacing.screenEdge,
                        bottom: Spacing.cozy,
                        trailing: Spacing.screenEdge
                    )
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            ForEach(viewModel.servers, id: \.id) { server in
                serverRow(server)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task { await viewModel.delete(server) }
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                        Button {
                            viewModel.beginEdit(server)
                        } label: {
                            Label("编辑", systemImage: "pencil")
                        }
                    }
            }
        }
    }
}

// MARK: - Server Row

private extension WebDAVServerListContentView {

    /// 渲染单条 WebDAV 服务器配置行。
    func serverRow(_ server: BackupServerRecord) -> some View {
        Button {
            Task { await viewModel.select(server) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: Spacing.compact) {
                    Text(server.title)
                        .font(AppTypography.body)
                    Text(server.serverAddress)
                        .font(AppTypography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if server.isUsing == 1 {
                    XMSelectionIndicator(
                        style: .checkmarkOnly,
                        isSelected: true,
                        font: AppTypography.body,
                        showsUnselectedBase: false
                    )
                }
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    let repositories = RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty()))
    NavigationStack {
        WebDAVServerListView()
    }
    .environment(repositories)
}
