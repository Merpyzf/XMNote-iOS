/**
 * [INPUT]: 依赖 WebKit 持久化数据仓与微信读书网页登录地址，维护授权页共享 Cookie
 * [OUTPUT]: 对外提供 WereadWebAuthorizationService，统一 WebView 配置、Cookie 读取写回与清理
 * [POS]: Services 的微信读书 Web 授权会话层，被授权 WebView 与 WereadImportRepository 共同复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import WebKit

@MainActor
final class WereadWebAuthorizationService {
    static let shared = WereadWebAuthorizationService()

    static let loginURL = URL(string: "https://weread.qq.com/#login")!
    static let cookieURL = URL(string: "https://weread.qq.com/")!
    static let desktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    private let dataStore = WKWebsiteDataStore(
        forIdentifier: UUID(uuidString: "D0D1C4F5-6C11-4A5A-95F8-9D3B7295AA05")!
    )

    /// 构造微信读书授权 WebView 配置，使用独立持久化 Cookie 容器与桌面页面模式。
    func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        return configuration
    }

    /// 生成登录页请求；页面加载失败由 WebView 导航回调转换为二维码失败态。
    func makeLoginRequest() -> URLRequest {
        var request = URLRequest(url: Self.loginURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(Self.desktopUserAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    /// 读取 weread.qq.com 域名 Cookie 并组装标准 Cookie 请求头。
    func cookieHeader() async -> String {
        let cookies = await dataStore.httpCookieStore.allCookies()
            .filter { cookie in
                let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                return domain == "weread.qq.com" || domain.hasSuffix(".weread.qq.com")
            }
        return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    /// 将 Repository 续期后的 Cookie 写回 WebKit，保证网页登录态与接口调用使用同一凭据。
    func replaceCookies(with header: String) async {
        await clearCookies()
        for item in Self.parseCookieHeader(header) {
            guard let cookie = HTTPCookie(properties: [
                .domain: ".weread.qq.com",
                .path: "/",
                .name: item.key,
                .value: item.value,
                .secure: "TRUE"
            ]) else { continue }
            await withCheckedContinuation { continuation in
                dataStore.httpCookieStore.setCookie(cookie) {
                    continuation.resume()
                }
            }
        }
    }

    /// 删除微信读书 Web Cookie，刷新、退出和确认授权失效时调用。
    func clearCookies() async {
        let cookies = await dataStore.httpCookieStore.allCookies()
        for cookie in cookies where cookie.domain.lowercased().contains("weread.qq.com") {
            await withCheckedContinuation { continuation in
                dataStore.httpCookieStore.delete(cookie) {
                    continuation.resume()
                }
            }
        }
    }

    private static func parseCookieHeader(_ header: String) -> [String: String] {
        var result: [String: String] = [:]
        for item in header.split(separator: ";") {
            let parts = item.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            result[name] = value
        }
        return result
    }
}
