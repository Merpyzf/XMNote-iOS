/**
 * [INPUT]: 依赖 SwiftUI、UniformTypeIdentifiers、带 Kindle 角标的导入插画与分模式引导、KindleImportViewModel、导入交互式玻璃主按钮与统一导入预览/反馈组件
 * [OUTPUT]: 对外提供 KindleImportView，按前置选择展示单一模式指引并通过系统文件入口导入 My Clippings.txt；品牌操作前景由主按钮语义令牌配对
 * [POS]: Views/Personal/DataImport 的 Kindle 平台页面，不宣称 iOS 能自动枚举 MTP
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UniformTypeIdentifiers

/// Kindle 导入页；连接设备与已有文件只区分准备说明，选择统一交给系统文件入口。
struct KindleImportView: View {
    @Environment(RepositoryContainer.self) private var repositories
    @State private var viewModel: KindleImportViewModel
    @State private var loadingGate = LoadingGate()
    @State private var isPickingFile = false
    @State private var showsError = false
    @State private var showsHelp = false
    let entryPoint: KindleImportEntryPoint

    private var guide: KindleImportGuide { .init(entryPoint: entryPoint) }

    /// 入口由目录前置选择决定，不在输入页再次混合呈现两套说明。
    init(entryPoint: KindleImportEntryPoint, gateway: any KindleImportGatewayProtocol) {
        self.entryPoint = entryPoint
        _viewModel = State(initialValue: KindleImportViewModel(gateway: gateway))
    }

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.section) {
                    NoteImportHero(
                        illustration: .txt,
                        title: guide.title,
                        subtitle: "My Clippings.txt · 支持多本书的书摘",
                        platform: .kindle
                    )
                    NoteImportPreparationSteps(steps: guide.steps)
                    NoteImportHelpButton(title: "如何准备 Kindle 书摘") { showsHelp = true }
                        .disabled(viewModel.isParsing)
                }
                .frame(maxWidth: NoteImportSourceLayout.readableWidth, alignment: .leading)
                .padding(Spacing.screenEdge)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.always)
            .safeAreaBar(edge: .bottom, spacing: Spacing.none) {
                selectFileAction
            }
            .scrollEdgeEffectStyle(.soft, for: .bottom)

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
        .sheet(isPresented: $showsHelp) { KindleImportHelpSheet(guide: guide) }
        .onChange(of: viewModel.isParsing) { _, _ in syncLoadingGate() }
        .onChange(of: viewModel.errorMessage) { _, message in showsError = message != nil }
        .onDisappear {
            loadingGate.hideImmediately()
            viewModel.cancel()
        }
        .animation(.smooth(duration: 0.16), value: loadingGate.isVisible)
        .xmSystemAlert(isPresented: $showsError, descriptor: errorDescriptor)
    }

    // 当前模式的唯一操作；解析期间保持原位状态并阻止重复选取。
    private var selectFileAction: some View {
        VStack(spacing: Spacing.base) {
            NoteImportPreviewHint()
            selectFileButton
        }
        .frame(maxWidth: NoteImportSourceLayout.readableWidth)
        .padding(Spacing.screenEdge)
        .frame(maxWidth: .infinity)
    }

    private var selectFileButton: some View {
        Button {
            isPickingFile = true
        } label: {
            HStack(spacing: Spacing.cozy) {
                if viewModel.isParsing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                }
                Text(viewModel.isParsing ? "正在解析文件…" : "选择文件")
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(NoteImportPrimaryButtonStyle())
        .disabled(viewModel.isParsing)
    }

    /// 仅在用户选择成功后解析；系统取消保持当前输入页与既有状态。
    private func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            viewModel.importFile(at: url, entryPoint: entryPoint)
        case .failure(let error):
            let nsError = error as NSError
            guard nsError.code != NSUserCancelledError else { return }
            viewModel.errorMessage = error.localizedDescription
        }
    }

    /// 主线程同步读取意图；页面离场立即撤销延迟展示，避免返回后遗留遮罩。
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
