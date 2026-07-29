/**
 * [INPUT]: 依赖 DesktopWebBookRepository、DesktopWebSettingsRepository、Nuke App 图片缓存、URLSession 与本地缓存目录
 * [OUTPUT]: 对外提供 Android 对齐的 Web 书籍封面代理，覆盖鉴权、SSRF、重定向、格式/大小校验、24 小时缓存、singleflight 与四路下载限流
 * [POS]: Infra 层 Web 封面代理服务；Package 仅依赖 DesktopWebBookCoverPort，不接触 App 数据库与图片管线
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import CryptoKit
import Darwin
import Foundation
import Nuke
import UIKit
import XMNoteWeb

/// 控制封面外部请求并发；等待任务取消时不会消费 permit，已获得 permit 的下载会在退出路径归还。
private actor DesktopWebCoverDownloadSemaphore {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) {
        permits = value
    }

    func acquire() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            permits += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// 封面代理以 actor 保护 singleflight 与缓存元数据；共享下载不随单个 HTTP 调用取消，避免其他等待者被连带中止。
actor DesktopWebBookCoverService {
    private struct CacheMeta: Codable {
        let fetchedAt: Int64
        let lastAccessAt: Int64
        let mimeType: String
    }

    private struct DownloadedImage: Sendable {
        let data: Data
        let mimeType: String
    }

    private static let cacheTTL: Int64 = 24 * 60 * 60 * 1_000
    private static let cacheMaximumSize = 100 * 1_024 * 1_024
    private static let cacheTrimTarget = 80 * 1_024 * 1_024
    private static let cleanupInterval: Int64 = 5 * 60 * 1_000
    private static let maximumResponseSize = 10 * 1_024 * 1_024
    private static let maximumRedirects = 3

    private let repository: DesktopWebBookRepository
    private let settingsRepository: DesktopWebSettingsRepository
    private let session: URLSession
    private let imagePipeline: ImagePipeline
    private let cacheDirectory: URL
    private let currentTimeMillis: @Sendable () -> Int64
    private let downloadSemaphore = DesktopWebCoverDownloadSemaphore(value: 4)
    private var inFlight: [String: Task<DownloadedImage, Error>] = [:]
    private var lastCleanupTime: Int64 = 0

    init(
        repository: DesktopWebBookRepository,
        settingsRepository: DesktopWebSettingsRepository,
        session: URLSession,
        imagePipeline: ImagePipeline = .shared,
        cacheDirectory: URL? = nil,
        currentTimeMillis: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        }
    ) {
        self.repository = repository
        self.settingsRepository = settingsRepository
        self.session = session
        self.imagePipeline = imagePipeline
        self.cacheDirectory = cacheDirectory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("web-book-cover-proxy", isDirectory: true)
        self.currentTimeMillis = currentTimeMillis
    }

    /// 查询包含 tombstone 的书籍后代理封面；只有缓存命中或完整验证成功才返回图片响应。
    func proxiedBookCover(
        bookID: Int64,
        expires: Int64?,
        signature: String?
    ) async throws -> DesktopWebRawHTTPResponse {
        let record: BookRecord
        do {
            record = try await repository.bookIncludingDeleted(id: bookID)
        } catch {
            throw DesktopWebAPIError(code: 404, message: "书籍不存在")
        }
        let cover = record.cover.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.shouldProxy(cover) else {
            throw DesktopWebAPIError(code: 404, message: "封面不存在")
        }
        try await validateAuthorization(
            bookID: bookID,
            cover: cover,
            expires: expires,
            signature: signature
        )

        let key = Self.sha256(cover)
        if let cached = loadFromProxyCache(key: key) {
            return Self.response(cached)
        }
        if let existing = inFlight[key] {
            return Self.response(try await existing.value)
        }

        let task = Task<DownloadedImage, Error> { [session, imagePipeline, downloadSemaphore] in
            await downloadSemaphore.acquire()
            do {
                let result: DownloadedImage
                if let cached = Self.loadFromNukeCache(
                    cover: cover,
                    pipeline: imagePipeline
                ) {
                    result = cached
                } else {
                    result = try await Self.download(
                        cover: cover,
                        session: session
                    )
                }
                await downloadSemaphore.release()
                return result
            } catch {
                await downloadSemaphore.release()
                throw error
            }
        }
        inFlight[key] = task
        do {
            let image = try await task.value
            inFlight.removeValue(forKey: key)
            try store(image: image, key: key)
            cleanupIfNeeded()
            return Self.response(image)
        } catch {
            inFlight.removeValue(forKey: key)
            throw error
        }
    }
}

private extension DesktopWebBookCoverService {
    func validateAuthorization(
        bookID: Int64,
        cover: String,
        expires: Int64?,
        signature: String?
    ) async throws {
        let auth = await settingsRepository.accessAuthSnapshot()
        guard auth.isEnabled else { return }
        guard let expires,
              expires >= currentTimeMillis(),
              let signature,
              !signature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Self.secureEquals(
                  signature,
                  Self.signature(
                      bookID: bookID,
                      cover: cover,
                      expires: expires,
                      secret: auth.accessCode
                  )
              ) else {
            throw DesktopWebAPIError(code: 403, message: "访问未授权")
        }
    }

    private func loadFromProxyCache(key: String) -> DownloadedImage? {
        let imageURL = cacheDirectory.appendingPathComponent("\(key).img")
        let metaURL = cacheDirectory.appendingPathComponent("\(key).meta.json")
        guard let metaData = try? Data(contentsOf: metaURL),
              var meta = try? JSONDecoder().decode(CacheMeta.self, from: metaData),
              currentTimeMillis() - meta.fetchedAt <= Self.cacheTTL,
              let data = try? Data(contentsOf: imageURL),
              !data.isEmpty else {
            try? FileManager.default.removeItem(at: imageURL)
            try? FileManager.default.removeItem(at: metaURL)
            return nil
        }
        let now = currentTimeMillis()
        meta = CacheMeta(
            fetchedAt: meta.fetchedAt,
            lastAccessAt: now,
            mimeType: meta.mimeType
        )
        if let encoded = try? JSONEncoder().encode(meta) {
            try? encoded.write(to: metaURL, options: .atomic)
        }
        try? FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: Double(now) / 1_000)],
            ofItemAtPath: imageURL.path
        )
        return DownloadedImage(data: data, mimeType: meta.mimeType)
    }

    private func store(image: DownloadedImage, key: String) throws {
        try FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
        let now = currentTimeMillis()
        let imageURL = cacheDirectory.appendingPathComponent("\(key).img")
        let metaURL = cacheDirectory.appendingPathComponent("\(key).meta.json")
        try image.data.write(to: imageURL, options: .atomic)
        try JSONEncoder().encode(
            CacheMeta(
                fetchedAt: now,
                lastAccessAt: now,
                mimeType: image.mimeType
            )
        ).write(to: metaURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: Double(now) / 1_000)],
            ofItemAtPath: imageURL.path
        )
    }

    func cleanupIfNeeded() {
        let now = currentTimeMillis()
        guard now - lastCleanupTime >= Self.cleanupInterval else { return }
        lastCleanupTime = now
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let metaURLs = Dictionary(
            uniqueKeysWithValues: files
                .filter { $0.lastPathComponent.hasSuffix(".meta.json") }
                .map {
                    (
                        String($0.lastPathComponent.dropLast(".meta.json".count)),
                        $0
                    )
                }
        )
        var survivors: [(image: URL, meta: URL, access: Int64, size: Int)] = []
        for imageURL in files where imageURL.pathExtension == "img" {
            let key = imageURL.deletingPathExtension().lastPathComponent
            guard let metaURL = metaURLs[key],
                  let data = try? Data(contentsOf: metaURL),
                  let meta = try? JSONDecoder().decode(CacheMeta.self, from: data),
                  now - meta.fetchedAt <= Self.cacheTTL else {
                try? fileManager.removeItem(at: imageURL)
                if let metaURL = metaURLs[key] {
                    try? fileManager.removeItem(at: metaURL)
                }
                continue
            }
            let values = try? imageURL.resourceValues(forKeys: [.fileSizeKey])
            survivors.append((
                image: imageURL,
                meta: metaURL,
                access: meta.lastAccessAt,
                size: values?.fileSize ?? 0
            ))
        }
        let imageKeys = Set(survivors.map { $0.image.deletingPathExtension().lastPathComponent })
        for (key, metaURL) in metaURLs where !imageKeys.contains(key) {
            try? fileManager.removeItem(at: metaURL)
        }

        var totalSize = survivors.reduce(0) { $0 + $1.size }
        guard totalSize > Self.cacheMaximumSize else { return }
        for item in survivors.sorted(by: { $0.access < $1.access }) {
            guard totalSize > Self.cacheTrimTarget else { break }
            totalSize -= item.size
            try? fileManager.removeItem(at: item.image)
            try? fileManager.removeItem(at: item.meta)
        }
    }
}

private extension DesktopWebBookCoverService {
    nonisolated private static func download(
        cover: String,
        session: URLSession
    ) async throws -> DownloadedImage {
        var current = try coverURL(cover)
        for redirectCount in 0...maximumRedirects {
            // NOTE(ANDROID-WEB-070): 最新 Android v46 先解析并校验 DNS、再由 HTTP 客户端重新建连，
            // 校验地址与实际连接地址之间存在 DNS rebinding 的 TOCTOU 窗口；当前为可观察基线保留同一边界。
            try validatePublicHost(current.host)
            var request = URLRequest(url: current, timeoutInterval: 10)
            request.httpMethod = "GET"
            if current.absoluteString.localizedCaseInsensitiveContains("douban") {
                request.setValue("https://douban.com/", forHTTPHeaderField: "Referer")
                request.setValue(
                    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36",
                    forHTTPHeaderField: "User-Agent"
                )
            }
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                throw DesktopWebAPIError(
                    code: 502,
                    message: error.localizedDescription.isEmpty
                        ? "代理图片失败"
                        : error.localizedDescription
                )
            }
            guard let http = response as? HTTPURLResponse else {
                throw DesktopWebAPIError(code: 502, message: "上游封面响应为空")
            }
            if (300...399).contains(http.statusCode) {
                guard redirectCount < maximumRedirects else {
                    throw DesktopWebAPIError(code: 502, message: "封面重定向次数过多")
                }
                guard let location = http.value(forHTTPHeaderField: "Location"),
                      let next = URL(string: location, relativeTo: current)?.absoluteURL else {
                    throw DesktopWebAPIError(code: 502, message: "封面重定向地址无效")
                }
                current = next
                continue
            }
            guard (200...299).contains(http.statusCode) else {
                throw DesktopWebAPIError(
                    code: 502,
                    message: "上游封面请求失败: HTTP \(http.statusCode)"
                )
            }
            guard !data.isEmpty else {
                throw DesktopWebAPIError(code: 502, message: "上游封面响应为空")
            }
            guard data.count <= maximumResponseSize else {
                throw DesktopWebAPIError(code: 413, message: "图片文件过大")
            }
            if let responseType = http.mimeType?.lowercased(),
               !responseType.hasPrefix("image/") {
                throw DesktopWebAPIError(code: 415, message: "远端资源不是图片")
            }
            return try validatedImage(data)
        }
        throw DesktopWebAPIError(code: 502, message: "封面代理失败")
    }

    nonisolated private static func loadFromNukeCache(
        cover: String,
        pipeline: ImagePipeline
    ) -> DownloadedImage? {
        guard let url = URL(string: cover) else { return nil }
        var request = URLRequest(url: url)
        if cover.localizedCaseInsensitiveContains("douban") {
            request.setValue("https://douban.com/", forHTTPHeaderField: "Referer")
            request.setValue(
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36",
                forHTTPHeaderField: "User-Agent"
            )
        }
        guard let data = pipeline.cache.cachedData(
            for: ImageRequest(urlRequest: request)
        ) else {
            return nil
        }
        return try? validatedImage(data)
    }

    nonisolated private static func validatedImage(_ data: Data) throws -> DownloadedImage {
        let mimeType: String
        if data.starts(with: [0xff, 0xd8, 0xff]) {
            mimeType = "image/jpeg"
        } else if data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) {
            mimeType = "image/png"
        } else if data.starts(with: Data("GIF87a".utf8))
                    || data.starts(with: Data("GIF89a".utf8)) {
            mimeType = "image/gif"
        } else if data.count >= 12,
                  data.starts(with: Data("RIFF".utf8)),
                  String(decoding: data[8..<12], as: UTF8.self) == "WEBP" {
            mimeType = "image/webp"
        } else {
            throw DesktopWebAPIError(code: 415, message: "远端资源不是图片")
        }
        guard UIImage(data: data)?.size.width ?? 0 > 0,
              UIImage(data: data)?.size.height ?? 0 > 0 else {
            throw DesktopWebAPIError(code: 415, message: "远端资源不是图片")
        }
        return DownloadedImage(data: data, mimeType: mimeType)
    }

    nonisolated private static func response(_ image: DownloadedImage) -> DesktopWebRawHTTPResponse {
        DesktopWebRawHTTPResponse(
            statusCode: 200,
            headers: [
                "Content-Type": image.mimeType,
                "Cache-Control": "private, max-age=3600"
            ],
            body: image.data
        )
    }

    nonisolated static func shouldProxy(_ cover: String) -> Bool {
        guard !cover.isEmpty,
              !cover.hasPrefix("/api/v1/book-covers/proxy/"),
              cover.lowercased().hasPrefix("http://")
                || cover.lowercased().hasPrefix("https://") else {
            return false
        }
        return !cover.localizedCaseInsensitiveContains("clippingkk")
            && !cover.localizedCaseInsensitiveContains("xmnote-")
    }

    nonisolated static func coverURL(_ value: String) throws -> URL {
        guard let url = URL(string: value),
              url.scheme == "http" || url.scheme == "https",
              url.host != nil else {
            throw DesktopWebAPIError(code: 404, message: "封面地址无效")
        }
        return url
    }

    nonisolated static func signature(
        bookID: Int64,
        cover: String,
        expires: Int64,
        secret: String
    ) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let digest = HMAC<SHA256>.authenticationCode(
            for: Data("\(bookID)|\(cover)|\(expires)".utf8),
            using: key
        )
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func secureEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    nonisolated static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    nonisolated static func validatePublicHost(_ host: String?) throws {
        guard let host, !host.isEmpty, host.lowercased() != "localhost" else {
            throw DesktopWebAPIError(code: 403, message: "不支持访问本地地址")
        }
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
            throw DesktopWebAPIError(code: 502, message: "无法解析封面地址")
        }
        defer { freeaddrinfo(first) }
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        var found = false
        while let info = cursor {
            found = true
            if isBlockedAddress(info.pointee.ai_addr, family: info.pointee.ai_family) {
                throw DesktopWebAPIError(code: 403, message: "不支持访问内网地址")
            }
            cursor = info.pointee.ai_next
        }
        if !found {
            throw DesktopWebAPIError(code: 502, message: "无法解析封面地址")
        }
    }

    nonisolated static func isBlockedAddress(
        _ address: UnsafeMutablePointer<sockaddr>?,
        family: Int32
    ) -> Bool {
        guard let address else { return true }
        if family == AF_INET {
            let value = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let first = Int((value >> 24) & 0xff)
            let second = Int((value >> 16) & 0xff)
            return first == 0 || first == 10 || first == 127 || first >= 224
                || (first == 100 && (64...127).contains(second))
                || (first == 169 && second == 254)
                || (first == 172 && (16...31).contains(second))
                || (first == 192 && second == 168)
                || (first == 198 && (18...19).contains(second))
        }
        if family == AF_INET6 {
            let bytes = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                withUnsafeBytes(of: pointer.pointee.sin6_addr) { Array($0) }
            }
            guard bytes.count >= 2 else { return true }
            return bytes.allSatisfy { $0 == 0 }
                || bytes == Array(repeating: 0, count: 15) + [1]
                || bytes[0] == 0xfc || bytes[0] == 0xfd
                || (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80)
                || bytes[0] == 0xff
        }
        return true
    }
}
