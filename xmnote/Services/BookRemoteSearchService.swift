/**
 * [INPUT]: 依赖 Foundation URLSession 执行 JSON 请求，依赖 BookSearchWebScenarioService 与 WebHTMLFetchService 处理网页抓取，依赖 SwiftSoup 解析站点 HTML
 * [OUTPUT]: 对外提供 BookRemoteSearchService，统一封装六书源搜索与豆瓣详情补抓
 * [POS]: Services 模块的书籍远端搜索业务层，负责把各站点协议差异翻译为统一搜索结果与录入预填种子
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import SwiftSoup

/// 统一远端书籍搜索服务，对外屏蔽 JSON API、网页抓取和站点风控差异。
final class BookRemoteSearchService {
    private let urlSession: URLSession
    private let webScenarioService: BookSearchWebScenarioService
    private let fetchService: WebHTMLFetchServiceProtocol

    init(
        urlSession: URLSession = .shared,
        webScenarioService: BookSearchWebScenarioService = .init(),
        fetchService: WebHTMLFetchServiceProtocol? = nil
    ) {
        self.urlSession = urlSession
        self.webScenarioService = webScenarioService
        self.fetchService = fetchService ?? WebHTMLFetchService.shared
    }

    /// 搜索指定来源书籍；ISBN 输入遵循 Android 端“优先 Wenqu / 豆瓣”兜底逻辑。
    func search(keyword: String, source: BookSearchSource) async throws -> [BookSearchResult] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BookSearchError.emptyKeyword
        }

        if trimmed.isISBN {
            if source == .douban {
                let seed = try await fetchDoubanSeed(isbn: trimmed)
                return [seed.searchResult(source: .douban)]
            }

            let wenquResults = try await searchWenqu(by: .isbn(trimmed))
            if !wenquResults.isEmpty {
                return wenquResults
            }
            let seed = try await fetchDoubanSeed(isbn: trimmed)
            return [seed.searchResult(source: .douban)]
        }

        switch source {
        case .wenqu:
            return try await searchWenqu(by: .query(trimmed))
        case .douban:
            return try await searchDouban(keyword: trimmed)
        case .qidian:
            return try await searchQidian(keyword: trimmed)
        case .zongHeng:
            return try await searchZongHeng(keyword: trimmed)
        case .jjwxc:
            return try await searchJJWXC(keyword: trimmed)
        case .cp:
            return try await searchCP(keyword: trimmed)
        }
    }

    /// 将列表结果补齐成录入页草稿种子；当前只有豆瓣条目需要详情补抓。
    func prepareSeed(for result: BookSearchResult) async throws -> BookEditorSeed {
        if let seed = result.seed {
            return seed
        }
        if let doubanId = result.doubanId {
            return try await fetchDoubanSeed(doubanId: doubanId)
        }
        if !result.isbn.isEmpty {
            return try await fetchDoubanSeed(isbn: result.isbn)
        }
        throw BookSearchError.remoteService(message: "当前结果缺少可补全的详情标识")
    }
}

private extension BookRemoteSearchService {
    enum WenquQuery {
        case query(String)
        case isbn(String)
        case doubanId(Int)
    }

    func searchWenqu(by query: WenquQuery) async throws -> [BookSearchResult] {
        var components = URLComponents(string: "https://wenqu.annatarhe.cn/api/v1/books/search")
        switch query {
        case .query(let keyword):
            components?.queryItems = [
                .init(name: "page", value: "1"),
                .init(name: "limit", value: "50"),
                .init(name: "query", value: keyword)
            ]
        case .isbn(let isbn):
            components?.queryItems = [.init(name: "isbn", value: isbn)]
        case .doubanId(let doubanId):
            components?.queryItems = [.init(name: "dbId", value: String(doubanId))]
        }
        guard let url = components?.url else {
            throw BookSearchError.sourceUnavailable(message: "Wenqu 请求地址无效")
        }

        let response: WenquResponse = try await requestJSON(
            url: url,
            additionalHeaders: [
                "X-Simple-Check": "500ae25e22b5de1b6c44a7d78908e7b7cc63f97b55ea9cdc50aa8fcd84b1fcba"
            ]
        )

        return response.books.map { item in
            let seed = BookEditorSeed(
                searchSource: .wenqu,
                title: item.title ?? "",
                rawTitle: item.originTitle ?? "",
                author: item.author ?? "",
                authorIntro: item.authorIntro ?? "",
                translator: item.translator ?? "",
                press: item.press ?? "",
                isbn: item.isbn ?? "",
                pubDate: normalizeDateString(item.pubdate),
                summary: item.summary ?? "",
                catalog: normalizeCatalog(item.catalog ?? ""),
                coverURL: item.image ?? "",
                doubanId: item.doubanId,
                totalPages: item.totalPages,
                totalWordCount: nil,
                preferredSourceName: nil,
                preferredBookType: .paper,
                preferredProgressUnit: .pagination
            )

            return BookSearchResult(
                id: "wenqu-\(item.id ?? Int.random(in: 1...999_999))",
                source: .wenqu,
                title: seed.title,
                author: seed.author,
                coverURL: seed.coverURL,
                subtitle: [seed.press, seed.pubDate].filter { !$0.isEmpty }.joined(separator: " · "),
                summary: seed.summary,
                translator: seed.translator,
                press: seed.press,
                isbn: seed.isbn,
                pubDate: seed.pubDate,
                doubanId: seed.doubanId,
                totalPages: seed.totalPages,
                totalWordCount: nil,
                seed: seed,
                detailPageURL: item.url
            )
        }
    }

    func searchDouban(keyword: String) async throws -> [BookSearchResult] {
        let result = try await webScenarioService.execute(.doubanSearch(keyword: keyword, page: 1))
        if result.probe.status == .antiBot {
            throw BookSearchError.doubanLoginRequired
        }
        guard case .doubanBooks(let books) = result.parsedPayload else {
            return []
        }
        return books.map { item in
            BookSearchResult(
                id: "douban-\(item.doubanId)",
                source: .douban,
                title: item.title,
                author: "",
                coverURL: item.coverURLString,
                subtitle: item.info,
                summary: "",
                translator: "",
                press: "",
                isbn: "",
                pubDate: "",
                doubanId: item.doubanId,
                totalPages: nil,
                totalWordCount: nil,
                seed: nil,
                detailPageURL: "https://book.douban.com/subject/\(item.doubanId)/"
            )
        }
    }

    func searchQidian(keyword: String) async throws -> [BookSearchResult] {
        let result = try await webScenarioService.execute(.qidianSearch(keyword: keyword, page: 1))
        return try parseQidianResults(html: result.fetchResult.html)
    }

    func searchZongHeng(keyword: String) async throws -> [BookSearchResult] {
        guard let url = URL(string: "https://search.zongheng.com/search/book?keyword=\(keyword.urlQueryEncoded)") else {
            throw BookSearchError.sourceUnavailable(message: "纵横请求地址无效")
        }
        let response: ZongHengResponse = try await requestJSON(url: url)
        return (response.data.datas.list ?? []).map { item in
            let title = item.name.htmlStripped
            let summary = (item.description ?? "").htmlStripped
            let cover = item.coverUrl.flatMap(Self.absoluteZongHengCoverURL) ?? ""
            let seed = BookEditorSeed(
                searchSource: .zongHeng,
                title: title,
                rawTitle: title,
                author: item.authorName ?? "",
                authorIntro: "",
                translator: "",
                press: "",
                isbn: "",
                pubDate: "",
                summary: summary,
                catalog: "",
                coverURL: cover,
                doubanId: nil,
                totalPages: nil,
                totalWordCount: item.totalWord,
                preferredSourceName: BookSearchSource.zongHeng.preferredDraftSourceName,
                preferredBookType: .ebook,
                preferredProgressUnit: .position
            )
            return BookSearchResult(
                id: "zongheng-\(item.bookId)",
                source: .zongHeng,
                title: seed.title,
                author: seed.author,
                coverURL: seed.coverURL,
                subtitle: item.keyword?.htmlStripped ?? "",
                summary: seed.summary,
                translator: "",
                press: "",
                isbn: "",
                pubDate: "",
                doubanId: nil,
                totalPages: nil,
                totalWordCount: item.totalWord,
                seed: seed,
                detailPageURL: nil
            )
        }
    }

    func searchJJWXC(keyword: String) async throws -> [BookSearchResult] {
        guard let url = URL(
            string: "https://www.jjwxc.net/search.php?kw=\(keyword.urlQueryEncodedGB18030)&t=1&ord=relate"
        ) else {
            throw BookSearchError.sourceUnavailable(message: "晋江请求地址无效")
        }

        let request = WebHTMLFetchRequest(url: url, channel: .http, sessionScope: .sharedDefault)
        let fetchResult = try await fetchService.fetchHTML(request)
        let roughResults = try parseJJWXCSearchResults(html: fetchResult.html)

        return try await withThrowingTaskGroup(of: BookSearchResult.self) { group in
            for result in roughResults {
                group.addTask {
                    try await self.enrichJJWXCCover(for: result)
                }
            }

            var finalResults: [BookSearchResult] = []
            for try await item in group {
                finalResults.append(item)
            }
            return finalResults
        }
    }

    func searchCP(keyword: String) async throws -> [BookSearchResult] {
        guard let url = URL(string: "https://gongzicp.com/webapi/search/novels?k=\(keyword.urlQueryEncoded)&page=1") else {
            throw BookSearchError.sourceUnavailable(message: "长佩请求地址无效")
        }
        let response: CPResponse = try await requestJSON(url: url)
        return response.data.list.map { item in
            let seed = BookEditorSeed(
                searchSource: .cp,
                title: item.name,
                rawTitle: item.name,
                author: item.author,
                authorIntro: "",
                translator: "",
                press: "",
                isbn: "",
                pubDate: normalizeDateString(item.updateTime),
                summary: item.description,
                catalog: "",
                coverURL: item.cover,
                doubanId: nil,
                totalPages: nil,
                totalWordCount: item.wordCount,
                preferredSourceName: BookSearchSource.cp.preferredDraftSourceName,
                preferredBookType: .ebook,
                preferredProgressUnit: .position
            )
            return BookSearchResult(
                id: "cp-\(item.id)",
                source: .cp,
                title: item.name,
                author: item.author,
                coverURL: item.cover,
                subtitle: item.info,
                summary: item.description,
                translator: "",
                press: "",
                isbn: "",
                pubDate: seed.pubDate,
                doubanId: nil,
                totalPages: nil,
                totalWordCount: item.wordCount,
                seed: seed,
                detailPageURL: nil
            )
        }
    }

    func fetchDoubanSeed(doubanId: Int) async throws -> BookEditorSeed {
        let result = try await webScenarioService.execute(.doubanDetail(doubanId: String(doubanId)))
        if result.probe.status == .antiBot {
            throw BookSearchError.doubanLoginRequired
        }
        return try parseDoubanDetail(html: result.fetchResult.html)
    }

    func fetchDoubanSeed(isbn: String) async throws -> BookEditorSeed {
        let result = try await webScenarioService.execute(.doubanISBN(isbn: isbn))
        if result.probe.status == .antiBot {
            throw BookSearchError.doubanLoginRequired
        }
        return try parseDoubanDetail(html: result.fetchResult.html)
    }

    func enrichJJWXCCover(for result: BookSearchResult) async throws -> BookSearchResult {
        guard let detailPageURL = result.detailPageURL,
              let url = URL(string: detailPageURL) else {
            return result
        }
        let request = WebHTMLFetchRequest(url: url, channel: .http, sessionScope: .sharedDefault)
        let fetchResult = try await fetchService.fetchHTML(request)
        guard let coverURL = try parseJJWXCCover(html: fetchResult.html) else {
            return result
        }
        let seed = result.seed?.replacingCoverURL(coverURL)
        return BookSearchResult(
            id: result.id,
            source: result.source,
            title: result.title,
            author: result.author,
            coverURL: coverURL,
            subtitle: result.subtitle,
            summary: result.summary,
            translator: result.translator,
            press: result.press,
            isbn: result.isbn,
            pubDate: result.pubDate,
            doubanId: result.doubanId,
            totalPages: result.totalPages,
            totalWordCount: result.totalWordCount,
            seed: seed,
            detailPageURL: result.detailPageURL
        )
    }

    func requestJSON<Response: Decodable>(
        url: URL,
        additionalHeaders: [String: String] = [:]
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        XMImageRequestBuilder.browserHeaderFields(for: url).forEach {
            request.setValue($0.value, forHTTPHeaderField: $0.key)
        }
        additionalHeaders.forEach {
            request.setValue($0.value, forHTTPHeaderField: $0.key)
        }

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BookSearchError.remoteService(message: "远端服务没有返回有效响应")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "状态码 \(httpResponse.statusCode)"
            if httpResponse.statusCode == 401 {
                throw BookSearchError.sourceUnavailable(message: "官方书源鉴权失败：\(message)")
            }
            throw BookSearchError.remoteService(message: message)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        return try decoder.decode(Response.self, from: data)
    }

    func parseQidianResults(html: String) throws -> [BookSearchResult] {
        let document = try SwiftSoup.parse(html)
        let items = try document.getElementsByClass("y-list__item").array()

        return try items.compactMap { item in
            let itemHTML = try item.html()
            let titleClass = dynamicClass(prefix: "_searchBookName_", html: itemHTML)
            let coverClass = dynamicClass(prefix: "_bookImg_", html: itemHTML)
            let summaryClass = dynamicClass(prefix: "_searchBookDesc_", html: itemHTML)
            let authorClass = dynamicClass(prefix: "_searchBookAuthor_", html: itemHTML)

            let title = try item.getElementsByClass(titleClass).first()?.text().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { return nil }
            let cover = try qidianCoverURL(from: item.getElementsByClass(coverClass).first())
            let author = try item.getElementsByClass(authorClass).first()?.text().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let summary = try item.getElementsByClass(summaryClass).first()?.text().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let seed = BookEditorSeed(
                searchSource: .qidian,
                title: title,
                rawTitle: title,
                author: author,
                authorIntro: "",
                translator: "",
                press: "",
                isbn: "",
                pubDate: "",
                summary: summary,
                catalog: "",
                coverURL: cover,
                doubanId: nil,
                totalPages: nil,
                totalWordCount: nil,
                preferredSourceName: BookSearchSource.qidian.preferredDraftSourceName,
                preferredBookType: .ebook,
                preferredProgressUnit: .position
            )
            return BookSearchResult(
                id: "qidian-\(title)-\(author)",
                source: .qidian,
                title: title,
                author: author,
                coverURL: cover,
                subtitle: "",
                summary: summary,
                translator: "",
                press: "",
                isbn: "",
                pubDate: "",
                doubanId: nil,
                totalPages: nil,
                totalWordCount: nil,
                seed: seed,
                detailPageURL: nil
            )
        }
    }

    func parseJJWXCSearchResults(html: String) throws -> [BookSearchResult] {
        let document = try SwiftSoup.parse(html)
        let searchResult = try document.body()?.getElementById("search_result")
        let divs = try searchResult?.getElementsByTag("div").array().filter {
            try $0.attr("id").isEmpty && $0.attr("class").isEmpty
        } ?? []

        return try divs.compactMap { div in
            let title = try div.getElementsByClass("title").select("a").first()?.text().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let href = try div.getElementsByClass("title").select("a").first()?.attr("href").trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty, !href.isEmpty else { return nil }
            let author = try div.getElementsByClass("info").select("a").first()?.text().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let intro = try div.getElementsByClass("intro").first()?.text().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let seed = BookEditorSeed(
                searchSource: .jjwxc,
                title: title,
                rawTitle: title,
                author: author,
                authorIntro: "",
                translator: "",
                press: "",
                isbn: "",
                pubDate: "",
                summary: intro,
                catalog: "",
                coverURL: "",
                doubanId: nil,
                totalPages: nil,
                totalWordCount: nil,
                preferredSourceName: BookSearchSource.jjwxc.preferredDraftSourceName,
                preferredBookType: .ebook,
                preferredProgressUnit: .position
            )
            return BookSearchResult(
                id: "jjwxc-\(href)",
                source: .jjwxc,
                title: title,
                author: author,
                coverURL: "",
                subtitle: "",
                summary: intro,
                translator: "",
                press: "",
                isbn: "",
                pubDate: "",
                doubanId: nil,
                totalPages: nil,
                totalWordCount: nil,
                seed: seed,
                detailPageURL: href
            )
        }
    }

    func parseJJWXCCover(html: String) throws -> String? {
        let document = try SwiftSoup.parse(html)
        let cover = try document.getElementsByClass("noveldefaultimage").first()?.attr("src")
        let trimmed = cover?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    func parseDoubanDetail(html: String) throws -> BookEditorSeed {
        let document = try SwiftSoup.parse(html)
        let title = try document.select("span[property='v:itemreviewed']").first()?.text().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cover = try document.select("#mainpic img").first()?.attr("src").trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let summary = try longestText(in: document.select("#link-report .intro").array())
        let authorIntro = try longestText(in: document.select("#author-intro .intro").array())
        let catalog = try longestText(in: document.select("div[id^=dir_]").array())
        let infoMap = try parseDoubanInfoMap(html: document.select("#info").html())
        let author = infoMap["作者"] ?? ""
        let translator = infoMap["译者"] ?? ""
        let press = infoMap["出版社"] ?? ""
        let isbn = infoMap["ISBN"] ?? ""
        let pubDate = normalizeDateString(infoMap["出版年"])
        let totalPages = Int((infoMap["页数"] ?? "").digitsOnly)
        let ogURL = try document.select("meta[property='og:url']").attr("content")
        let doubanId = Int(ogURL.doubanSubjectID ?? "")

        return BookEditorSeed(
            searchSource: .douban,
            title: title,
            rawTitle: infoMap["原作名"] ?? title,
            author: author,
            authorIntro: authorIntro,
            translator: translator,
            press: press,
            isbn: isbn,
            pubDate: pubDate,
            summary: summary,
            catalog: normalizeCatalog(catalog),
            coverURL: cover,
            doubanId: doubanId,
            totalPages: totalPages,
            totalWordCount: nil,
            preferredSourceName: nil,
            preferredBookType: .paper,
            preferredProgressUnit: .pagination
        )
    }

    func parseDoubanInfoMap(html: String) throws -> [String: String] {
        let withLines = html.replacingOccurrences(
            of: "(?i)<br\\s*/?>",
            with: "\n",
            options: .regularExpression
        )
        let text = withLines
            .replacingOccurrences(of: "(?is)<script.*?</script>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: "\u{00a0}", with: " ").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var result: [String: String] = [:]
        for line in lines {
            let parts = line.components(separatedBy: ":")
            guard parts.count >= 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = parts.dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty, !value.isEmpty {
                result[key] = value
            }
        }
        return result
    }

    func longestText(in elements: [Element]) throws -> String {
        try elements
            .map { try $0.text().trimmingCharacters(in: .whitespacesAndNewlines) }
            .max(by: { $0.count < $1.count }) ?? ""
    }

    func dynamicClass(prefix: String, html: String) -> String {
        guard let range = html.range(of: prefix) else {
            return prefix
        }
        let tail = html[range.lowerBound...]
        guard let end = tail.firstIndex(of: "\"") else {
            return prefix
        }
        return String(tail[..<end])
    }

    func qidianCoverURL(from element: Element?) throws -> String {
        guard let element else { return "" }
        let dataSrc = try element.attr("data-src")
        if !dataSrc.isEmpty {
            return dataSrc.hasPrefix("https") ? dataSrc : "https:\(dataSrc)"
        }
        let src = try element.attr("src")
        return src.hasPrefix("https") ? src : "https:\(src)"
    }

    static func absoluteZongHengCoverURL(_ path: String) -> String {
        if path.hasPrefix("https://") {
            return path
        }
        return "https://static.zongheng.com/upload\(path)"
    }

    func normalizeDateString(_ rawValue: String?) -> String {
        guard let raw = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return ""
        }
        if raw.contains("T"), let prefix = raw.split(separator: "T").first {
            return String(prefix)
        }
        return raw
    }

    func normalizeCatalog(_ rawValue: String) -> String {
        rawValue
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

private struct WenquResponse: Decodable {
    let count: Int
    let books: [WenquBook]
}

private struct WenquBook: Decodable {
    let id: Int?
    let author: String?
    let authorIntro: String?
    let catalog: String?
    let doubanId: Int?
    let image: String?
    let isbn: String?
    let originTitle: String?
    let press: String?
    let pubdate: String?
    let summary: String?
    let title: String?
    let totalPages: Int?
    let translator: String?
    let url: String?
}

private struct ZongHengResponse: Decodable {
    let data: DataContainer

    struct DataContainer: Decodable {
        let datas: DatasContainer
    }

    struct DatasContainer: Decodable {
        let list: [Item]?
    }

    struct Item: Decodable {
        let bookId: Int
        let name: String
        let coverUrl: String?
        let keyword: String?
        let authorName: String?
        let description: String?
        let totalWord: Int?
    }
}

private struct CPResponse: Decodable {
    let data: DataContainer

    struct DataContainer: Decodable {
        let list: [Item]
    }

    struct Item: Decodable {
        let id: Int
        let name: String
        let cover: String
        let description: String
        let info: String
        let author: String
        let wordCount: Int?
        let updateTime: String?

        enum CodingKeys: String, CodingKey {
            case id = "novel_id"
            case name = "novel_name"
            case cover = "novel_cover"
            case description = "novel_desc"
            case info = "novel_info"
            case author = "novel_author"
            case wordCount = "novel_wordnumber"
            case updateTime = "novel_uptime"
        }
    }
}

private extension BookEditorSeed {
    func searchResult(source: BookSearchSource) -> BookSearchResult {
        BookSearchResult(
            id: "\(source.rawValue)-\(doubanId ?? 0)-\(title)",
            source: source,
            title: title,
            author: author,
            coverURL: coverURL,
            subtitle: [press, pubDate].filter { !$0.isEmpty }.joined(separator: " · "),
            summary: summary,
            translator: translator,
            press: press,
            isbn: isbn,
            pubDate: pubDate,
            doubanId: doubanId,
            totalPages: totalPages,
            totalWordCount: totalWordCount,
            seed: self,
            detailPageURL: nil
        )
    }

    func replacingCoverURL(_ coverURL: String) -> BookEditorSeed {
        var copy = self
        copy.coverURL = coverURL
        return copy
    }
}

private extension String {
    var urlQueryEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }

    var urlQueryEncodedGB18030: String {
        guard let encoding = Self.stringEncoding(forIANAName: "GB18030"),
              let data = data(using: encoding) else {
            return urlQueryEncoded
        }
        return data.percentEncodedForURLQuery
    }

    var isISBN: Bool {
        let raw = replacingOccurrences(of: "-", with: "").uppercased()
        let pattern = "^(?:\\d{9}[\\dX]|\\d{13})$"
        return raw.range(of: pattern, options: .regularExpression) != nil
    }

    var digitsOnly: String {
        filter(\.isNumber)
    }

    var htmlStripped: String {
        (try? SwiftSoup.parse(self).text()) ?? self
    }

    var doubanSubjectID: String? {
        guard let regex = try? NSRegularExpression(pattern: "/subject/(\\d+)/", options: []) else {
            return nil
        }
        let range = NSRange(startIndex..<endIndex, in: self)
        guard let match = regex.firstMatch(in: self, options: [], range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: self) else {
            return nil
        }
        return String(self[captureRange])
    }

    static func stringEncoding(forIANAName name: String) -> String.Encoding? {
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else {
            return nil
        }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }
}

private extension Data {
    var percentEncodedForURLQuery: String {
        return map { byte in
            if byte.isURLQueryUnreservedASCII {
                return String(UnicodeScalar(byte))
            }
            return String(format: "%%%02X", byte)
        }
        .joined()
    }
}

private extension UInt8 {
    var isURLQueryUnreservedASCII: Bool {
        switch self {
        case 48...57, 65...90, 97...122, 45, 46, 95, 126:
            return true
        default:
            return false
        }
    }
}
