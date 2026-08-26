/**
 * [INPUT]: 依赖 BackupRestoreTarget、XMSettingsGroup 与备份恢复动作
 * [OUTPUT]: 对外提供 BackupRestoreConfirmSheet，展示恢复来源并承接取消/确认
 * [POS]: Views/Personal/Backup/Sheets 的恢复确认业务 Sheet
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 在执行不可撤销恢复前展示备份来源、设备与时间，并把最终决策交还页面 owner。
struct BackupRestoreConfirmSheet: View {
    let target: BackupRestoreTarget
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        return formatter
    }()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.comfortable) {
                    XMSettingsGroup(
                        horizontalPadding: Spacing.none,
                        verticalPadding: Spacing.none
                    ) {
                        VStack(spacing: Spacing.none) {
                            detailRow(title: "来源", value: target.sourceName)
                            XMSettingsDivider()
                                .padding(.leading, Spacing.contentEdge)
                            detailRow(title: "设备", value: target.deviceName)
                            XMSettingsDivider()
                                .padding(.leading, Spacing.contentEdge)
                            detailRow(title: "备份时间", value: backupDateText)
                        }
                    }

                    Text("恢复后，当前设备上的数据将被备份中的内容替换。此操作无法撤销。")
                        .font(AppTypography.footnote)
                        .foregroundStyle(Color.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, Spacing.screenEdge)
                .padding(.vertical, Spacing.base)
            }
            .scrollBounceBehavior(.always)
            .background(Color.surfacePage)
            .navigationTitle("从备份恢复")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("恢复", action: onConfirm)
                        .foregroundStyle(Color.feedbackError)
                }
            }
        }
    }

    private var backupDateText: String {
        guard let backupDate = target.backupDate else { return "未知" }
        return Self.dateFormatter.string(from: backupDate)
    }

    private func detailRow(title: String, value: String) -> some View {
        HStack(spacing: Spacing.base) {
            Text(title)
                .font(AppTypography.subheadlineMedium)
                .foregroundStyle(Color.textPrimary)
            Spacer()
            Text(value)
                .font(AppTypography.subheadline)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, Spacing.contentEdge)
        .padding(.vertical, Spacing.comfortable)
    }
}
