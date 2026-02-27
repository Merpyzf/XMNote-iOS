import Foundation

/**
 * [INPUT]: 依赖 Models 与 Services 层的数据类型定义
 * [OUTPUT]: 对外提供 Book/Note/BackupServer/Backup 四类 Repository 协议
 * [POS]: Domain 层仓储契约，定义 Presentation 获取本地/网络数据的唯一入口
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

protocol BookRepositoryProtocol {
    func observeBooks() -> AsyncThrowingStream<[BookItem], Error>
    func observeBookDetail(bookId: Int64) -> AsyncThrowingStream<BookDetail?, Error>
    func observeBookNotes(bookId: Int64) -> AsyncThrowingStream<[NoteExcerpt], Error>
}

protocol NoteRepositoryProtocol {
    func observeTagSections() -> AsyncThrowingStream<[TagSection], Error>
    func fetchNoteDetail(noteId: Int64) async throws -> NoteDetailPayload?
    func saveNoteDetail(noteId: Int64, contentHTML: String, ideaHTML: String) async throws
}

protocol BackupServerRepositoryProtocol {
    func fetchServers() async throws -> [BackupServerRecord]
    func fetchCurrentServer() async throws -> BackupServerRecord?
    func saveServer(_ input: BackupServerFormInput, editingServer: BackupServerRecord?) async throws
    func delete(_ server: BackupServerRecord) async throws
    func select(_ server: BackupServerRecord) async throws
    func testConnection(_ input: BackupServerFormInput) async throws
}

protocol BackupRepositoryProtocol {
    func backup(progress: (@Sendable (BackupProgress) -> Void)?) async throws
    func fetchBackupHistory() async throws -> [BackupFileInfo]
    func restore(_ backup: BackupFileInfo, progress: (@Sendable (RestoreProgress) -> Void)?) async throws
}
