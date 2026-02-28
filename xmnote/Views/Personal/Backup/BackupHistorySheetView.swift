/**
 * [INPUT]: 依赖 DataBackupViewModel 提供备份列表与恢复操作
 * [OUTPUT]: 对外提供 BackupHistorySheetView，备份历史展示与恢复确认弹层
 * [POS]: Backup 模块历史弹层，被 DataBackupView 以 sheet 方式呈现
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

struct BackupHistorySheetView: View {
    @Bindable var viewModel: DataBackupViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.backupList.isEmpty {
                    EmptyStateView(icon: "clock.arrow.circlepath", message: "暂无备份记录")
                } else {
                    backupListView
                }
            }
            .navigationTitle("备份历史")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .alert("确认恢复", isPresented: $viewModel.showRestoreConfirm) {
                Button("取消", role: .cancel) {}
                Button("恢复", role: .destructive) {
                    guard let backup = viewModel.selectedBackup else { return }
                    dismiss()
                    Task { await viewModel.performRestore(backup) }
                }
            } message: {
                Text("恢复将覆盖当前所有数据，此操作不可撤销")
            }
        }
    }
}

// MARK: - Backup List

private extension BackupHistorySheetView {

    var backupListView: some View {
        List(viewModel.backupList) { backup in
            Button {
                viewModel.selectedBackup = backup
                viewModel.showRestoreConfirm = true
            } label: {
                backupRow(backup)
            }
            .buttonStyle(.plain)
        }
    }

    func backupRow(_ backup: BackupFileInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(backup.deviceName)
                    .font(.body)
                Spacer()
                Text(formattedSize(backup.size))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let date = backup.backupDate {
                Text(date, style: .date) + Text(" ") + Text(date, style: .time)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

#Preview {
    let repositories = RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty()))
    BackupHistorySheetView(
        viewModel: DataBackupViewModel(
            backupRepository: repositories.backupRepository,
            serverRepository: repositories.backupServerRepository
        )
    )
}
