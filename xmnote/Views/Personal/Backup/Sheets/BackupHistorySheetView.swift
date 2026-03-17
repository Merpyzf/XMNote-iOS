/**
 * [INPUT]: 依赖 DataBackupViewModel 提供备份列表与恢复操作
 * [OUTPUT]: 对外提供 BackupHistorySheetView，备份历史展示与恢复确认弹层
 * [POS]: Backup 模块历史弹层，被 DataBackupView 以 sheet 方式呈现
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 备份历史弹层，展示远端备份列表并触发恢复确认流程。
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
        }
    }
}

// MARK: - Backup List

private extension BackupHistorySheetView {

    var backupListView: some View {
        List(viewModel.backupList) { backup in
            Button {
                dismiss()
                Task { @MainActor in
                    viewModel.presentRestoreTarget(for: backup)
                }
            } label: {
                backupRow(backup)
            }
            .buttonStyle(.plain)
        }
    }

    /// 渲染单条备份历史记录行。
    func backupRow(_ backup: BackupFileInfo) -> some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            Text(backup.name)
                .font(AppTypography.body)
                .foregroundStyle(.primary)
            HStack {
                Text(backup.deviceName)
                Spacer()
                Text(formattedSize(backup.size))
                    .font(AppTypography.caption)
                    .foregroundStyle(.secondary)
            }
            .font(AppTypography.caption)
            .foregroundStyle(.secondary)
            if let date = backup.backupDate {
                Text("\(date, style: .date) \(date, style: .time)")
            }
        }
        .font(AppTypography.caption)
    }

    /// 将备份文件大小格式化为易读文本。
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
            backupRepository: repositories.backupRepository
        )
    )
}
