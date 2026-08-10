/**
 * [INPUT]: 依赖 Foundation 提供跨层值语义与并发标记
 * [OUTPUT]: 对外提供 BookContentWorkspaceSnapshot、单书内容排序偏好及书评、相关分类、相关内容摘要模型
 * [POS]: Domain/Models 的书籍笔记域工作区模型，供 ContentRepository、BookDetailViewModel 与书籍详情页共享
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// Android 单书内容管理使用的持久化排序作用域；rawValue 与 ContentType 数据库协议保持一致。
nonisolated enum BookContentSortType: Int64, CaseIterable, Hashable, Sendable {
    case notes = 2
    case related = 3
    case reviews = 4
}

/// Android `sort.order` 的业务值；相关与书评仅接受时间规则，书摘额外接受位置规则。
nonisolated enum BookContentSortRule: Int64, CaseIterable, Hashable, Sendable {
    case createdDateAscending = 1
    case createdDateDescending = 2
    case positionAscending = 3
    case positionDescending = 4

    /// 返回当前内容类型允许写入的规则，避免页面把书摘专属位置规则写入其他类型。
    static func allowedRules(for type: BookContentSortType) -> [Self] {
        switch type {
        case .notes:
            [.createdDateAscending, .createdDateDescending, .positionAscending, .positionDescending]
        case .related, .reviews:
            [.createdDateAscending, .createdDateDescending]
        }
    }

    /// 返回排序菜单文案；位置规则只会出现在书摘域，时间规则可被三类内容复用。
    func title(for type: BookContentSortType) -> String {
        switch self {
        case .createdDateAscending:
            "最早记录优先"
        case .createdDateDescending:
            "最近记录优先"
        case .positionAscending:
            type == .notes ? "位置从前到后" : "最早记录优先"
        case .positionDescending:
            type == .notes ? "位置从后到前" : "最近记录优先"
        }
    }
}

/// 单本书三个内容类型互不串值的持久化排序快照。
nonisolated struct BookContentSortPreferences: Hashable, Sendable {
    let notes: BookContentSortRule
    let related: BookContentSortRule
    let reviews: BookContentSortRule

    /// Android 未持久化时的静态兜底；Repository 会进一步按全书 weread_range 决定书摘首次默认值。
    static let fallback = Self(
        notes: .positionAscending,
        related: .createdDateAscending,
        reviews: .createdDateAscending
    )

    /// 按当前工作区类型读取规则，供页面菜单与 Repository 查询共享同一值。
    func rule(for type: BookContentSortType) -> BookContentSortRule {
        switch type {
        case .notes: notes
        case .related: related
        case .reviews: reviews
        }
    }
}

/// 新建自定义相关分类的可见范围；全局分类会出现在所有书籍中。
nonisolated enum BookContentCategoryScope: Hashable, Sendable {
    case currentBook
    case allBooks
}

/// 书籍详情工作区中的书评摘要，保留原始 HTML 并允许 ViewModel 缓存纯文本预览。
nonisolated struct BookContentReviewItem: Identifiable, Hashable, Sendable {
    let id: Int64
    let title: String
    let contentHTML: String
    let contentPlainText: String
    let createdDate: Int64

    /// 构建书评摘要；Repository 可只提供 HTML，纯文本由页面状态源在后台生成。
    init(
        id: Int64,
        title: String,
        contentHTML: String,
        contentPlainText: String = "",
        createdDate: Int64
    ) {
        self.id = id
        self.title = title
        self.contentHTML = contentHTML
        self.contentPlainText = contentPlainText
        self.createdDate = createdDate
    }
}

/// 书籍详情可见的相关分类；系统分类只读，相关书籍分类由独立选书链路负责。
nonisolated struct BookContentCategoryOption: Identifiable, Hashable, Sendable {
    let id: Int64
    let title: String
    let order: Int64
    let contentCount: Int
    let ownerBookID: Int64
    let isHidden: Bool
    let isSystemDefault: Bool
    let isRelatedBook: Bool

    var isGlobal: Bool { ownerBookID == 0 }
}

/// 相关条目的业务目标，区分普通内容查看与相关书籍详情跳转。
nonisolated enum BookContentRelatedDestination: Hashable, Sendable {
    case content(contentID: Int64)
    case book(bookID: Int64)
}

/// 书籍详情工作区中的相关条目摘要，以 category_content 关系 ID 维持稳定列表身份。
nonisolated struct BookContentRelatedItem: Identifiable, Hashable, Sendable {
    let id: Int64
    let destination: BookContentRelatedDestination
    let title: String
    let subtitle: String
    let contentHTML: String
    let contentPlainText: String
    let coverURL: String
    let createdDate: Int64
    let isPlaceholder: Bool

    /// 构建普通相关内容或相关书籍摘要；纯文本预览可由 ViewModel 后台补齐。
    init(
        id: Int64,
        destination: BookContentRelatedDestination,
        title: String,
        subtitle: String,
        contentHTML: String,
        contentPlainText: String = "",
        coverURL: String,
        createdDate: Int64,
        isPlaceholder: Bool = false
    ) {
        self.id = id
        self.destination = destination
        self.title = title
        self.subtitle = subtitle
        self.contentHTML = contentHTML
        self.contentPlainText = contentPlainText
        self.coverURL = coverURL
        self.createdDate = createdDate
        self.isPlaceholder = isPlaceholder
    }
}

/// 按 Android 分类顺序聚合的单个相关内容分区。
nonisolated struct BookContentRelatedSection: Identifiable, Hashable, Sendable {
    let id: Int64
    let title: String
    let items: [BookContentRelatedItem]
}

/// 书籍详情笔记域工作区快照，集中承载书评、相关分区与新建分类候选。
nonisolated struct BookContentWorkspaceSnapshot: Hashable, Sendable {
    let reviews: [BookContentReviewItem]
    let relatedSections: [BookContentRelatedSection]
    let categories: [BookContentCategoryOption]
    let sortPreferences: BookContentSortPreferences

    static let empty = Self(
        reviews: [],
        relatedSections: [],
        categories: [],
        sortPreferences: .fallback
    )

    var categoryOptions: [BookContentCategoryOption] {
        categories.filter { !$0.isHidden && !$0.isRelatedBook }
    }

    var relatedItemCount: Int {
        relatedSections.reduce(0) { $0 + $1.items.count }
    }
}
