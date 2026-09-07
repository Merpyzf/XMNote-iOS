/**
 * [INPUT]: 依赖 VisionKit 二维码扫描、NoteImportRepository 分享页读取、HanWangNoteImportParser 与系统中性表单按钮
 * [OUTPUT]: 对外提供汉王分享二维码扫描、内容确认与统一预览
 * [POS]: Views/Personal/DataImport 的汉王特殊入口，对齐 Android 扫码→抓取→编辑→解析链路
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import Vision
import VisionKit

struct HanWangImportView: View {
    private enum Field: Hashable {
        case link
        case title
        case content
    }

    let repository: any NoteImportRepositoryProtocol
    @State private var scannedURL = ""
    @State private var bookTitle = ""
    @State private var noteContent = ""
    @State private var isLoading = false
    @State private var books: [NoteImportDraftBook] = []
    @State private var opensPreview = false
    @State private var errorMessage: String?
    @State private var task: Task<Void, Never>?
    @State private var readLoadingGate = LoadingGate()
    @FocusState private var focusedField: Field?

    var body: some View {
        Form {
            if noteContent.isEmpty {
                Section("扫描汉王分享二维码") {
                    if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                        HanWangQRScanner { value in guard scannedURL != value else { return }; scannedURL = value; load(value) } onError: { errorMessage = $0 }
                            .frame(height: 320).clipShape(RoundedRectangle(cornerRadius: CornerRadius.blockLarge))
                    } else {
                        TextField("也可以粘贴二维码中的链接", text: $scannedURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .link)
                            .submitLabel(.go)
                            .onSubmit { load(scannedURL) }
                        Button("读取链接") { load(scannedURL) }
                            .tint(Color.textPrimary)
                    }
                }
            } else {
                Section("书籍信息") {
                    TextField("书名", text: $bookTitle)
                        .focused($focusedField, equals: .title)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .content }
                }
                Section("书摘内容") {
                    TextEditor(text: $noteContent)
                        .focused($focusedField, equals: .content)
                        .frame(minHeight: 260)
                }
                Section {
                    Button("开始导入") { parse() }
                        .tint(Color.textPrimary)
                        .disabled(bookTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || noteContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if readLoadingGate.isVisible {
                Section {
                    LoadingStateView("正在获取书摘内容…", style: .inline)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("汉王阅读器")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $opensPreview) { UnifiedNoteImportPreviewView(books: books, repository: repository) }
        .onChange(of: isLoading) { _, _ in syncReadLoadingVisibility() }
        .onDisappear {
            focusedField = nil
            task?.cancel()
            readLoadingGate.hideImmediately()
        }
        .xmSystemAlert(
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            ),
            descriptor: errorMessage.map { message in
                .init(
                    title: "导入失败",
                    message: message,
                    actions: [.init(title: "知道了") { errorMessage = nil }]
                )
            }
        )
    }

    private func load(_ value: String) {
        guard !value.isEmpty else { errorMessage = "未识别到二维码链接"; return }
        focusedField = nil
        isLoading = true
        syncReadLoadingVisibility()
        task = Task {
            do {
                noteContent = try await repository.fetchHanWangShareContent(from: value)
            } catch is CancellationError {
            } catch { errorMessage = error.localizedDescription }
            isLoading = false
        }
    }

    private func parse() {
        focusedField = nil
        task = Task {
            do {
                books = try await HanWangNoteImportParser(bookTitle: bookTitle).parse(data: Data(noteContent.utf8), fileExtension: "txt").map { source in var value = source; value.source = 19; return value }
                opensPreview = true
            } catch { errorMessage = error.localizedDescription }
        }
    }

    /// 将读取业务状态单向映射到延迟显示门闩，避免快速请求闪烁。
    private func syncReadLoadingVisibility() {
        readLoadingGate.update(intent: isLoading ? .read : .none)
    }
}

private struct HanWangQRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onError: (String) -> Void
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced, recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false, isGuidanceEnabled: true, isHighlightingEnabled: true)
        controller.delegate = context.coordinator
        do { try controller.startScanning() } catch { onError("扫码启动失败：\(error.localizedDescription)") }
        return controller
    }
    func updateUIViewController(_: DataScannerViewController, context _: Context) {}
    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator _: Coordinator) { controller.stopScanning() }
    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void; var latest: String?
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }
        func dataScanner(_: DataScannerViewController, didAdd items: [RecognizedItem], allItems _: [RecognizedItem]) { for item in items { if case .barcode(let barcode) = item, let value = barcode.payloadStringValue, value != latest { latest = value; onCode(value) } } }
    }
}
