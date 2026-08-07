/**
 * [INPUT]: 依赖 ChapterManagementRepositoryProtocol/OCRRepositoryProtocol 提供事务导入、OCR 偏好与识别能力
 * [OUTPUT]: 对外提供 ChapterBatchImportViewModel，驱动多行解析预览、选区缩进/文本撤销重做、句点归一、OCR 追加与原子导入
 * [POS]: ViewModels/Book 的章节批量录入状态源，由 ChapterBatchImportSheet 持有并在离场时取消任务
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Observation

/// 章节批量录入状态源；所有可观察状态和历史栈由 MainActor 串行维护。
@MainActor
@Observable
final class ChapterBatchImportViewModel: Identifiable {
    let id = UUID()
    let bookID: Int64

    private(set) var text = ""
    private(set) var draft: ChapterBatchImportDraft?
    private(set) var parseErrorMessage: String?
    private(set) var operationErrorMessage: String?
    private(set) var isRecognizing = false
    private(set) var isImporting = false
    private(set) var importResult: ChapterBatchImportResult?

    private let chapterRepository: any ChapterManagementRepositoryProtocol
    private let ocrRepository: any OCRRepositoryProtocol
    private var undoHistory: [String] = []
    private var redoHistory: [String] = []
    private var recognitionTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    private var recognitionRequestID: UUID?
    private var importRequestID: UUID?

    /// 注入同一页面使用的目录与 OCR 仓储；初始空文本不显示阻断错误。
    init(
        bookID: Int64,
        chapterRepository: any ChapterManagementRepositoryProtocol,
        ocrRepository: any OCRRepositoryProtocol
    ) {
        self.bookID = bookID
        self.chapterRepository = chapterRepository
        self.ocrRepository = ocrRepository
    }

    /// 页面离场时取消尚未完成的 OCR/导入 Task；数据库事务是否已提交由 Repository 自身保证原子性。
    isolated deinit {
        recognitionTask?.cancel()
        importTask?.cancel()
    }

    var previewEntries: [ChapterBatchImportEntry] {
        draft?.entries ?? []
    }

    var canUndo: Bool { !undoHistory.isEmpty && !isBusy }
    var canRedo: Bool { !redoHistory.isEmpty && !isBusy }
    var canImport: Bool { draft != nil && !isBusy }
    var isBusy: Bool { isRecognizing || isImporting }

    /// 接收 TextEditor 的最新全文；每次用户修改都进入有界撤销栈并实时重建预览。
    func replaceText(_ newValue: String) {
        setText(newValue, recordingHistory: true)
    }

    /// 撤销最近一次文本变化；程序化句点转换与 OCR 追加同样会回到此前全文。
    func undoTextChange() {
        guard canUndo, let previous = undoHistory.popLast() else { return }
        Self.appendBounded(text, to: &redoHistory)
        setText(previous, recordingHistory: false)
    }

    /// 重做最近一次已撤销的文本变化。
    func redoTextChange() {
        guard canRedo, let next = redoHistory.popLast() else { return }
        Self.appendBounded(text, to: &undoHistory)
        setText(next, recordingHistory: false)
    }

    /// 将全文句点统一为中文形态，并把转换纳入撤销历史。
    func normalizeToChinesePeriods() {
        setText(
            ChapterBatchImportParser.normalizePeriods(in: text, toChinese: true),
            recordingHistory: true
        )
    }

    /// 将全文句点统一为英文形态，并把转换纳入撤销历史。
    func normalizeToEnglishPeriods() {
        setText(
            ChapterBatchImportParser.normalizePeriods(in: text, toChinese: false),
            recordingHistory: true
        )
    }

    /// 增加光标所在行或连续选中行的目录层级；成功后返回更新后的 UTF-16 选区供页面恢复。
    func increaseIndent(
        selectionLocation: Int,
        selectionLength: Int
    ) -> ChapterBatchIndentResult? {
        guard !isBusy else { return nil }
        operationErrorMessage = nil
        do {
            guard let result = try ChapterBatchImportParser.increaseIndent(
                in: text,
                selectionLocation: selectionLocation,
                selectionLength: selectionLength
            ) else {
                return nil
            }
            setText(result.text, recordingHistory: true)
            return result
        } catch {
            operationErrorMessage = error.localizedDescription
            return nil
        }
    }

    /// 使用现有 OCRRepository 识别相机或照片数据；Task 不强持有页面，MainActor 代际只接受最新未取消结果。
    func recognizeAndAppend(imageData: Data) {
        guard !imageData.isEmpty, !isBusy else { return }
        operationErrorMessage = nil
        isRecognizing = true
        recognitionTask?.cancel()
        let requestID = UUID()
        recognitionRequestID = requestID
        let ocrRepository = self.ocrRepository
        recognitionTask = Task { [weak self] in
            defer {
                self?.finishRecognition(requestID: requestID)
            }
            do {
                let preferences = ocrRepository.fetchPreferences()
                let result = try await ocrRepository.recognizeText(
                    request: OCRRecognitionRequest(
                        imageData: imageData,
                        preferences: preferences
                    )
                )
                guard !Task.isCancelled,
                      let self,
                      recognitionRequestID == requestID else { return }
                appendRecognizedText(result.text)
            } catch is CancellationError {
                return
            } catch {
                guard let self, recognitionRequestID == requestID else { return }
                operationErrorMessage = error.localizedDescription
            }
        }
    }

    /// 提交当前已验证草稿；Task 可随页面取消，Repository 已开始的单一写事务仍自行保证原子性。
    func importChapters() {
        guard !isBusy else { return }
        guard let draft else {
            operationErrorMessage = parseErrorMessage ?? ChapterBatchImportError.emptyInput.localizedDescription
            return
        }
        operationErrorMessage = nil
        isImporting = true
        importTask?.cancel()
        let requestID = UUID()
        importRequestID = requestID
        let chapterRepository = self.chapterRepository
        let bookID = self.bookID
        importTask = Task { [weak self] in
            defer {
                self?.finishImport(requestID: requestID)
            }
            do {
                let result = try await chapterRepository.importChapterBatch(bookID: bookID, draft: draft)
                guard !Task.isCancelled,
                      let self,
                      importRequestID == requestID else { return }
                importResult = result
            } catch is CancellationError {
                return
            } catch {
                guard let self, importRequestID == requestID else { return }
                operationErrorMessage = error.localizedDescription
            }
        }
    }

    /// 接收相册读取或相机图片处理失败，统一交给 Sheet 的 XMSystemAlert 呈现。
    func presentOperationError(_ message: String) {
        operationErrorMessage = message
    }

    /// 清除已经由 XMSystemAlert 展示的 OCR 或导入错误，避免重复呈现。
    func consumeOperationError() {
        operationErrorMessage = nil
    }

    /// Sheet 离场时使旧请求代际立即失效并取消 Task；Repository 已进入的数据库事务仍保持自身原子性。
    func cancelPendingWork() {
        recognitionRequestID = nil
        importRequestID = nil
        recognitionTask?.cancel()
        importTask?.cancel()
        recognitionTask = nil
        importTask = nil
        isRecognizing = false
        isImporting = false
    }
}

private extension ChapterBatchImportViewModel {
    static let maximumHistoryCount = 80

    /// 仅允许当前 OCR 代际收口，防止被取消的旧 Task 清空新请求门闩。
    func finishRecognition(requestID: UUID) {
        guard recognitionRequestID == requestID else { return }
        isRecognizing = false
        recognitionTask = nil
        recognitionRequestID = nil
    }

    /// 仅允许当前导入代际收口，避免页面离场后的迟到完成覆盖新状态。
    func finishImport(requestID: UUID) {
        guard importRequestID == requestID else { return }
        isImporting = false
        importTask = nil
        importRequestID = nil
    }

    /// 应用全文并重建草稿；同值写入不污染撤销栈。
    func setText(_ newValue: String, recordingHistory: Bool) {
        guard newValue != text else { return }
        if recordingHistory {
            Self.appendBounded(text, to: &undoHistory)
            redoHistory.removeAll(keepingCapacity: true)
        }
        text = newValue
        refreshPreview()
    }

    /// OCR 结果保持原换行；当前已有内容时只补一个边界换行，避免把两条目录粘连。
    func appendRecognizedText(_ recognizedText: String) {
        guard !recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            operationErrorMessage = OCRRepositoryError.emptyText.localizedDescription
            return
        }
        let separator = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n"
        setText(text + separator + recognizedText, recordingHistory: true)
    }

    /// 空输入保持安静；非空输入的层级错误以内联方式持续显示并阻断导入。
    func refreshPreview() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            draft = nil
            parseErrorMessage = nil
            return
        }
        do {
            draft = try ChapterBatchImportParser.parse(text)
            parseErrorMessage = nil
        } catch {
            draft = nil
            parseErrorMessage = error.localizedDescription
        }
    }

    /// 将文本历史限制在高频编辑仍可预测的固定窗口内，避免长目录持续占用内存。
    static func appendBounded(_ value: String, to history: inout [String]) {
        history.append(value)
        if history.count > Self.maximumHistoryCount {
            history.removeFirst(history.count - Self.maximumHistoryCount)
        }
    }
}
