/**
 * [INPUT]: 依赖 DesktopWebChapterRepository 的有效书籍校验、Foundation URLSession 与文渠 JSON 合同
 * [OUTPUT]: 对外提供 ChapterController 在线目录搜索、豆瓣编号解析、fuzzywuzzy 排序和目录规范化
 * [POS]: Data 层网页章节在线仓储；网络结果只经 Repository 进入 XMNoteWeb Adapter
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// 文渠远端书籍的最小快照，只保留 Android 在线章节接口读取的字段。
nonisolated struct DesktopWebWenquBookSnapshot: Decodable, Sendable, Equatable {
    let title: String?
    let author: String?
    let press: String?
    let pubdate: String?
    let image: String?
    let catalog: String?
    let doubanId: Int?
}

/// 文渠列表包络；count 与 books 都参与 Android 的在线目录存在性判断。
nonisolated struct DesktopWebWenquResponse: Decodable, Sendable, Equatable {
    let count: Int
    let books: [DesktopWebWenquBookSnapshot]
}

/// 区分关键字搜索与豆瓣编号搜索，测试可注入稳定的远端结果。
nonisolated enum DesktopWebWenquQuery: Sendable, Equatable {
    case keyword(String)
    case doubanID(Int)
}

/// WebOnlineChapterCandidateDto 的 App 层网络投影。
nonisolated struct DesktopWebOnlineChapterCandidateSnapshot: Sendable, Equatable {
    let title: String
    let author: String
    let publisher: String
    let pubDate: String
    let cover: String
    let doubanID: Int
    let hasCatalog: Bool
}

/// WebOnlineChapterCatalogDto 的 App 层网络投影。
nonisolated struct DesktopWebOnlineChapterCatalogSnapshot: Sendable, Equatable {
    let doubanID: Int
    let title: String
    let catalog: String
}

/// 通过可注入文渠请求闭包复刻 Android OnlineSearchService 的章节专用路径。
nonisolated struct DesktopWebChapterOnlineRepository: Sendable {
    typealias FetchBooks = @Sendable (DesktopWebWenquQuery) async throws -> DesktopWebWenquResponse

    private static let endpoint = "https://wenqu.annatarhe.cn/api/v1/books/search"
    private static let simpleCheck = "500ae25e22b5de1b6c44a7d78908e7b7cc63f97b55ea9cdc50aa8fcd84b1fcba"

    let chapterRepository: DesktopWebChapterRepository
    let fetchBooks: FetchBooks

    /// 默认通过 URLSession 访问与 Android 相同的文渠端点；测试闭包用于隔离外部网络波动。
    init(
        chapterRepository: DesktopWebChapterRepository,
        fetchBooks: @escaping FetchBooks = DesktopWebChapterOnlineRepository.fetch
    ) {
        self.chapterRepository = chapterRepository
        self.fetchBooks = fetchBooks
    }

    /// 校验有效书籍与非空关键字后，按 fuzzywuzzy 1.3.1 的 title+author 分数稳定倒序。
    func searchCandidates(
        bookID: Int64,
        keyword: String
    ) async throws -> [DesktopWebOnlineChapterCandidateSnapshot] {
        try await chapterRepository.requireActiveBook(bookID)
        guard !Self.isBlank(keyword) else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("搜索关键词不能为空")
        }

        let response = try await fetchBooks(.keyword(keyword))
        return response.books.enumerated()
            .sorted { lhs, rhs in
                let lhsScore = Self.ratio(lhs.element.title ?? "", keyword)
                    + Self.ratio(lhs.element.author ?? "", keyword)
                let rhsScore = Self.ratio(rhs.element.title ?? "", keyword)
                    + Self.ratio(rhs.element.author ?? "", keyword)
                return lhsScore == rhsScore ? lhs.offset < rhs.offset : lhsScore > rhsScore
            }
            .compactMap { _, book in
                guard let doubanID = book.doubanId, doubanID != 0 else { return nil }
                return DesktopWebOnlineChapterCandidateSnapshot(
                    title: book.title ?? "",
                    author: book.author ?? "",
                    publisher: book.press ?? "",
                    pubDate: book.pubdate ?? "",
                    cover: book.image ?? "",
                    doubanID: doubanID,
                    hasCatalog: !Self.isBlank(book.catalog ?? "")
                )
            }
    }

    /// 优先使用正数请求参数，否则回退本地书籍豆瓣编号，再按 Android 规则选择精确或首条结果。
    func onlineCatalog(
        bookID: Int64,
        requestedDoubanID: Int?
    ) async throws -> DesktopWebOnlineChapterCatalogSnapshot {
        let bookDoubanID = try await chapterRepository.activeBookDoubanID(bookID)
        let resolvedID: Int
        if let requestedDoubanID, requestedDoubanID > 0 {
            resolvedID = requestedDoubanID
        } else {
            guard bookDoubanID != 0 else {
                throw DesktopWebCatalogRepositoryError.invalidArgument("当前书籍缺少豆瓣编号")
            }
            resolvedID = Int(bookDoubanID)
        }

        let response = try await fetchBooks(.doubanID(resolvedID))
        guard response.count > 0, !response.books.isEmpty else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("未找到在线目录")
        }
        let book = response.books.first { $0.doubanId == resolvedID } ?? response.books[0]
        let catalog = Self.normalizeOnlineCatalog(book.catalog ?? "")
        guard !Self.isBlank(catalog) else {
            throw DesktopWebCatalogRepositoryError.invalidArgument("未找到在线目录")
        }
        return DesktopWebOnlineChapterCatalogSnapshot(
            doubanID: book.doubanId ?? 0,
            title: book.title ?? "",
            catalog: catalog
        )
    }
}

nonisolated extension DesktopWebChapterOnlineRepository {
    /// 复刻 OnlineSearchService.normalizeOnlineCatalog，清除四类不可见字符并压缩空行。
    static func normalizeOnlineCatalog(_ catalog: String) -> String {
        catalog
            .components(separatedBy: "\n")
            .map { line in
                let normalized = line
                    .replacingOccurrences(of: "\u{00A0}", with: " ")
                    .replacingOccurrences(of: "\u{200B}", with: "")
                    .replacingOccurrences(of: "\u{200C}", with: "")
                    .replacingOccurrences(of: "\u{200D}", with: "")
                    .replacingOccurrences(of: "\u{FEFF}", with: "")
                return kotlinTrimmed(normalized)
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// 复刻 fuzzywuzzy 1.3.1 SimpleRatio：UTF-16 编辑距离中替换成本为 2，最终四舍五入到整数。
    static func ratio(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs.utf16)
        let right = Array(rhs.utf16)
        let lengthSum = left.count + right.count
        guard lengthSum > 0 else { return 0 }
        let distance = levenshteinDistance(left, right)
        return Int((100 * Double(lengthSum - distance) / Double(lengthSum)).rounded())
    }

    private static func levenshteinDistance(_ lhs: [UInt16], _ rhs: [UInt16]) -> Int {
        guard !lhs.isEmpty else { return rhs.count }
        guard !rhs.isEmpty else { return lhs.count }
        var previous = Array(0...rhs.count)
        for (leftIndex, leftValue) in lhs.enumerated() {
            var current = Array(repeating: 0, count: rhs.count + 1)
            current[0] = leftIndex + 1
            for (rightIndex, rightValue) in rhs.enumerated() {
                let deletion = previous[rightIndex + 1] + 1
                let insertion = current[rightIndex] + 1
                let replacement = previous[rightIndex] + (leftValue == rightValue ? 0 : 2)
                current[rightIndex + 1] = min(deletion, insertion, replacement)
            }
            previous = current
        }
        return previous[rhs.count]
    }

    private static func isBlank(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy(isKotlinWhitespace)
    }

    private static func kotlinTrimmed(_ value: String) -> String {
        let scalars = Array(value.unicodeScalars)
        var lower = 0
        var upper = scalars.count
        while lower < upper, isKotlinWhitespace(scalars[lower]) { lower += 1 }
        while upper > lower, isKotlinWhitespace(scalars[upper - 1]) { upper -= 1 }
        var result = String.UnicodeScalarView()
        scalars[lower..<upper].forEach { result.append($0) }
        return String(result)
    }

    private static func isKotlinWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .spaceSeparator, .lineSeparator, .paragraphSeparator:
            return true
        default:
            return (0x0009...0x000D).contains(scalar.value)
                || (0x001C...0x001F).contains(scalar.value)
        }
    }

    /// 发起单次文渠 JSON 请求；调用任务取消会传播到 URLSession，不产生本地数据副作用。
    private static func fetch(_ query: DesktopWebWenquQuery) async throws -> DesktopWebWenquResponse {
        var components = URLComponents(string: endpoint)
        switch query {
        case .keyword(let keyword):
            components?.queryItems = [
                .init(name: "page", value: "1"),
                .init(name: "limit", value: "50"),
                .init(name: "query", value: keyword)
            ]
        case .doubanID(let doubanID):
            components?.queryItems = [.init(name: "dbId", value: String(doubanID))]
        }
        guard let url = components?.url else {
            throw DesktopWebCatalogRepositoryError.invalidDatabaseValue("文渠请求地址无效")
        }
        var request = URLRequest(url: url)
        request.setValue(simpleCheck, forHTTPHeaderField: "X-Simple-Check")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(DesktopWebWenquResponse.self, from: data)
    }
}

nonisolated extension DesktopWebChapterRepository {
    /// 返回有效书籍的豆瓣编号；一次读取同时完成 ActiveBookGuard 与字段解析。
    func activeBookDoubanID(_ bookID: Int64) async throws -> Int64 {
        let value = try await database.dbPool.read { db in
            // SQL 目的：读取在线目录所需豆瓣编号并同时校验有效书籍。
            // 涉及表：book。
            // 关键过滤：id 精确匹配、id != 0、is_deleted = 0；不按 user owner 过滤。
            // 时间字段：无。
            // 返回字段用途：在线目录请求参数缺省时回退本地 douban_id。
            try Int64.fetchOne(
                db,
                sql: "SELECT douban_id FROM book WHERE id = ? AND id != 0 AND is_deleted = 0",
                arguments: [bookID]
            )
        }
        guard let value else {
            throw DesktopWebCatalogRepositoryError.notFound("书籍不存在: \(bookID)")
        }
        return value
    }
}
