/**
 * [INPUT]: 依赖 WebKit WKWebView 读取番茄搜索页运行时 DOM，依赖 FanqieWebVerificationService 复用共享会话与请求头策略
 * [OUTPUT]: 对外提供 FanqieDOMSearchService，统一输出番茄详情链接、调试快照与风控状态报告
 * [POS]: Services 模块的番茄 DOM 搜索层，专门解决番茄搜索页首屏壳页、桌面视口与风控伪空态问题
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import OSLog
import WebKit

/// 番茄搜索页 DOM 抓取器，对正式链路返回详情链接，对调试链路返回完整运行报告。
final class FanqieDOMSearchService {
    enum DebugStatus: String, Sendable {
        case idle
        case loading
        case success
        case empty
        case unrecognizedResult
        case verificationRequired
        case timeout
        case failed

        var title: String {
            switch self {
            case .idle:
                return "未开始"
            case .loading:
                return "抓取中"
            case .success:
                return "成功"
            case .empty:
                return "空结果"
            case .unrecognizedResult:
                return "结构未识别"
            case .verificationRequired:
                return "命中风控"
            case .timeout:
                return "超时"
            case .failed:
                return "失败"
            }
        }
    }

    struct DebugSnapshot: Identifiable, Sendable {
        let id = UUID()
        let attempt: Int
        let finalURL: String
        let documentReadyState: String
        let viewportWidth: Int
        let hasSearchInput: Bool
        let hasEmptyResultText: Bool
        let hasLoadingIndicator: Bool
        let hasVerificationMarker: Bool
        let stateLoading: Bool?
        let stateTotal: Int?
        let resultContainerCount: Int
        let candidateURLCount: Int
        let stateBookIDCount: Int
        let reactBookIDCount: Int
        let linkCount: Int
        let urlHasForceMobile: Bool
        let selectorHitNames: [String]
        let resultTextSamples: [String]
    }

    struct DebugEvent: Identifiable, Sendable {
        let id = UUID()
        let message: String
    }

    struct DebugReport: Sendable {
        let keyword: String
        let requestURL: String?
        let finalURL: String?
        let status: DebugStatus
        let message: String?
        let htmlResult: String?
        let htmlLength: Int?
        let detailPageURLs: [URL]
        let candidateDetailPageURLs: [URL]
        let selectorHitNames: [String]
        let resultTextSamples: [String]
        let resultHTMLSamples: [String]
        let snapshots: [DebugSnapshot]
        let events: [DebugEvent]

        static func idle(keyword: String) -> DebugReport {
            DebugReport(
                keyword: keyword,
                requestURL: nil,
                finalURL: nil,
                status: .idle,
                message: nil,
                htmlResult: nil,
                htmlLength: nil,
                detailPageURLs: [],
                candidateDetailPageURLs: [],
                selectorHitNames: [],
                resultTextSamples: [],
                resultHTMLSamples: [],
                snapshots: [],
                events: []
            )
        }

        static func loading(keyword: String, requestURL: String?) -> DebugReport {
            DebugReport(
                keyword: keyword,
                requestURL: requestURL,
                finalURL: nil,
                status: .loading,
                message: nil,
                htmlResult: nil,
                htmlLength: nil,
                detailPageURLs: [],
                candidateDetailPageURLs: [],
                selectorHitNames: [],
                resultTextSamples: [],
                resultHTMLSamples: [],
                snapshots: [],
                events: [.init(message: "开始搜索“\(keyword)”")]
            )
        }
    }

    private static let logger = Logger(subsystem: "xmnote", category: "FanqieDOMSearch")
    private let maxPollCount = 30
    private let pollDelayNanoseconds: UInt64 = 300_000_000
    private let maxViewportRetryCount = 1
    private let requiredStableObservationCount = 3
    private let desktopViewport = CGRect(x: 0, y: 0, width: 1440, height: 900)

    /// 在共享番茄会话中打开搜索页，并从运行时 DOM 中提取详情页链接。
    @MainActor
    func fetchDetailPageURLs(keyword: String) async throws -> [URL] {
        let report = await runDebugSearch(keyword: keyword, captureHTML: false)

        switch report.status {
        case .success:
            return report.detailPageURLs
        case .empty:
            return []
        case .unrecognizedResult:
            throw BookSearchError.sourceUnavailable(
                message: report.message ?? "番茄页面已加载，但当前结果结构尚未识别"
            )
        case .verificationRequired:
            throw BookSearchError.fanqieVerificationRequired
        case .timeout:
            throw BookSearchError.sourceUnavailable(message: report.message ?? "番茄搜索结果加载超时，请稍后重试")
        case .failed, .idle, .loading:
            throw BookSearchError.sourceUnavailable(message: report.message ?? "番茄搜索页暂时不可用，请稍后重试")
        }
    }

    /// 为测试页输出完整的番茄搜索 DOM 调试报告。
    @MainActor
    func runDebugSearch(keyword: String, captureHTML: Bool = true) async -> DebugReport {
        let verificationService = FanqieWebVerificationService.shared
        let trimmedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKeyword.isEmpty else {
            return makeReport(
                keyword: keyword,
                requestURL: nil,
                finalURL: nil,
                status: .failed,
                message: "请输入番茄搜索关键词。",
                htmlResult: nil,
                detailPageURLs: [],
                candidateDetailPageURLs: [],
                selectorHitNames: [],
                resultTextSamples: [],
                resultHTMLSamples: [],
                snapshots: [],
                events: [.init(message: "关键词为空，未开始搜索")]
            )
        }

        guard let searchURL = verificationService.makeSearchURL(keyword: trimmedKeyword) else {
            return makeReport(
                keyword: trimmedKeyword,
                requestURL: nil,
                finalURL: nil,
                status: .failed,
                message: "番茄搜索地址无效",
                htmlResult: nil,
                detailPageURLs: [],
                candidateDetailPageURLs: [],
                selectorHitNames: [],
                resultTextSamples: [],
                resultHTMLSamples: [],
                snapshots: [],
                events: [.init(message: "搜索地址构造失败")]
            )
        }

        var allSnapshots: [DebugSnapshot] = []
        var allEvents: [DebugEvent] = [.init(message: "开始搜索“\(trimmedKeyword)”")]
        var lastCandidateDetailPageURLs: [URL] = []
        var lastSelectorHitNames: [String] = []
        var lastResultTextSamples: [String] = []
        var lastResultHTMLSamples: [String] = []

        for retryIndex in 0...maxViewportRetryCount {
            let attemptLabel = retryIndex == 0 ? "首轮搜索" : "桌面视口重试第 \(retryIndex) 次"
            allEvents.append(.init(message: "\(attemptLabel)：创建桌面 WebView（1440x900）"))
            Self.logger.notice("[fanqie.search.start] keyword=\(trimmedKeyword, privacy: .public) retry=\(retryIndex)")

            let configuration = verificationService.makeWebViewConfiguration(preferredContentMode: .desktop)
            let webView = makeSearchWebView(configuration: configuration)
            let navigationLoader = NavigationLoader()
            webView.navigationDelegate = navigationLoader

            do {
                try await navigationLoader.load(webView: webView, request: verificationService.makeRequest(url: searchURL))
                let finishedURL = webView.url?.absoluteString ?? searchURL.absoluteString
                allEvents.append(.init(message: "搜索页加载完成：\(finishedURL)"))
                Self.logger.notice("[fanqie.search.did-finish] keyword=\(trimmedKeyword, privacy: .public) retry=\(retryIndex) finalURL=\(finishedURL, privacy: .public)")
            } catch {
                let message = "搜索页加载失败：\(error.localizedDescription)"
                allEvents.append(.init(message: message))
                Self.logger.error("[fanqie.search.webview-error] keyword=\(trimmedKeyword, privacy: .public) retry=\(retryIndex) error=\(error.localizedDescription, privacy: .public)")
                return makeReport(
                    keyword: trimmedKeyword,
                    requestURL: searchURL.absoluteString,
                    finalURL: webView.url?.absoluteString ?? searchURL.absoluteString,
                    status: .failed,
                    message: "番茄搜索页暂时不可用，请稍后重试",
                    htmlResult: captureHTML ? await captureHTMLIfNeeded(on: webView) : nil,
                    detailPageURLs: [],
                    candidateDetailPageURLs: lastCandidateDetailPageURLs,
                    selectorHitNames: lastSelectorHitNames,
                    resultTextSamples: lastResultTextSamples,
                    resultHTMLSamples: lastResultHTMLSamples,
                    snapshots: allSnapshots,
                    events: allEvents
                )
            }

            var shouldRetryForViewport = false
            var stableResultWithoutCandidateCount = 0

            for attempt in 0..<maxPollCount {
                do {
                    let rawSnapshot = try await evaluateSnapshot(on: webView)
                    let candidateDetailPageURLs = resolveCandidateDetailPageURLs(from: rawSnapshot)
                    let snapshot = makeDebugSnapshot(
                        from: rawSnapshot,
                        attempt: attempt + 1,
                        finalURL: webView.url,
                        candidateDetailPageURLs: candidateDetailPageURLs
                    )
                    lastCandidateDetailPageURLs = candidateDetailPageURLs
                    lastSelectorHitNames = rawSnapshot.selectorHitNames
                    lastResultTextSamples = rawSnapshot.resultTextSamples
                    lastResultHTMLSamples = rawSnapshot.resultHTMLSamples
                    allSnapshots.append(snapshot)
                    Self.logger.debug(
                        "[fanqie.search.snapshot] retry=\(retryIndex) attempt=\(snapshot.attempt) links=\(snapshot.linkCount) candidates=\(snapshot.candidateURLCount) stateBookIDs=\(snapshot.stateBookIDCount) reactBookIDs=\(snapshot.reactBookIDCount) ready=\(snapshot.documentReadyState, privacy: .public) width=\(snapshot.viewportWidth) hasInput=\(snapshot.hasSearchInput) hasEmpty=\(snapshot.hasEmptyResultText) hasLoading=\(snapshot.hasLoadingIndicator) hasVerify=\(snapshot.hasVerificationMarker) stateLoading=\(String(describing: snapshot.stateLoading), privacy: .public) stateTotal=\(String(describing: snapshot.stateTotal), privacy: .public) forceMobile=\(snapshot.urlHasForceMobile) containers=\(snapshot.resultContainerCount) url=\(snapshot.finalURL, privacy: .public)"
                    )

                    let hasVerification = snapshot.hasVerificationMarker
                        || FanqieVerificationHeuristics.requiresVerification(html: "", finalURL: webView.url)
                    if hasVerification {
                        allEvents.append(.init(message: "命中番茄风控，等待用户完成验证"))
                        Self.logger.notice("[fanqie.search.verification-required] url=\(snapshot.finalURL, privacy: .public)")
                        return makeReport(
                            keyword: trimmedKeyword,
                            requestURL: searchURL.absoluteString,
                            finalURL: snapshot.finalURL,
                            status: .verificationRequired,
                            message: "番茄搜索触发了站点验证",
                            htmlResult: captureHTML ? await captureHTMLIfNeeded(on: webView) : nil,
                            detailPageURLs: [],
                            candidateDetailPageURLs: candidateDetailPageURLs,
                            selectorHitNames: rawSnapshot.selectorHitNames,
                            resultTextSamples: rawSnapshot.resultTextSamples,
                            resultHTMLSamples: rawSnapshot.resultHTMLSamples,
                            snapshots: allSnapshots,
                            events: allEvents
                        )
                    }

                    let viewportAbnormal = snapshot.urlHasForceMobile || snapshot.viewportWidth < 600
                    if viewportAbnormal {
                        allEvents.append(.init(message: "当前页面落入移动视口：width=\(snapshot.viewportWidth)，URL=\(snapshot.finalURL)"))
                        if retryIndex < maxViewportRetryCount {
                            allEvents.append(.init(message: "销毁当前 WebView，重建桌面视口后重试"))
                            shouldRetryForViewport = true
                            break
                        }

                        Self.logger.error("[fanqie.search.viewport-error] width=\(snapshot.viewportWidth) url=\(snapshot.finalURL, privacy: .public)")
                        return makeReport(
                            keyword: trimmedKeyword,
                            requestURL: searchURL.absoluteString,
                            finalURL: snapshot.finalURL,
                            status: .failed,
                            message: "番茄搜索页视口异常，请稍后重试",
                            htmlResult: captureHTML ? await captureHTMLIfNeeded(on: webView) : nil,
                            detailPageURLs: [],
                            candidateDetailPageURLs: candidateDetailPageURLs,
                            selectorHitNames: rawSnapshot.selectorHitNames,
                            resultTextSamples: rawSnapshot.resultTextSamples,
                            resultHTMLSamples: rawSnapshot.resultHTMLSamples,
                            snapshots: allSnapshots,
                            events: allEvents
                        )
                    }

                    if !candidateDetailPageURLs.isEmpty {
                        allEvents.append(.init(message: "命中详情链接 \(candidateDetailPageURLs.count) 条"))
                        Self.logger.notice("[fanqie.search.links-found] count=\(candidateDetailPageURLs.count) url=\(snapshot.finalURL, privacy: .public)")
                        return makeReport(
                            keyword: trimmedKeyword,
                            requestURL: searchURL.absoluteString,
                            finalURL: snapshot.finalURL,
                            status: .success,
                            message: nil,
                            htmlResult: captureHTML ? await captureHTMLIfNeeded(on: webView) : nil,
                            detailPageURLs: candidateDetailPageURLs,
                            candidateDetailPageURLs: candidateDetailPageURLs,
                            selectorHitNames: rawSnapshot.selectorHitNames,
                            resultTextSamples: rawSnapshot.resultTextSamples,
                            resultHTMLSamples: rawSnapshot.resultHTMLSamples,
                            snapshots: allSnapshots,
                            events: allEvents
                        )
                    }

                    let stateSaysEmpty = snapshot.stateLoading == false
                        && (snapshot.stateTotal ?? 0) == 0
                        && snapshot.resultContainerCount == 0
                        && rawSnapshot.reactBookIDs.isEmpty
                        && snapshot.hasVerificationMarker == false
                    if snapshot.hasEmptyResultText || stateSaysEmpty {
                        allEvents.append(.init(message: "搜索结束，番茄返回空结果"))
                        Self.logger.notice("[fanqie.search.empty] url=\(snapshot.finalURL, privacy: .public)")
                        return makeReport(
                            keyword: trimmedKeyword,
                            requestURL: searchURL.absoluteString,
                            finalURL: snapshot.finalURL,
                            status: .empty,
                            message: nil,
                            htmlResult: captureHTML ? await captureHTMLIfNeeded(on: webView) : nil,
                            detailPageURLs: [],
                            candidateDetailPageURLs: [],
                            selectorHitNames: rawSnapshot.selectorHitNames,
                            resultTextSamples: rawSnapshot.resultTextSamples,
                            resultHTMLSamples: rawSnapshot.resultHTMLSamples,
                            snapshots: allSnapshots,
                            events: allEvents
                        )
                    }

                    let pageIsStable = snapshot.documentReadyState == "complete"
                        && snapshot.hasLoadingIndicator == false
                    let shellOnly = snapshot.hasSearchInput
                        && snapshot.resultContainerCount == 0
                        && snapshot.candidateURLCount == 0
                        && rawSnapshot.reactBookIDs.isEmpty
                        && snapshot.stateTotal == nil
                        && snapshot.hasEmptyResultText == false
                    let hasResultEvidence = snapshot.resultContainerCount > 0
                        || rawSnapshot.reactBookIDs.isEmpty == false
                        || (snapshot.stateTotal ?? 0) > 0
                        || rawSnapshot.resultTextSamples.isEmpty == false

                    if pageIsStable && hasResultEvidence && candidateDetailPageURLs.isEmpty {
                        stableResultWithoutCandidateCount += 1
                    } else {
                        stableResultWithoutCandidateCount = 0
                    }

                    if stableResultWithoutCandidateCount >= requiredStableObservationCount {
                        allEvents.append(.init(message: "页面已稳定并展示结果，但当前解析规则未识别到详情链接"))
                        Self.logger.error(
                            "[fanqie.search.unrecognized] total=\(String(describing: snapshot.stateTotal), privacy: .public) containers=\(snapshot.resultContainerCount) url=\(snapshot.finalURL, privacy: .public)"
                        )
                        return makeReport(
                            keyword: trimmedKeyword,
                            requestURL: searchURL.absoluteString,
                            finalURL: snapshot.finalURL,
                            status: .unrecognizedResult,
                            message: "番茄页面已加载，但当前结果结构尚未识别",
                            htmlResult: captureHTML ? await captureHTMLIfNeeded(on: webView) : nil,
                            detailPageURLs: [],
                            candidateDetailPageURLs: [],
                            selectorHitNames: rawSnapshot.selectorHitNames,
                            resultTextSamples: rawSnapshot.resultTextSamples,
                            resultHTMLSamples: rawSnapshot.resultHTMLSamples,
                            snapshots: allSnapshots,
                            events: allEvents
                        )
                    }

                    let needsMoreTime = snapshot.documentReadyState != "complete"
                        || snapshot.hasLoadingIndicator
                        || (shellOnly && snapshot.stateLoading == true)
                        || shellOnly
                    if needsMoreTime, attempt < maxPollCount - 1 {
                        try await Task.sleep(nanoseconds: pollDelayNanoseconds)
                        continue
                    }

                    if (pageIsStable == false || hasResultEvidence == false) && attempt < maxPollCount - 1 {
                        try await Task.sleep(nanoseconds: pollDelayNanoseconds)
                        continue
                    }
                } catch {
                    allEvents.append(.init(message: "搜索页快照解析失败：\(error.localizedDescription)"))
                    Self.logger.error("[fanqie.search.snapshot-failed] keyword=\(trimmedKeyword, privacy: .public) retry=\(retryIndex) error=\(error.localizedDescription, privacy: .public)")
                    return makeReport(
                        keyword: trimmedKeyword,
                        requestURL: searchURL.absoluteString,
                        finalURL: webView.url?.absoluteString ?? searchURL.absoluteString,
                        status: .failed,
                        message: "番茄搜索页状态解析失败",
                        htmlResult: captureHTML ? await captureHTMLIfNeeded(on: webView) : nil,
                        detailPageURLs: [],
                        candidateDetailPageURLs: lastCandidateDetailPageURLs,
                        selectorHitNames: lastSelectorHitNames,
                        resultTextSamples: lastResultTextSamples,
                        resultHTMLSamples: lastResultHTMLSamples,
                        snapshots: allSnapshots,
                        events: allEvents
                    )
                }
            }

            if shouldRetryForViewport {
                continue
            }

            let finalURL = webView.url?.absoluteString ?? searchURL.absoluteString
            allEvents.append(.init(message: "页面持续未稳定，等待搜索结果超时"))
            Self.logger.error("[fanqie.search.timeout] url=\(finalURL, privacy: .public)")
            return makeReport(
                keyword: trimmedKeyword,
                requestURL: searchURL.absoluteString,
                finalURL: finalURL,
                status: .timeout,
                message: "番茄搜索结果加载超时，请稍后重试",
                htmlResult: captureHTML ? await captureHTMLIfNeeded(on: webView) : nil,
                detailPageURLs: [],
                candidateDetailPageURLs: lastCandidateDetailPageURLs,
                selectorHitNames: lastSelectorHitNames,
                resultTextSamples: lastResultTextSamples,
                resultHTMLSamples: lastResultHTMLSamples,
                snapshots: allSnapshots,
                events: allEvents
            )
        }

        return makeReport(
            keyword: trimmedKeyword,
            requestURL: searchURL.absoluteString,
            finalURL: searchURL.absoluteString,
            status: .failed,
            message: "番茄搜索页暂时不可用，请稍后重试",
            htmlResult: nil,
            detailPageURLs: [],
            candidateDetailPageURLs: lastCandidateDetailPageURLs,
            selectorHitNames: lastSelectorHitNames,
            resultTextSamples: lastResultTextSamples,
            resultHTMLSamples: lastResultHTMLSamples,
            snapshots: allSnapshots,
            events: allEvents
        )
    }
}

@MainActor
private extension FanqieDOMSearchService {
    struct RawSnapshot: Decodable {
        let hrefs: [String]
        let stateBookIDs: [String]
        let reactBookIDs: [String]
        let hasSearchInput: Bool
        let hasEmptyResultText: Bool
        let hasLoadingIndicator: Bool
        let hasVerificationMarker: Bool
        let documentReadyState: String
        let viewportWidth: Int
        let stateLoading: Bool?
        let stateTotal: Int?
        let resultContainerCount: Int
        let urlHasForceMobile: Bool
        let selectorHitNames: [String]
        let resultTextSamples: [String]
        let resultHTMLSamples: [String]
    }

    func makeSearchWebView(configuration: WKWebViewConfiguration) -> WKWebView {
        let webView = WKWebView(frame: desktopViewport, configuration: configuration)
        webView.customUserAgent = XMImageRequestBuilder.browserUserAgent
        webView.allowsBackForwardNavigationGestures = false
        webView.bounds = desktopViewport
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        return webView
    }

    func evaluateSnapshot(on webView: WKWebView) async throws -> RawSnapshot {
        let script = """
        (() => {
            const html = (document.documentElement?.outerHTML || "").toLowerCase();
            const bodyText = document.body?.innerText || "";
            const state = window.__INITIAL_STATE__?.search || null;
            const resultSelectors = [
                "[class*='search-book']",
                "[class*='book-item']",
                "[class*='search-item']",
                "[data-e2e*='search']"
            ];
            const resultNodes = Array.from(document.querySelectorAll(resultSelectors.join(",")));
            const resultItemNodes = Array.from(document.querySelectorAll(".search-book-item"));
            const directHrefs = Array.from(document.querySelectorAll("a[href*='/page/'], a[href^='/page/']"))
                .map((node) => node.href || node.getAttribute("href") || "");
            const nestedHrefs = resultNodes.flatMap((node) => Array.from(node.querySelectorAll("a[href]"))
                .map((link) => link.href || link.getAttribute("href") || "")
            );
            const hrefs = Array.from(new Set(
                directHrefs
                    .concat(nestedHrefs)
                    .map((value) => typeof value === "string" ? value.trim() : "")
                    .filter((value) => value.includes("/page/"))
            ));
            const hasLoadingIndicator = [
                "[class*='loading']",
                "[class*='skeleton']",
                "[class*='placeholder']",
                "[aria-busy='true']"
            ].some((selector) => document.querySelector(selector) !== null);
            const resultContainerCount = resultNodes.length;
            const markers = [
                "verifycenter/captcha",
                "bdturing-verify",
                "x-vc-bdturing-parameters",
                "verify_data",
                "verify_mmo",
                "captcha/v2"
            ];
            const selectorHitNames = [];
            if (document.querySelector("input[placeholder]")) selectorHitNames.push("input[placeholder]");
            if (document.querySelector("a[href*='/page/'], a[href^='/page/']")) selectorHitNames.push("a[href*='/page/']");
            if (resultNodes.length > 0) selectorHitNames.push("result-container");
            if (resultItemNodes.length > 0) selectorHitNames.push("search-book-item");

            const resultTextSamples = resultNodes
                .map((node) => (node.innerText || "").replace(/\\s+/g, " ").trim())
                .filter(Boolean)
                .slice(0, 3)
                .map((text) => text.slice(0, 180));
            const resultHTMLSamples = resultNodes
                .map((node) => (node.outerHTML || "").replace(/\\s+/g, " ").trim())
                .filter(Boolean)
                .slice(0, 2)
                .map((text) => text.slice(0, 600));

            const stateBookIDs = [];
            const seenBookIDs = new Set();
            const collectBookIDs = (value, depth = 0) => {
                if (value == null || depth > 6) return;
                if (Array.isArray(value)) {
                    value.forEach((item) => collectBookIDs(item, depth + 1));
                    return;
                }
                if (typeof value !== "object") return;

                const candidateKeys = ["book_id", "bookId", "novel_id", "novelId", "bookIdStr"];
                candidateKeys.forEach((key) => {
                    const rawValue = value[key];
                    if (rawValue == null) return;
                    const normalized = String(rawValue).trim();
                    if (!normalized || seenBookIDs.has(normalized)) return;
                    seenBookIDs.add(normalized);
                    stateBookIDs.push(normalized);
                });

                Object.values(value).forEach((nested) => collectBookIDs(nested, depth + 1));
            };
            collectBookIDs(state);

            const reactBookIDs = [];
            const seenReactBookIDs = new Set();
            const isBookListArray = (value) => Array.isArray(value)
                && value.some((item) => item && typeof item === "object" && (item.book_id != null || item.book_name != null));
            const extractSearchBookList = (value, depth = 0) => {
                if (value == null || depth > 4) return null;
                if (isBookListArray(value)) return value;
                if (Array.isArray(value)) {
                    for (const item of value) {
                        const nested = extractSearchBookList(item, depth + 1);
                        if (nested) return nested;
                    }
                    return null;
                }
                if (typeof value !== "object") return null;

                const directCandidates = [
                    value.searchBookList,
                    value.props?.searchBookList,
                    value.pendingProps?.searchBookList,
                    value.memoizedProps?.searchBookList,
                    value.props,
                    value.pendingProps,
                    value.memoizedProps
                ];
                for (const candidate of directCandidates) {
                    const nested = extractSearchBookList(candidate, depth + 1);
                    if (nested) return nested;
                }
                return null;
            };
            const reactInternalKeys = ["__reactInternalInstance$", "__reactFiber$"];
            const resolveReactSearchBookList = (node) => {
                const internalKey = Object.getOwnPropertyNames(node).find((key) =>
                    reactInternalKeys.some((prefix) => key.startsWith(prefix))
                );
                if (!internalKey) return [];

                const visited = new Set();
                let cursor = node[internalKey];
                for (let depth = 0; cursor && depth < 12; depth += 1) {
                    if (visited.has(cursor)) break;
                    visited.add(cursor);
                    const payload = extractSearchBookList([cursor.pendingProps, cursor.memoizedProps]);
                    if (payload && payload.length) {
                        return payload;
                    }
                    cursor = cursor.return || null;
                }
                return [];
            };

            for (const node of resultItemNodes) {
                const searchBookList = resolveReactSearchBookList(node);
                for (const item of searchBookList) {
                    const normalized = String(item?.book_id || "").trim();
                    if (!normalized || seenReactBookIDs.has(normalized)) continue;
                    seenReactBookIDs.add(normalized);
                    reactBookIDs.push(normalized);
                }
            }

            return JSON.stringify({
                hrefs,
                stateBookIDs,
                reactBookIDs,
                hasSearchInput: document.querySelector("input[placeholder]") !== null,
                hasEmptyResultText: bodyText.includes("没有搜索到相关结果"),
                hasLoadingIndicator,
                hasVerificationMarker: markers.some((marker) => html.includes(marker)),
                documentReadyState: document.readyState || "",
                viewportWidth: Math.round(window.innerWidth || 0),
                stateLoading: typeof state?.loading === "boolean" ? state.loading : null,
                stateTotal: typeof state?.total === "number" ? state.total : null,
                resultContainerCount,
                urlHasForceMobile: window.location.href.includes("force_mobile=1"),
                selectorHitNames,
                resultTextSamples,
                resultHTMLSamples
            });
        })();
        """
        let rawValue = try await evaluateString(on: webView, script: script)
        guard let data = rawValue.data(using: .utf8) else {
            Self.logger.error("[fanqie.search.snapshot-decode] status=invalid-utf8")
            throw BookSearchError.sourceUnavailable(message: "番茄搜索页状态解析失败")
        }
        do {
            return try JSONDecoder().decode(RawSnapshot.self, from: data)
        } catch {
            Self.logger.error("[fanqie.search.snapshot-decode] status=failed error=\(error.localizedDescription, privacy: .public)")
            throw BookSearchError.sourceUnavailable(message: "番茄搜索页状态解析失败")
        }
    }

    func makeDebugSnapshot(
        from rawSnapshot: RawSnapshot,
        attempt: Int,
        finalURL: URL?,
        candidateDetailPageURLs: [URL]
    ) -> DebugSnapshot {
        let resolvedURL = finalURL?.absoluteString ?? ""
        return DebugSnapshot(
            attempt: attempt,
            finalURL: resolvedURL,
            documentReadyState: rawSnapshot.documentReadyState,
            viewportWidth: rawSnapshot.viewportWidth,
            hasSearchInput: rawSnapshot.hasSearchInput,
            hasEmptyResultText: rawSnapshot.hasEmptyResultText,
            hasLoadingIndicator: rawSnapshot.hasLoadingIndicator,
            hasVerificationMarker: rawSnapshot.hasVerificationMarker,
            stateLoading: rawSnapshot.stateLoading,
            stateTotal: rawSnapshot.stateTotal,
            resultContainerCount: rawSnapshot.resultContainerCount,
            candidateURLCount: candidateDetailPageURLs.count,
            stateBookIDCount: rawSnapshot.stateBookIDs.count,
            reactBookIDCount: rawSnapshot.reactBookIDs.count,
            linkCount: rawSnapshot.hrefs.count,
            urlHasForceMobile: rawSnapshot.urlHasForceMobile,
            selectorHitNames: rawSnapshot.selectorHitNames,
            resultTextSamples: rawSnapshot.resultTextSamples
        )
    }

    func captureHTMLIfNeeded(on webView: WKWebView) async -> String? {
        try? await evaluateString(on: webView, script: "document.documentElement.outerHTML")
    }

    func evaluateString(on webView: WKWebView, script: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let stringValue = value as? String {
                    continuation.resume(returning: stringValue)
                    return
                }
                continuation.resume(returning: value.map { String(describing: $0) } ?? "")
            }
        }
    }

    func absoluteFanqieDetailURL(from rawHref: String) -> URL? {
        let trimmed = rawHref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.host?.contains("fanqienovel.com") == true {
            return url
        }
        guard trimmed.hasPrefix("/page/") else { return nil }
        return URL(string: "https://fanqienovel.com\(trimmed)")
    }

    func absoluteFanqieDetailURL(fromBookID rawBookID: String) -> URL? {
        let trimmed = rawBookID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: "https://fanqienovel.com/page/\(trimmed)")
    }

    func resolveCandidateDetailPageURLs(from rawSnapshot: RawSnapshot) -> [URL] {
        let hrefURLs = rawSnapshot.hrefs.compactMap(absoluteFanqieDetailURL(from:))
        let stateURLs = rawSnapshot.stateBookIDs.compactMap(absoluteFanqieDetailURL(fromBookID:))
        let reactURLs = rawSnapshot.reactBookIDs.compactMap(absoluteFanqieDetailURL(fromBookID:))
        return deduplicatedDetailPageURLs(hrefURLs + stateURLs + reactURLs)
    }

    func deduplicatedDetailPageURLs(_ detailPageURLs: [URL]) -> [URL] {
        var seenBookIDs = Set<String>()
        var results: [URL] = []

        for detailPageURL in detailPageURLs {
            let bookID = detailPageURL.lastPathComponent
            guard !bookID.isEmpty, seenBookIDs.insert(bookID).inserted else {
                continue
            }
            results.append(detailPageURL)
            if results.count == 10 {
                break
            }
        }

        return results
    }

    func makeReport(
        keyword: String,
        requestURL: String?,
        finalURL: String?,
        status: DebugStatus,
        message: String?,
        htmlResult: String?,
        detailPageURLs: [URL],
        candidateDetailPageURLs: [URL],
        selectorHitNames: [String],
        resultTextSamples: [String],
        resultHTMLSamples: [String],
        snapshots: [DebugSnapshot],
        events: [DebugEvent]
    ) -> DebugReport {
        DebugReport(
            keyword: keyword,
            requestURL: requestURL,
            finalURL: finalURL,
            status: status,
            message: message,
            htmlResult: htmlResult,
            htmlLength: htmlResult?.count,
            detailPageURLs: detailPageURLs,
            candidateDetailPageURLs: candidateDetailPageURLs,
            selectorHitNames: selectorHitNames,
            resultTextSamples: resultTextSamples,
            resultHTMLSamples: resultHTMLSamples,
            snapshots: snapshots,
            events: events
        )
    }

    final class NavigationLoader: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Error>?
        private var hasCompleted = false

        func load(webView: WKWebView, request: URLRequest) async throws {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                webView.load(request)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            finish(with: .success(()))
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            finish(with: .failure(error))
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            finish(with: .failure(error))
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            finish(with: .failure(WebHTMLFetchError.webView(description: "网页内容进程异常终止。")))
        }

        func webView(
            _ webView: WKWebView,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            completionHandler(.performDefaultHandling, nil)
        }

        private func finish(with result: Result<Void, Error>) {
            guard hasCompleted == false, let continuation else { return }
            hasCompleted = true
            self.continuation = nil
            continuation.resume(with: result)
        }
    }
}
