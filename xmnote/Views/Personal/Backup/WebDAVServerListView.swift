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
                WebDAVServerListContentView(viewModel: viewModel)
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
}

// MARK: - Content View

/// WebDAVServerListContentView 负责当前场景的struct定义，明确职责边界并组织相关能力。
private struct WebDAVServerListContentView: View {
    @Bindable var viewModel: WebDAVServerViewModel

    var body: some View {
        List {
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
                        .tint(.orange)
                    }
            }
        }
        .disabled(viewModel.isProcessing)
        .overlay {
            if viewModel.isProcessing {
                ProgressView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { viewModel.beginAdd() } label: {
                    Image(systemName: "plus")
                }
                .disabled(viewModel.isProcessing)
            }
        }
        .sheet(isPresented: $viewModel.isShowingForm) {
            WebDAVServerFormView(viewModel: viewModel)
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
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.brand)
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
