/**
 * [INPUT]: 依赖 Foundation 的 Codable、Locale、TimeZone、URL 与 UUID，接收导出范围、目标、设置和会员快照
 * [OUTPUT]: 对外提供跨原生界面与 Desktop Web 共用的导出领域模型、稳定目标标识、进度、产物和结果语义
 * [POS]: Domain 层导出合同；不感知 SwiftUI、数据库、网络客户端或具体文件生成器
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 导出的业务数据类型，决定可选目标与数据快照结构。
nonisolated enum ExportKind: String, CaseIterable, Codable, Sendable {
    case noteExcerpt = "note_excerpt"
    case bookInformation = "book_information"

    var title: String {
        switch self {
        case .noteExcerpt: "书摘"
        case .bookInformation: "书籍信息"
        }
    }

}

/// 一次导出的书籍范围；明确 ID 顺序与书单关系顺序都属于请求语义。
nonisolated enum ExportScope: Hashable, Codable, Sendable {
    case allBooks
    case bookIDs([Int64])
    case collectionID(Int64)
}

/// 导出目标使用稳定字符串作为跨版本合同，绝不依赖界面下标或 Android 枚举 ordinal。
nonisolated enum ExportTarget: String, CaseIterable, Codable, Sendable {
    case yuque
    case notion
    case oneNote = "one_note"
    case siYuan = "si_yuan"
    case obsidian
    case pdf
    case markdown
    case text
    case csv

    /// 返回当前数据类型支持的完整产品目标列表。
    static func supportedTargets(for kind: ExportKind) -> [ExportTarget] {
        switch kind {
        case .noteExcerpt:
            [.yuque, .notion, .oneNote, .siYuan, .obsidian, .pdf, .markdown, .text]
        case .bookInformation:
            [.csv, .notion]
        }
    }

    var title: String {
        switch self {
        case .yuque: "语雀"
        case .notion: "Notion"
        case .oneNote: "OneNote"
        case .siYuan: "思源笔记"
        case .obsidian: "Obsidian"
        case .pdf: "PDF"
        case .markdown: "Markdown"
        case .text: "TXT"
        case .csv: "CSV"
        }
    }

    /// 兼容既有 Desktop Web 请求字符串；领域持久化仍使用 rawValue 稳定标识。
    var desktopWebIdentifier: String {
        switch self {
        case .oneNote: "onenote"
        case .siYuan: "siyuan"
        default: rawValue
        }
    }

    var isLocalFile: Bool {
        switch self {
        case .pdf, .markdown, .text, .csv: true
        case .yuque, .notion, .oneNote, .siYuan, .obsidian: false
        }
    }

    /// Markdown 与 TXT 免费，其余目标沿用 Android 高级版限制。
    var requiresPremium: Bool {
        self != .markdown && self != .text
    }

    /// 校验目标与数据类型的组合，阻止跨层调用绕过界面选择约束。
    func supports(_ kind: ExportKind) -> Bool {
        Self.supportedTargets(for: kind).contains(self)
    }
}

/// 书摘、关联笔记与书评的不可变选择快照。
nonisolated struct ExportContentSelection: Codable, Hashable, Sendable {
    var includesNotes: Bool
    var includesRelatedNotes: Bool
    var includesReviews: Bool

    static let all = ExportContentSelection(
        includesNotes: true,
        includesRelatedNotes: true,
        includesReviews: true
    )

    var hasSelection: Bool {
        includesNotes || includesRelatedNotes || includesReviews
    }
}

/// Android 书籍信息导出的 29 个稳定字段标识与默认顺序。
nonisolated enum ExportBookField: String, CaseIterable, Codable, Sendable {
    case cover
    case name
    case author
    case translator
    case press
    case publishDate = "publish_date"
    case isbn
    case source
    case purchaseDate = "purchase_date"
    case price
    case readStatus = "read_status"
    case readScore = "read_score"
    case readScoreDisplay = "read_score_display"
    case readTag = "read_tag"
    case group
    case douban
    case bookType = "book_type"
    case readStatusChangedDate = "read_status_changed_date"
    case readingProgress = "reading_progress"
    case lastReadingDate = "last_reading_date"
    case totalPagination = "total_pagination"
    case wordCount = "word_count"
    case totalReadingTime = "total_reading_time"
    case readDoneCount = "read_done_count"
    case noteCount = "note_count"
    case reviewCount = "review_count"
    case relevantCount = "relevant_count"
    case createdDate = "created_date"
    case updatedDate = "updated_date"

    /// Android CSV 当前明确不输出的五个派生字段，即使用户设置为启用也会排除。
    var isCSVOutputField: Bool {
        ![.readScoreDisplay, .noteCount, .reviewCount, .relevantCount, .updatedDate].contains(self)
    }

    var title: String {
        switch self {
        case .cover: "封面"
        case .name: "书名"
        case .author: "作者"
        case .translator: "译者"
        case .press: "出版社"
        case .publishDate: "出版年月"
        case .isbn: "ISBN"
        case .source: "来源"
        case .purchaseDate: "购入日期"
        case .price: "价格"
        case .readStatus: "阅读状态"
        case .readScore: "我的评分"
        case .readScoreDisplay: "评分展示"
        case .readTag: "标签"
        case .group: "分组"
        case .douban: "豆瓣"
        case .bookType: "书籍类型"
        case .readStatusChangedDate: "状态更新时间"
        case .readingProgress: "阅读进度"
        case .lastReadingDate: "最后阅读"
        case .totalPagination: "总页数"
        case .wordCount: "字数"
        case .totalReadingTime: "累计阅读时长（分钟）"
        case .readDoneCount: "读完次数"
        case .noteCount: "书摘数"
        case .reviewCount: "书评数"
        case .relevantCount: "关联笔记数"
        case .createdDate: "加入书库时间"
        case .updatedDate: "最近修改时间"
        }
    }
}

/// 用户可排序并启停的书籍字段条目；字段身份与开关一起持久化，避免数组位置承担语义。
nonisolated struct ExportBookFieldSelection: Codable, Hashable, Sendable {
    let field: ExportBookField
    var isEnabled: Bool
}

/// 非敏感导出设置；凭据只存在 Keychain，不进入 Codable 设置快照。
nonisolated struct ExportSettingsSnapshot: Codable, Hashable, Sendable {
    var content: ExportContentSelection
    var includesDateTime: Bool
    var includesPage: Bool
    var includesTags: Bool
    var includesBookInformation: Bool
    var pdfReadingFontSize: Double
    var pdfBookFontSize: Double
    var pdfKeepsItemTogether: Bool
    var yuqueRepositoryID: String
    var oneNoteSectionName: String
    var siYuanHost: String
    var siYuanPort: Int
    var siYuanNotebookID: String
    var obsidianHost: String
    var obsidianDirectory: String
    var obsidianExportsTags: Bool
    var obsidianPinnedCertificateSHA256: String
    var notionDataSourceID: String
    var bookFields: [ExportBookFieldSelection]
    var lastNoteTarget: ExportTarget
    var lastBookTarget: ExportTarget

    static let androidDefault = ExportSettingsSnapshot(
        content: .all,
        includesDateTime: true,
        includesPage: true,
        includesTags: true,
        includesBookInformation: true,
        pdfReadingFontSize: 11,
        pdfBookFontSize: 11,
        pdfKeepsItemTogether: true,
        yuqueRepositoryID: "",
        oneNoteSectionName: "书摘导出",
        siYuanHost: "",
        siYuanPort: 6806,
        siYuanNotebookID: "",
        obsidianHost: "",
        obsidianDirectory: "",
        obsidianExportsTags: true,
        obsidianPinnedCertificateSHA256: "",
        notionDataSourceID: "",
        bookFields: ExportBookField.allCases.map { ExportBookFieldSelection(field: $0, isEnabled: true) },
        lastNoteTarget: .markdown,
        lastBookTarget: .csv
    )
}

/// 一次执行的冻结请求；调用后界面设置变化不会影响进行中的文件或远端写入。
nonisolated struct ExportRequest: Sendable {
    let kind: ExportKind
    let scope: ExportScope
    let target: ExportTarget
    let settings: ExportSettingsSnapshot
    let isPremium: Bool
    let nowMilliseconds: Int64
    let localeIdentifier: String
    let timeZoneIdentifier: String
    let confirmedNotionPageRebuildBookIDs: Set<Int64>

    /// 用显式时钟与区域创建可复现请求，默认值只在用户点击执行的瞬间求值一次。
    init(
        kind: ExportKind,
        scope: ExportScope,
        target: ExportTarget,
        settings: ExportSettingsSnapshot,
        isPremium: Bool,
        nowMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
        localeIdentifier: String = Locale.current.identifier,
        timeZoneIdentifier: String = TimeZone.current.identifier,
        confirmedNotionPageRebuildBookIDs: Set<Int64> = []
    ) {
        self.kind = kind
        self.scope = scope
        self.target = target
        self.settings = settings
        self.isPremium = isPremium
        self.nowMilliseconds = nowMilliseconds
        self.localeIdentifier = localeIdentifier
        self.timeZoneIdentifier = timeZoneIdentifier
        self.confirmedNotionPageRebuildBookIDs = confirmedNotionPageRebuildBookIDs
    }
}

/// Repository 一次性读取的中立快照；生成器不再回访数据库。
nonisolated struct ExportSnapshot: Sendable {
    let books: [ExportBookSnapshot]
}

/// 单书完整导出快照，暂复用已验证的 Data 层业务投影，不向生成器暴露数据库连接。
nonisolated struct ExportBookSnapshot: Sendable {
    let book: DesktopWebBookSnapshot
    let chapters: [DesktopWebChapterSnapshot]
    let notes: [DesktopWebBookNoteSnapshot]
    let reviews: [DesktopWebBookReviewSnapshot]
    let relatedNotes: [DesktopWebRelatedNoteSnapshot]
}

/// 导出执行阶段，用于原生界面和 Desktop Web 统一展示。
nonisolated enum ExportProgressPhase: String, Codable, Sendable {
    case preflighting
    case readingSnapshot
    case generating
    case uploading
    case finishing
}

/// 节流后的导出进度；Repository 保证对外发布频率不高于每秒十次。
nonisolated struct ExportProgress: Sendable {
    let phase: ExportProgressPhase
    let completedUnits: Int
    let totalUnits: Int
    let message: String

    var fractionCompleted: Double {
        guard totalUnits > 0 else { return 0 }
        return min(1, max(0, Double(completedUnits) / Double(totalUnits)))
    }
}

/// 可分享或保存的本地文件产物。
nonisolated struct ExportArtifact: Sendable, Hashable {
    let fileName: String
    let mediaType: String
    let fileURL: URL
}

/// 导出失败类型区分安全重试、不可盲目重试与远端状态未知。
nonisolated enum ExportFailureDisposition: String, Codable, Sendable {
    case retryable
    case nonRetryable
    case resultUncertain
}

/// 失败后的显式恢复动作；只描述可以由用户确认触发的窄范围操作，不把重试语义塞进文案。
nonisolated enum ExportRecoveryAction: String, Codable, Sendable {
    case confirmNotionPageRebuild = "confirm_notion_page_rebuild"
}

/// 单书或目标级结构化失败，不用字符串拼接丢失重试语义。
nonisolated struct ExportFailure: Error, Sendable {
    let bookID: Int64?
    let bookName: String?
    let target: ExportTarget
    let message: String
    let disposition: ExportFailureDisposition
    let recoveryAction: ExportRecoveryAction?

    init(
        bookID: Int64?,
        bookName: String?,
        target: ExportTarget,
        message: String,
        disposition: ExportFailureDisposition,
        recoveryAction: ExportRecoveryAction? = nil
    ) {
        self.bookID = bookID
        self.bookName = bookName
        self.target = target
        self.message = message
        self.disposition = disposition
        self.recoveryAction = recoveryAction
    }
}

/// 临时文件持有票据；分享或保存完成后由调用方显式清理，遗忘时 deinit 仍兜底回收。
nonisolated final class ArtifactTicket: @unchecked Sendable, Identifiable {
    let id = UUID()
    let artifacts: [ExportArtifact]
    private let rootURL: URL
    private let lock = NSLock()
    private var isCleaned = false

    init(rootURL: URL, artifacts: [ExportArtifact]) {
        self.rootURL = rootURL
        self.artifacts = artifacts
    }

    deinit {
        cleanup()
    }

    /// 幂等清理本次任务的专属临时目录；锁只保护一次性文件删除标记，不跨线程执行用户代码。
    func cleanup() {
        lock.lock()
        guard !isCleaned else {
            lock.unlock()
            return
        }
        isCleaned = true
        lock.unlock()
        try? FileManager.default.removeItem(at: rootURL)
    }
}

/// 统一导出结果允许本地文件、远端部分成功以及结构化失败同时存在。
nonisolated struct ExportResult: Sendable {
    let requestedBookCount: Int
    let successCount: Int
    let failures: [ExportFailure]
    let artifactTicket: ArtifactTicket?

    var isCompleteSuccess: Bool {
        successCount == requestedBookCount && failures.isEmpty
    }

    /// 只有全部失败都被 Repository 明确标记为可安全重试时，界面才允许重复整次请求。
    var canSafelyRetry: Bool {
        !failures.isEmpty && failures.allSatisfy { $0.disposition == .retryable }
    }

    /// 结果不确定表示远端可能已经完成写入，用户必须先到目标服务核对，不能盲目重试。
    var hasUncertainRemoteResult: Bool {
        failures.contains { $0.disposition == .resultUncertain }
    }

    /// 只返回确实需要用户确认重建的书籍 ID，避免整批重复写入已成功或其他失败书籍。
    var notionPageRebuildBookIDs: Set<Int64> {
        Set(failures.compactMap { failure in
            guard failure.recoveryAction == .confirmNotionPageRebuild else { return nil }
            return failure.bookID
        })
    }
}
