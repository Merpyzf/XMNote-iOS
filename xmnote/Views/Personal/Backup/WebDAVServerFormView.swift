/**
 * [INPUT]: 依赖 WebDAVServerViewModel 提供表单状态与连通性测试
 * [OUTPUT]: 对外提供 WebDAVServerFormView，服务器新增编辑表单
 * [POS]: Backup 模块服务器表单弹层，被 WebDAVServerListView 以 sheet 呈现
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 备份服务器编辑表单，负责输入校验、连通性测试与保存提交。
struct WebDAVServerFormView: View {
    @Bindable var viewModel: WebDAVServerViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        XMSheetScaffold(
            title: viewModel.editingServer == nil ? "添加服务器" : "编辑服务器",
            onClose: {
                guard !viewModel.isTesting else { return }
                dismiss()
            },
            isConfirmationDisabled: !viewModel.isFormValid,
            isConfirming: viewModel.isTesting,
            confirmationAction: save
        ) {
            VStack(alignment: .leading, spacing: Spacing.section) {
                formFields
                testSection
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.bottom, Spacing.contentEdge)
            .disabled(viewModel.isTesting)
        }
        .interactiveDismissDisabled(viewModel.isTesting)
    }

    /// 保存任务继承当前 Sheet 生命周期；ViewModel 串行执行连通性校验与写入，成功后才关闭。
    private func save() {
        Task {
            if await viewModel.save() {
                dismiss()
            }
        }
    }
}

// MARK: - Form Fields

private extension WebDAVServerFormView {

    var formFields: some View {
        XMSettingsGroup {
            TextField("名称", text: $viewModel.formTitle)
                .frame(minHeight: XMSettingsPageLayout.inputMinHeight)
            XMSettingsDivider()
            TextField("服务器地址", text: $viewModel.formAddress)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .frame(minHeight: XMSettingsPageLayout.inputMinHeight)
            XMSettingsDivider()
            TextField("账号", text: $viewModel.formAccount)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .frame(minHeight: XMSettingsPageLayout.inputMinHeight)
            XMSettingsDivider()
            SecureField("密码", text: $viewModel.formPassword)
                .frame(minHeight: XMSettingsPageLayout.inputMinHeight)
        }
        .font(AppTypography.body)
    }

    var testSection: some View {
        XMSettingsGroup {
            Button {
                Task { await viewModel.testConnection() }
            } label: {
                HStack {
                    Text("测试连接")
                    Spacer()
                    if viewModel.isTesting {
                        LoadingStateView(style: .inline)
                    }
                }
            }
            .disabled(!viewModel.isFormValid || viewModel.isTesting)

            if let message = viewModel.testResultMessage {
                XMSettingsDivider()
                Text(message)
                    .font(AppTypography.caption)
                    .foregroundStyle(message.contains("成功") ? Color.feedbackSuccess : Color.feedbackError)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Spacing.cozy)
            }
        }
    }
}

#Preview {
    let repositories = RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty()))
    WebDAVServerFormView(viewModel: WebDAVServerViewModel(repository: repositories.backupServerRepository))
}
