/**
 * [INPUT]: 依赖 Foundation Codable/Sendable，不依赖 App 数据库或 UI
 * [OUTPUT]: 提供 ReadTimeController 与 ReadingRecordController 6 个 API 的 DTO 和能力端口
 * [POS]: XMNoteWeb 阅读记录公共边界；只表达 Android v46 Web 合同
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// Android CreateReadingSessionDto；可选字段缺失时应用 Kotlin 默认值。
public struct DesktopWebReadingSessionCreateRequest: Codable, Sendable, Equatable {
    public let bookId: Int64
    public let startTime: Int64
    public let endTime: Int64
    public let elapsedSeconds: Int64
    public let countdownSeconds: Int64
    public let pausedDurationMillis: Int64
    public let position: Double?
    public let recordedPositionUnit: Int?
    public let insight: String?
    public let confirmedLongDuration: Bool

    public init(
        bookId: Int64,
        startTime: Int64,
        endTime: Int64,
        elapsedSeconds: Int64,
        countdownSeconds: Int64 = 0,
        pausedDurationMillis: Int64 = 0,
        position: Double? = nil,
        recordedPositionUnit: Int? = nil,
        insight: String? = nil,
        confirmedLongDuration: Bool = false
    ) {
        self.bookId = bookId
        self.startTime = startTime
        self.endTime = endTime
        self.elapsedSeconds = elapsedSeconds
        self.countdownSeconds = countdownSeconds
        self.pausedDurationMillis = pausedDurationMillis
        self.position = position
        self.recordedPositionUnit = recordedPositionUnit
        self.insight = insight
        self.confirmedLongDuration = confirmedLongDuration
    }

    private enum CodingKeys: String, CodingKey {
        case bookId, startTime, endTime, elapsedSeconds, countdownSeconds
        case pausedDurationMillis, position, recordedPositionUnit, insight, confirmedLongDuration
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bookId = try container.decode(Int64.self, forKey: .bookId)
        startTime = try container.decode(Int64.self, forKey: .startTime)
        endTime = try container.decode(Int64.self, forKey: .endTime)
        elapsedSeconds = try container.decode(Int64.self, forKey: .elapsedSeconds)
        countdownSeconds = try container.decodeIfPresent(Int64.self, forKey: .countdownSeconds) ?? 0
        pausedDurationMillis = try container.decodeIfPresent(Int64.self, forKey: .pausedDurationMillis) ?? 0
        position = try container.decodeIfPresent(Double.self, forKey: .position)
        recordedPositionUnit = try container.decodeIfPresent(Int.self, forKey: .recordedPositionUnit)
        insight = try container.decodeIfPresent(String.self, forKey: .insight)
        confirmedLongDuration = try container.decodeIfPresent(Bool.self, forKey: .confirmedLongDuration) ?? false
    }
}

/// Android `mapOf("id" to id)` 的创建响应。
public struct DesktopWebCreatedReadingSession: Codable, Sendable, Equatable {
    public let id: Int64

    public init(id: Int64) {
        self.id = id
    }
}

/// Android UpsertReadingRecordRequest。
public struct DesktopWebReadingRecordUpsertRequest: Codable, Sendable, Equatable {
    public let mode: String
    public let startTime: Int64?
    public let endTime: Int64?
    public let fuzzyReadDate: Int64?
    public let elapsedSeconds: Int64
    public let position: Double?
    public let recordedPositionUnit: Int?
    public let insight: String?

    public init(
        mode: String,
        startTime: Int64? = nil,
        endTime: Int64? = nil,
        fuzzyReadDate: Int64? = nil,
        elapsedSeconds: Int64,
        position: Double? = nil,
        recordedPositionUnit: Int? = nil,
        insight: String? = nil
    ) {
        self.mode = mode
        self.startTime = startTime
        self.endTime = endTime
        self.fuzzyReadDate = fuzzyReadDate
        self.elapsedSeconds = elapsedSeconds
        self.position = position
        self.recordedPositionUnit = recordedPositionUnit
        self.insight = insight
    }
}

/// Android WebReadingRecordDto。
public struct DesktopWebReadingRecord: Codable, Sendable, Equatable {
    public let id: Int64
    public let bookId: Int64
    public let mode: String
    public let startTime: Int64
    public let endTime: Int64
    public let fuzzyReadDate: Int64
    public let elapsedSeconds: Int64
    public let countdownSeconds: Int64
    public let pausedDurationMillis: Int64
    public let position: Double
    public let recordedPositionUnit: Int?
    public let insight: String
    public let createdTime: Int64
    public let updatedTime: Int64

    public init(
        id: Int64,
        bookId: Int64,
        mode: String,
        startTime: Int64,
        endTime: Int64,
        fuzzyReadDate: Int64,
        elapsedSeconds: Int64,
        countdownSeconds: Int64,
        pausedDurationMillis: Int64,
        position: Double,
        recordedPositionUnit: Int?,
        insight: String,
        createdTime: Int64,
        updatedTime: Int64
    ) {
        self.id = id
        self.bookId = bookId
        self.mode = mode
        self.startTime = startTime
        self.endTime = endTime
        self.fuzzyReadDate = fuzzyReadDate
        self.elapsedSeconds = elapsedSeconds
        self.countdownSeconds = countdownSeconds
        self.pausedDurationMillis = pausedDurationMillis
        self.position = position
        self.recordedPositionUnit = recordedPositionUnit
        self.insight = insight
        self.createdTime = createdTime
        self.updatedTime = updatedTime
    }
}

/// App 注入的阅读记录能力；实现必须经 App Repository 访问数据库。
public protocol DesktopWebReadingRecordPort: Sendable {
    /// 保存 Web 直接提交的完成态计时；任务取消时由 App Repository 的事务边界决定是否提交。
    func createReadingSession(_ request: DesktopWebReadingSessionCreateRequest) async throws -> Int64

    /// 读取一本有效书籍的完成态阅读记录并按 Android 三字段比较器排序。
    func readingRecords(bookID: Int64, sortOrder: String) async throws -> [DesktopWebReadingRecord]

    /// 按书籍和记录双重归属读取单条有效记录；冻结合同不限制记录状态。
    func readingRecord(bookID: Int64, recordID: Int64) async throws -> DesktopWebReadingRecord

    /// 创建精确或模糊阅读记录，并在正进度前移时同步书籍进度。
    func createReadingRecord(
        bookID: Int64,
        request: DesktopWebReadingRecordUpsertRequest
    ) async throws -> DesktopWebReadingRecord

    /// 全量替换阅读记录业务字段，同时保留原始创建时间。
    func updateReadingRecord(
        bookID: Int64,
        recordID: Int64,
        request: DesktopWebReadingRecordUpsertRequest
    ) async throws -> DesktopWebReadingRecord

    /// 软删除属于指定书籍的有效记录；冻结合同不限制记录状态。
    func deleteReadingRecord(bookID: Int64, recordID: Int64) async throws
}
