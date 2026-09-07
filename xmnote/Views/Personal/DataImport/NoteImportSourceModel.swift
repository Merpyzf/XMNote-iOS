/**
 * [INPUT]: 依赖输入来源、文件仓储、已验证 Parser Registry 与导入草稿
 * [OUTPUT]: 提供文件批次检查、原文草稿、逐项解析反馈和预览准备状态
 * [POS]: Views/Personal/DataImport 的功能私有输入状态 owner；不写数据库
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Observation

/// 单个文件的稳定选择身份与解析结果，失败不会移除原文件或其他成功结果。
struct NoteImportSelectedFile: Identifiable {
    let id = UUID()
    let access: NoteImportFileAccess
    var books: [NoteImportDraftBook] = []
    var error: String?
}

/// 在 MainActor 管理输入状态；每次取消使请求票据失效，避免迟到解析触发导航。
@MainActor @Observable
final class NoteImportSourceModel {
    let input: NoteImportSourceInput
    var files: [NoteImportSelectedFile] = []
    var clipboardText = ""
    var hasEditedClipboard = false
    var errorMessage: String?
    var isParsing = false
    var progressText = ""
    var parsedBooks: [NoteImportDraftBook] = []
    var opensPreview = false
    private var lockedSource: NoteImportParserID?
    private var task: Task<Void, Never>?
    private var requestID = UUID()
    private let fileRepository = NoteImportFileRepository()

    var hasInput: Bool { input.isFile ? !files.isEmpty : !clipboardText.isEmpty }
    var successfulFileCount: Int { files.filter { !$0.books.isEmpty }.count }
    var hasFileErrors: Bool { files.contains { $0.error != nil } }

    /// 由来源页面创建一次，输入调整不重建会话。
    init(input: NoteImportSourceInput) {
        self.input = input
        lockedSource = input.parserIDs.first?.importSourceFamily
    }

    /// 追加未选择的文件并保持系统访问票据；取消选择器时调用方不改变清单。
    func addFiles(_ urls: [URL]) {
        guard !isParsing else { return }
        for url in urls where !files.contains(where: { $0.access.url.standardizedFileURL == url.standardizedFileURL }) {
            files.append(NoteImportSelectedFile(access: NoteImportFileAccess(url: url)))
        }
        invalidatePreview()
    }

    /// 移除只影响当前选择，访问票据在异步读取和 UI 均释放后归还。
    func removeFile(_ id: UUID) {
        guard !isParsing else { return }
        files.removeAll { $0.id == id }
        if files.allSatisfy({ $0.books.isEmpty }) { lockedSource = input.parserIDs.first?.importSourceFamily }
        invalidatePreview()
    }

    /// 接收用户主动读取或完成编辑的原文，不写回系统剪贴板。
    func setClipboard(_ text: String, edited: Bool) {
        guard !isParsing else { return }
        clipboardText = text
        hasEditedClipboard = edited
        invalidatePreview()
    }

    /// 输入变化后丢弃聚合预览，不破坏未变更文件已经取得的解析结果。
    private func invalidatePreview() {
        parsedBooks = []
        opensPreview = false
        errorMessage = nil
    }

    /// 显式接受部分成功结果；失败文件留在输入页，返回后仍可重试。
    func previewSuccessfulFiles() {
        guard !isParsing, successfulFileCount > 0 else { return }
        parsedBooks = files.flatMap(\.books)
        opensPreview = true
    }

    /// MainActor 编排逐文件解析，I/O 在仓储 Actor、Parser 在后台任务；所有回写校验取消与请求身份。
    func parse(registry: NoteImportParserRegistry) {
        guard hasInput, !isParsing else { return }
        cancelParsing()
        let request = UUID()
        requestID = request
        errorMessage = nil
        isParsing = true
        task = Task { [weak self] in
            guard let self else { return }
            defer { if requestID == request { isParsing = false; task = nil } }
            if input.isFile {
                for index in files.indices {
                    guard requestID == request, !Task.isCancelled else { return }
                    if !files[index].books.isEmpty { continue }
                    progressText = "正在解析 \(index + 1)/\(files.count)"
                    files[index].error = nil
                    do {
                        let fileAccess = files[index].access
                        let data = try await fileRepository.read(fileAccess)
                        guard requestID == request, !Task.isCancelled else { return }
                        let result = try await Self.parseContent(
                            data: data, fileName: fileAccess.url.lastPathComponent,
                            input: input, lockedSource: lockedSource, registry: registry
                        )
                        guard requestID == request, !Task.isCancelled else { return }
                        lockedSource = result.parserID.importSourceFamily
                        files[index].books = result.books.settingSource(for: result.parserID)
                    } catch is CancellationError {
                        return
                    } catch {
                        guard requestID == request, !Task.isCancelled else { return }
                        files[index].error = error.localizedDescription
                    }
                }
                guard requestID == request, !Task.isCancelled else { return }
                if hasFileErrors {
                    errorMessage = "部分文件未能解析，请检查各文件的提示。你可以重试、移除文件，或仅预览成功的文件。"
                    if successfulFileCount == 0 { errorMessage = "未能解析这些文件，请检查格式和来源后重试。" }
                } else {
                    parsedBooks = files.flatMap(\.books)
                    opensPreview = !parsedBooks.isEmpty
                }
            } else {
                progressText = "正在解析"
                do {
                    let result = try await Self.parseContent(
                        data: Data(clipboardText.utf8), fileName: "clipboard.txt",
                        input: input, lockedSource: lockedSource, registry: registry
                    )
                    guard requestID == request, !Task.isCancelled else { return }
                    parsedBooks = result.books.settingSource(for: result.parserID)
                    opensPreview = true
                } catch is CancellationError {
                    return
                } catch {
                    guard requestID == request, !Task.isCancelled else { return }
                    errorMessage = "\(error.localizedDescription)。请查看并检查原文，或重新复制完整笔记。"
                }
            }
        }
    }

    /// 离场立即使回写失效；取消向文件读取与后台 Parser 传播，不依赖 Parser 是否及时响应。
    func cancelParsing() {
        requestID = UUID()
        task?.cancel()
        task = nil
        isParsing = false
    }

    /// 在后台执行来源限定解析，版本候选仅限同一来源；取消显式传递给非结构化 worker。
    nonisolated private static func parseContent(
        data: Data, fileName: String, input: NoteImportSourceInput,
        lockedSource: NoteImportParserID?, registry: NoteImportParserRegistry
    ) async throws -> ParsedInput {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let ext = (fileName as NSString).pathExtension.lowercased()
            var candidates = input.parserIDs
            if candidates.contains(.weread830) {
                candidates = NoteImportDetection.detectWereadClipboard(data: data).map { [$0] } ?? []
            } else if candidates.isEmpty {
                let detected = NoteImportDetection.detect(data: data, fileExtension: ext)
                    ?? (ext == "epub" ? .ireaderEpub : nil)
                    ?? (ext == "zip" ? .appleBooks : nil)
                candidates = detected.map { [$0] } ?? []
            }
            guard !candidates.isEmpty else { throw NoteImportParserError.noteFormat }
            if let lockedSource, candidates.contains(where: { $0.importSourceFamily != lockedSource }) {
                throw NoteImportParserError.unexpected("文件来源与本批次不一致，请分别导入")
            }
            var lastError: Error = NoteImportParserError.noteFormat
            for parserID in candidates {
                try Task.checkCancellation()
                do {
                    let books = try await registry.parse(data: data, fileName: fileName, fileExtension: ext, using: parserID)
                    try Task.checkCancellation()
                    guard books.contains(where: { !$0.notes.isEmpty || !$0.reviews.isEmpty }) else {
                        throw NoteImportParserError.noteNotFound
                    }
                    return ParsedInput(books: books, parserID: parserID)
                } catch is CancellationError { throw CancellationError() }
                catch { lastError = error }
            }
            if input.isFile, lastError as? NoteImportParserError == .noteFormat {
                throw NoteImportParserError.unexpected("无法识别为当前来源的笔记，请检查文件来源和导出格式")
            }
            throw lastError
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }
}

/// 后台解析只返回领域草稿与实际解析器，页面回到 MainActor 后再设置来源和导航。
nonisolated private struct ParsedInput: Sendable {
    let books: [NoteImportDraftBook]
    let parserID: NoteImportParserID
}
