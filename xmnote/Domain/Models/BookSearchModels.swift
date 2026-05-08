/**
 * [INPUT]: 依赖 Foundation 的 Hashable/URL 语义，承接在线搜索与录入页预填所需的跨层数据
 * [OUTPUT]: 对外提供 BookSearchSource、BookSearchSettings、BookSearchResult、BookSearchError、BookEditorSeed 等搜索域模型
 * [POS]: Domain/Models 的书籍搜索与录入预填模型定义，被搜索仓储、ViewModel 与书籍搜索页共同消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 在线书籍搜索源，保留 Android 端来源顺序，并兼容 iOS 已接入的豆瓣来源。
enum BookSearchSource: Int, CaseIterable, Identifiable, Hashable, Sendable, Codable {
    case wenqu = 0
    case qidian = 1
    case zongHeng = 2
    case jjwxc = 3
    case fanqie = 4
    case cp = 5
    case douban = 6

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .wenqu:
            return "纸间书摘"
        case .douban:
            return "豆瓣读书"
        case .qidian:
            return "起点中文网"
        case .zongHeng:
            return "纵横中文网"
        case .jjwxc:
            return "晋江文学城"
        case .fanqie:
            return "番茄小说"
        case .cp:
            return "长佩文学"
        }
    }

    /// 豆瓣搜索页只返回轻量卡片，进入录入页前必须补抓详情。
    var requiresDetailHydration: Bool {
        self == .douban
    }

    /// 网文平台默认按电子书语义创建，纸书搜索源不强制覆盖偏好。
    var preferredDraftSourceName: String? {
        switch self {
        case .qidian:
            return "起点中文网"
        case .zongHeng:
            return "纵横中文网"
        case .jjwxc:
            return "晋江文学城"
        case .fanqie:
            return "番茄小说"
        case .cp:
            return "长佩文学"
        case .wenqu, .douban:
            return nil
        }
    }
}

/// 添加书籍搜索设置，对齐 Android 快速切换来源、当前来源与创建后返回首页偏好。
struct BookSearchSettings: Hashable, Sendable, Codable {
    var defaultSource: BookSearchSource
    var isQuickSourceSwitchEnabled: Bool
    var shouldReturnToBookshelfAfterSave: Bool

    static let `default` = BookSearchSettings(
        defaultSource: .wenqu,
        isQuickSourceSwitchEnabled: false,
        shouldReturnToBookshelfAfterSave: false
    )
}

/// 搜索结果条目，承接列表页渲染与进入录入页前的预填数据。
struct BookSearchResult: Identifiable, Hashable, Sendable {
    let id: String
    let source: BookSearchSource
    let title: String
    let author: String
    let coverURL: String
    let subtitle: String
    let summary: String
    let translator: String
    let press: String
    let isbn: String
    let pubDate: String
    let doubanId: Int?
    let totalPages: Int?
    let totalWordCount: Int?
    let seed: BookEditorSeed?
    let detailPageURL: String?
}

/// 搜索页错误语义，避免 UI 层直接透传站点细节。
enum BookSearchError: LocalizedError {
    case emptyKeyword
    case doubanLoginRequired
    case fanqieVerificationRequired
    case sourceUnavailable(message: String)
    case remoteService(message: String)

    var errorDescription: String? {
        switch self {
        case .emptyKeyword:
            return "请输入书名、作者或 ISBN"
        case .doubanLoginRequired:
            return "豆瓣需要先登录后再继续搜索"
        case .fanqieVerificationRequired:
            return "番茄搜索触发了站点验证"
        case .sourceUnavailable(let message), .remoteService(let message):
            return message
        }
    }
}

/// 搜索结果进入录入页前的预填载荷，兼容在线搜索与手动创建两种入口。
struct BookEditorSeed: Identifiable, Hashable, Sendable, Codable {
    var searchSource: BookSearchSource?
    var title: String
    var rawTitle: String
    var author: String
    var authorIntro: String
    var translator: String
    var press: String
    var isbn: String
    var pubDate: String
    var summary: String
    var catalog: String
    var coverURL: String
    var doubanId: Int?
    var totalPages: Int?
    var totalWordCount: Int?
    var preferredSourceName: String?
    var preferredBookType: BookEntryBookType?
    var preferredProgressUnit: BookEntryProgressUnit?

    var id: String {
        [
            title,
            author,
            isbn,
            String(doubanId ?? 0),
            searchSource.map { String($0.rawValue) } ?? "manual"
        ].joined(separator: "|")
    }

    static let manual = BookEditorSeed(
        searchSource: nil,
        title: "",
        rawTitle: "",
        author: "",
        authorIntro: "",
        translator: "",
        press: "",
        isbn: "",
        pubDate: "",
        summary: "",
        catalog: "",
        coverURL: "",
        doubanId: nil,
        totalPages: nil,
        totalWordCount: nil,
        preferredSourceName: nil,
        preferredBookType: nil,
        preferredProgressUnit: nil
    )
}
