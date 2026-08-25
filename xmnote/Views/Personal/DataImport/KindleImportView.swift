/**
 * [INPUT]: 依赖 SwiftUI、UniformTypeIdentifiers、KindleImportViewModel 与统一导入预览/反馈组件
 * [OUTPUT]: 对外提供 KindleImportView，覆盖连接设备与普通 My Clippings.txt 两个真实系统文件入口
 * [POS]: Views/Personal/DataImport 的 Kindle 平台页面，不宣称 iOS 能自动枚举 MTP
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UniformTypeIdentifiers

/// Kindle 导入页；两个入口只区分用户引导，最终共用 DefaultKindleImportGateway。
struct KindleImportView: View {
    @Environment(RepositoryContainer.self) private var repositories
    @State private var viewModel: KindleImportViewModel
    @State private var loadingGate = LoadingGate()
    @State private var isPickingFile = false
    @State private var pendingEntryPoint: KindleImportEntryPoint = .manualFile
    @State private var showsError = false

    init(gateway: any KindleImportGatewayProtocol) {
        _viewModel = State(initialValue: KindleImportViewModel(gateway: gateway))
    }

    var body: some View {
        ZStack {
            ScrollView {
                VStack(spacing: Spacing.section) {
                    connectedDeviceCard
                    manualFileCard
                    platformDifference
                }
                .padding(Spacing.screenEdge)
            }
            .scrollBounceBehavior(.always)

            if loadingGate.isVisible {
                LoadingStateView("正在读取并解析 Kindle 书摘…", style: .card)
                    .padding(Spacing.screenEdge)
                    .transition(.opacity)
            }
        }
        .background(Color.surfacePage)
        .navigationTitle("Kindle")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $isPickingFile,
            allowedContentTypes: [.plainText],
            allowsMultipleSelection: false,
            onCompletion: handleFileSelection
        )
        .navigationDestination(isPresented: $viewModel.opensPreview) {
            UnifiedNoteImportPreviewView(
                books: viewModel.parsedBooks,
                repository: repositories.noteImportRepository
            )
        }
        .onChange(of: viewModel.isParsing) { _, _ in syncLoadingGate() }
        .onChange(of: viewModel.errorMessage) { _, message in showsError = message != nil }
        .onDisappear {
            loadingGate.hideImmediately()
            viewModel.cancel()
        }
        .animation(.smooth(duration: 0.16), value: loadingGate.isVisible)
        .xmSystemAlert(isPresented: $showsError, descriptor: errorDescriptor)
    }

    private var connectedDeviceCard: some View {
        importCard(
            icon: "externaldrive.connected.to.line.below",
            title: "从已连接的 Kindle 导入",
            message: "先用 USB-C 或转接器连接 Kindle。若设备存储出现在系统“文件”中，请打开 Documents 并选择 My Clippings.txt。",
            actionTitle: "在“文件”中查找 Kindle",
            entryPoint: .connectedDevice
        )
    }

    private var manualFileCard: some View {
        importCard(
            icon: "doc.text",
            title: "选择 My Clippings.txt",
            message: "也可以选择已保存到 iCloud Drive、本机或其他文件提供方的 Kindle 书摘文件",
            actionTitle: "选择文件",
            entryPoint: .manualFile
        )
    }

    private var platformDifference: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            Label("iOS 平台说明", systemImage: "info.circle")
                .font(AppTypography.headline)
                .foregroundStyle(Color.textPrimary)
            Text("iOS 不向第三方 App 提供通用 Kindle MTP 自动扫描接口，因此需要由你在系统“文件”中确认设备和文件。单个文件上限为 32 MiB。")
                .font(AppTypography.subheadline)
                .foregroundStyle(Color.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.contentEdge)
        .background(Color.surfaceNested, in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge))
        .accessibilityElement(children: .combine)
    }

    private func importCard(
        icon: String,
        title: LocalizedStringKey,
        message: LocalizedStringKey,
        actionTitle: LocalizedStringKey,
        entryPoint: KindleImportEntryPoint
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            Label(title, systemImage: icon)
                .font(AppTypography.title3)
                .foregroundStyle(Color.textPrimary)
            Text(message)
                .font(AppTypography.body)
                .foregroundStyle(Color.textSecondary)
            Button {
                pendingEntryPoint = entryPoint
                isPickingFile = true
            } label: {
                Text(actionTitle)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isParsing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.contentEdge)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge))
    }

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            viewModel.importFile(at: url, entryPoint: pendingEntryPoint)
        case .failure(let error):
            let nsError = error as NSError
            guard nsError.code != NSUserCancelledError else { return }
            viewModel.errorMessage = error.localizedDescription
        }
    }

    private func syncLoadingGate() {
        loadingGate.update(intent: viewModel.isParsing ? .read : .none)
    }

    private var errorDescriptor: XMSystemAlertDescriptor? {
        guard let message = viewModel.errorMessage else { return nil }
        return XMSystemAlertDescriptor(
            title: "无法导入 Kindle 书摘",
            message: message,
            actions: [
                XMSystemAlertAction(title: "知道了") {
                    viewModel.errorMessage = nil
                }
            ]
        )
    }
}
