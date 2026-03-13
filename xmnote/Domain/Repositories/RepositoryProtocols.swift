import Foundation

/**
 * [INPUT]: 依赖 Models 与 Services 层的数据类型定义
 * [OUTPUT]: 对外提供 Book/Note/BackupServer/Backup/S3/Statistics/ReadCalendarColor/Timeline/ReadingDashboard 及书籍搜索/录入共十二类 Repository 协议
 * [POS]: Domain 层仓储契约，定义 Presentation 获取本地/网络数据的唯一入口
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 书籍模块数据访问契约，定义书架、书籍详情与书摘的统一读取入口。
protocol BookRepositoryProtocol {
    /// 持续监听书架列表变化，供书籍首页实时刷新。
    func observeBooks() -> AsyncThrowingStream<[BookItem], Error>
    /// 持续监听指定书籍详情变化，供详情页实时更新。
    func observeBookDetail(bookId: Int64) -> AsyncThrowingStream<BookDetail?, Error>
    /// 持续监听指定书籍下的书摘列表变化。
    func observeBookNotes(bookId: Int64) -> AsyncThrowingStream<[NoteExcerpt], Error>
}

/// 书籍搜索仓储契约，统一封装六书源搜索、豆瓣详情补抓与最近搜索持久化。
protocol BookSearchRepositoryProtocol {
    /// 按来源搜索远端书籍列表；空关键字视为业务错误。
    func search(keyword: String, source: BookSearchSource) async throws -> [BookSearchResult]
    /// 将搜索结果补齐为录入页种子；豆瓣等轻量结果需要在这里抓详情。
    func prepareSeed(for result: BookSearchResult) async throws -> BookEditorSeed
    /// 读取最近搜索词，供搜索页初始态展示。
    func fetchRecentQueries() -> [String]
    /// 写入最近搜索词，按最近使用顺序去重保留。
    func saveRecentQuery(_ query: String)
    /// 删除单条最近搜索词。
    func removeRecentQuery(_ query: String)
}

/// 书籍录入仓储契约，统一封装录入选项、偏好读取与新增保存事务。
protocol BookEditorRepositoryProtocol {
    /// 拉取录入页所需的来源、分组、标签与偏好配置。
    func fetchOptions() async throws -> BookEditorOptions
    /// 基于搜索种子与录入偏好生成首屏草稿。
    func makeDraft(from seed: BookEditorSeed?) -> BookEditorDraft
    /// 保存录入偏好，用于下次手动创建或搜索结果补空。
    func savePreference(_ preference: BookEntryPreference)
    /// 按 Android 判重与事务规则保存新书。
    func saveBook(_ draft: BookEditorDraft) async throws -> Int64
}

/// 笔记模块数据访问契约，覆盖标签分组订阅与笔记详情读写。
protocol NoteRepositoryProtocol {
    /// 持续监听标签分组及其笔记摘要，供笔记页分区渲染。
    func observeTagSections() -> AsyncThrowingStream<[TagSection], Error>
    /// 按笔记 ID 拉取可编辑详情（正文/想法 HTML 与元信息）。
    func fetchNoteDetail(noteId: Int64) async throws -> NoteDetailPayload?
    /// 保存笔记正文与想法 HTML，提交后触发下游观察流更新。
    func saveNoteDetail(noteId: Int64, contentHTML: String, ideaHTML: String) async throws
}

/// 备份服务器配置契约，覆盖服务器列表、当前选择、增删改与连通性校验。
protocol BackupServerRepositoryProtocol {
    /// 拉取全部备份服务器配置，供列表页展示。
    func fetchServers() async throws -> [BackupServerRecord]
    /// 读取当前选中的备份服务器；未选择时返回 nil。
    func fetchCurrentServer() async throws -> BackupServerRecord?
    /// 新增或更新备份服务器配置（地址、账号、密码等）。
    func saveServer(_ input: BackupServerFormInput, editingServer: BackupServerRecord?) async throws
    /// 删除指定备份服务器配置。
    func delete(_ server: BackupServerRecord) async throws
    /// 将指定服务器设为当前备份目标。
    func select(_ server: BackupServerRecord) async throws
    /// 校验 WebDAV 连接可用性，失败时抛出网络或认证错误。
    func testConnection(_ input: BackupServerFormInput) async throws
}

/// 数据备份契约，覆盖备份执行、历史读取与恢复流程。
protocol BackupRepositoryProtocol {
    /// 执行一次完整备份流程，并通过回调上报阶段进度。
    func backup(progress: (@Sendable (BackupProgress) -> Void)?) async throws
    /// 获取远端备份历史列表，供恢复入口展示可选备份。
    func fetchBackupHistory() async throws -> [BackupFileInfo]
    /// 使用指定备份执行恢复流程，并通过回调上报阶段进度。
    func restore(_ backup: BackupFileInfo, progress: (@Sendable (RestoreProgress) -> Void)?) async throws
}

/// S3 配置契约，覆盖默认配置映射、自定义配置 CRUD、启用切换与联通性校验。
protocol S3ConfigRepositoryProtocol {
    /// 拉取全部可用 S3 配置，供设置页或测试入口展示。
    func fetchConfigs() async throws -> [S3Config]
    /// 读取当前启用的 S3 配置；未配置时返回 nil。
    func fetchCurrentConfig() async throws -> S3Config?
    /// 新增或更新自定义 S3 配置。
    func saveConfig(_ input: S3ConfigFormInput, editingConfig: S3Config?) async throws -> S3Config
    /// 删除指定 S3 配置。
    func delete(_ config: S3Config) async throws
    /// 将指定 S3 配置设为当前启用配置。
    func select(_ config: S3Config) async throws
    /// 校验给定配置是否具备上传与删除测试对象的能力。
    func testConnection(_ input: S3ConfigFormInput) async throws
}

/// S3 上传契约，覆盖当前配置下的文件上传、联通性校验、删除与取消。
protocol S3UploadRepositoryProtocol: AnyObject {
    /// 使用当前启用配置上传本地文件并返回对象键与远端地址。
    func uploadFile(localURL: URL, prefix: String, progress: (@Sendable (Double) -> Void)?) async throws -> S3UploadResult
    /// 校验当前启用配置是否可访问 S3 兼容网关。
    func testCurrentConfiguration() async throws
    /// 删除指定对象键或完整 URL 对应的远端对象。
    func deleteObject(path: String) async throws
    /// 取消当前正在执行的上传请求。
    func cancelCurrentUpload()
}

/// 阅读日历事件条封面取色仓储
protocol ReadCalendarColorRepositoryProtocol {
    /// 返回最终可渲染颜色：
    /// - resolved: 封面主色提取成功
    /// - failed: 提取失败，已回退哈希色
    func resolveEventColor(
        bookId: Int64,
        bookName: String,
        coverURL: String
    ) async -> ReadCalendarSegmentColor
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

    /// 获取阅读日历最早可展示日期
    /// - Parameter excludedEventTypes: 需排除的事件类型集合
    /// - Returns: 最早存在阅读行为的日期（startOfDay），无数据则返回 nil
    func fetchReadCalendarEarliestDate(
        excludedEventTypes: Set<ReadCalendarEventType>
    ) async throws -> Date?

    /// 按月获取阅读日历数据（书籍事件 + 读完标记）
    /// - Parameters:
    ///   - monthStart: 目标月份任意日期（实现内会归一到该月 1 日）
    ///   - excludedEventTypes: 需排除的事件类型集合
    /// - Returns: 月数据（仅包含有活动或读完记录的日期键）
    func fetchReadCalendarMonthData(
        monthStart: Date,
        excludedEventTypes: Set<ReadCalendarEventType>
    ) async throws -> ReadCalendarMonthData

    /// 按自然年获取阅读时长 Top 书籍（精确聚合）
    /// - Parameters:
    ///   - year: 自然年（如 2026）
    ///   - excludedEventTypes: 需排除的事件类型集合
    ///   - limit: 返回条数上限
    /// - Returns: 年度阅读时长 Top 书籍（按 readSeconds 降序）
    func fetchReadCalendarYearTopBooks(
        year: Int,
        excludedEventTypes: Set<ReadCalendarEventType>,
        limit: Int
    ) async throws -> [ReadCalendarMonthlyDurationBook]
}

extension StatisticsRepositoryProtocol {
    /// 便捷方法：按“全部年份 + 全部统计维度”返回热力图数据。
    func fetchAllHeatmapData() async throws -> (days: [Date: HeatmapDay], earliestDate: Date?) {
        let result = try await fetchHeatmapData(year: 0, dataType: .all)
        return (result.days, result.earliestDate)
    }

    /// 便捷方法：不排除事件类型时读取阅读日历最早可展示日期。
    func fetchReadCalendarEarliestDate() async throws -> Date? {
        try await fetchReadCalendarEarliestDate(excludedEventTypes: [])
    }

    /// 便捷方法：不排除事件类型时读取指定月份阅读日历数据。
    func fetchReadCalendarMonthData(monthStart: Date) async throws -> ReadCalendarMonthData {
        try await fetchReadCalendarMonthData(monthStart: monthStart, excludedEventTypes: [])
    }

    /// 便捷方法：不排除事件类型时读取年度阅读时长榜。
    func fetchReadCalendarYearTopBooks(year: Int, limit: Int = 10) async throws -> [ReadCalendarMonthlyDurationBook] {
        try await fetchReadCalendarYearTopBooks(
            year: year,
            excludedEventTypes: [],
            limit: limit
        )
    }
}

/// 时间线事件仓储契约，覆盖按时间范围的事件列表查询与日历标记聚合。
protocol TimelineRepositoryProtocol {
    /// 查询指定毫秒时间戳范围内的事件列表，按时间降序排列并按日分组。
    /// - Parameters:
    ///   - startTimestamp: 起始毫秒时间戳（含）
    ///   - endTimestamp: 结束毫秒时间戳（含）
    ///   - category: 事件分类过滤（.all 查全部）
    func fetchTimelineEvents(
        startTimestamp: Int64,
        endTimestamp: Int64,
        category: TimelineEventCategory
    ) async throws -> [TimelineSection]

    /// 聚合指定月份的日历标记（每日活跃状态与阅读进度），供日历 cell 渲染。
    /// - Parameters:
    ///   - monthStart: 目标月份首日
    ///   - category: 事件分类过滤（.all 查全部）
    func fetchCalendarMarkers(
        for monthStart: Date,
        category: TimelineEventCategory
    ) async throws -> [Date: TimelineDayMarker]
}

/// 在读首页仪表盘仓储契约，集中封装首页聚合读取与目标写入。
protocol ReadingDashboardRepositoryProtocol {
    /// 持续观察首页聚合快照；数据库变更或目标调整后会自动刷新。
    func observeDashboard(referenceDate: Date) -> AsyncThrowingStream<ReadingDashboardSnapshot, Error>

    /// 更新指定日期对应的每日阅读目标（秒）。
    func updateDailyReadingGoal(seconds: Int, for date: Date) async throws

    /// 更新指定年份对应的年度阅读目标（本）。
    func updateYearlyReadGoal(count: Int, forYear year: Int) async throws
}
