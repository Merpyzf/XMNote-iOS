import Foundation

/**
 * [INPUT]: 依赖 Foundation 的 Date/DateFormatter 进行时间格式化
 * [OUTPUT]: 对外提供 BookItem、BookshelfSnapshot、BookshelfItem、BookshelfOrderItem、BookshelfListContext、BookDetail、NoteExcerpt 等书籍域展示模型
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
nonisolated enum BookshelfItemID: Hashable, Sendable {
    case book(Int64)
    case group(Int64)
}

/// 首页书架浏览维度，用于控制书架内容层的只读展示形态。
enum BookshelfDimension: String, CaseIterable, Codable, Hashable, Sendable {
    case `default`
    case status
    case tag
    case source
    case rating
    case author
    case press

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
        case .press:
            return "出版社"
        }
    }
}

/// 书架布局模式，按书架维度持久化到本地轻量设置。
enum BookshelfLayoutMode: String, CaseIterable, Codable, Hashable, Sendable {
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

/// 书架排序模式，用于兼容默认书架排序入口判断。
enum BookshelfSortMode: String, Hashable, Sendable {
    case custom
    case criteria

    var title: String {
        switch self {
        case .custom:
            return "手动排序"
        case .criteria:
            return "条件排序"
        }
    }
}

/// 书架排序依据，按 Android display type 的可选排序语义收敛成 iOS 侧统一枚举。
enum BookshelfSortCriteria: String, CaseIterable, Codable, Hashable, Sendable {
    case custom
    case name
    case bookCount
    case rating

    var title: String {
        switch self {
        case .custom:
            return "手动排序"
        case .name:
            return "名称"
        case .bookCount:
            return "书籍数量"
        case .rating:
            return "评分"
        }
    }

    /// 返回指定维度允许展示和提交的排序依据。
    static func available(for dimension: BookshelfDimension) -> [BookshelfSortCriteria] {
        switch dimension {
        case .default:
            return [.custom, .name, .rating]
        case .status, .tag, .source:
            return [.custom, .bookCount, .name]
        case .rating:
            return [.rating, .bookCount]
        case .author, .press:
            return [.name, .bookCount]
        }
    }
}

/// 条件排序方向。
enum BookshelfSortOrder: String, CaseIterable, Codable, Hashable, Sendable {
    case ascending
    case descending

    var title: String {
        switch self {
        case .ascending:
            return "升序"
        case .descending:
            return "降序"
        }
    }
}

/// 书名在书架卡片上的展示策略，先作为设置语义沉淀，后续视觉细化继续复用。
enum BookshelfTitleDisplayMode: String, CaseIterable, Codable, Hashable, Sendable {
    case standard
    case compact
    case full

    var title: String {
        switch self {
        case .standard:
            return "默认"
        case .compact:
            return "紧凑"
        case .full:
            return "完整"
        }
    }
}

/// 删除分组时组内书籍回到默认书架的位置选择，等待删除与分组写入完成 Android 对齐后启用。
nonisolated enum GroupBooksPlacement: String, Hashable, Codable, Sendable {
    case start
    case end
}

/// 书架展示配置，按浏览维度保存布局、排序、分区与辅助信息偏好。
struct BookshelfDisplaySetting: Codable, Hashable, Sendable {
    static let defaultValue = BookshelfDisplaySetting()

    var layoutMode: BookshelfLayoutMode = .grid
    var columnCount: Int = 3
    var showsNoteCount: Bool = true
    var sortCriteria: BookshelfSortCriteria = .custom
    var sortOrder: BookshelfSortOrder = .ascending
    var isSectionEnabled: Bool = false
    var titleDisplayMode: BookshelfTitleDisplayMode = .standard

    var sortMode: BookshelfSortMode {
        sortCriteria == .custom ? .custom : .criteria
    }

    /// 为指定维度提供 Android 语义更接近的默认排序。
    static func defaultValue(for dimension: BookshelfDimension) -> BookshelfDisplaySetting {
        var setting = BookshelfDisplaySetting()
        switch dimension {
        case .default, .status, .tag, .source:
            setting.sortCriteria = .custom
        case .rating:
            setting.sortCriteria = .rating
            setting.sortOrder = .descending
        case .author, .press:
            setting.sortCriteria = .name
        }
        return setting
    }
}

/// 书架排序写入项，携带 Book/Group 稳定身份与当前置顶状态，供移动操作保持 Android 置顶边界。
nonisolated struct BookshelfOrderItem: Hashable, Sendable {
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
    let press: String
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
        press: String = "",
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
        self.press = press
        self.score = score
        self.noteCount = noteCount
    }
}

/// 书架聚合列表中的只读书籍行，作为导航路由载荷避免二级页直接访问数据库。
nonisolated struct BookshelfBookListItem: Identifiable, Hashable, Codable, Sendable {
    let id: Int64
    let title: String
    let author: String
    let cover: String
    let noteCount: Int

    /// 从书架书籍载荷裁剪出列表页需要的稳定展示字段。
    nonisolated init(payload: BookshelfBookPayload) {
        self.id = payload.id
        self.title = payload.name
        self.author = payload.author
        self.cover = payload.cover
        self.noteCount = payload.noteCount
    }

    /// 构建组内书籍等轻量来源的只读列表行。
    nonisolated init(
        id: Int64,
        title: String,
        author: String,
        cover: String,
        noteCount: Int
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.cover = cover
        self.noteCount = noteCount
    }
}

/// 书架二级列表上下文，标识二级列表应从 Repository 观察哪一类书籍集合。
nonisolated enum BookshelfListContext: Hashable, Codable, Sendable {
    case defaultGroup(Int64)
    case readStatus(Int64?)
    case tag(Int64?)
    case source(Int64?)
    case rating(Int64)
    case author(String)
    case press(String)

    var dimension: BookshelfDimension {
        switch self {
        case .defaultGroup:
            return .default
        case .readStatus:
            return .status
        case .tag:
            return .tag
        case .source:
            return .source
        case .rating:
            return .rating
        case .author:
            return .author
        case .press:
            return .press
        }
    }
}

/// 可提交排序写入的聚合上下文。
nonisolated enum BookshelfAggregateOrderContext: Hashable, Codable, Sendable {
    case readStatus
    case tag
    case source
}

/// 书架二级列表观察快照，由 Repository 实时生成而不是由路由携带静态书籍数组。
nonisolated struct BookshelfBookListSnapshot: Hashable, Sendable {
    static let empty = BookshelfBookListSnapshot(title: "", subtitle: "", books: [])

    let title: String
    let subtitle: String
    let books: [BookshelfBookListItem]
}

/// 书架二级只读列表路由载荷，承载分组、标签、来源、评分、作者、出版社等聚合入口。
nonisolated struct BookshelfBookListRoute: Hashable, Codable, Sendable {
    let context: BookshelfListContext
    let title: String
    let subtitleHint: String
}

/// 书架中的分组展示载荷，保留组名、数量和代表封面。
nonisolated struct BookshelfGroupPayload: Hashable, Sendable {
    let id: Int64
    let name: String
    let bookCount: Int
    let representativeCovers: [String]
    let books: [BookshelfBookListItem]
}

/// 书架分区，承载状态、评分等“标题 + 代表书籍条”的只读布局。
struct BookshelfSection: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let context: BookshelfListContext
    let orderID: Int64?
    let books: [BookshelfBookPayload]

    var count: Int {
        books.count
    }
}

/// 书架聚合卡，承载标签、来源、作者等“标题 + 数量 + 封面拼贴”的只读布局。
nonisolated struct BookshelfAggregateGroup: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let count: Int
    let context: BookshelfListContext
    let orderID: Int64?
    let representativeCovers: [String]
    let books: [BookshelfBookListItem]
}

/// 非默认维度聚合快照，供 UICollectionView 聚合入口统一渲染。
struct BookshelfAggregateSnapshot: Hashable, Sendable {
    static let empty = BookshelfAggregateSnapshot()

    var statusSections: [BookshelfSection] = []
    var tagGroups: [BookshelfAggregateGroup] = []
    var sourceGroups: [BookshelfAggregateGroup] = []
    var ratingSections: [BookshelfSection] = []
    var authorSections: [BookshelfAuthorSection] = []
    var pressGroups: [BookshelfAggregateGroup] = []
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
    var pressGroups: [BookshelfAggregateGroup] = []

    nonisolated var aggregateSnapshot: BookshelfAggregateSnapshot {
        BookshelfAggregateSnapshot(
            statusSections: statusSections,
            tagGroups: tagGroups,
            sourceGroups: sourceGroups,
            ratingSections: ratingSections,
            authorSections: authorSections,
            pressGroups: pressGroups
        )
    }

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
        case .press:
            return pressGroups.isEmpty
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
