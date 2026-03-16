/**
 * [INPUT]: 依赖 RepositoryContainer 注入仓储，依赖 DataBackupViewModel 驱动状态
 * [OUTPUT]: 对外提供 DataBackupView，承载 provider 选择、授权状态与手动备份/恢复入口
 * [POS]: Backup 模块入口壳层，对齐 Android 的云备份 provider 切换模式
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 数据备份入口页，聚合 provider 选择、当前 provider 状态与手动备份/恢复入口。
struct DataBackupView: View {
    @Environment(AppState.self) private var appState
    @Environment(RepositoryContainer.self) private var repositories
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel: DataBackupViewModel?

    var body: some View {
        Group {
            if let viewModel {
                DataBackupContentView(viewModel: viewModel)
            } else {
                Color.clear
            }
        }
        .background(Color.surfacePage)
        .navigationTitle("数据备份")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard viewModel == nil else { return }
            let viewModel = DataBackupViewModel(
                backupRepository: repositories.backupRepository,
                onRestoreSucceeded: { appState.dataEpoch += 1 }
            )
            self.viewModel = viewModel
            await viewModel.loadPageData()
        }
        .onChange(of: scenePhase) { _, newValue in
            guard newValue == .active, let viewModel else { return }
            Task { await viewModel.refreshOnBecomeActive() }
        }
    }
}

// MARK: - Content View

private struct DataBackupContentView: View {
    @Bindable var viewModel: DataBackupViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.base) {
                providerSection
                currentProviderSection
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
            Button("确定") {
                viewModel.acknowledgeRestoreSuccess()
            }
        } message: {
            Text("数据已恢复，页面将刷新")
        }
        .sheet(isPresented: $viewModel.isShowingBackupHistory) {
            BackupHistorySheetView(viewModel: viewModel)
        }
        .confirmationDialog("云备份方式", isPresented: $viewModel.isShowingProviderPicker) {
            ForEach([CloudBackupProvider.webdav, .aliyunDrive]) { provider in
                Button(provider.displayName) {
                    Task { await viewModel.selectProvider(provider) }
                }
            }
            Button("取消", role: .cancel) {}
        }
    }
}

// MARK: - Provider Section

private extension DataBackupContentView {

    var providerSection: some View {
        CardContainer {
            Button {
                viewModel.isShowingProviderPicker = true
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: Spacing.compact) {
                        Text("云备份方式")
                            .font(AppTypography.subheadline)
                        Text(viewModel.selectedProviderSummary)
                            .font(AppTypography.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(viewModel.selectedProvider.displayName)
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.brand)
                    Image(systemName: "chevron.right")
                        .font(AppTypography.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(Spacing.contentEdge)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isBusy)
        }
    }

    @ViewBuilder
    var currentProviderSection: some View {
        switch viewModel.selectedProvider {
        case .webdav:
            webdavSection
        case .aliyunDrive:
            aliyunDriveSection
        }
    }

    var webdavSection: some View {
        CardContainer {
            NavigationLink(value: PersonalRoute.webdavServers) {
                HStack {
                    VStack(alignment: .leading, spacing: Spacing.compact) {
                        Text("WebDAV 服务器")
                            .font(AppTypography.subheadline)
                        if let server = viewModel.currentServer {
                            Text(server.title)
                                .font(AppTypography.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("未配置")
                                .font(AppTypography.caption)
                                .foregroundStyle(Color.feedbackError)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(AppTypography.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(Spacing.contentEdge)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    var aliyunDriveSection: some View {
        CardContainer {
            VStack(spacing: Spacing.none) {
                if let accountInfo = viewModel.aliyunAccountInfo {
                    aliyunAccountRow(accountInfo)
                    Divider().padding(.leading, 64)
                    Button {
                        Task { await viewModel.revokeAliyunDriveAuthorization() }
                    } label: {
                        HStack {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                .font(AppTypography.body)
                                .foregroundStyle(Color.feedbackError)
                                .frame(width: 24)
                            Text("退出阿里云盘")
                            Spacer()
                        }
                        .padding(.horizontal, Spacing.contentEdge)
                        .padding(.vertical, Spacing.comfortable)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isBusy)
                } else if viewModel.isAliyunAuthorized {
                    VStack(alignment: .leading, spacing: Spacing.compact) {
                        HStack {
                            Image(systemName: "checkmark.shield")
                                .font(AppTypography.body)
                                .foregroundStyle(Color.brand)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: Spacing.compact) {
                                Text("阿里云盘已登录")
                                Text(viewModel.aliyunAccountInfoErrorMessage ?? "当前可继续进行云备份")
                                    .font(AppTypography.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, Spacing.contentEdge)
                        .padding(.top, Spacing.comfortable)

                        Divider().padding(.leading, 64)

                        Button {
                            Task { await viewModel.revokeAliyunDriveAuthorization() }
                        } label: {
                            HStack {
                                Image(systemName: "rectangle.portrait.and.arrow.right")
                                    .font(AppTypography.body)
                                    .foregroundStyle(Color.feedbackError)
                                    .frame(width: 24)
                                Text("退出阿里云盘")
                                Spacer()
                            }
                            .padding(.horizontal, Spacing.contentEdge)
                            .padding(.vertical, Spacing.comfortable)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.isBusy)
                    }
                } else {
                    Button {
                        Task { await viewModel.authorizeAliyunDrive() }
                    } label: {
                        HStack {
                            Image(systemName: "person.crop.circle.badge.plus")
                                .font(AppTypography.body)
                                .foregroundStyle(Color.brand)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: Spacing.compact) {
                                Text("登录阿里云盘")
                                Text("登录后可将备份保存到阿里云盘")
                                    .font(AppTypography.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, Spacing.contentEdge)
                        .padding(.vertical, Spacing.comfortable)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isBusy)
                }
            }
        }
    }

    func aliyunAccountRow(_ accountInfo: CloudBackupAccountInfo) -> some View {
        HStack(spacing: Spacing.base) {
            avatarView(for: accountInfo.avatarURL)
            VStack(alignment: .leading, spacing: Spacing.compact) {
                Text(accountInfo.nickName)
                    .font(AppTypography.subheadline)
                Text(accountInfo.storageSummary ?? accountInfo.userId)
                    .font(AppTypography.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(Spacing.contentEdge)
    }

    @ViewBuilder
    func avatarView(for urlString: String) -> some View {
        if let url = URL(string: urlString), !urlString.isEmpty {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    Circle()
                        .fill(Color.brand.opacity(0.12))
                        .overlay {
                            Image(systemName: "person.fill")
                                .foregroundStyle(Color.brand)
                        }
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(Circle())
        } else {
            Circle()
                .fill(Color.brand.opacity(0.12))
                .overlay {
                    Image(systemName: "person.fill")
                        .foregroundStyle(Color.brand)
                }
                .frame(width: 40, height: 40)
        }
    }
}

// MARK: - Action Section

private extension DataBackupContentView {

    var actionSection: some View {
        CardContainer {
            VStack(spacing: Spacing.none) {
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
                    .font(AppTypography.body)
                    .foregroundStyle(Color.brand)
                    .frame(width: 24)
                Text("备份数据")
                Spacer()
                if !viewModel.lastBackupDateText.isEmpty {
                    Text(viewModel.lastBackupDateText)
                        .font(AppTypography.caption)
                        .foregroundStyle(viewModel.lastBackupState == .failed ? Color.feedbackError : .secondary)
                }
            }
            .padding(.horizontal, Spacing.contentEdge)
            .padding(.vertical, Spacing.comfortable)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.canPerformCloudOperation)
    }

    var restoreButton: some View {
        Button {
            Task {
                if await viewModel.fetchBackupHistory() {
                    viewModel.isShowingBackupHistory = true
                }
            }
        } label: {
            HStack {
                Image(systemName: "icloud.and.arrow.down")
                    .font(AppTypography.body)
                    .foregroundStyle(Color.brand)
                    .frame(width: 24)
                Text("恢复数据")
                Spacer()
            }
            .padding(.horizontal, Spacing.contentEdge)
            .padding(.vertical, Spacing.comfortable)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.canPerformCloudOperation)
    }
}

// MARK: - Operation Overlay

private extension DataBackupContentView {

    @ViewBuilder
    var operationOverlay: some View {
        if let loadingText = viewModel.blockingMessage {
            ZStack {
                Color.overlay.ignoresSafeArea()
                VStack(spacing: Spacing.base) {
                    ProgressView()
                        .controlSize(.large)
                    Text(loadingText)
                        .font(AppTypography.subheadline)
                        .foregroundStyle(.white)
                }
                .padding(Spacing.double)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
            }
        } else if viewModel.operationState != .idle {
            ZStack {
                Color.overlay.ignoresSafeArea()
                VStack(spacing: Spacing.base) {
                    ProgressView()
                        .controlSize(.large)
                    Text(operationText)
                        .font(AppTypography.subheadline)
                        .foregroundStyle(.white)
                }
                .padding(Spacing.double)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
            }
        }
    }

    var operationText: String {
        switch viewModel.operationState {
        case .idle:
            ""
        case .backingUp(let progress):
            switch progress {
            case .preparing:
                "准备中…"
            case .packaging:
                "打包数据…"
            case .uploading(let fraction):
                if let fraction {
                    "上传中 \(Int(fraction * 100))%"
                } else {
                    "上传中…"
                }
            case .finalizing:
                "正在完成备份…"
            case .completed:
                "备份完成"
            }
        case .restoring(let progress):
            switch progress {
            case .downloading(let fraction):
                if let fraction {
                    "下载中 \(Int(fraction * 100))%"
                } else {
                    "下载中…"
                }
            case .verifying:
                "校验数据…"
            case .extracting:
                "解压中…"
            case .replacing:
                "替换数据库…"
            case .completed:
                "恢复完成"
            }
        }
    }
}

#Preview {
    NavigationStack {
        DataBackupView()
    }
    .environment(AppState())
    .environment(RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty())))
}
