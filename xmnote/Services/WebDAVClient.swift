/**
 * [INPUT]: 依赖 Alamofire、NetworkClient、NetworkError、HTTPMethod+WebDAV
 * [OUTPUT]: 对外提供 WebDAVClient 与 WebDAVResource，封装 WebDAV 协议操作
 * [POS]: Services 模块的 WebDAV 协议客户端，被 BackupRepository 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Alamofire

// MARK: - WebDAV Resource

struct WebDAVResource: Sendable {
    let href: String
    let displayName: String
    let contentLength: Int64
    let lastModified: Date?
    let isDirectory: Bool
}

// MARK: - WebDAVClient

struct WebDAVClient: Sendable {
    private let networkClient: NetworkClient
    let baseURL: String

    init(baseURL: String, username: String, password: String) {
        // 确保 baseURL 以 / 结尾
        self.baseURL = baseURL.hasSuffix("/") ? baseURL : baseURL + "/"
        self.networkClient = NetworkClient(username: username, password: password)
    }
}

// MARK: - 核心操作

extension WebDAVClient {

    /// 测试连接（PROPFIND 根目录 Depth: 0）
    func testConnection() async throws {
        let url = baseURL
        let xmlBody = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><d:propfind xmlns:d=\"DAV:\"><d:allprop/></d:propfind>"
        let headers: HTTPHeaders = [
            "Depth": "0",
            "Content-Type": "application/xml"
        ]

        let response = await networkClient.session
            .request(url, method: .propfind, headers: headers) { $0.httpBody = xmlBody.data(using: .utf8) }
            .serializingData()
            .response

        try validateResponse(response.response)
    }

    /// PROPFIND — 列出目录内容（Depth: 1）
    func listDirectory(_ path: String) async throws -> [WebDAVResource] {
        let url = resolveURL(path)
        let xmlBody = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><d:propfind xmlns:d=\"DAV:\"><d:allprop/></d:propfind>"
        let headers: HTTPHeaders = [
            "Depth": "1",
            "Content-Type": "application/xml"
        ]

        let response = await networkClient.session
            .request(url, method: .propfind, headers: headers) { $0.httpBody = xmlBody.data(using: .utf8) }
            .serializingData()
            .response

        try validateResponse(response.response)

        guard let data = response.data else {
            throw NetworkError.invalidResponse
        }

        let parser = WebDAVXMLParser()
        return try parser.parse(data)
    }

    /// MKCOL — 创建目录
    func createDirectory(_ path: String) async throws {
        let url = resolveURL(path.hasSuffix("/") ? path : path + "/")

        let response = await networkClient.session
            .request(url, method: .mkcol)
            .serializingData()
            .response

        // 201 Created 或 405 Method Not Allowed（目录已存在）都算成功
        if let statusCode = response.response?.statusCode,
           statusCode == 201 || statusCode == 405 {
            return
        }
        try validateResponse(response.response)
    }

    /// PUT — 上传文件
    func uploadFile(localURL: URL, remotePath: String,
                    progress: (@Sendable (Double) -> Void)?) async throws {
        let url = resolveURL(remotePath)

        let response = await networkClient.session
            .upload(localURL, to: url, method: .put)
            .uploadProgress { p in progress?(p.fractionCompleted) }
            .serializingData()
            .response

        try validateResponse(response.response)
    }

    /// GET — 下载文件
    func downloadFile(remotePath: String, to localURL: URL,
                      progress: (@Sendable (Double) -> Void)?) async throws {
        let url = resolveURL(remotePath)
        let destination: DownloadRequest.Destination = { _, _ in
            (localURL, [.removePreviousFile, .createIntermediateDirectories])
        }

        let response = await networkClient.session
            .download(url, to: destination)
            .downloadProgress { p in progress?(p.fractionCompleted) }
            .serializingDownloadedFileURL()
            .response

        try validateResponse(response.response)
    }

    /// DELETE — 删除远程资源
    func deleteResource(_ path: String) async throws {
        let url = resolveURL(path)

        let response = await networkClient.session
            .request(url, method: .delete)
            .serializingData()
            .response

        try validateResponse(response.response)
    }

    /// 检查资源是否存在（HEAD 请求）
    func exists(_ path: String) async throws -> Bool {
        let url = resolveURL(path)

        let response = await networkClient.session
            .request(url, method: .head)
            .serializingData()
            .response

        guard let statusCode = response.response?.statusCode else {
            return false
        }
        return (200..<300).contains(statusCode)
    }
}

// MARK: - 辅助方法

private extension WebDAVClient {

    func resolveURL(_ path: String) -> String {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return baseURL + (trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmed)
    }

    func validateResponse(_ response: HTTPURLResponse?) throws {
        guard let statusCode = response?.statusCode else {
            throw NetworkError.invalidResponse
        }
        switch statusCode {
        case 200..<300, 207:
            return
        case 401:
            throw NetworkError.unauthorized
        case 404:
            throw NetworkError.notFound
        case 500..<600:
            throw NetworkError.serverError(statusCode: statusCode)
        default:
            throw NetworkError.serverError(statusCode: statusCode)
        }
    }
}

// MARK: - WebDAV XML Parser
// 解析 PROPFIND 207 Multi-Status 响应

private class WebDAVXMLParser: NSObject, XMLParserDelegate {
    private var resources: [WebDAVResource] = []
    private var currentElement = ""
    private var currentText = ""

    // 当前正在解析的 response 属性
    private var href = ""
    private var displayName = ""
    private var contentLength: Int64 = 0
    private var lastModified: Date?
    private var isDirectory = false
    private var inResponse = false

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    func parse(_ data: Data) throws -> [WebDAVResource] {
        resources = []
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else {
            throw NetworkError.xmlParsingFailed
        }
        return resources
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let local = elementName.components(separatedBy: ":").last ?? elementName
        currentElement = local
        currentText = ""

        if local == "response" {
            inResponse = true
            href = ""
            displayName = ""
            contentLength = 0
            lastModified = nil
            isDirectory = false
        }
        if local == "collection" {
            isDirectory = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let local = elementName.components(separatedBy: ":").last ?? elementName
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        if inResponse {
            switch local {
            case "href":
                href = text.removingPercentEncoding ?? text
            case "displayname":
                displayName = text
            case "getcontentlength":
                contentLength = Int64(text) ?? 0
            case "getlastmodified":
                lastModified = Self.dateFormatter.date(from: text)
            case "response":
                let name = displayName.isEmpty
                    ? (href as NSString).lastPathComponent
                    : displayName
                resources.append(WebDAVResource(
                    href: href,
                    displayName: name,
                    contentLength: contentLength,
                    lastModified: lastModified,
                    isDirectory: isDirectory
                ))
                inResponse = false
            default:
                break
            }
        }
    }
}
