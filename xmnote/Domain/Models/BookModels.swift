import Foundation

/**
 * [INPUT]: 依赖 Foundation 的 Date/DateFormatter 进行时间格式化
 * [OUTPUT]: 对外提供 BookItem、BookshelfSnapshot、BookshelfItem、BookshelfOrderItem、BookDetail、NoteExcerpt 等书籍域展示模型
 * [POS]: Domain/Models 的书籍聚合模型定义，被 BookViewModel 与 BookRepository 实现共同消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 书架条目模型，承载书籍列表页展示所需的核心字段。
struct BookItem: Identifiable {
    let id: Int64
    let name: String
    let author: String
    let cover: String
    let readStatusId: Int64
    let noteCount: Int
    let pinned: Bool
}

/// 书架条目的稳定身份，区分书籍与分组，避免双表自增 ID 在 UI 与写入意图中混淆。
enum BookshelfItemID: Hashable, Sendable {
    case book(Int64)
    case group(Int64)
}

/// 首页书架浏览维度，用于控制书架内容层的只读展示形态。
enum BookshelfDimension: String, CaseIterable, Hashable, Sendable {
    case `default`
    case status
    case tag
    case source
    case rating
    case author

    var title: String {
        switch self {
        case .default:
            return "默认"
        case .status:
            return "状态"
        case .tag:
            return "标签"
        case .source:
            return "来源"
        case .rating:
            return "评分"
        case .author:
            return "作者"
        }
    }
}

/// 书架布局模式，本轮仅影响本地 UI 展示，不写入数据库或同步字段。
enum BookshelfLayoutMode: String, CaseIterable, Hashable, Sendable {
    case grid
    case list

    var title: String {
        switch self {
        case .grid:
            return "网格"
        case .list:
            return "列表"
        }
    }
}

/// 书架排序模式，本轮仅显示当前读取语义，不开放写入排序。
enum BookshelfSortMode: String, Hashable, Sendable {
    case custom

    var title: String {
        switch self {
        case .custom:
            return "手动排序"
        }
    }
}

/// 书架展示配置，本轮仅保存在内存中，用于控制只读 UI 密度与辅助信息。
struct BookshelfDisplaySetting: Hashable, Sendable {
    static let defaultValue = BookshelfDisplaySetting()

    var layoutMode: BookshelfLayoutMode = .grid
    var columnCount: Int = 3
    var showsNoteCount: Bool = true
    var sortMode: BookshelfSortMode = .custom
}

/// 书架排序写入项，携带 Book/Group 稳定身份与当前置顶状态，供移动操作保持 Android 置顶边界。
struct BookshelfOrderItem: Hashable, Sendable {
    let id: BookshelfItemID
    let isPinned: Bool
}

/// 书架条目内容，统一表达书籍卡片与分组卡片。
enum BookshelfItemContent: Hashable, Sendable {
    case book(BookshelfBookPayload)
    case group(BookshelfGroupPayload)
}

/// 书架条目统一模型，承载排序、置顶和具体展示内容。
struct BookshelfItem: Identifiable, Hashable, Sendable {
    let id: BookshelfItemID
    let pinned: Bool
    let pinOrder: Int64
    let sortOrder: Int64
    let content: BookshelfItemContent

    var title: String {
        switch content {
        case .book(let payload):
            return payload.name
        case .group(let payload):
            return payload.name
        }
    }
}

/// 书架中的单本书展示载荷，保留默认网格渲染所需字段。
struct BookshelfBookPayload: Hashable, Sendable {
    let id: Int64
    let name: String
    let author: String
    let cover: String
    let readStatusId: Int64
    let readStatusName: String
    let sourceId: Int64
    let sourceName: String
    let score: Int64
    let noteCount: Int

    /// 构建书架书籍展示载荷，聚合维度字段提供默认值以兼容既有调用。
    nonisolated init(
        id: Int64,
        name: String,
        author: String,
        cover: String,
        readStatusId: Int64,
        readStatusName: String = "",
        sourceId: Int64 = 0,
        sourceName: String = "",
        score: Int64 = 0,
        noteCount: Int
    ) {
        self.id = id
        self.name = name
        self.author = author
        self.cover = cover
        self.readStatusId = readStatusId
        self.readStatusName = readStatusName
        self.sourceId = sourceId
        self.sourceName = sourceName
        self.score = score
        self.noteCount = noteCount
    }
}

/// 书架中的分组展示载荷，保留组名、数量和代表封面。
struct BookshelfGroupPayload: Hashable, Sendable {
    let id: Int64
    let name: String
    let bookCount: Int
    let representativeCovers: [String]
}

/// 书架分区，承载状态、评分等“标题 + 代表书籍条”的只读布局。
struct BookshelfSection: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let books: [BookshelfBookPayload]

    var count: Int {
        books.count
    }
}

/// 书架聚合卡，承载标签、来源、作者等“标题 + 数量 + 封面拼贴”的只读布局。
struct BookshelfAggregateGroup: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let count: Int
    let representativeCovers: [String]
}

/// 作者字母分区，承载右侧索引和两列作者聚合卡。
struct BookshelfAuthorSection: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let authors: [BookshelfAggregateGroup]
}

/// 首页书架只读快照，一次性提供各浏览维度所需的数据。
struct BookshelfSnapshot: Hashable, Sendable {
    static let empty = BookshelfSnapshot()

    var defaultItems: [BookshelfItem] = []
    var statusSections: [BookshelfSection] = []
    var tagGroups: [BookshelfAggregateGroup] = []
    var sourceGroups: [BookshelfAggregateGroup] = []
    var ratingSections: [BookshelfSection] = []
    var authorSections: [BookshelfAuthorSection] = []

    /// 判断指定维度是否没有可展示内容，供 ViewModel 派生空态。
    func isEmpty(for dimension: BookshelfDimension) -> Bool {
        switch dimension {
        case .default:
            return defaultItems.isEmpty
        case .status:
            return statusSections.isEmpty
        case .tag:
            return tagGroups.isEmpty
        case .source:
            return sourceGroups.isEmpty
        case .rating:
            return ratingSections.isEmpty
        case .author:
            return authorSections.isEmpty
        }
    }
}

/// 书籍详情页模型，聚合书名、作者、出版社、书摘数量与阅读状态。
struct BookDetail: Identifiable {
    let id: Int64
    let name: String
    let author: String
    let cover: String
    let press: String
    let noteCount: Int
    let readStatusName: String
}

/// 书籍详情中的书摘条目，包含正文、感想、位置与时间信息。
struct NoteExcerpt: Identifiable {
    let id: Int64
    let content: String
    let idea: String
    let position: String
    let positionUnit: Int64
    let includeTime: Bool
    let createdDate: Int64

    var footerText: String {
        var parts: [String] = []
        if !position.isEmpty {
            let unit = switch positionUnit {
            case 1: "位置"
            case 2: "%"
            default: "页"
            }
            parts.append(positionUnit == 2 ? "\(position)\(unit)" : "第\(position)\(unit)")
        }
        if includeTime, createdDate > 0 {
            parts.append(Self.formatDate(createdDate))
        }
        return parts.joined(separator: " | ")
    }

    private static func formatDate(_ timestamp: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(timestamp) / 1000.0)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"
        return formatter.string(from: date)
    }
}
