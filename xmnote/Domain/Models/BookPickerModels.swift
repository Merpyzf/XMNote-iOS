/**
 * [INPUT]: 依赖 Foundation 与 BookSearchSource，定义通用书籍选择流的跨层模型与配置语义
 * [OUTPUT]: 对外提供 BookPickerBook、BookPickerSelection、BookPickerScope、BookPickerSelectionMode、BookPickerCreationAction、BookPickerConfiguration、BookPickerResult
 * [POS]: Domain/Models 的书籍选择领域模型，被 BookPickerView、ViewModel 与调用业务页共同消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 书籍选择流的本地书籍结果模型，统一承接本地查询、已选回显与创建成功回填。
struct BookPickerBook: Identifiable, Hashable, Codable, Sendable {
    let id: Int64
    let title: String
    let author: String
    let press: String
    let coverURL: String
    let positionUnit: Int64
    let totalPosition: Int64
    let totalPagination: Int64

    nonisolated init(
        id: Int64,
        title: String,
        author: String,
        press: String = "",
        coverURL: String = "",
        positionUnit: Int64 = 0,
        totalPosition: Int64 = 0,
        totalPagination: Int64 = 0
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.press = press
        self.coverURL = coverURL
        self.positionUnit = positionUnit
        self.totalPosition = totalPosition
        self.totalPagination = totalPagination
    }
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

/// 书籍选择流中“新增一本书”入口的打开方式。
enum BookPickerCreationAction: Hashable, Codable, Sendable {
    case inlineManualEditor
    case separateSearchPage
    case nestedSearchPage
}

/// 在线结果点击后的回流策略，决定是否必须先落为本地书再返回业务页。
enum BookPickerOnlineSelectionPolicy: Hashable, Codable, Sendable {
    case requireLocalCreation
    case returnRemoteSelection
}

/// 多选确认策略，决定是否允许用空选择表达“全部/未限制”语义。
enum BookPickerMultipleConfirmationPolicy: Hashable, Codable, Sendable {
    case requiresSelection
    case allowsEmptyResult
}

/// 在线结果直返给业务页时的统一载荷，保证远端条目与补齐后的编辑种子同时可用。
struct BookPickerRemoteSelection: Identifiable, Hashable, Sendable {
    let result: BookSearchResult
    let seed: BookEditorSeed

    var id: String { result.id }
}

/// 书籍选择流的统一结果项，兼容本地书与在线直返结果。
enum BookPickerSelection: Identifiable, Hashable, Sendable {
    case local(BookPickerBook)
    case remote(BookPickerRemoteSelection)

    var id: String {
        switch self {
        case .local(let book):
            return "local-\(book.id)"
        case .remote(let remoteSelection):
            return "remote-\(remoteSelection.id)"
        }
    }
}

/// 书籍选择流的公共配置，统一收口标题、来源范围、多选能力与默认上下文。
struct BookPickerConfiguration: Hashable, Codable, Sendable {
    var title: String
    var scope: BookPickerScope
    var selectionMode: BookPickerSelectionMode
    var allowsCreationFlow: Bool
    var creationAction: BookPickerCreationAction
    var onlineSelectionPolicy: BookPickerOnlineSelectionPolicy
    var multipleConfirmationPolicy: BookPickerMultipleConfirmationPolicy
    var multipleConfirmationTitle: String
    var defaultQuery: String
    var preselectedBooks: [BookPickerBook]
    var onlineSources: [BookSearchSource]
    var preferredOnlineSource: BookSearchSource?

    init(
        title: String = "选择书籍",
        scope: BookPickerScope,
        selectionMode: BookPickerSelectionMode,
        allowsCreationFlow: Bool = false,
        creationAction: BookPickerCreationAction = .inlineManualEditor,
        onlineSelectionPolicy: BookPickerOnlineSelectionPolicy = .requireLocalCreation,
        multipleConfirmationPolicy: BookPickerMultipleConfirmationPolicy = .requiresSelection,
        multipleConfirmationTitle: String = "添加所选书籍",
        defaultQuery: String = "",
        preselectedBooks: [BookPickerBook] = [],
        onlineSources: [BookSearchSource] = BookSearchSource.allCases,
        preferredOnlineSource: BookSearchSource? = nil
    ) {
        self.title = title
        self.scope = scope
        self.selectionMode = selectionMode
        self.allowsCreationFlow = allowsCreationFlow
        self.creationAction = creationAction
        self.onlineSelectionPolicy = onlineSelectionPolicy
        self.multipleConfirmationPolicy = multipleConfirmationPolicy
        self.multipleConfirmationTitle = multipleConfirmationTitle
        self.defaultQuery = defaultQuery
        self.preselectedBooks = preselectedBooks
        self.onlineSources = onlineSources
        self.preferredOnlineSource = preferredOnlineSource
    }
}

/// 书籍选择流的统一回流结果语义。
enum BookPickerResult: Hashable, Sendable {
    case cancelled
    case single(BookPickerSelection)
    case multiple([BookPickerSelection])
    case addFlowRequested
}
