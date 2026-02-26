import SwiftUI

struct DataBackupView: View {
    @Environment(DatabaseManager.self) private var databaseManager
    @State private var viewModel: DataBackupViewModel?

    var body: some View {
        Group {
            if let viewModel {
                DataBackupContentView(viewModel: viewModel)
            } else {
                Color.clear
            }
        }
        .background(Color.windowBackground)
        .navigationTitle("数据备份")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard viewModel == nil else { return }
            let vm = DataBackupViewModel(databaseManager: databaseManager)
            viewModel = vm
            await vm.loadPageData()
        }
    }
}

// MARK: - Content View

private struct DataBackupContentView: View {
    @Bindable var viewModel: DataBackupViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.base) {
                serverSection
                actionSection
            }
            .padding(Spacing.screenEdge)
        }
        .overlay { operationOverlay }
        .alert("错误", isPresented: $viewModel.showError) {
            Button("确定") {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .alert("恢复成功", isPresented: $viewModel.showRestoreSuccess) {
            Button("确定") {}
        } message: {
            Text("数据已恢复到备份时的状态")
        }
        .sheet(isPresented: $viewModel.isShowingBackupHistory) {
            BackupHistorySheet(viewModel: viewModel)
        }
    }
}

// MARK: - Server Section

private extension DataBackupContentView {

    var serverSection: some View {
        CardContainer {
            NavigationLink(value: PersonalRoute.webdavServers) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("备份服务器")
                            .font(.subheadline)
                        if let server = viewModel.currentServer {
                            Text(server.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("未配置")
                                .font(.caption)
                                .foregroundStyle(.red.opacity(0.87))
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(Spacing.contentEdge)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Action Section

private extension DataBackupContentView {

    var actionSection: some View {
        CardContainer {
            VStack(spacing: 0) {
                backupButton
                Divider().padding(.leading, Spacing.contentEdge)
                restoreButton
            }
        }
    }

    var backupButton: some View {
        Button {
            Task { await viewModel.performBackup() }
        } label: {
            HStack {
                Image(systemName: "icloud.and.arrow.up")
                    .font(.body)
                    .foregroundStyle(Color.brand)
                    .frame(width: 24)
                Text("备份数据")
                Spacer()
                if !viewModel.lastBackupDateText.isEmpty {
                    Text(viewModel.lastBackupDateText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, Spacing.contentEdge)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(viewModel.currentServer == nil || viewModel.operationState != .idle)
    }

    var restoreButton: some View {
        Button {
            Task {
                await viewModel.fetchBackupHistory()
                viewModel.isShowingBackupHistory = true
            }
        } label: {
            HStack {
                Image(systemName: "icloud.and.arrow.down")
                    .font(.body)
                    .foregroundStyle(Color.brand)
                    .frame(width: 24)
                Text("恢复数据")
                Spacer()
            }
            .padding(.horizontal, Spacing.contentEdge)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(viewModel.currentServer == nil || viewModel.operationState != .idle)
    }
}

// MARK: - Operation Overlay

private extension DataBackupContentView {

    @ViewBuilder
    var operationOverlay: some View {
        if viewModel.operationState != .idle {
            ZStack {
                Color.black.opacity(0.4).ignoresSafeArea()
                VStack(spacing: Spacing.base) {
                    ProgressView()
                        .controlSize(.large)
                    Text(operationText)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                }
                .padding(Spacing.double)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: CornerRadius.card))
            }
        }
    }

    var operationText: String {
        switch viewModel.operationState {
        case .idle:
            ""
        case .backingUp(let progress):
            switch progress {
            case .preparing: "准备中…"
            case .packaging: "打包数据…"
            case .uploading(let pct): "上传中 \(Int(pct * 100))%"
            case .cleaning: "清理旧备份…"
            case .completed: "备份完成"
            }
        case .restoring(let progress):
            switch progress {
            case .downloading(let pct): "下载中 \(Int(pct * 100))%"
            case .verifying: "校验数据…"
            case .extracting: "解压中…"
            case .replacing: "替换数据库…"
            case .completed: "恢复完成"
            }
        }
    }
}

#Preview {
    NavigationStack {
        DataBackupView()
    }
    .environment(try! DatabaseManager(database: .empty()))
}
