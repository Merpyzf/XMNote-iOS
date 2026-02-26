import SwiftUI

struct WebDAVServerListView: View {
    @Environment(DatabaseManager.self) private var databaseManager
    @State private var viewModel: WebDAVServerViewModel?

    var body: some View {
        Group {
            if let viewModel {
                WebDAVServerListContentView(viewModel: viewModel)
            } else {
                Color.clear
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("备份服务器")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard viewModel == nil else { return }
            let vm = WebDAVServerViewModel(database: databaseManager.database)
            viewModel = vm
            await vm.loadServers()
        }
    }
}

// MARK: - Content View

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

    func serverRow(_ server: BackupServerRecord) -> some View {
        Button {
            Task { await viewModel.select(server) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(server.title)
                        .font(.body)
                    Text(server.serverAddress)
                        .font(.caption)
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
    NavigationStack {
        WebDAVServerListView()
    }
}
