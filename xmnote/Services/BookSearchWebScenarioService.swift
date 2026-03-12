/**
 * [INPUT]: 依赖 WebHTMLFetchService 提供抓取通道，依赖 SwiftSoup 提供 DOM 解析与选择器探针
 * [OUTPUT]: 对外提供 BookSearchWebScenarioService、BookSearchWebScenario 与 ScenarioProbeResult，统一在线搜索网页场景编排
 * [POS]: Services 模块的在线搜索网页场景层，对通用抓取能力做业务意图翻译
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import SwiftSoup

struct ScenarioProbeResult: Sendable {
    enum Status: String, Sendable {
        case matched
        case partial
        case antiBot
        case selectorMiss
        case parseFailed

        var title: String {
            switch self {
            case .matched:
                return "命中"
            case .partial:
                return "部分命中"
            case .antiBot:
                return "命中风控"
            case .selectorMiss:
                return "选择器缺失"
            case .parseFailed:
                return "解析失败"
            }
        }
    }

    let status: Status
    let summary: String
    let selectorHits: [String]
    let title: String?
    let matchedCount: Int
}

struct ScenarioFetchAttempt: Identifiable, Sendable {
    let id = UUID()
    let channel: WebFetchChannel
    let finalURL: URL?
    let elapsedMilliseconds: Int?
    let probeStatusTitle: String?
    let summary: String
}

struct DoubanSearchBookItem: Identifiable, Sendable {
    let doubanId: Int
    let title: String
    let coverURLString: String
    let info: String

    var id: Int { doubanId }
}

enum ScenarioParsedPayload: Sendable {
    case doubanBooks([DoubanSearchBookItem])
}

struct ScenarioFetchResult: Sendable {
    let fetchResult: WebHTMLFetchResult
    let probe: ScenarioProbeResult
    let attemptedChannels: [WebFetchChannel]
    let selectedChannel: WebFetchChannel
    let fallbackReason: String?
    let attempts: [ScenarioFetchAttempt]
    let parsedPayload: ScenarioParsedPayload?
}

enum BookSearchWebScenario: Identifiable, Sendable {
    case doubanSearch(keyword: String, page: Int)
    case doubanDetail(doubanId: String)
    case doubanISBN(isbn: String)
    case doubanAuthor(urlString: String)
    case qidianSearch(keyword: String, page: Int)
    case manual(urlString: String)

    var id: String {
        switch self {
        case .doubanSearch(let keyword, let page):
            return "douban-search-\(keyword)-\(page)"
        case .doubanDetail(let doubanId):
            return "douban-detail-\(doubanId)"
        case .doubanISBN(let isbn):
            return "douban-isbn-\(isbn)"
        case .doubanAuthor(let urlString):
            return "douban-author-\(urlString)"
        case .qidianSearch(let keyword, let page):
            return "qidian-search-\(keyword)-\(page)"
        case .manual(let urlString):
            return "manual-\(urlString)"
        }
    }

    var title: String {
        switch self {
        case .doubanSearch:
            return "豆瓣搜索页"
        case .doubanDetail:
            return "豆瓣详情页"
        case .doubanISBN:
            return "豆瓣 ISBN 跳转页"
        case .doubanAuthor:
            return "豆瓣作者页"
        case .qidianSearch:
            return "起点移动搜索页"
        case .manual:
            return "手动 URL"
        }
    }

    var note: String {
        switch self {
        case .doubanSearch:
            return "对齐 Android DoubanBookHelper.searchBook"
        case .doubanDetail:
            return "抓详情页结构与基本字段容器"
        case .doubanISBN:
            return "验证 ISBN 跳转后最终详情页 HTML"
        case .doubanAuthor:
            return "验证作者资料页 DOM 是否可解析"
        case .qidianSearch:
            return "对齐 Android QiDianParser 依赖的列表结构"
        case .manual:
            return "任意网页 HTML 抓取验证"
        }
    }
}

/// 在线搜索网页场景服务，将书籍搜索意图翻译为抓取请求并输出 DOM 探针结果。
final class BookSearchWebScenarioService {
    private let fetchService: WebHTMLFetchServiceProtocol

    init(fetchService: WebHTMLFetchServiceProtocol) {
        self.fetchService = fetchService
    }

    convenience init() {
        self.init(fetchService: WebHTMLFetchService.shared)
    }

    /// 执行指定场景抓取，并根据站点规则生成探针结果与回退轨迹。
    func execute(
        _ scenario: BookSearchWebScenario,
        channel: WebFetchChannel? = nil,
        sessionScope: WebSessionScope? = nil
    ) async throws -> ScenarioFetchResult {
        let plan = try buildPlan(for: scenario, channel: channel, sessionScope: sessionScope)
        var attempts: [ScenarioFetchAttempt] = []
        var fallbackReason: String?

        for (index, request) in plan.requests.enumerated() {
            do {
                let fetchResult = try await fetchService.fetchHTML(request)
                let probe = await ScenarioProbeEngine.probe(
                    html: fetchResult.html,
                    finalURL: fetchResult.finalURL,
                    cookies: fetchResult.cookies,
                    scenario: scenario
                )
                let parsedPayload = await ScenarioProbeEngine.parsePayload(
                    html: fetchResult.html,
                    scenario: scenario
                )
                attempts.append(
                    ScenarioFetchAttempt(
                        channel: request.channel,
                        finalURL: fetchResult.finalURL,
                        elapsedMilliseconds: fetchResult.elapsedMilliseconds,
                        probeStatusTitle: probe.status.title,
                        summary: probe.summary
                    )
                )

                if let reason = fallbackReasonIfNeeded(
                    for: scenario,
                    probe: probe,
                    fetchResult: fetchResult,
                    requestChannel: request.channel,
                    hasNextAttempt: index < plan.requests.count - 1
                ) {
                    fallbackReason = reason
                    continue
                }

                return ScenarioFetchResult(
                    fetchResult: fetchResult,
                    probe: probe,
                    attemptedChannels: attempts.map(\.channel),
                    selectedChannel: fetchResult.channel,
                    fallbackReason: fallbackReason,
                    attempts: attempts,
                    parsedPayload: parsedPayload
                )
            } catch {
                attempts.append(
                    ScenarioFetchAttempt(
                        channel: request.channel,
                        finalURL: nil,
                        elapsedMilliseconds: nil,
                        probeStatusTitle: nil,
                        summary: error.localizedDescription
                    )
                )
                guard index < plan.requests.count - 1 else {
                    throw error
                }
                fallbackReason = error.localizedDescription
            }
        }

        throw WebHTMLFetchError.network(description: "未命中可用抓取结果。")
    }
}

private extension BookSearchWebScenarioService {
    struct ScenarioPlan {
        let requests: [WebHTMLFetchRequest]
    }

    func buildPlan(
        for scenario: BookSearchWebScenario,
        channel: WebFetchChannel?,
        sessionScope: WebSessionScope?
    ) throws -> ScenarioPlan {
        let resolvedScope = sessionScope ?? defaultSessionScope(for: scenario)
        let url = try makeURL(for: scenario)
        let channels = resolvedChannels(for: scenario, explicitChannel: channel)
        let requests = channels.map {
            WebHTMLFetchRequest(
                url: url,
                channel: $0,
                sessionScope: resolvedScope,
                timeout: 20,
                additionalHeaders: [:],
                waitPolicy: .default
            )
        }
        return ScenarioPlan(requests: requests)
    }

    func makeURL(for scenario: BookSearchWebScenario) throws -> URL {
        switch scenario {
        case .doubanSearch(let keyword, let page):
            let start = max(page - 1, 0) * 15
            return try makeURL(
                string: "https://search.douban.com/book/subject_search?search_text=\(keyword.urlQueryEncoded)&cat=1001&start=\(start)"
            )
        case .doubanDetail(let doubanId):
            return try makeURL(string: "https://book.douban.com/subject/\(doubanId)/")
        case .doubanISBN(let isbn):
            return try makeURL(string: "https://book.douban.com/isbn/\(isbn)/")
        case .doubanAuthor(let urlString):
            return try makeURL(string: urlString)
        case .qidianSearch(let keyword, let page):
            return try makeURL(string: "https://m.qidian.com/soushu/\(keyword.urlPathEncoded).html?pageNum=\(max(page, 1))")
        case .manual(let urlString):
            return try makeURL(string: urlString)
        }
    }

    func makeURL(string: String) throws -> URL {
        guard let url = URL(string: string) else {
            throw WebHTMLFetchError.network(description: "URL 不合法：\(string)")
        }
        return url
    }

    func resolvedChannels(for scenario: BookSearchWebScenario, explicitChannel: WebFetchChannel?) -> [WebFetchChannel] {
        if let explicitChannel, explicitChannel != .automatic {
            return [explicitChannel]
        }

        switch scenario {
        case .doubanSearch:
            return [.webView]
        case .doubanDetail, .doubanISBN, .doubanAuthor:
            return [.http, .webView]
        case .qidianSearch:
            return [.webView]
        case .manual:
            return [.http, .webView]
        }
    }

    func defaultSessionScope(for scenario: BookSearchWebScenario) -> WebSessionScope {
        switch scenario {
        case .doubanSearch, .doubanDetail, .doubanISBN, .doubanAuthor:
            return .sharedDouban
        case .qidianSearch, .manual:
            return .sharedDefault
        }
    }

    func fallbackReasonIfNeeded(
        for scenario: BookSearchWebScenario,
        probe: ScenarioProbeResult,
        fetchResult: WebHTMLFetchResult,
        requestChannel: WebFetchChannel,
        hasNextAttempt: Bool
    ) -> String? {
        guard hasNextAttempt else { return nil }
        guard requestChannel == .http else { return nil }

        switch scenario {
        case .manual:
            return nil
        case .doubanDetail, .doubanISBN, .doubanAuthor:
            switch probe.status {
            case .matched:
                return nil
            case .partial:
                return acceptsPartialDetailProbe(probe) ? nil : "HTTP 页面仅部分命中，回退到 WebView。"
            case .antiBot:
                return "HTTP 页面命中风控，回退到 WebView。"
            case .selectorMiss, .parseFailed:
                return "HTTP 页面未命中可解析结构，回退到 WebView。"
            }
        case .doubanSearch, .qidianSearch:
            return nil
        }
    }

    func acceptsPartialDetailProbe(_ probe: ScenarioProbeResult) -> Bool {
        probe.matchedCount > 0 && (probe.title?.isEmpty == false)
    }
}

private enum ScenarioProbeEngine {
    nonisolated static func probe(
        html: String,
        finalURL: URL,
        cookies: [HTTPCookie],
        scenario: BookSearchWebScenario
    ) async -> ScenarioProbeResult {
        await Task.detached(priority: .utility) {
            probeSynchronously(
                html: html,
                finalURL: finalURL,
                cookies: cookies,
                scenario: scenario
            )
        }.value
    }

    nonisolated static func parsePayload(
        html: String,
        scenario: BookSearchWebScenario
    ) async -> ScenarioParsedPayload? {
        await Task.detached(priority: .utility) {
            parsePayloadSynchronously(html: html, scenario: scenario)
        }.value
    }

    private nonisolated static func probeSynchronously(
        html: String,
        finalURL: URL,
        cookies: [HTTPCookie],
        scenario: BookSearchWebScenario
    ) -> ScenarioProbeResult {
        switch scenario {
        case .doubanSearch:
            return probeDoubanSearch(html: html, finalURL: finalURL, cookies: cookies)
        case .doubanDetail, .doubanISBN:
            return probeDoubanDetail(html: html, finalURL: finalURL)
        case .doubanAuthor:
            return probeDoubanAuthor(html: html, finalURL: finalURL)
        case .qidianSearch:
            return probeQidianSearch(html: html)
        case .manual:
            return probeManual(html: html)
        }
    }

    private nonisolated static func parsePayloadSynchronously(
        html: String,
        scenario: BookSearchWebScenario
    ) -> ScenarioParsedPayload? {
        switch scenario {
        case .doubanSearch:
            return .doubanBooks(parseDoubanSearchBooks(html: html))
        case .doubanDetail, .doubanISBN, .doubanAuthor, .qidianSearch, .manual:
            return nil
        }
    }

    private nonisolated static func probeDoubanSearch(html: String, finalURL: URL, cookies: [HTTPCookie]) -> ScenarioProbeResult {
        if let antiBot = detectDoubanAntiBot(html: html, finalURL: finalURL) {
            return antiBot
        }
        let probe = probeDocument(
            html: html,
            selectors: [".item-root", ".title-text", ".meta.abstract", "a[href*='subject/']"],
            successSummary: { document, hits in
                let count = (try? document.select(".item-root").count) ?? 0
                let title = try? document.title()
                return ScenarioProbeResult(
                    status: hits.count >= 2 ? .matched : .partial,
                    summary: count > 0 ? "命中 \(count) 条豆瓣结果卡片。" : "页面结构存在，但未命中结果卡片。",
                    selectorHits: hits,
                    title: title,
                    matchedCount: count
                )
            }
        )
        if probe.matchedCount == 0, hasDoubanLoginCookie(cookies) == false {
            return ScenarioProbeResult(
                status: .antiBot,
                summary: "豆瓣搜索结果为空，且共享会话缺少登录 Cookie。",
                selectorHits: probe.selectorHits,
                title: probe.title,
                matchedCount: 0
            )
        }
        return probe
    }

    private nonisolated static func probeDoubanDetail(html: String, finalURL: URL) -> ScenarioProbeResult {
        if let antiBot = detectDoubanAntiBot(html: html, finalURL: finalURL) {
            return antiBot
        }
        return probeDocument(
            html: html,
            selectors: ["#info", "span[property='v:itemreviewed']", "#mainpic img", ".rating_num"],
            successSummary: { document, hits in
                let title = try? document.select("span[property='v:itemreviewed']").first()?.text()
                return ScenarioProbeResult(
                    status: hits.count >= 2 ? .matched : .partial,
                    summary: title?.isEmpty == false ? "已命中详情页标题与基础字段容器。" : "已获取详情页 HTML，但标题节点为空。",
                    selectorHits: hits,
                    title: title,
                    matchedCount: hits.count
                )
            }
        )
    }

    private nonisolated static func probeDoubanAuthor(html: String, finalURL: URL) -> ScenarioProbeResult {
        if let antiBot = detectDoubanAntiBot(html: html, finalURL: finalURL) {
            return antiBot
        }
        return probeDocument(
            html: html,
            selectors: ["meta[property='og:url']", "#content", ".info", ".article"],
            successSummary: { document, hits in
                let title = try? document.title()
                return ScenarioProbeResult(
                    status: hits.count >= 2 ? .matched : .partial,
                    summary: hits.isEmpty ? "未命中作者页关键容器。" : "已命中作者页基础结构。",
                    selectorHits: hits,
                    title: title,
                    matchedCount: hits.count
                )
            }
        )
    }

    private nonisolated static func probeQidianSearch(html: String) -> ScenarioProbeResult {
        probeDocument(
            html: html,
            selectors: [".y-list__item", "[class*='_searchBookName_']", "[class*='_bookImg_']", "[class*='_searchBookAuthor_']"],
            successSummary: { document, hits in
                let count = (try? document.select(".y-list__item").count) ?? 0
                let title = try? document.title()
                return ScenarioProbeResult(
                    status: hits.count >= 2 ? .matched : .partial,
                    summary: count > 0 ? "命中 \(count) 条起点搜索结果。" : "页面已打开，但未命中结果列表。",
                    selectorHits: hits,
                    title: title,
                    matchedCount: count
                )
            }
        )
    }

    private nonisolated static func probeManual(html: String) -> ScenarioProbeResult {
        probeDocument(
            html: html,
            selectors: ["html", "head > title", "body", "a[href]"],
            successSummary: { document, hits in
                let title = try? document.title()
                let links = (try? document.select("a[href]").count) ?? 0
                return ScenarioProbeResult(
                    status: hits.count >= 3 ? .matched : .partial,
                    summary: "基础 DOM 可解析，链接数 \(links)。",
                    selectorHits: hits,
                    title: title,
                    matchedCount: links
                )
            }
        )
    }

    private nonisolated static func parseDoubanSearchBooks(html: String) -> [DoubanSearchBookItem] {
        guard let document = try? SwiftSoup.parse(html) else {
            return []
        }
        guard let itemRoots = try? document.getElementsByClass("item-root").array() else {
            return []
        }
        return itemRoots.compactMap { itemRoot in
            parseDoubanSearchBook(itemRoot)
        }
    }

    private nonisolated static func parseDoubanSearchBook(_ itemRoot: Element) -> DoubanSearchBookItem? {
        guard let titleElement = try? itemRoot.getElementsByClass("title-text").first(),
              let rawTitle = try? titleElement.text() else {
            return nil
        }
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.isEmpty == false else { return nil }

        let subjectURL = (try? titleElement.attr("href")) ?? ""
        guard let doubanId = extractDoubanId(from: subjectURL) else {
            return nil
        }

        let cover = ((try? itemRoot.getElementsByClass("cover").first()?.attr("src")) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let info = ((try? itemRoot.getElementsByClass("meta abstract").first()?.text()) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return DoubanSearchBookItem(
            doubanId: doubanId,
            title: title,
            coverURLString: cover,
            info: info
        )
    }

    private nonisolated static func extractDoubanId(from subjectURL: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: "/subject/(\\d+)/", options: []) else {
            return nil
        }
        let range = NSRange(subjectURL.startIndex..<subjectURL.endIndex, in: subjectURL)
        guard let match = regex.firstMatch(in: subjectURL, options: [], range: range),
              match.numberOfRanges > 1,
              let idRange = Range(match.range(at: 1), in: subjectURL) else {
            return nil
        }
        return Int(subjectURL[idRange])
    }

    private nonisolated static func detectDoubanAntiBot(html: String, finalURL: URL) -> ScenarioProbeResult? {
        let lowercasedURL = finalURL.absoluteString.lowercased()
        let antiBotTexts = [
            "有异常请求从你的 ip 发出",
            "登录后再访问豆瓣",
            "sec.douban.com",
            "misc/sorry"
        ]
        let normalizedHTML = html.lowercased()
        let hitText = antiBotTexts.first { normalizedHTML.contains($0) || lowercasedURL.contains($0) }
        guard let hitText else {
            return nil
        }
        return ScenarioProbeResult(
            status: .antiBot,
            summary: "命中豆瓣风控线索：\(hitText)。",
            selectorHits: [],
            title: nil,
            matchedCount: 0
        )
    }

    private nonisolated static func hasDoubanLoginCookie(_ cookies: [HTTPCookie]) -> Bool {
        cookies.contains { cookie in
            let name = cookie.name.lowercased()
            return name == "dbcl2" || name == "ck"
        }
    }

    private nonisolated static func probeDocument(
        html: String,
        selectors: [String],
        successSummary: (Document, [String]) -> ScenarioProbeResult
    ) -> ScenarioProbeResult {
        do {
            let document = try SwiftSoup.parse(html)
            let hits = selectors.compactMap { selector in
                ((try? document.select(selector).isEmpty()) == false) ? selector : nil
            }
            guard !hits.isEmpty else {
                return ScenarioProbeResult(
                    status: .selectorMiss,
                    summary: "未命中任何关键选择器。",
                    selectorHits: [],
                    title: try? document.title(),
                    matchedCount: 0
                )
            }
            return successSummary(document, hits)
        } catch {
            return ScenarioProbeResult(
                status: .parseFailed,
                summary: error.localizedDescription,
                selectorHits: [],
                title: nil,
                matchedCount: 0
            )
        }
    }
}

private extension String {
    var urlQueryEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }

    var urlPathEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self
    }
}
