/**
 * [INPUT]: 依赖 Foundation、NoteImportModels、NoteImportDetection 与各已验证 Parser
 * [OUTPUT]: 对外提供 NoteImportParserRegistry，确保 UI 只调用经过 Golden 验证的单一路径
 * [POS]: Data/Import 的 Parser 装配入口，集中管理检测优先级与 Parser 实例
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

nonisolated struct NoteImportParserRegistry: Sendable {
    private let parsers: [NoteImportParserID: any NoteImportParser]

    init(parsers: [any NoteImportParser] = Self.productionParsers) {
        self.parsers = Dictionary(uniqueKeysWithValues: parsers.map { ($0.id, $0) })
    }

    init(attachmentImporter: any NoteImportAttachmentImporter) {
        var configured = Self.productionParsers.filter { $0.id != .dimo }
        configured.append(DimoNoteImportParser(attachmentImporter: attachmentImporter))
        parsers = Dictionary(uniqueKeysWithValues: configured.map { ($0.id, $0) })
    }

    /// 先执行 Android 同序检测，再调用唯一注册 Parser；不支持或未迁移的输入不会走猜测路径。
    func parse(data: Data, fileExtension: String?) async throws -> [NoteImportDraftBook] {
        guard let parserID = NoteImportDetection.detect(data: data, fileExtension: fileExtension),
              let parser = parsers[parserID]
        else { throw NoteImportParserError.noteFormat }
        return try await parser.parse(data: data, fileExtension: fileExtension)
    }

    func parser(for id: NoteImportParserID) -> (any NoteImportParser)? {
        parsers[id]
    }

    /// 剪贴板等 Android 显式来源入口必须传入 Parser ID，避免宽泛正则之间产生伪自动识别。
    func parse(data: Data, fileExtension: String?, using id: NoteImportParserID) async throws -> [NoteImportDraftBook] {
        guard let parser = parsers[id] else { throw NoteImportParserError.noteFormat }
        return try await parser.parse(data: data, fileExtension: fileExtension)
    }

    func parse(
        data: Data,
        fileName: String,
        fileExtension: String?,
        using id: NoteImportParserID
    ) async throws -> [NoteImportDraftBook] {
        guard let parser = parsers[id] else { throw NoteImportParserError.noteFormat }
        if let fileNameAware = parser as? any NoteImportFileNameAwareParser {
            return try await fileNameAware.parse(data: data, fileName: fileName, fileExtension: fileExtension)
        }
        return try await parser.parse(data: data, fileExtension: fileExtension)
    }

    private static let productionParsers: [any NoteImportParser] = [
        BooxOldNoteImportParser(),
        BooxNewNoteImportParser(),
        DoubanReadNoteImportParser(),
        DedaoNoteImportParser(),
        DangdangNoteImportParser(),
        DimoNoteImportParser(attachmentImporter: PassthroughNoteImportAttachmentImporter()),
        WereadOldNoteImportParser(),
        WereadPre830NoteImportParser(),
        Weread830NoteImportParser(),
        DuokanNoteImportParser(),
        IReaderSelectedNoteImportParser(),
        MoonReaderNoteImportParser(),
        DoubanAppNoteImportParser(),
        Reader163NoteImportParser(),
        FanqieNoteImportParser(),
        ReadingoNoteImportParser(),
        KindleAppNoteImportParser(),
        KOReaderNoteImportParser(),
        LegadoNoteImportParser(),
        NeatReaderNoteImportParser(),
        KoodoNoteImportParser(),
        ReedenNoteImportParser(),
        KindleClippingsNoteImportParser(),
        JDReaderNoteImportParser(),
        IReaderFileNoteImportParser(),
        IReaderEBookNoteImportParser(),
        AppleBooksNoteImportParser()
    ]
}
