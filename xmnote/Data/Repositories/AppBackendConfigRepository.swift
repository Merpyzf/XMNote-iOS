/**
 * [INPUT]: 依赖 Foundation URLSession 请求 XMNote 应用后端，依赖 UserDefaults 持久化按 key 隔离的配置缓存
 * [OUTPUT]: 对外提供 AppBackendConfigRepository，统一查询并缓存 NOTE_IMAGE_UPLOAD_LIMIT、WENQU-CONFIG 等动态配置
 * [POS]: Data 层通用应用后端配置仓储，是业务 Repository 获取远端开关与参数的唯一网络入口
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 通用应用后端配置仓储；Actor 串行化缓存读写，并用单飞任务避免同一 key 并发重复请求。
actor AppBackendConfigRepository: AppBackendConfigRepositoryProtocol {
    nonisolated private static let endpoint = URL(
        string: "https://www.xmnote.com/api/front/v1/config"
    )!
    nonisolated private static let cacheStorageKey = "app_backend_config_cache_v1"
    nonisolated private static let freshnessInterval: TimeInterval = 6 * 60 * 60

    private let urlSession: URLSession
    private let userDefaults: UserDefaults
    private let now: @Sendable () -> Date
    private var inFlightRequests: [String: Task<String?, Error>] = [:]

    /// 注入网络会话、缓存与时钟；生产环境复用共享会话，事实 fixture 可注入确定性依赖。
    init(
        urlSession: URLSession = .shared,
        userDefaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.urlSession = urlSession
        self.userDefaults = userDefaults
        self.now = now
    }

    /// 查询任意应用配置；新鲜缓存直接返回，过期缓存刷新失败时继续离线可用。
    func queryValue(key: String) async -> String? {
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else { return nil }

        let cachedEntry = cacheEntries()[normalizedKey]
        if let cachedEntry,
           now().timeIntervalSince(cachedEntry.fetchedAt) < Self.freshnessInterval {
            return cachedEntry.value
        }

        let requestTask: Task<String?, Error>
        if let existingTask = inFlightRequests[normalizedKey] {
            requestTask = existingTask
        } else {
            let urlSession = urlSession
            requestTask = Task {
                try await Self.fetchRemoteValue(
                    key: normalizedKey,
                    urlSession: urlSession
                )
            }
            inFlightRequests[normalizedKey] = requestTask
        }

        do {
            let value = try await requestTask.value
            var entries = cacheEntries()
            entries[normalizedKey] = AppBackendConfigCacheEntry(
                value: value,
                fetchedAt: now()
            )
            persistCacheEntries(entries)
            inFlightRequests[normalizedKey] = nil
            return value
        } catch {
            inFlightRequests[normalizedKey] = nil
            return cachedEntry?.value
        }
    }
}

private extension AppBackendConfigRepository {
    /// POST JSON 请求并严格校验 HTTP 与响应结构；调用任务取消会由 URLSession 协作终止。
    nonisolated static func fetchRemoteValue(
        key: String,
        urlSession: URLSession
    ) async throws -> String? {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(AppBackendConfigRequest(key: key))

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw AppBackendConfigRepositoryError.invalidResponse
        }
        return try JSONDecoder().decode(AppBackendConfigResponse.self, from: data).data.first?.value
    }

    func cacheEntries() -> [String: AppBackendConfigCacheEntry] {
        guard let data = userDefaults.data(forKey: Self.cacheStorageKey),
              let entries = try? JSONDecoder().decode(
                [String: AppBackendConfigCacheEntry].self,
                from: data
              ) else {
            return [:]
        }
        return entries
    }

    func persistCacheEntries(_ entries: [String: AppBackendConfigCacheEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        userDefaults.set(data, forKey: Self.cacheStorageKey)
    }
}

/// 应用后端配置查询请求体。
nonisolated private struct AppBackendConfigRequest: Encodable, Sendable {
    let key: String
}

/// 应用后端配置查询响应，只解码业务使用的 data/value 最小字段集。
nonisolated private struct AppBackendConfigResponse: Decodable, Sendable {
    let code: Int
    let message: String
    let data: [AppBackendConfigValue]
}

/// 单条应用后端配置值。
nonisolated private struct AppBackendConfigValue: Decodable, Sendable {
    let value: String
}

/// 按配置 key 持久化的值与最后成功刷新时间。
nonisolated private struct AppBackendConfigCacheEntry: Codable, Sendable {
    let value: String?
    let fetchedAt: Date
}

/// 应用后端没有返回可解码成功响应时使用的内部错误。
nonisolated private enum AppBackendConfigRepositoryError: Error {
    case invalidResponse
}
