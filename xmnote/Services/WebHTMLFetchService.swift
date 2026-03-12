/**
 * [INPUT]: 依赖 Foundation URLSession 与 WebKit WKWebView/WKHTTPCookieStore，依赖 XMImageRequestBuilder 提供站点请求头策略
 * [OUTPUT]: 对外提供 WebHTMLFetchService 与网页抓取基础类型，统一 HTML 抓取、Cookie 桥接与会话隔离
 * [POS]: Services 模块的网页抓取基础设施，服务后续在线搜索与 Debug 验证场景
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import WebKit

@MainActor
protocol WebHTMLFetchServiceProtocol {
    /// 抓取目标网页 HTML，按请求指定的通道与会话策略返回可解析结果。
    func fetchHTML(_ request: WebHTMLFetchRequest) async throws -> WebHTMLFetchResult
}

enum WebFetchChannel: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case http
    case webView

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic:
            return "自动"
        case .http:
            return "HTTP"
        case .webView:
            return "WebView"
        }
    }
}

enum WebSessionScope: String, CaseIterable, Identifiable, Sendable {
    case sharedDefault
    case sharedDouban
    case ephemeral

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sharedDefault:
            return "共享默认"
        case .sharedDouban:
            return "共享豆瓣"
        case .ephemeral:
            return "临时会话"
        }
    }

    var webDataStoreIdentifier: UUID {
        switch self {
        case .sharedDefault:
            return UUID(uuidString: "D0D1C4F5-6C11-4A5A-95F8-9D3B7295AA01") ?? UUID()
        case .sharedDouban:
            return UUID(uuidString: "D0D1C4F5-6C11-4A5A-95F8-9D3B7295AA02") ?? UUID()
        case .ephemeral:
            return UUID(uuidString: "D0D1C4F5-6C11-4A5A-95F8-9D3B7295AA03") ?? UUID()
        }
    }
}

enum WebWaitPolicy: Sendable, Equatable {
    case afterDidFinish(delayMilliseconds: Int)

    static let `default`: WebWaitPolicy = .afterDidFinish(delayMilliseconds: 280)

    var delayNanoseconds: UInt64 {
        switch self {
        case .afterDidFinish(let delayMilliseconds):
            return UInt64(max(delayMilliseconds, 0)) * 1_000_000
        }
    }
}

struct WebHTMLFetchRequest: Sendable {
    let url: URL
    let channel: WebFetchChannel
    let sessionScope: WebSessionScope
    let timeout: TimeInterval
    let additionalHeaders: [String: String]
    let waitPolicy: WebWaitPolicy

    init(
        url: URL,
        channel: WebFetchChannel = .automatic,
        sessionScope: WebSessionScope = .sharedDefault,
        timeout: TimeInterval = 20,
        additionalHeaders: [String: String] = [:],
        waitPolicy: WebWaitPolicy = .default
    ) {
        self.url = url
        self.channel = channel
        self.sessionScope = sessionScope
        self.timeout = timeout
        self.additionalHeaders = additionalHeaders
        self.waitPolicy = waitPolicy
    }

    func overridingChannel(_ channel: WebFetchChannel) -> WebHTMLFetchRequest {
        WebHTMLFetchRequest(
            url: url,
            channel: channel,
            sessionScope: sessionScope,
            timeout: timeout,
            additionalHeaders: additionalHeaders,
            waitPolicy: waitPolicy
        )
    }
}

struct WebHTMLFetchResult: Sendable {
    let html: String
    let finalURL: URL
    let pageTitle: String?
    let channel: WebFetchChannel
    let elapsedMilliseconds: Int
    let cookies: [HTTPCookie]

    var htmlLength: Int {
        html.count
    }
}

enum WebHTMLFetchError: LocalizedError {
    case invalidHTTPResponse
    case emptyHTML
    case network(description: String)
    case webView(description: String)

    var errorDescription: String? {
        switch self {
        case .invalidHTTPResponse:
            return "服务端未返回有效的 HTTP 响应。"
        case .emptyHTML:
            return "页面返回了空 HTML。"
        case .network(let description):
            return description
        case .webView(let description):
            return description
        }
    }
}

/// 网页 HTML 抓取服务，负责执行 HTTP / WebView 两条运输链路，并统一维护 Cookie 与会话隔离。
@MainActor
final class WebHTMLFetchService: WebHTMLFetchServiceProtocol {
    static let shared = WebHTMLFetchService()

    private struct SessionContext {
        let dataStore: WKWebsiteDataStore
        let webView: WKWebView
    }

    private let cookieBridge = WebHTTPCookieBridge()
    private let webViewGate = WebViewSessionGate()
    private var sessionContexts: [WebSessionScope: SessionContext] = [:]

    /// 执行一次 HTML 抓取；`.automatic` 仅作为兼容行为保留，正式自动策略由场景层编排。
    func fetchHTML(_ request: WebHTMLFetchRequest) async throws -> WebHTMLFetchResult {
        switch request.channel {
        case .automatic:
            do {
                return try await fetchViaHTTP(request.overridingChannel(.http))
            } catch {
                return try await fetchViaWebView(request.overridingChannel(.webView))
            }
        case .http:
            return try await fetchViaHTTP(request)
        case .webView:
            return try await fetchViaWebView(request)
        }
    }
}

private extension WebHTMLFetchService {
    func fetchViaHTTP(_ request: WebHTMLFetchRequest) async throws -> WebHTMLFetchResult {
        let startedAt = ContinuousClock.now
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = "GET"
        urlRequest.timeoutInterval = request.timeout
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        applyHeaders(to: &urlRequest, additionalHeaders: request.additionalHeaders)

        let requestCookies = await cookieBridge.cookiesForRequest(url: request.url) {
            self.cookieStore(for: request.sessionScope)
        }
        if !requestCookies.isEmpty {
            HTTPCookie.requestHeaderFields(with: requestCookies).forEach {
                urlRequest.setValue($0.value, forHTTPHeaderField: $0.key)
            }
        }

        let session = makeURLSession(timeout: request.timeout)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw WebHTMLFetchError.network(description: error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebHTMLFetchError.invalidHTTPResponse
        }

        let responseURL = httpResponse.url ?? request.url
        let responseCookies = HTTPCookie.cookies(withResponseHeaderFields: normalizedHeaders(httpResponse), for: responseURL)
        await cookieBridge.merge(responseCookies) {
            self.cookieStore(for: request.sessionScope)
        }

        let html = await HTMLDecoder.decode(
            data: data,
            textEncodingName: httpResponse.textEncodingName
        )
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WebHTMLFetchError.emptyHTML
        }

        return WebHTMLFetchResult(
            html: html,
            finalURL: responseURL,
            pageTitle: nil,
            channel: .http,
            elapsedMilliseconds: elapsedMilliseconds(since: startedAt),
            cookies: await cookieBridge.allCookies {
                self.cookieStore(for: request.sessionScope)
            }
        )
    }

    func fetchViaWebView(_ request: WebHTMLFetchRequest) async throws -> WebHTMLFetchResult {
        let executeLoad = {
            try await self.performWebViewLoad(request)
        }

        if request.sessionScope == .ephemeral {
            return try await executeLoad()
        }

        return try await webViewGate.withAccess(scope: request.sessionScope) {
            try await executeLoad()
        }
    }

    func performWebViewLoad(_ request: WebHTMLFetchRequest) async throws -> WebHTMLFetchResult {
        let startedAt = ContinuousClock.now
        let context = sessionContext(for: request.sessionScope)
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = "GET"
        urlRequest.timeoutInterval = request.timeout
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        applyHeaders(to: &urlRequest, additionalHeaders: request.additionalHeaders)

        let cookies = await cookieBridge.cookiesForRequest(url: request.url) {
            self.cookieStore(for: request.sessionScope)
        }
        if !cookies.isEmpty {
            HTTPCookie.requestHeaderFields(with: cookies).forEach {
                urlRequest.setValue($0.value, forHTTPHeaderField: $0.key)
            }
        }

        let loaderResult = try await WebViewHTMLLoader.loadHTML(
            with: context.webView,
            request: urlRequest,
            waitPolicy: request.waitPolicy
        )

        return WebHTMLFetchResult(
            html: loaderResult.html,
            finalURL: loaderResult.finalURL,
            pageTitle: loaderResult.pageTitle,
            channel: .webView,
            elapsedMilliseconds: elapsedMilliseconds(since: startedAt),
            cookies: await cookieBridge.allCookies {
                self.cookieStore(for: request.sessionScope)
            }
        )
    }

    private func sessionContext(for scope: WebSessionScope) -> SessionContext {
        if scope != .ephemeral, let existing = sessionContexts[scope] {
            return existing
        }

        let dataStore: WKWebsiteDataStore
        switch scope {
        case .ephemeral:
            dataStore = .nonPersistent()
        case .sharedDefault, .sharedDouban:
            if #available(iOS 17.0, *) {
                dataStore = WKWebsiteDataStore(forIdentifier: scope.webDataStoreIdentifier)
            } else {
                dataStore = .default()
            }
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = XMImageRequestBuilder.browserUserAgent
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }

        let context = SessionContext(dataStore: dataStore, webView: webView)
        if scope != .ephemeral {
            sessionContexts[scope] = context
        }
        return context
    }

    func cookieStore(for scope: WebSessionScope) -> WKHTTPCookieStore {
        sessionContext(for: scope).dataStore.httpCookieStore
    }

    func applyHeaders(to request: inout URLRequest, additionalHeaders: [String: String]) {
        XMImageRequestBuilder.browserHeaderFields(for: request.url).forEach {
            request.setValue($0.value, forHTTPHeaderField: $0.key)
        }
        additionalHeaders.forEach {
            request.setValue($0.value, forHTTPHeaderField: $0.key)
        }
    }

    func normalizedHeaders(_ response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        response.allHeaderFields.forEach { key, value in
            headers[String(describing: key)] = String(describing: value)
        }
        return headers
    }

    func makeURLSession(timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Int {
        let duration = start.duration(to: ContinuousClock.now)
        let seconds = duration.components.seconds
        let attoseconds = duration.components.attoseconds
        return max(0, Int(seconds * 1_000) + Int(attoseconds / 1_000_000_000_000_000))
    }
}

private actor HTMLDecoder {
    static func decode(data: Data, textEncodingName: String?) async -> String {
        await Task.detached(priority: .utility) {
            decodeSynchronously(data: data, textEncodingName: textEncodingName)
        }.value
    }

    private static func decodeSynchronously(data: Data, textEncodingName: String?) -> String {
        if let textEncodingName,
           let encoding = stringEncoding(forIANAName: textEncodingName),
           let html = String(data: data, encoding: encoding) {
            return html
        }
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        if let gb18030Encoding = stringEncoding(forIANAName: "GB18030"),
           let html = String(data: data, encoding: gb18030Encoding) {
            return html
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func stringEncoding(forIANAName name: String) -> String.Encoding? {
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else {
            return nil
        }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }
}

private actor WebHTTPCookieBridge {
    func allCookies(storeProvider: @escaping @MainActor () -> WKHTTPCookieStore) async -> [HTTPCookie] {
        let store = await MainActor.run {
            storeProvider()
        }
        return await store.allCookies()
    }

    func cookiesForRequest(
        url: URL,
        storeProvider: @escaping @MainActor () -> WKHTTPCookieStore
    ) async -> [HTTPCookie] {
        let cookies = await allCookies(storeProvider: storeProvider)
        return cookies.filter { $0.matches(url: url) }
    }

    func merge(
        _ cookies: [HTTPCookie],
        storeProvider: @escaping @MainActor () -> WKHTTPCookieStore
    ) async {
        guard !cookies.isEmpty else { return }
        let store = await MainActor.run {
            storeProvider()
        }
        for cookie in cookies {
            await store.setCookie(cookie)
        }
    }
}

private actor WebViewSessionGate {
    private var isLockedByScope: [WebSessionScope: Bool] = [:]
    private var waitersByScope: [WebSessionScope: [CheckedContinuation<Void, Never>]] = [:]

    func withAccess<T: Sendable>(scope: WebSessionScope, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        await acquire(scope: scope)
        defer { release(scope: scope) }
        return try await operation()
    }

    private func acquire(scope: WebSessionScope) async {
        if isLockedByScope[scope] != true {
            isLockedByScope[scope] = true
            return
        }

        await withCheckedContinuation { continuation in
            waitersByScope[scope, default: []].append(continuation)
        }
    }

    private func release(scope: WebSessionScope) {
        guard var waiters = waitersByScope[scope], waiters.isEmpty == false else {
            isLockedByScope[scope] = false
            waitersByScope[scope] = nil
            return
        }

        let continuation = waiters.removeFirst()
        waitersByScope[scope] = waiters.isEmpty ? nil : waiters
        continuation.resume()
    }
}

private extension HTTPCookie {
    nonisolated func matches(url: URL) -> Bool {
        guard let host = url.host?.lowercased() else {
            return false
        }
        let normalizedDomain = domain
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        let pathPrefix = path.isEmpty ? "/" : path
        let hostMatches = host == normalizedDomain || host.hasSuffix("." + normalizedDomain)
        let pathMatches = url.path.isEmpty ? pathPrefix == "/" : url.path.hasPrefix(pathPrefix)
        return hostMatches && pathMatches
    }
}

private enum WebViewHTMLLoader {
    struct Result {
        let html: String
        let finalURL: URL
        let pageTitle: String?
    }

    static func loadHTML(
        with webView: WKWebView,
        request: URLRequest,
        waitPolicy: WebWaitPolicy
    ) async throws -> Result {
        let proxy = NavigationProxy(waitPolicy: waitPolicy)
        webView.stopLoading()
        webView.navigationDelegate = proxy
        defer {
            if webView.navigationDelegate === proxy {
                webView.navigationDelegate = nil
            }
        }
        return try await proxy.load(webView: webView, request: request)
    }

    private final class NavigationProxy: NSObject, WKNavigationDelegate {
        private let waitPolicy: WebWaitPolicy
        private var continuation: CheckedContinuation<Result, Error>?
        private var hasCompleted = false

        init(waitPolicy: WebWaitPolicy) {
            self.waitPolicy = waitPolicy
        }

        func load(webView: WKWebView, request: URLRequest) async throws -> Result {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                webView.load(request)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                do {
                    try await stabilizeDOM(on: webView)
                    let html = try await evaluateString(webView, script: "document.documentElement.outerHTML")
                    let pageTitle = try? await evaluateString(webView, script: "document.title")
                    guard let finalURL = webView.url ?? webView.backForwardList.currentItem?.url else {
                    finish(with: Swift.Result.failure(WebHTMLFetchError.webView(description: "WebView 未返回最终 URL。")))
                        return
                    }
                    guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        finish(with: Swift.Result.failure(WebHTMLFetchError.emptyHTML))
                        return
                    }
                    finish(with: Swift.Result.success(Result(html: html, finalURL: finalURL, pageTitle: pageTitle)))
                } catch {
                    finish(with: Swift.Result.failure(error))
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            finish(with: Swift.Result.failure(WebHTMLFetchError.webView(description: error.localizedDescription)))
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            finish(with: Swift.Result.failure(WebHTMLFetchError.webView(description: error.localizedDescription)))
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            finish(with: Swift.Result.failure(WebHTMLFetchError.webView(description: "网页内容进程异常终止。")))
        }

        func webView(
            _ webView: WKWebView,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            completionHandler(.performDefaultHandling, nil)
        }

        private func stabilizeDOM(on webView: WKWebView) async throws {
            for _ in 0..<6 {
                let state = try await evaluateString(webView, script: "document.readyState")
                if state == "complete" || state == "interactive" {
                    break
                }
                try await Task.sleep(nanoseconds: 120_000_000)
            }
            try await Task.sleep(nanoseconds: waitPolicy.delayNanoseconds)
        }

        private func evaluateString(_ webView: WKWebView, script: String) async throws -> String {
            try await withCheckedThrowingContinuation { continuation in
                webView.evaluateJavaScript(script) { value, error in
                    if let error {
                        continuation.resume(throwing: WebHTMLFetchError.webView(description: error.localizedDescription))
                        return
                    }
                    if let stringValue = value as? String {
                        continuation.resume(returning: stringValue)
                        return
                    }
                    if let value {
                        continuation.resume(returning: String(describing: value))
                        return
                    }
                    continuation.resume(returning: "")
                }
            }
        }

        private func finish(with result: Swift.Result<WebViewHTMLLoader.Result, Error>) {
            guard hasCompleted == false, let continuation else { return }
            hasCompleted = true
            self.continuation = nil
            continuation.resume(with: result)
        }
    }
}
