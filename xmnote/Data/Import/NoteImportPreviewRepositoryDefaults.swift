/**
 * [INPUT]: 依赖导入仓储协议与无损 Draft Adapter
 * [OUTPUT]: 为旧导入仓储替身保留非预览调用兼容性，缺失写能力明确报错
 * [POS]: Data/Import 的协议兼容边界；生产仓储覆盖全部预览方法
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

extension NoteImportRepositoryProtocol {
    /// 旧调用方不恢复不存在的偏好。
    func fetchPreviewPreferences(sourceKey: String) -> NoteImportFilter { .init() }
    /// 缺少持久化能力时不伪报成功。
    func savePreviewPreferences(_ filter: NoteImportFilter, sourceKey: String) throws { throw NoteImportDurationError.unavailable }
    /// 旧替身必须显式实现读取能力，不能把本地记录猜成空。
    func assessImportDuration(targetID: Int64?, drafts: [NoteImportDraftBook]) async throws -> NoteImportDurationAssessment { throw NoteImportDurationError.unavailable }
    /// 同目标原子提交不能退回逐书接口。
    func commitImportGroup(_ group: NoteImportCommitGroup) async throws -> NoteImportCommitGroupResult { throw NoteImportDurationError.unavailable }

    /// MainActor 编排旧匹配调用，名称命中仅作为候选，取消继续向上传播。
    func previewTargetMatch(for draft: NoteImportDraftBook) async throws -> NoteImportTargetMatch {
        try await matchLocalBook(for: draft) == nil ? .none : .candidate
    }
    /// 旧仓储缺少编辑读取能力时明确失败，避免返回虚构目标资料。
    func fetchPreviewBookMetadata(id: Int64) async throws -> NoteImportBookMetadata { throw BookEditorError.bookNotFound }
    /// 兼容旧仓储的只读选项请求，不创建分组或标签。
    func fetchPreviewEditorOptions() async throws -> BookEditorOptions {
        BookEditorOptions(sources: [], groups: [], tags: [], preference: .default)
    }
}

extension WereadImportRepositoryProtocol {
    /// 旧来源没有组级写能力时明确失败。
    func commitPreviewGroup(_ group: NoteImportCommitGroup) async throws -> NoteImportCommitGroupResult { throw NoteImportDurationError.unavailable }

    /// 兼容旧来源仓储的快照转换，生产微信读书仓储使用其专用转换器。
    func makePreviewDrafts(_ books: [WereadImportBook]) -> [NoteImportDraftBook] { books.map { $0.asNoteImportDraft() } }
    /// 缺少新提交能力时明确失败；不把已编辑载荷退回旧的有损提交接口。
    func commitPreviewImport(books: [NoteImportCommitBook], progress: @escaping (Int, Int) -> Void) async throws {
        throw NoteImportParserError.unexpected("当前仓储不支持预览提交")
    }
}
