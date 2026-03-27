/**
 * [INPUT]: 依赖 Foundation 与 BookSearchSource，定义通用书籍选择流的跨层模型与配置语义
 * [OUTPUT]: 对外提供 BookPickerBook、BookPickerScope、BookPickerSelectionMode、BookPickerConfiguration、BookPickerResult
 * [POS]: Domain/Models 的书籍选择领域模型，被 BookPickerView、ViewModel 与调用业务页共同消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 书籍选择流的本地书籍结果模型，统一承接本地查询、已选回显与创建成功回填。
struct BookPickerBook: Identifiable, Hashable, Codable, Sendable {
    let id: Int64
    let title: String
    let author: String
    let coverURL: String
    let positionUnit: Int64
    let totalPosition: Int64
    let totalPagination: Int64
}

/// 书籍选择流的来源范围配置。
enum BookPickerScope: Hashable, Codable, Sendable {
    case local
    case online
    case both
}

/// 书籍选择流的选择模式配置。
enum BookPickerSelectionMode: Hashable, Codable, Sendable {
    case single
    case multiple
}

/// 书籍选择流的公共配置，统一收口标题、来源范围、多选能力与默认上下文。
struct BookPickerConfiguration: Hashable, Codable, Sendable {
    var title: String
    var scope: BookPickerScope
    var selectionMode: BookPickerSelectionMode
    var allowsManualCreate: Bool
    var defaultQuery: String
    var preselectedBooks: [BookPickerBook]
    var onlineSources: [BookSearchSource]
    var preferredOnlineSource: BookSearchSource?

    init(
        title: String = "选择书籍",
        scope: BookPickerScope,
        selectionMode: BookPickerSelectionMode,
        allowsManualCreate: Bool = false,
        defaultQuery: String = "",
        preselectedBooks: [BookPickerBook] = [],
        onlineSources: [BookSearchSource] = BookSearchSource.allCases,
        preferredOnlineSource: BookSearchSource? = nil
    ) {
        self.title = title
        self.scope = scope
        self.selectionMode = selectionMode
        self.allowsManualCreate = allowsManualCreate
        self.defaultQuery = defaultQuery
        self.preselectedBooks = preselectedBooks
        self.onlineSources = onlineSources
        self.preferredOnlineSource = preferredOnlineSource
    }
}

/// 书籍选择流的统一回流结果语义。
enum BookPickerResult: Hashable, Sendable {
    case cancelled
    case single(BookPickerBook)
    case multiple([BookPickerBook])
}
