import SwiftUI

struct WebDAVServerFormView: View {
    @Bindable var viewModel: WebDAVServerViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                formFields
                testSection
            }
            .disabled(viewModel.isTesting)
            .navigationTitle(viewModel.editingServer == nil ? "添加服务器" : "编辑服务器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(viewModel.isTesting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if viewModel.isTesting {
                        ProgressView()
                    } else {
                        Button("保存") {
                            Task {
                                if await viewModel.save() {
                                    dismiss()
                                }
                            }
                        }
                        .disabled(!viewModel.isFormValid)
                    }
                }
            }
        }
        .interactiveDismissDisabled(viewModel.isTesting)
    }
}

// MARK: - Form Fields

private extension WebDAVServerFormView {

    var formFields: some View {
        Section {
            TextField("名称", text: $viewModel.formTitle)
            TextField("服务器地址", text: $viewModel.formAddress)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("账号", text: $viewModel.formAccount)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("密码", text: $viewModel.formPassword)
        }
    }

    var testSection: some View {
        Section {
            Button {
                Task { await viewModel.testConnection() }
            } label: {
                HStack {
                    Text("测试连接")
                    Spacer()
                    if viewModel.isTesting {
                        ProgressView()
                    }
                }
            }
            .disabled(!viewModel.isFormValid || viewModel.isTesting)

            if let message = viewModel.testResultMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(message.contains("成功") ? Color.brand : .red)
            }
        }
    }
}

#Preview {
    let repositories = RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty()))
    WebDAVServerFormView(viewModel: WebDAVServerViewModel(repository: repositories.backupServerRepository))
}
