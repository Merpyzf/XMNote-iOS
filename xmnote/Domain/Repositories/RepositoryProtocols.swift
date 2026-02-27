import Foundation

/**
 * [INPUT]: 依赖 Models 与 Services 层的数据类型定义
 * [OUTPUT]: 对外提供 Book/Note/BackupServer/Backup/Statistics 五类 Repository 协议
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

/// 统计数据仓储（热力图、阅读统计）
/// 对齐 Android StatisticsRepository.getChartData(year=0)
protocol StatisticsRepositoryProtocol {
    /// 按统计类型与年份获取热力图数据
    /// - Parameters:
    ///   - year: 0 表示全部年份；>0 表示指定自然年
    ///   - dataType: 统计维度（书摘/阅读/全部/打卡）
    /// - Returns: (数据字典, 起始日期, 结束日期)
    ///   - 起始日期为 nil 表示无可用数据
    ///   - 结束日期用于控制图表显示范围（例如指定年份时为该年 12/31）
    func fetchHeatmapData(
        year: Int,
        dataType: HeatmapStatisticsDataType
    ) async throws -> (days: [Date: HeatmapDay], earliestDate: Date?, latestDate: Date?)

    /// 获取热力图全量数据（从最早记录到今天）
    /// 返回值：(数据字典, 最早记录日期)；最早日期为 nil 表示无任何阅读记录
    func fetchAllHeatmapData() async throws -> (days: [Date: HeatmapDay], earliestDate: Date?)
}

extension StatisticsRepositoryProtocol {
    func fetchAllHeatmapData() async throws -> (days: [Date: HeatmapDay], earliestDate: Date?) {
        let result = try await fetchHeatmapData(year: 0, dataType: .all)
        return (result.days, result.earliestDate)
    }
}
