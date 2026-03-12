/**
 * [INPUT]: 依赖 WebKit 持久化数据仓与 XMImageRequestBuilder 浏览器请求头，依赖 sharedDouban 会话标识复用豆瓣登录态
 * [OUTPUT]: 对外提供 DoubanWebLoginService，统一豆瓣登录页请求、Cookie 判定与登录 WebView 配置
 * [POS]: Services 模块的豆瓣登录态能力层，为网页抓取测试页与后续在线搜索场景提供复用登录入口
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import WebKit

@MainActor
final class DoubanWebLoginService {
    static let shared = DoubanWebLoginService()

    let sessionScope: WebSessionScope = .sharedDouban
    let loginURL = URL(string: "https://accounts.douban.com/passport/login")!

    /// 生成豆瓣登录请求，统一复用浏览器 UA 与站点请求头策略。
    func makeLoginRequest() -> URLRequest {
        var request = URLRequest(url: loginURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        XMImageRequestBuilder.browserHeaderFields(for: loginURL).forEach {
            request.setValue($0.value, forHTTPHeaderField: $0.key)
        }
        return request
    }

    /// 判断共享豆瓣会话是否已经具备可用登录态，仅以关键登录 Cookie 为准。
    func isLoggedIn(sessionScope: WebSessionScope = .sharedDouban) async -> Bool {
        let cookies = await cookieStore(for: sessionScope).allCookies()
        return hasLoginCookie(in: cookies)
    }

    /// 为豆瓣登录页构造 WebView 配置，确保与抓取链路复用同一持久化数据仓。
    func makeWebViewConfiguration(sessionScope: WebSessionScope = .sharedDouban) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore(for: sessionScope)
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        return configuration
    }

    /// 从指定会话读取 Cookie，用于登录页回流和后续业务判定。
    func cookieStore(for sessionScope: WebSessionScope = .sharedDouban) -> WKHTTPCookieStore {
        dataStore(for: sessionScope).httpCookieStore
    }

    /// 对外暴露统一的登录态判定规则，避免 UI 层散落 Cookie 名称。
    func hasLoginCookie(in cookies: [HTTPCookie]) -> Bool {
        cookies.contains { cookie in
            let name = cookie.name.lowercased()
            return name == "dbcl2" || name == "ck"
        }
    }
}

private extension DoubanWebLoginService {
    func dataStore(for sessionScope: WebSessionScope) -> WKWebsiteDataStore {
        switch sessionScope {
        case .sharedDefault, .sharedDouban:
            return WKWebsiteDataStore(forIdentifier: sessionScope.webDataStoreIdentifier)
        case .ephemeral:
            return .nonPersistent()
        }
    }
}
