/**
 * [INPUT]: 依赖 WebKit 持久化数据仓与 XMImageRequestBuilder 浏览器请求头，依赖 sharedFanqie 会话标识复用番茄验证态
 * [OUTPUT]: 对外提供 FanqieWebVerificationService 与 FanqieVerificationHeuristics，统一番茄验证页请求、Cookie 仓与风控判定
 * [POS]: Services 模块的番茄验证能力层，为搜索页风控恢复与验证页回流提供复用入口
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import WebKit

/// FanqieVerificationHeuristics 负责当前场景的enum定义，明确职责边界并组织相关能力。
enum FanqieVerificationHeuristics {
    nonisolated static let verificationMarkers = [
        "verifycenter/captcha",
        "bdturing-verify",
        "x-vc-bdturing-parameters",
        "verify_data",
        "verify_mmo",
        "captcha/v2"
    ]

    nonisolated static func requiresVerification(html: String, finalURL: URL?) -> Bool {
        let normalizedHTML = html.lowercased()
        let normalizedURL = finalURL?.absoluteString.lowercased() ?? ""
        return verificationMarkers.contains { marker in
            normalizedHTML.contains(marker) || normalizedURL.contains(marker)
        }
    }

    nonisolated static func isSearchPage(url: URL?) -> Bool {
        guard let url, let host = url.host?.lowercased() else {
            return false
        }
        guard host.hasSuffix("fanqienovel.com") else {
            return false
        }
        return url.path.lowercased().hasPrefix("/search/")
    }

    nonisolated static func makeSearchURL(keyword: String) -> URL? {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmed
        return URL(string: "https://fanqienovel.com/search/\(encoded)")
    }
}

@MainActor
/// FanqieWebVerificationService 负责当前场景的class定义，明确职责边界并组织相关能力。
final class FanqieWebVerificationService {
    static let shared = FanqieWebVerificationService()

    let sessionScope: WebSessionScope = .sharedFanqie

    /// 为番茄搜索页构造标准请求，确保验证页与抓取链路共享相同浏览器头与数据仓。
    func makeSearchRequest(keyword: String) -> URLRequest? {
        guard let url = makeSearchURL(keyword: keyword) else {
            return nil
        }
        return makeRequest(url: url)
    }

    /// 将现成的番茄搜索 URL 转成标准请求，供验证页直接加载。
    func makeRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        XMImageRequestBuilder.browserHeaderFields(for: url).forEach {
            request.setValue($0.value, forHTTPHeaderField: $0.key)
        }
        return request
    }

    /// 为番茄页面构造共享的 WebView 配置，保证验证完成后 Cookie 可被搜索链路直接复用。
    func makeWebViewConfiguration(
        sessionScope: WebSessionScope = .sharedFanqie,
        preferredContentMode: WKWebpagePreferences.ContentMode = .mobile
    ) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore(for: sessionScope)
        configuration.defaultWebpagePreferences.preferredContentMode = preferredContentMode
        return configuration
    }

    /// 统一生成番茄搜索页 URL，避免 UI 层散落编码逻辑。
    func makeSearchURL(keyword: String) -> URL? {
        FanqieVerificationHeuristics.makeSearchURL(keyword: keyword)
    }
}

private extension FanqieWebVerificationService {
    func dataStore(for sessionScope: WebSessionScope) -> WKWebsiteDataStore {
        switch sessionScope {
        case .sharedDefault, .sharedDouban, .sharedFanqie:
            return WKWebsiteDataStore(forIdentifier: sessionScope.webDataStoreIdentifier)
        case .ephemeral:
            return .nonPersistent()
        }
    }
}
