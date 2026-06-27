import Foundation

/**
 * [INPUT]: 依赖 Foundation 的 Date/DateFormatter 进行时间格式化
 * [OUTPUT]: 对外提供 BookItem、BookshelfSnapshot、BookshelfItem、BookshelfOrderItem、BookshelfListContext、BookshelfBatchEditOptions、BookshelfMoveGroupOption、BookCollectionSummary、BookCollectionDisplaySetting（含书单首页分组偏好）、BookCollectionBookMetadataEditInput、BookDetail、NoteExcerpt 等书籍域展示模型
 * [POS]: Domain/Models 的书籍聚合模型定义，被 BookViewModel 与 BookRepository 实现共同消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 书摘位置单位展示策略，按 Android BookPositionUnit 对齐：0=进度、1=位置、2=页码。
nonisolated enum NotePositionUnitFormatter {
    /// 生成无标签的位置展示文本，供卡片 footer 组合时间等元信息。
    nonisolated static func footerText(position: String, unit: Int64) -> String? {
        guard !position.isEmpty else { return nil }
        if unit == 0 {
            return "\(position)%"
        }
        return position
    }

    /// 生成带单位标签的位置展示文本，供详情页独立展示位置元信息。
    nonisolated static func labeledFooterText(position: String, unit: Int64) -> String? {
        guard let value = footerText(position: position, unit: unit) else { return nil }
        return "\(title(for: unit))：\(value)"
    }

    /// 返回位置单位标题，未知值按 Android 页码兜底口径处理。
    nonisolated static func title(for unit: Int64) -> String {
        switch unit {
        case 0:
            return "进度"
        case 1:
            return "位置"
        default:
            return "页码"
        }
    }
}

/// 书架条目模型，承载书籍列表页展示所需的核心字段。
nonisolated struct BookItem: Identifiable {
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
nonisolated enum BookshelfDimension: String, CaseIterable, Codable, Hashable, Sendable {
    case `default`
    case status
    case tag
    case source
    case rating
    case author
    case press

    nonisolated var title: String {
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
nonisolated enum BookshelfLayoutMode: String, CaseIterable, Codable, Hashable, Sendable {
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
nonisolated enum BookshelfSortMode: String, Hashable, Sendable {
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
nonisolated enum BookshelfSortCriteria: String, CaseIterable, Codable, Hashable, Sendable {
    case custom
    case createdDate
    case modifiedDate
    case publishDate
    case name
    case noteCount
    case bookCount
    case rating
    case readDoneDate
    case totalReadingTime
    case readStatus
    case tagName
    case authorName
    case pressName
    case source
    case readingProgress

    var title: String {
        switch self {
        case .custom:
            return "手动排序"
        case .createdDate:
            return "创建时间"
        case .modifiedDate:
            return "修改时间"
        case .publishDate:
            return "出版时间"
        case .name:
            return "名称"
        case .noteCount:
            return "书摘数量"
        case .bookCount:
            return "书籍数量"
        case .rating:
            return "评分"
        case .readDoneDate:
            return "读完时间"
        case .totalReadingTime:
            return "阅读时长"
        case .readStatus:
            return "阅读状态"
        case .tagName:
            return "标签名称"
        case .authorName:
            return "作者名称"
        case .pressName:
            return "出版社名称"
        case .source:
            return "书籍来源"
        case .readingProgress:
            return "阅读进度"
        }
    }

    var systemImage: String {
        switch self {
        case .custom:
            return "hand.draw"
        case .createdDate:
            return "calendar.badge.plus"
        case .modifiedDate:
            return "clock.arrow.circlepath"
        case .publishDate:
            return "calendar"
        case .name:
            return "textformat.abc"
        case .noteCount:
            return "note.text"
        case .bookCount:
            return "books.vertical"
        case .rating:
            return "star"
        case .readDoneDate:
            return "checkmark.circle"
        case .totalReadingTime:
            return "timer"
        case .readStatus:
            return "circle.dotted"
        case .tagName:
            return "tag"
        case .authorName:
            return "person.text.rectangle"
        case .pressName:
            return "building.columns"
        case .source:
            return "tray"
        case .readingProgress:
            return "chart.line.uptrend.xyaxis"
        }
    }

    var ascendingTitle: String {
        switch self {
        case .createdDate, .modifiedDate, .publishDate, .readDoneDate:
            return "由远及近"
        case .name, .tagName, .authorName, .pressName, .source:
            return "A-Z"
        case .noteCount, .bookCount:
            return "由少到多"
        case .rating, .readingProgress:
            return "由低到高"
        case .totalReadingTime:
            return "由短到长"
        case .readStatus:
            return "由前到后"
        case .custom:
            return "升序"
        }
    }

    var descendingTitle: String {
        switch self {
        case .createdDate, .modifiedDate, .publishDate, .readDoneDate:
            return "由近及远"
        case .name, .tagName, .authorName, .pressName, .source:
            return "Z-A"
        case .noteCount, .bookCount:
            return "由多到少"
        case .rating, .readingProgress:
            return "由高到低"
        case .totalReadingTime:
            return "由长到短"
        case .readStatus:
            return "由后到前"
        case .custom:
            return "降序"
        }
    }

    nonisolated var supportsSection: Bool {
        switch self {
        case .createdDate, .modifiedDate, .publishDate, .name, .readDoneDate, .readStatus, .tagName, .authorName, .pressName, .source:
            return true
        case .custom, .noteCount, .bookCount, .rating, .totalReadingTime, .readingProgress:
            return false
        }
    }

    nonisolated var sectionToggleTitle: String {
        switch self {
        case .createdDate, .modifiedDate, .readDoneDate:
            return "按月份分区"
        case .publishDate:
            return "按出版年份分区"
        case .name, .readStatus, .tagName, .authorName, .pressName, .source:
            return "按标题分区"
        case .custom, .noteCount, .bookCount, .rating, .totalReadingTime, .readingProgress:
            return "按条件分区"
        }
    }

    /// 返回指定维度允许展示和提交的排序依据。
    static func available(for dimension: BookshelfDimension) -> [BookshelfSortCriteria] {
        switch dimension {
        case .default:
            return [.custom, .noteCount, .totalReadingTime, .readingProgress, .rating, .createdDate, .modifiedDate, .readDoneDate, .publishDate, .name]
        case .status:
            return [.custom, .readStatus, .bookCount]
        case .tag:
            return [.custom, .createdDate, .bookCount]
        case .source:
            return [.custom, .source, .bookCount]
        case .rating:
            return [.rating, .bookCount]
        case .author:
            return [.authorName, .bookCount]
        case .press:
            return [.pressName, .bookCount]
        }
    }

    /// 返回二级书籍列表允许展示和提交的排序依据，对齐 Android `getDefaultSubDisplaySetting`。
    static func availableForBookList(for dimension: BookshelfDimension) -> [BookshelfSortCriteria] {
        switch dimension {
        case .default:
            return [.custom] + secondaryBookCriteria
        case .rating:
            return [.createdDate, .modifiedDate, .publishDate, .name, .noteCount, .rating, .readDoneDate, .totalReadingTime, .readingProgress]
        case .status, .tag, .source, .author, .press:
            return secondaryBookCriteria
        }
    }

    private static var secondaryBookCriteria: [BookshelfSortCriteria] {
        [.noteCount, .totalReadingTime, .readingProgress, .rating, .createdDate, .modifiedDate, .readDoneDate, .publishDate, .name]
    }
}

/// 条件排序方向。
nonisolated enum BookshelfSortOrder: String, CaseIterable, Codable, Hashable, Sendable {
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
nonisolated enum BookshelfTitleDisplayMode: String, CaseIterable, Codable, Hashable, Sendable {
    case standard
    case compact
    case full

    var title: String {
        switch self {
        case .standard:
            return "默认显示"
        case .compact:
            return "滚动显示"
        case .full:
            return "两行显示"
        }
    }

    var subtitle: String {
        switch self {
        case .standard:
            return "单行显示，超出省略"
        case .compact:
            return "单行显示，超出时自动滚动"
        case .full:
            return "最多显示两行，超出省略"
        }
    }
}

/// 书架显示设置的持久化作用域，区分首页聚合维度和二级书籍列表。
nonisolated enum BookshelfDisplaySettingScope: String, Codable, Hashable, Sendable {
    case main
    case bookList
}

/// 删除分组时组内书籍回到默认书架的位置选择，等待删除与分组写入完成 Android 对齐后启用。
nonisolated enum GroupBooksPlacement: String, Hashable, Codable, Sendable {
    case start
    case end
}

/// 书架展示配置，按浏览维度保存布局、排序、分区与辅助信息偏好。
nonisolated struct BookshelfDisplaySetting: Codable, Hashable, Sendable {
    static let defaultValue = BookshelfDisplaySetting()

    var layoutMode: BookshelfLayoutMode = .grid
    var columnCount: Int = 3
    var showsNoteCount: Bool = true
    var sortCriteria: BookshelfSortCriteria = .custom
    var sortOrder: BookshelfSortOrder = .descending
    var isSectionEnabled: Bool = false
    var pinnedInAllSorts: Bool = true
    var titleDisplayMode: BookshelfTitleDisplayMode = .standard

    var sortMode: BookshelfSortMode {
        sortCriteria == .custom ? .custom : .criteria
    }

    /// 使用默认参数构建显示设置，兼容旧本地设置缺少新增字段时的解码回退。
    init(
        layoutMode: BookshelfLayoutMode = .grid,
        columnCount: Int = 3,
        showsNoteCount: Bool = true,
        sortCriteria: BookshelfSortCriteria = .custom,
        sortOrder: BookshelfSortOrder = .descending,
        isSectionEnabled: Bool = false,
        pinnedInAllSorts: Bool = true,
        titleDisplayMode: BookshelfTitleDisplayMode = .standard
    ) {
        self.layoutMode = layoutMode
        self.columnCount = columnCount
        self.showsNoteCount = showsNoteCount
        self.sortCriteria = sortCriteria
        self.sortOrder = sortOrder
        self.isSectionEnabled = isSectionEnabled
        self.pinnedInAllSorts = pinnedInAllSorts
        self.titleDisplayMode = titleDisplayMode
    }

    /// 从本地轻量设置解码；新增字段缺失时按 Android 默认显示语义补齐。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            layoutMode: try container.decodeIfPresent(BookshelfLayoutMode.self, forKey: .layoutMode) ?? .grid,
            columnCount: try container.decodeIfPresent(Int.self, forKey: .columnCount) ?? 3,
            showsNoteCount: try container.decodeIfPresent(Bool.self, forKey: .showsNoteCount) ?? true,
            sortCriteria: try container.decodeIfPresent(BookshelfSortCriteria.self, forKey: .sortCriteria) ?? .custom,
            sortOrder: try container.decodeIfPresent(BookshelfSortOrder.self, forKey: .sortOrder) ?? .descending,
            isSectionEnabled: try container.decodeIfPresent(Bool.self, forKey: .isSectionEnabled) ?? false,
            pinnedInAllSorts: try container.decodeIfPresent(Bool.self, forKey: .pinnedInAllSorts) ?? true,
            titleDisplayMode: try container.decodeIfPresent(BookshelfTitleDisplayMode.self, forKey: .titleDisplayMode) ?? .standard
        )
    }

    private enum CodingKeys: String, CodingKey {
        case layoutMode
        case columnCount
        case showsNoteCount
        case sortCriteria
        case sortOrder
        case isSectionEnabled
        case pinnedInAllSorts
        case titleDisplayMode
    }

    /// 为指定维度提供 Android 语义更接近的默认排序。
    nonisolated static func defaultValue(for dimension: BookshelfDimension) -> BookshelfDisplaySetting {
        var setting = BookshelfDisplaySetting()
        switch dimension {
        case .default, .status, .tag, .source:
            setting.sortCriteria = .custom
            setting.sortOrder = .descending
        case .rating:
            setting.sortCriteria = .rating
            setting.sortOrder = .ascending
            setting.pinnedInAllSorts = false
        case .author:
            setting.sortCriteria = .authorName
            setting.sortOrder = .ascending
            setting.pinnedInAllSorts = false
        case .press:
            setting.sortCriteria = .pressName
            setting.sortOrder = .ascending
            setting.pinnedInAllSorts = false
        }
        return setting
    }

    /// 为二级书籍列表提供 Android `getDefaultSubDisplaySetting` 的默认排序。
    nonisolated static func defaultBookListValue(for dimension: BookshelfDimension) -> BookshelfDisplaySetting {
        var setting = BookshelfDisplaySetting()
        switch dimension {
        case .default:
            setting.sortCriteria = .custom
        case .rating:
            setting.sortCriteria = .readDoneDate
        case .status, .tag, .source, .author, .press:
            setting.sortCriteria = .createdDate
        }
        setting.sortOrder = .descending
        setting.pinnedInAllSorts = true
        return setting
    }
}

/// 书架条目的条件排序元数据，避免默认书架 Book/Group 在 Repository 外再访问数据库。
nonisolated struct BookshelfItemSortMetadata: Hashable, Sendable {
    static let empty = BookshelfItemSortMetadata()

    var createdDate: Int64 = 0
    var modifiedDate: Int64 = 0
    var publishDate: Int64 = 0
    var noteCount: Int = 0
    var rating: Int64 = 0
    var readDoneDate: Int64 = 0
    var totalReadingTime: Int64 = 0
    var readingProgress: Double?
    var bookCount: Int = 1
}

/// 书架排序写入项，携带 Book/Group 稳定身份与当前置顶状态，供移动操作保持 Android 置顶边界。
nonisolated struct BookshelfOrderItem: Hashable, Sendable {
    let id: BookshelfItemID
    let isPinned: Bool
}

/// 二级书籍列表排序写入项，携带 Book 身份与当前置顶状态，供默认分组内移动保持置顶边界。
nonisolated struct BookshelfBookListOrderItem: Hashable, Sendable {
    let id: Int64
    let isPinned: Bool
}

/// 来源选项分区，区分“我的来源”与 Android 默认内置来源。
nonisolated enum BookshelfSourceCategory: Hashable, Sendable {
    case mine
    case appDefault

    var title: String {
        switch self {
        case .mine:
            return "我的来源"
        case .appDefault:
            return "默认来源"
        }
    }
}

/// 批量来源 Sheet 选项，包含标题与分区元数据。
nonisolated struct BookshelfSourceOption: Identifiable, Hashable, Sendable {
    let id: Int64
    let title: String
    let category: BookshelfSourceCategory
}

/// 批量移组 Sheet 选项，包含分组标题、书籍数量与代表封面。
nonisolated struct BookshelfMoveGroupOption: Identifiable, Hashable, Sendable {
    let id: Int64
    let title: String
    let bookCount: Int
    let representativeCovers: [String]
}

/// 批量加入书单 Sheet 使用的轻量书单摘要，排除年度书单，仅承载手动书单候选项。
nonisolated struct BookCollectionSummary: Identifiable, Hashable, Sendable {
    let id: Int64
    let title: String
    let description: String
    let bookCount: Int
    let representativeCovers: [String]
}

/// 书单类型，区分用户手动维护的书单与系统按读完年份同步的年度书单。
nonisolated enum BookCollectionKind: String, Codable, Hashable, Sendable {
    case manual
    case annual

    var title: String {
        switch self {
        case .manual:
            return "我的书单"
        case .annual:
            return "年度书单"
        }
    }
}

/// 书单首页展示方式，控制书单卡片在列表与网格之间切换。
nonisolated enum BookCollectionDisplayMode: String, CaseIterable, Codable, Hashable, Sendable {
    case list
    case grid

    var title: String {
        switch self {
        case .list:
            return "列表"
        case .grid:
            return "网格"
        }
    }

    var systemImage: String {
        switch self {
        case .list:
            return "list.bullet"
        case .grid:
            return "square.grid.2x2"
        }
    }
}

/// 书单封面排布方式，控制集合封面是偏自然堆叠还是规整拼贴。
nonisolated enum BookCollectionCoverArrangement: String, CaseIterable, Codable, Hashable, Sendable {
    case stacked
    case regular

    var title: String {
        switch self {
        case .stacked:
            return "堆叠"
        case .regular:
            return "规整"
        }
    }
}

/// 书单首页显示偏好，独立于书架显示设置以避免混入书籍列表专属语义。
nonisolated struct BookCollectionDisplaySetting: Codable, Hashable, Sendable {
    static let defaultValue = BookCollectionDisplaySetting()

    var displayMode: BookCollectionDisplayMode = .list
    var coverArrangement: BookCollectionCoverArrangement = .stacked
    var showsStatistics: Bool = true
    var selectedKind: BookCollectionKind = .manual

    /// 使用默认参数构建书单显示设置，兼容旧本地设置缺少新增字段时的解码回退。
    init(
        displayMode: BookCollectionDisplayMode = .list,
        coverArrangement: BookCollectionCoverArrangement = .stacked,
        showsStatistics: Bool = true,
        selectedKind: BookCollectionKind = .manual
    ) {
        self.displayMode = displayMode
        self.coverArrangement = coverArrangement
        self.showsStatistics = showsStatistics
        self.selectedKind = selectedKind
    }

    /// 从本地轻量设置解码；字段缺失时回到当前书单首页的默认展示语义。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            displayMode: try container.decodeIfPresent(BookCollectionDisplayMode.self, forKey: .displayMode) ?? .list,
            coverArrangement: try container.decodeIfPresent(BookCollectionCoverArrangement.self, forKey: .coverArrangement) ?? .stacked,
            showsStatistics: try container.decodeIfPresent(Bool.self, forKey: .showsStatistics) ?? true,
            selectedKind: try container.decodeIfPresent(BookCollectionKind.self, forKey: .selectedKind) ?? .manual
        )
    }

    private enum CodingKeys: String, CodingKey {
        case displayMode
        case coverArrangement
        case showsStatistics
        case selectedKind
    }
}

/// 书单列表项，承载列表首屏展示、排序和书单展示域统计所需字段；年度书单的 `finishedCount` 使用年度投影书籍数，手动书单按当前已读状态统计。
nonisolated struct BookCollectionListItem: Identifiable, Hashable, Sendable {
    let id: Int64
    let title: String
    let description: String
    let kind: BookCollectionKind
    let order: Int64
    let year: Int?
    let bookCount: Int
    let finishedCount: Int
    let targetReadCount: Int?
    let representativeCovers: [String]
}

/// 书单列表快照，按 Android “我的书单 / 年度书单”事实分组，但交由 iOS 页面用分段结构表达。
nonisolated struct BookCollectionListSnapshot: Hashable, Sendable {
    static let empty = BookCollectionListSnapshot(manualCollections: [], annualCollections: [])

    let manualCollections: [BookCollectionListItem]
    let annualCollections: [BookCollectionListItem]

    var isEmpty: Bool {
        manualCollections.isEmpty && annualCollections.isEmpty
    }
}

/// 书单内的书籍关系展示项，保留 collection_book relation 字段，避免丢失收藏理由、排序与时间戳语义。
nonisolated struct BookCollectionBookItem: Identifiable, Hashable, Sendable {
    let id: Int64
    let collectionID: Int64
    let book: BookshelfBookListItem
    let summary: String
    let summaryPlainText: String
    let recommend: String
    let isPlaceholder: Bool
    let order: Int64
    let createdDate: Int64
    let updatedDate: Int64
}

/// 书单内单本书籍元信息编辑输入，对齐 Android 书单编辑页可修改的书籍字段与 relation 收藏理由。
nonisolated struct BookCollectionBookMetadataEditInput: Hashable, Sendable {
    let collectionBookID: Int64
    let bookID: Int64
    let title: String
    let author: String
    let press: String
    let pubDate: String
    let coverURL: String
    let recommend: String
}

/// 书单添加书籍的统一输入，覆盖本地有效书和可作为书单占位书保存的远端/导入草稿。
nonisolated enum BookCollectionBookSelectionInput: Hashable, Sendable {
    case localBook(id: Int64)
    case placeholder(BookCollectionPlaceholderBookDraft)
}

/// 书单占位书草稿，对齐 Android `book.is_deleted = 1` 的书单关系语义。
nonisolated struct BookCollectionPlaceholderBookDraft: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let rawTitle: String
    let author: String
    let translator: String
    let press: String
    let isbn: String
    let pubDate: String
    let summary: String
    let coverURL: String
    let doubanId: Int?
    let totalPages: Int?
    let totalWordCount: Int?
    let preferredBookType: BookEntryBookType?
    let preferredProgressUnit: BookEntryProgressUnit?
    let recommend: String

    init(
        id: String = UUID().uuidString,
        title: String,
        rawTitle: String = "",
        author: String = "",
        translator: String = "",
        press: String = "",
        isbn: String = "",
        pubDate: String = "",
        summary: String = "",
        coverURL: String = "",
        doubanId: Int? = nil,
        totalPages: Int? = nil,
        totalWordCount: Int? = nil,
        preferredBookType: BookEntryBookType? = nil,
        preferredProgressUnit: BookEntryProgressUnit? = nil,
        recommend: String = ""
    ) {
        self.id = id
        self.title = title
        self.rawTitle = rawTitle
        self.author = author
        self.translator = translator
        self.press = press
        self.isbn = isbn
        self.pubDate = pubDate
        self.summary = summary
        self.coverURL = coverURL
        self.doubanId = doubanId
        self.totalPages = totalPages
        self.totalWordCount = totalWordCount
        self.preferredBookType = preferredBookType
        self.preferredProgressUnit = preferredProgressUnit
        self.recommend = recommend
    }

    init(remoteSelection: BookPickerRemoteSelection) {
        let seed = remoteSelection.seed
        self.init(
            id: remoteSelection.result.id,
            title: seed.title.isEmpty ? remoteSelection.result.title : seed.title,
            rawTitle: seed.rawTitle,
            author: seed.author.isEmpty ? remoteSelection.result.author : seed.author,
            translator: seed.translator,
            press: seed.press,
            isbn: seed.isbn,
            pubDate: seed.pubDate,
            summary: seed.summary.isEmpty ? remoteSelection.result.summary : seed.summary,
            coverURL: seed.coverURL.isEmpty ? remoteSelection.result.coverURL : seed.coverURL,
            doubanId: seed.doubanId,
            totalPages: seed.totalPages,
            totalWordCount: seed.totalWordCount,
            preferredBookType: seed.preferredBookType,
            preferredProgressUnit: seed.preferredProgressUnit,
            recommend: ""
        )
    }
}

/// 微信读书书单导入预览，保存前只存在于内存，避免解析异常时写入半成品数据。
nonisolated struct BookCollectionImportPreview: Identifiable, Hashable, Sendable {
    let id: String
    let sourceURL: String
    let title: String
    let description: String
    let books: [BookCollectionImportPreviewBook]

    init(
        id: String = UUID().uuidString,
        sourceURL: String,
        title: String,
        description: String,
        books: [BookCollectionImportPreviewBook]
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.title = title
        self.description = description
        self.books = books
    }
}

/// 微信读书书单导入预览中的单本书条目，保留推荐语到 `collection_book.recommend`。
nonisolated struct BookCollectionImportPreviewBook: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let author: String
    let coverURL: String
    let summary: String
    let recommend: String

    init(
        id: String = UUID().uuidString,
        title: String,
        author: String,
        coverURL: String = "",
        summary: String = "",
        recommend: String = ""
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.coverURL = coverURL
        self.summary = summary
        self.recommend = recommend
    }

    var placeholderDraft: BookCollectionPlaceholderBookDraft {
        BookCollectionPlaceholderBookDraft(
            id: id,
            title: title,
            author: author,
            summary: summary,
            coverURL: coverURL,
            recommend: recommend
        )
    }
}

/// 书单导出或分享生成后的临时文件载体，供系统分享面板使用。
nonisolated struct BookCollectionGeneratedFile: Identifiable, Hashable, Sendable {
    let id: UUID
    let title: String
    let url: URL
    let urls: [URL]
    let kind: Kind

    enum Kind: Hashable, Sendable {
        case export
        case shareImage
    }

    init(title: String, url: URL, kind: Kind) {
        self.init(title: title, urls: [url], kind: kind)
    }

    init(title: String, urls: [URL], kind: Kind) {
        self.id = UUID()
        self.title = title
        self.url = urls[0]
        self.urls = urls
        self.kind = kind
    }
}

/// 书单详情快照，汇总 collection 元信息、书籍关系和年度目标信息。
nonisolated struct BookCollectionDetail: Identifiable, Hashable, Sendable {
    let id: Int64
    let title: String
    let description: String
    let kind: BookCollectionKind
    let order: Int64
    let year: Int?
    let targetReadCount: Int?
    let books: [BookCollectionBookItem]

    var bookCount: Int { books.count }

    /// 返回书单展示域的读完数：年度书单按年度投影集合计数，手动书单按当前书籍已读状态计数；不是全局阅读统计或读完次数。
    var finishedCount: Int {
        switch kind {
        case .annual:
            return bookCount
        case .manual:
            return books.filter { $0.book.readStatusId == BookEntryReadingStatus.finished.rawValue }.count
        }
    }
}

/// 书单编辑输入，仅覆盖 Android 当前允许保存的标题与简介字段。
nonisolated struct BookCollectionFormInput: Hashable, Sendable {
    let title: String
    let description: String
}

/// 书架批量编辑可选项，统一承载标签、来源与阅读状态 Sheet 所需数据。
nonisolated struct BookshelfBatchEditOptions: Hashable, Sendable {
    static let empty = BookshelfBatchEditOptions(
        tags: [],
        sources: [],
        readStatuses: [],
        initialTagIDs: [],
        initialSourceID: nil,
        initialReadStatusID: nil,
        initialReadStatusChangedAt: nil,
        initialRatingScore: nil
    )

    let tags: [BookEditorNamedOption]
    let sources: [BookshelfSourceOption]
    let readStatuses: [BookEditorNamedOption]
    let initialTagIDs: [Int64]
    let initialSourceID: Int64?
    let initialReadStatusID: Int64?
    let initialReadStatusChangedAt: Int64?
    let initialRatingScore: Int64?
}

/// 批量设置阅读状态的写入输入，封装状态时间与读完评分语义。
nonisolated struct BookshelfBatchReadStatusInput: Hashable, Sendable {
    let statusID: Int64
    let changedAt: Int64
    let ratingScore: Int64?
}

/// 书架写操作反馈，区分处理中、成功、警告与错误，供 iOS 内联提示按语义展示。
nonisolated struct BookshelfActionFeedback: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case processing
        case success
        case warning
        case error
    }

    let kind: Kind
    let message: String
}

/// 书架条目内容，统一表达书籍卡片与分组卡片。
nonisolated enum BookshelfItemContent: Hashable, Sendable {
    case book(BookshelfBookPayload)
    case group(BookshelfGroupPayload)
}

/// 书架条目统一模型，承载排序、置顶和具体展示内容。
nonisolated struct BookshelfItem: Identifiable, Hashable, Sendable {
    let id: BookshelfItemID
    let pinned: Bool
    let pinOrder: Int64
    let sortOrder: Int64
    var sortMetadata: BookshelfItemSortMetadata = .empty
    let bookListItem: BookshelfBookListItem?
    let content: BookshelfItemContent

    /// 构建书架混排条目，书籍条目可携带完整列表行展示模型，分组条目保持为空。
    nonisolated init(
        id: BookshelfItemID,
        pinned: Bool,
        pinOrder: Int64,
        sortOrder: Int64,
        sortMetadata: BookshelfItemSortMetadata = .empty,
        bookListItem: BookshelfBookListItem? = nil,
        content: BookshelfItemContent
    ) {
        self.id = id
        self.pinned = pinned
        self.pinOrder = pinOrder
        self.sortOrder = sortOrder
        self.sortMetadata = sortMetadata
        self.bookListItem = bookListItem
        self.content = content
    }

    nonisolated var title: String {
        switch content {
        case .book(let payload):
            return payload.name
        case .group(let payload):
            return payload.name
        }
    }
}

/// 书架中的单本书展示载荷，保留默认网格渲染所需字段。
nonisolated struct BookshelfBookPayload: Hashable, Sendable {
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

/// 二级书籍列表行的轻量标签，保留导航恢复所需的稳定展示字段。
nonisolated struct BookshelfBookListTag: Identifiable, Hashable, Codable, Sendable {
    let id: Int64
    let name: String
    let order: Int64
}

/// 书架聚合列表中的只读书籍行，作为导航路由载荷避免二级页直接访问数据库。
nonisolated struct BookshelfBookListItem: Identifiable, Hashable, Codable, Sendable {
    let id: Int64
    let title: String
    let author: String
    let cover: String
    let readStatusId: Int64
    let readStatusName: String
    let readStatusBadgeTitle: String
    let sourceName: String
    let press: String
    let pubDateText: String
    let score: Int64
    let noteCount: Int
    let tags: [BookshelfBookListTag]
    let pinned: Bool
    let createdDate: Int64
    let modifiedDate: Int64
    let readDoneDate: Int64
    let totalReadingTime: Int64
    let readingProgressText: String
    let bookmarkText: String

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case author
        case cover
        case readStatusId
        case readStatusName
        case readStatusBadgeTitle
        case sourceName
        case press
        case pubDateText
        case score
        case noteCount
        case tags
        case pinned
        case createdDate
        case modifiedDate
        case readDoneDate
        case totalReadingTime
        case readingProgressText
        case bookmarkText
    }

    /// 从书架书籍载荷裁剪出列表页需要的稳定展示字段。
    nonisolated init(
        payload: BookshelfBookPayload,
        pinned: Bool = false,
        pubDateText: String = "",
        tags: [BookshelfBookListTag] = [],
        createdDate: Int64 = 0,
        modifiedDate: Int64 = 0,
        readDoneDate: Int64 = 0,
        totalReadingTime: Int64 = 0,
        readingProgressText: String = "",
        bookmarkText: String = "",
        readStatusBadgeTitle: String = ""
    ) {
        self.id = payload.id
        self.title = payload.name
        self.author = payload.author
        self.cover = payload.cover
        self.readStatusId = payload.readStatusId
        self.readStatusName = payload.readStatusName
        self.readStatusBadgeTitle = readStatusBadgeTitle
        self.sourceName = payload.sourceName
        self.press = payload.press
        self.pubDateText = pubDateText
        self.score = payload.score
        self.noteCount = payload.noteCount
        self.tags = tags
        self.pinned = pinned
        self.createdDate = createdDate
        self.modifiedDate = modifiedDate
        self.readDoneDate = readDoneDate
        self.totalReadingTime = totalReadingTime
        self.readingProgressText = readingProgressText
        self.bookmarkText = bookmarkText
    }

    /// 构建组内书籍等轻量来源的只读列表行。
    nonisolated init(
        id: Int64,
        title: String,
        author: String,
        cover: String,
        readStatusId: Int64 = 0,
        readStatusName: String = "",
        readStatusBadgeTitle: String = "",
        sourceName: String = "",
        press: String = "",
        pubDateText: String = "",
        score: Int64 = 0,
        noteCount: Int,
        tags: [BookshelfBookListTag] = [],
        pinned: Bool = false,
        createdDate: Int64 = 0,
        modifiedDate: Int64 = 0,
        readDoneDate: Int64 = 0,
        totalReadingTime: Int64 = 0,
        readingProgressText: String = "",
        bookmarkText: String = ""
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.cover = cover
        self.readStatusId = readStatusId
        self.readStatusName = readStatusName
        self.readStatusBadgeTitle = readStatusBadgeTitle
        self.sourceName = sourceName
        self.press = press
        self.pubDateText = pubDateText
        self.score = score
        self.noteCount = noteCount
        self.tags = tags
        self.pinned = pinned
        self.createdDate = createdDate
        self.modifiedDate = modifiedDate
        self.readDoneDate = readDoneDate
        self.totalReadingTime = totalReadingTime
        self.readingProgressText = readingProgressText
        self.bookmarkText = bookmarkText
    }

    /// 解码书籍列表行，兼容旧路由恢复数据中缺少状态与来源字段的场景。
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int64.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        author = try container.decode(String.self, forKey: .author)
        cover = try container.decode(String.self, forKey: .cover)
        readStatusId = try container.decodeIfPresent(Int64.self, forKey: .readStatusId) ?? 0
        readStatusName = try container.decodeIfPresent(String.self, forKey: .readStatusName) ?? ""
        readStatusBadgeTitle = try container.decodeIfPresent(String.self, forKey: .readStatusBadgeTitle) ?? readStatusName
        sourceName = try container.decodeIfPresent(String.self, forKey: .sourceName) ?? ""
        press = try container.decodeIfPresent(String.self, forKey: .press) ?? ""
        pubDateText = try container.decodeIfPresent(String.self, forKey: .pubDateText) ?? ""
        score = try container.decodeIfPresent(Int64.self, forKey: .score) ?? 0
        noteCount = try container.decode(Int.self, forKey: .noteCount)
        tags = try container.decodeIfPresent([BookshelfBookListTag].self, forKey: .tags) ?? []
        pinned = try container.decode(Bool.self, forKey: .pinned)
        createdDate = try container.decodeIfPresent(Int64.self, forKey: .createdDate) ?? 0
        modifiedDate = try container.decodeIfPresent(Int64.self, forKey: .modifiedDate) ?? 0
        readDoneDate = try container.decodeIfPresent(Int64.self, forKey: .readDoneDate) ?? 0
        totalReadingTime = try container.decodeIfPresent(Int64.self, forKey: .totalReadingTime) ?? 0
        readingProgressText = try container.decodeIfPresent(String.self, forKey: .readingProgressText) ?? ""
        bookmarkText = try container.decodeIfPresent(String.self, forKey: .bookmarkText) ?? ""
    }

    /// 编码书籍列表行，供导航恢复与本地临时快照保持完整展示上下文。
    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(author, forKey: .author)
        try container.encode(cover, forKey: .cover)
        try container.encode(readStatusId, forKey: .readStatusId)
        try container.encode(readStatusName, forKey: .readStatusName)
        try container.encode(readStatusBadgeTitle, forKey: .readStatusBadgeTitle)
        try container.encode(sourceName, forKey: .sourceName)
        try container.encode(press, forKey: .press)
        try container.encode(pubDateText, forKey: .pubDateText)
        try container.encode(score, forKey: .score)
        try container.encode(noteCount, forKey: .noteCount)
        try container.encode(tags, forKey: .tags)
        try container.encode(pinned, forKey: .pinned)
        try container.encode(createdDate, forKey: .createdDate)
        try container.encode(modifiedDate, forKey: .modifiedDate)
        try container.encode(readDoneDate, forKey: .readDoneDate)
        try container.encode(totalReadingTime, forKey: .totalReadingTime)
        try container.encode(readingProgressText, forKey: .readingProgressText)
        try container.encode(bookmarkText, forKey: .bookmarkText)
    }

    /// 按当前排序依据返回 Android 列表/网格同源的辅助展示文案。
    nonisolated func sortAuxiliaryText(for criteria: BookshelfSortCriteria) -> String? {
        switch criteria {
        case .createdDate:
            return Self.formattedDayText(createdDate)
        case .modifiedDate:
            return Self.formattedDayText(modifiedDate)
        case .publishDate:
            let text = pubDateText.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : "出版 \(text)"
        case .readDoneDate:
            return Self.formattedDayText(readDoneDate) ?? "未读完"
        case .rating:
            return String(format: "评分 %.1f", Double(score) / 10.0)
        case .totalReadingTime:
            return "阅读 \(totalReadingTimeText)"
        case .readingProgress:
            let text = readingProgressText.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : "进度 \(text)"
        case .custom, .name, .noteCount, .bookCount, .readStatus, .tagName, .authorName, .pressName, .source:
            return nil
        }
    }

    /// 将阅读总秒数转换为 Android `toReadableTimeDuration(spaceDelimiter = true)` 同源文案。
    nonisolated var totalReadingTimeText: String {
        Self.formattedDuration(totalReadingTime)
    }

    private nonisolated static func formattedDayText(_ timestamp: Int64) -> String? {
        guard timestamp > 0 else { return nil }
        let date = Date(timeIntervalSince1970: Double(timestamp) / 1000.0)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy 年 M 月 d 日"
        return formatter.string(from: date)
    }

    private nonisolated static func formattedDuration(_ seconds: Int64) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let restSeconds = seconds % 60
        if hours > 0 {
            if minutes == 0 {
                return "\(hours) 小时"
            }
            return "\(hours) 小时 \(minutes) 分钟"
        }
        if minutes > 0 {
            if restSeconds > 0 {
                return "\(minutes) 分钟 \(restSeconds) 秒"
            }
            return "\(minutes) 分钟"
        }
        return "\(max(0, restSeconds)) 秒"
    }
}

/// 二级书籍列表分区，承载 Android 分区排序语义下的标题与书籍行。
nonisolated struct BookshelfBookListSection: Identifiable, Hashable, Sendable {
    let id: String
    let title: String?
    let books: [BookshelfBookListItem]
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
    static let empty = BookshelfBookListSnapshot(title: "", subtitle: "", sections: [])

    let title: String
    let subtitle: String
    let sections: [BookshelfBookListSection]

    var books: [BookshelfBookListItem] {
        sections.flatMap(\.books)
    }

    /// 兼容非分区列表构建；后续分区由 Repository 根据显示设置生成。
    init(
        title: String,
        subtitle: String,
        books: [BookshelfBookListItem]
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            sections: [
                BookshelfBookListSection(
                    id: "books",
                    title: nil,
                    books: books
                )
            ]
        )
    }

    /// 构建已完成分区格式化的二级列表快照。
    init(
        title: String,
        subtitle: String,
        sections: [BookshelfBookListSection]
    ) {
        self.title = title
        self.subtitle = subtitle
        self.sections = sections
    }
}

/// 书架二级只读列表路由载荷，承载分组、标签、来源、评分、作者、出版社等聚合入口。
nonisolated struct BookshelfBookListRoute: Hashable, Codable, Sendable {
    let context: BookshelfListContext
    let title: String
    let subtitleHint: String

    /// 构建二级列表路由，仅携带可恢复的语义上下文，书籍数据统一由 Repository 实时读取。
    init(
        context: BookshelfListContext,
        title: String,
        subtitleHint: String
    ) {
        self.context = context
        self.title = title
        self.subtitleHint = subtitleHint
    }

    private enum CodingKeys: String, CodingKey {
        case context
        case title
        case subtitleHint
    }

    /// 从可恢复路由载荷解码二级列表，恢复路径保持实时读取。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.context = try container.decode(BookshelfListContext.self, forKey: .context)
        self.title = try container.decode(String.self, forKey: .title)
        self.subtitleHint = try container.decode(String.self, forKey: .subtitleHint)
    }

    /// 编码可恢复的语义路由，避免把书籍列表数据写入 scene 状态。
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(context, forKey: .context)
        try container.encode(title, forKey: .title)
        try container.encode(subtitleHint, forKey: .subtitleHint)
    }

    static func == (lhs: BookshelfBookListRoute, rhs: BookshelfBookListRoute) -> Bool {
        lhs.context == rhs.context
            && lhs.title == rhs.title
            && lhs.subtitleHint == rhs.subtitleHint
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(context)
        hasher.combine(title)
        hasher.combine(subtitleHint)
    }
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
nonisolated struct BookshelfSection: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let context: BookshelfListContext
    let orderID: Int64?
    var sortMetadata: BookshelfItemSortMetadata = .empty
    let books: [BookshelfBookPayload]

    nonisolated var count: Int {
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
    var sortMetadata: BookshelfItemSortMetadata = .empty
    let representativeCovers: [String]
    let books: [BookshelfBookListItem]
}

/// 默认书架分区，承载条件排序分区标题与 Book/Group 混排条目。
nonisolated struct BookshelfDefaultSection: Identifiable, Hashable, Sendable {
    let id: String
    let title: String?
    let items: [BookshelfItem]
}

/// 非默认维度聚合快照，供 UICollectionView 聚合入口统一渲染。
nonisolated struct BookshelfAggregateSnapshot: Hashable, Sendable {
    static let empty = BookshelfAggregateSnapshot()

    var statusSections: [BookshelfSection] = []
    var tagGroups: [BookshelfAggregateGroup] = []
    var sourceGroups: [BookshelfAggregateGroup] = []
    var ratingSections: [BookshelfSection] = []
    var authorSections: [BookshelfAuthorSection] = []
    var pressGroups: [BookshelfAggregateGroup] = []
}

/// 作者字母分区，承载右侧索引和两列作者聚合卡。
nonisolated struct BookshelfAuthorSection: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let authors: [BookshelfAggregateGroup]
}

/// 首页书架只读快照，一次性提供各浏览维度所需的数据。
nonisolated struct BookshelfSnapshot: Hashable, Sendable {
    static let empty = BookshelfSnapshot()

    var defaultItems: [BookshelfItem] = []
    var defaultSections: [BookshelfDefaultSection] = []
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
            return defaultSections.isEmpty && defaultItems.isEmpty
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

/// 书籍详情可点击属性类型，用于把作者与出版社继续导向现有二级书籍列表。
nonisolated enum BookDetailAttributeKind: Hashable, Sendable {
    case author
    case translator
    case press
    case pubDate
    case isbn
    case source
    case readStatus

    var title: String {
        switch self {
        case .author:
            return "作者"
        case .translator:
            return "译者"
        case .press:
            return "出版社"
        case .pubDate:
            return "出版时间"
        case .isbn:
            return "ISBN"
        case .source:
            return "来源"
        case .readStatus:
            return "阅读状态"
        }
    }
}

/// 书籍详情页资料属性，属性值保留原始展示文本。
nonisolated struct BookDetailAttribute: Identifiable, Hashable, Sendable {
    let kind: BookDetailAttributeKind
    let value: String

    var id: String { "\(kind)-\(value)" }
}

/// 书籍详情页目录条目，按 Android v41 章节层级字段展示缩进。
nonisolated struct BookDetailChapter: Identifiable, Hashable, Sendable {
    let id: Int64
    let title: String
    let level: Int64
    let order: Int64
}

/// 书籍详情页模型，聚合资料字段、目录、书摘数量与阅读状态。
nonisolated struct BookDetail: Identifiable, Sendable {
    let id: Int64
    let name: String
    let author: String
    let cover: String
    let press: String
    let noteCount: Int
    let readStatusName: String
    let summary: String
    let summaryPlainText: String
    let authorIntro: String
    let authorIntroPlainText: String
    let attributes: [BookDetailAttribute]
    let chapters: [BookDetailChapter]

    /// 构建详情页展示模型；纯文本预览由页面状态源按需预处理，Repository 可只提供原始 HTML 字段。
    init(
        id: Int64,
        name: String,
        author: String,
        cover: String,
        press: String,
        noteCount: Int,
        readStatusName: String,
        summary: String,
        summaryPlainText: String = "",
        authorIntro: String,
        authorIntroPlainText: String = "",
        attributes: [BookDetailAttribute],
        chapters: [BookDetailChapter]
    ) {
        self.id = id
        self.name = name
        self.author = author
        self.cover = cover
        self.press = press
        self.noteCount = noteCount
        self.readStatusName = readStatusName
        self.summary = summary
        self.summaryPlainText = summaryPlainText
        self.authorIntro = authorIntro
        self.authorIntroPlainText = authorIntroPlainText
        self.attributes = attributes
        self.chapters = chapters
    }
}

/// 书籍详情中的书摘条目，包含正文、感想、位置与时间信息。
nonisolated struct NoteExcerpt: Identifiable, Sendable {
    let id: Int64
    let content: String
    let contentPlainText: String
    let idea: String
    let ideaPlainText: String
    let position: String
    let positionUnit: Int64
    let includeTime: Bool
    let createdDate: Int64

    /// 构建书摘展示模型；纯文本预览由页面状态源按需预处理，Repository 可只提供原始 HTML 字段。
    init(
        id: Int64,
        content: String,
        contentPlainText: String = "",
        idea: String,
        ideaPlainText: String = "",
        position: String,
        positionUnit: Int64,
        includeTime: Bool,
        createdDate: Int64
    ) {
        self.id = id
        self.content = content
        self.contentPlainText = contentPlainText
        self.idea = idea
        self.ideaPlainText = ideaPlainText
        self.position = position
        self.positionUnit = positionUnit
        self.includeTime = includeTime
        self.createdDate = createdDate
    }

    var footerText: String {
        var parts: [String] = []
        if let positionText = NotePositionUnitFormatter.footerText(position: position, unit: positionUnit) {
            parts.append(positionText)
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
