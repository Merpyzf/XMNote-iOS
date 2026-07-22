/**
 * [INPUT]: 依赖 VisionKit 二维码扫描、SwiftSoup 分享页解析和 HanWangNoteImportParser
 * [OUTPUT]: 对外提供汉王分享二维码扫描、内容确认与统一预览
 * [POS]: Views/Personal/DataImport 的汉王特殊入口，对齐 Android 扫码→抓取→编辑→解析链路
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftSoup
import SwiftUI
import Vision
import VisionKit

struct HanWangImportView: View {
    let repository: any NoteImportRepositoryProtocol
    @State private var scannedURL = ""
    @State private var bookTitle = ""
    @State private var noteContent = ""
    @State private var isLoading = false
    @State private var books: [NoteImportDraftBook] = []
    @State private var opensPreview = false
    @State private var errorMessage: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        Form {
            if noteContent.isEmpty {
                Section("扫描汉王分享二维码") {
                    if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                        HanWangQRScanner { value in guard scannedURL != value else { return }; scannedURL = value; load(value) } onError: { errorMessage = $0 }
                            .frame(height: 320).clipShape(RoundedRectangle(cornerRadius: CornerRadius.blockLarge))
                    } else { TextField("也可以粘贴二维码中的链接", text: $scannedURL); Button("读取链接") { load(scannedURL) } }
                }
            } else {
                Section("书籍信息") { TextField("书名", text: $bookTitle) }
                Section("书摘内容") { TextEditor(text: $noteContent).frame(minHeight: 260) }
                Section { Button("开始导入") { parse() }.disabled(bookTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || noteContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
            if isLoading { Section { HStack { ProgressView(); Text("正在获取书摘内容") } } }
        }
        .navigationTitle("汉王阅读器")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $opensPreview) { UnifiedNoteImportPreviewView(books: books, repository: repository) }
        .onDisappear { task?.cancel() }
        .alert("导入失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("知道了") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
    }

    private func load(_ value: String) {
        guard !value.isEmpty else { errorMessage = "未识别到二维码链接"; return }
        isLoading = true
        task = Task {
            do {
                let url = try Self.realURL(from: value)
                var request = URLRequest(url: url); request.timeoutInterval = 20
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let html = String(data: data, encoding: .utf8) else { throw NoteImportParserError.unexpected("未从二维码中找到书摘") }
                let document = try SwiftSoup.parse(html)
                guard let paragraph = try document.getElementsByTag("p").first() else { throw NoteImportParserError.unexpected("未从二维码中找到书摘") }
                let result = try paragraph.html().replacingOccurrences(of: "<br>", with: "\n")
                guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NoteImportParserError.unexpected("未从二维码中找到书摘") }
                noteContent = result
            } catch is CancellationError {
            } catch { errorMessage = error.localizedDescription }
            isLoading = false
        }
    }

    private func parse() {
        task = Task {
            do {
                books = try await HanWangNoteImportParser(bookTitle: bookTitle).parse(data: Data(noteContent.utf8), fileExtension: "txt").map { source in var value = source; value.source = 19; return value }
                opensPreview = true
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private nonisolated static func realURL(from raw: String) throws -> URL {
        let candidate: String
        if let hash = raw.firstIndex(of: "#") {
            let fragment = raw[raw.index(after: hash)...]
            if let range = fragment.range(of: "path=") {
                let suffix = fragment[range.upperBound...]
                candidate = String(suffix.prefix { $0 != "&" })
            } else { candidate = raw }
        } else if let components = URLComponents(string: raw), let path = components.queryItems?.first(where: { $0.name == "path" })?.value, !path.isEmpty { candidate = path }
        else { candidate = raw }
        guard let url = URL(string: candidate.removingPercentEncoding ?? candidate) else { throw NoteImportParserError.unexpected("二维码链接无效") }
        return url
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
