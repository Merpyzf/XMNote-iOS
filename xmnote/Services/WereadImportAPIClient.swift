/**
 * [INPUT]: 依赖 Foundation URLSession 与微信读书 Web API，输入授权 Cookie、书籍 ID 和请求参数
 * [OUTPUT]: 对外提供 WereadImportAPIClient，封装 10 秒超时、请求头、错误码校验和原始 JSON/HTML 响应
 * [POS]: Services 层微信读书网络边界，仅由 WereadImportRepository 使用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 微信读书 Web API 的可替换边界；生产实现与测试桩共享同一请求、响应及授权错误语义。
@MainActor
protocol WereadImportAPIClientProtocol: AnyObject {
    func get(_ path: String, cookie: String) async throws -> WereadImportAPIClient.Response
    func post(_ path: String, cookie: String, json: [String: Any]) async throws -> WereadImportAPIClient.Response
    func shelfHTML(cookie: String) async throws -> String
}

@MainActor
final class WereadImportAPIClient: WereadImportAPIClientProtocol {
    struct Response {
        let object: [String: Any]
        let httpResponse: HTTPURLResponse
    }

    private let session: URLSession
    private let baseURL = URL(string: "https://weread.qq.com")!
    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36"

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration)
    }

    func get(_ path: String, cookie: String) async throws -> Response {
        try await request(path: path, method: "GET", cookie: cookie, body: nil)
    }

    func post(_ path: String, cookie: String, json: [String: Any]) async throws -> Response {
        let data = try JSONSerialization.data(withJSONObject: json)
        return try await request(path: path, method: "POST", cookie: cookie, body: data)
    }

    func shelfHTML(cookie: String) async throws -> String {
        var request = URLRequest(url: resolvedURL("/web/shelf"))
        request.timeoutInterval = 10
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        _ = try validateHTTP(response)
        guard let html = String(data: data, encoding: .utf8) else { throw WereadImportError.invalidResponse }
        return html
    }

    private func request(path: String, method: String, cookie: String, body: Data?) async throws -> Response {
        var request = URLRequest(url: resolvedURL(path))
        request.httpMethod = method
        request.timeoutInterval = 10
        request.httpBody = body
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        let http = try validateHTTP(response)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WereadImportError.invalidResponse
        }
        let code = Self.int(object["errCode"]) ?? Self.int(object["errcode"]) ?? 0
        if code != 0 {
            let message = code == -10102
                ? "当前操作有点频繁，被微信读书限制了一下。别着急，保持在这个页面，过一会儿点击重试就可以继续导入。"
                : (Self.string(object["errMsg"]) ?? Self.string(object["errmsg"]) ?? "")
            throw WereadImportError.remote(code: code, message: message)
        }
        return Response(object: object, httpResponse: http)
    }

    private func validateHTTP(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw WereadImportError.invalidResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw WereadImportError.authorizationExpired }
        guard (200..<300).contains(http.statusCode) else {
            throw WereadImportError.remote(code: http.statusCode, message: "网络请求失败（\(http.statusCode)）")
        }
        return http
    }

    private func resolvedURL(_ path: String) -> URL {
        URL(string: path, relativeTo: baseURL)?.absoluteURL ?? baseURL
    }

    static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    static func int64(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String { return Int64(value) }
        return nil
    }

    static func dictionary(_ value: Any?) -> [String: Any]? { value as? [String: Any] }
    static func array(_ value: Any?) -> [[String: Any]] { value as? [[String: Any]] ?? [] }
}
