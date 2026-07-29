/**
 * [INPUT]: 依赖 S3 配置/上传 Repository、UserDefaults、UIKit 图片解码与会员状态闭包
 * [OUTPUT]: 对外提供 DesktopWebUploadPort 及内容写入时的同步票据提交能力
 * [POS]: Infra 层 Web 上传风控与对象存储适配；Package 不接触 S3 SDK 或 App 设置
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import UIKit
import XMNoteWeb

/// 以锁保护可持久化票据状态；远端上传在锁外执行，回写前再次校验票据仍有效。
final class DesktopWebUploadService: DesktopWebUploadPort, @unchecked Sendable {
    private enum Status: String, Codable {
        case reserved
        case uploadedPendingCommit = "uploaded_pending_commit"
        case committed
        case released
        case expired
        case releasedPendingCleanup = "released_pending_cleanup"
        case cleanupFailed = "cleanup_failed"
    }

    private struct Ticket: Codable {
        let id: String
        let accountKey: String
        let configID: Int64
        let createdAt: Int64
        var expiresAt: Int64
        var status: Status
        var uploadedURL: String?
        var objectKey: String?
        var updatedAt: Int64
        let shouldLimit: Bool
    }

    private struct Store: Codable {
        var tickets: [String: Ticket] = [:]
        var cleanupTasks: [CleanupTask] = []
        var rateLimitHits: [String: [Int64]] = [:]

        private enum CodingKeys: String, CodingKey {
            case tickets
            case cleanupTasks
            case rateLimitHits
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tickets = try container.decodeIfPresent([String: Ticket].self, forKey: .tickets) ?? [:]
            cleanupTasks = try container.decodeIfPresent([CleanupTask].self, forKey: .cleanupTasks) ?? []
            rateLimitHits = try container.decodeIfPresent([String: [Int64]].self, forKey: .rateLimitHits) ?? [:]
        }
    }

    private struct CleanupTask: Codable {
        let ticketID: String
        // NOTE(ANDROID-WEB-080): Android 清理任务只保存 objectKey，删除时使用“当前”COS 配置；
        // 切换存储配置后可能在错误桶执行删除。冻结合同阶段保留该任务形状。
        let objectKey: String
        let createdAt: Int64
        var updatedAt: Int64
        var attemptCount: Int
        var nextRetryAt: Int64
    }

    private struct Subject {
        let accountKey: String
        let configID: Int64
        let shouldLimit: Bool
        let dailyLimit: Int
    }

    private static let storeKey = "desktopWeb.noteImageUploadRiskControl"
    private static let reservedTTL: Int64 = 10 * 60 * 1_000
    private static let uploadedTTL: Int64 = 24 * 60 * 60 * 1_000
    private static let terminalRetention: Int64 = 3 * 24 * 60 * 60 * 1_000
    private static let cleanupRetryBaseDelay: Int64 = 30 * 1_000
    private static let maxCleanupRetryCount = 5
    private let lock = NSLock()
    private let defaults: UserDefaults
    private let configRepository: any S3ConfigRepositoryProtocol
    private let uploadRepository: any S3UploadRepositoryProtocol
    private let isPremiumProvider: @Sendable () async -> Bool
    private let currentTimeMillis: @Sendable () -> Int64
    private var latestConfigID: Int64 = 1

    init(
        configRepository: any S3ConfigRepositoryProtocol,
        uploadRepository: any S3UploadRepositoryProtocol,
        defaults: UserDefaults = .standard,
        isPremiumProvider: @escaping @Sendable () async -> Bool = { false },
        currentTimeMillis: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        }
    ) {
        self.configRepository = configRepository
        self.uploadRepository = uploadRepository
        self.defaults = defaults
        self.isPremiumProvider = isPremiumProvider
        self.currentTimeMillis = currentTimeMillis
    }

    /// 预留 1...20 个十分钟票据，并在默认对象存储的非会员场景扣除当日剩余额度。
    func reserveNoteImageTickets(count: Int) async throws -> DesktopWebUploadTicketReserveResult {
        let normalized = max(1, count)
        guard normalized <= 20 else {
            throw DesktopWebAPIError(code: 40001, message: "单次最多上传 20 张图片")
        }
        let subject = try await subject()
        await drainCleanupTasks()
        return try withStore { store, now in
            cleanup(&store, now: now)
            try enforceRateLimit(&store, key: "reserve:\(subject.accountKey)", now: now)
            let remainingBefore = remaining(subject: subject, store: store, now: now)
            if subject.shouldLimit, normalized > remainingBefore {
                throw DesktopWebAPIError(code: 40007, message: "今日图片上传额度已用完，请升级会员或切换自定义 COS")
            }
            let tickets = (0..<normalized).map { _ -> DesktopWebUploadTicket in
                let id = UUID().uuidString
                let expires = now + Self.reservedTTL
                store.tickets[id] = Ticket(
                    id: id,
                    accountKey: subject.accountKey,
                    configID: subject.configID,
                    createdAt: now,
                    expiresAt: expires,
                    status: .reserved,
                    uploadedURL: nil,
                    objectKey: nil,
                    updatedAt: now,
                    shouldLimit: subject.shouldLimit
                )
                return .init(ticketId: id, expiresAt: expires)
            }
            return .init(
                tickets: tickets,
                remaining: subject.shouldLimit ? remaining(subject: subject, store: store, now: now) : nil
            )
        }
    }

    /// 验证票据与图片后上传到 web_note 前缀，成功票据转入 24 小时待提交态。
    func uploadNoteImage(ticketID: String, file: DesktopWebUploadedFile) async throws -> DesktopWebNoteImageUploadResult {
        let id = ticketID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw DesktopWebAPIError(code: 40001, message: "缺少上传凭证") }
        let subject = try await subject()
        await drainCleanupTasks()
        let now = currentTimeMillis()
        try withStore { store, _ in
            cleanup(&store, now: now)
            try enforceRateLimit(&store, key: "upload:\(subject.accountKey)", now: now)
            _ = try requireTicket(id, subject: subject, store: store, status: .reserved, now: now)
        }
        let validated = try Self.validateImage(file)
        let localURL = try Self.writeTemporary(validated.data, mimeType: validated.mimeType)
        defer { try? FileManager.default.removeItem(at: localURL) }
        let uploaded: S3UploadResult
        do {
            // NOTE(ANDROID-WEB-074): Android 在全局 synchronized 锁内等待远端上传，
            // 任一慢请求会阻塞所有票据与封面操作；iOS 有意把网络等待放在 store 锁外。
            // NOTE(ANDROID-WEB-079): 远端成功到票据持久化之间仍有进程终止窗口，可能遗留孤儿对象。
            uploaded = try await uploadRepository.uploadFile(localURL: localURL, prefix: "web_note", progress: nil)
        } catch {
            throw DesktopWebAPIError(code: 50002, message: "图片上传失败: \(error.localizedDescription)")
        }
        let objectKey = uploaded.remoteURL.path(percentEncoded: true)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !objectKey.isEmpty else {
            throw DesktopWebAPIError(code: 50002, message: "图片上传失败：无法识别远端文件路径")
        }
        let expires = now + Self.uploadedTTL
        return try withStore { store, _ in
            var ticket = try requireTicket(id, subject: subject, store: store, status: .reserved, now: now)
            ticket.status = .uploadedPendingCommit
            ticket.uploadedURL = uploaded.remoteURL.absoluteString
            ticket.objectKey = objectKey
            ticket.expiresAt = expires
            ticket.updatedAt = now
            store.tickets[id] = ticket
            return .init(url: uploaded.remoteURL.absoluteString, ticketId: id, expiresAt: expires)
        }
    }

    /// 释放票据；已上传对象优先远端删除，删除失败保留待清理状态供后续调用重试。
    func releaseNoteImageTickets(_ ticketIDs: [String]) async throws {
        let subject = try await subject()
        await drainCleanupTasks()
        let ids = Array(Set(ticketIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
        guard !ids.isEmpty else { return }
        var pendingDeletes: [(String, String)] = []
        withStore { store, now in
            cleanup(&store, now: now)
            for id in ids {
                guard var ticket = store.tickets[id], belongs(ticket, to: subject) else { continue }
                if ticket.status == .reserved {
                    ticket.status = .released
                    ticket.updatedAt = now
                    store.tickets[id] = ticket
                } else if ticket.status == .uploadedPendingCommit, let objectKey = ticket.objectKey {
                    pendingDeletes.append((id, objectKey))
                }
            }
        }
        for (id, path) in pendingDeletes {
            let deleted: Bool
            do {
                try await uploadRepository.deleteObject(path: path)
                deleted = true
            } catch {
                deleted = false
            }
            withStore { store, now in
                guard var ticket = store.tickets[id], ticket.status == .uploadedPendingCommit else { return }
                ticket.status = deleted ? .released : .releasedPendingCleanup
                ticket.updatedAt = now
                store.tickets[id] = ticket
                if !deleted, let objectKey = ticket.objectKey {
                    enqueueCleanupTask(
                        &store,
                        ticketID: id,
                        objectKey: objectKey,
                        now: now
                    )
                }
            }
        }
    }

    /// 上传书籍封面，复用同一图片校验与频率门禁但不消费笔记图片票据。
    func uploadBookCover(file: DesktopWebUploadedFile) async throws -> DesktopWebBookCoverUploadResult {
        let subject = try await subject()
        await drainCleanupTasks()
        try withStore { store, now in
            cleanup(&store, now: now)
            try enforceRateLimit(&store, key: "cover:\(subject.accountKey)", now: now)
        }
        let validated = try Self.validateImage(file)
        let localURL = try Self.writeTemporary(validated.data, mimeType: validated.mimeType)
        defer { try? FileManager.default.removeItem(at: localURL) }
        do {
            let result = try await uploadRepository.uploadFile(localURL: localURL, prefix: "web_cover", progress: nil)
            return .init(url: result.remoteURL.absoluteString)
        } catch {
            throw DesktopWebAPIError(code: 50002, message: "图片上传失败: \(error.localizedDescription)")
        }
    }

    /// 在书摘/书评/相关内容事务写入前同步验证并提交票据，避免上传对象成为未引用孤儿。
    func commitUploadedTickets(_ ticketIDs: [String]?, imageURLs: [String]) throws {
        let ids = Array(Set((ticketIDs ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
        guard !ids.isEmpty else { return }
        let normalizedURLs = Set(imageURLs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        let subject = synchronousSubjectSnapshot()
        try withStore { store, now in
            cleanup(&store, now: now)
            for id in ids {
                if let expiredTicket = store.tickets[id],
                   belongs(expiredTicket, to: subject),
                   expiredTicket.expiresAt <= now {
                    if expiredTicket.status == .uploadedPendingCommit {
                        var released = expiredTicket
                        released.status = .releasedPendingCleanup
                        released.updatedAt = now
                        store.tickets[id] = released
                        if let objectKey = released.objectKey {
                            enqueueCleanupTask(
                                &store,
                                ticketID: id,
                                objectKey: objectKey,
                                now: now
                            )
                        }
                    }
                    throw DesktopWebAPIError(code: 40008, message: "图片上传凭证已过期，请重新上传")
                }
                let ticket = try requireTicket(
                    id,
                    subject: subject,
                    store: store,
                    status: .uploadedPendingCommit,
                    now: now
                )
                guard ticket.expiresAt > now else {
                    var expired = ticket
                    expired.status = .releasedPendingCleanup
                    expired.updatedAt = now
                    store.tickets[id] = expired
                    if let objectKey = expired.objectKey {
                        enqueueCleanupTask(
                            &store,
                            ticketID: id,
                            objectKey: objectKey,
                            now: now
                        )
                    }
                    throw DesktopWebAPIError(code: 40008, message: "图片上传凭证已过期，请重新上传")
                }
                guard let url = ticket.uploadedURL, normalizedURLs.contains(url) else {
                    throw DesktopWebAPIError(code: 40008, message: "图片上传凭证与当前内容不匹配，请重新上传")
                }
            }
            var limitedCount = 0
            for id in ids {
                guard var ticket = store.tickets[id] else { continue }
                ticket.status = .committed
                ticket.updatedAt = now
                if ticket.shouldLimit { limitedCount += 1 }
                store.tickets[id] = ticket
            }
            if limitedCount > 0 {
                let key = Self.savedCountKey(now: now)
                defaults.set(defaults.integer(forKey: key) + limitedCount, forKey: key)
            }
        }
    }
}

private extension DesktopWebUploadService {
    private func subject() async throws -> Subject {
        let config = try await configRepository.fetchCurrentConfig()
        let configID = max(1, config?.id ?? 1)
        let isPremium = await isPremiumProvider()
        let accountKey = currentAccountKey()
        let shouldLimit = !isPremium && configID == 1
        let dailyLimit = max(0, Int(defaults.string(forKey: "noteImageUploadLimit") ?? "20") ?? 20)
        lock.withLock { latestConfigID = configID }
        return Subject(accountKey: accountKey, configID: configID, shouldLimit: shouldLimit, dailyLimit: dailyLimit)
    }

    private func synchronousSubjectSnapshot() -> Subject {
        let configID = lock.withLock { latestConfigID }
        return Subject(
            accountKey: currentAccountKey(),
            configID: configID,
            shouldLimit: false,
            dailyLimit: 0
        )
    }

    private func currentAccountKey() -> String {
        let account = defaults.string(forKey: "account")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let tokenSuffix = String((defaults.string(forKey: "accessToken") ?? "").suffix(16))
        return account.isEmpty ? (tokenSuffix.isEmpty ? "local-device" : tokenSuffix) : account
    }

    private func withStore<T>(_ body: (inout Store, Int64) throws -> T) rethrows -> T {
        try lock.withLock {
            var store = loadStore()
            let now = currentTimeMillis()
            defer { saveStore(store) }
            return try body(&store, now)
        }
    }

    private func loadStore() -> Store {
        guard let data = defaults.data(forKey: Self.storeKey),
              let store = try? JSONDecoder().decode(Store.self, from: data) else {
            // NOTE(ANDROID-WEB-078): Android 在票据 JSON 损坏时静默重置为空 store，
            // 已上传对象和待清理任务会失去索引；基线阶段保留同一恢复语义。
            return Store()
        }
        return store
    }

    private func saveStore(_ store: Store) {
        if let data = try? JSONEncoder().encode(store) { defaults.set(data, forKey: Self.storeKey) }
    }

    private func cleanup(_ store: inout Store, now: Int64) {
        for (id, var ticket) in store.tickets {
            guard ticket.expiresAt <= now else { continue }
            switch ticket.status {
            case .reserved:
                ticket.status = .expired
                ticket.updatedAt = now
                store.tickets[id] = ticket
            case .uploadedPendingCommit:
                ticket.status = .releasedPendingCleanup
                if let objectKey = ticket.objectKey {
                    enqueueCleanupTask(
                        &store,
                        ticketID: id,
                        objectKey: objectKey,
                        now: now
                    )
                }
                ticket.updatedAt = now
                store.tickets[id] = ticket
            case .committed, .released, .expired, .releasedPendingCleanup, .cleanupFailed:
                break
            }
        }
        store.tickets = store.tickets.filter { _, ticket in
            let terminal: Set<Status> = [.released, .expired, .committed, .cleanupFailed]
            return !terminal.contains(ticket.status) || now - ticket.updatedAt <= Self.terminalRetention
        }
        for key in store.rateLimitHits.keys {
            store.rateLimitHits[key] = store.rateLimitHits[key]?.filter { now - $0 <= 10 * 60 * 1_000 }
        }
    }

    private func enforceRateLimit(_ store: inout Store, key: String, now: Int64) throws {
        var hits = store.rateLimitHits[key, default: []].filter { now - $0 <= 10 * 60 * 1_000 }
        let shortCount = hits.filter { now - $0 <= 60 * 1_000 }.count
        guard shortCount < 30, hits.count < 120 else {
            throw DesktopWebAPIError(code: 40006, message: "图片上传过于频繁，请稍后再试")
        }
        hits.append(now)
        store.rateLimitHits[key] = hits
    }

    private func remaining(subject: Subject, store: Store, now: Int64) -> Int {
        let saved = defaults.integer(forKey: Self.savedCountKey(now: now))
        let active = store.tickets.values.filter {
            belongs($0, to: subject) && $0.expiresAt > now
                && ($0.status == .reserved || $0.status == .uploadedPendingCommit)
        }.count
        return max(0, subject.dailyLimit - saved - active)
    }

    private func belongs(_ ticket: Ticket, to subject: Subject) -> Bool {
        ticket.accountKey == subject.accountKey && ticket.configID == subject.configID
    }

    private func requireTicket(
        _ id: String,
        subject: Subject,
        store: Store,
        status: Status,
        now: Int64
    ) throws -> Ticket {
        guard let ticket = store.tickets[id] else {
            throw DesktopWebAPIError(code: 40008, message: "上传凭证不存在或已失效")
        }
        guard belongs(ticket, to: subject) else {
            throw DesktopWebAPIError(code: 40008, message: "上传凭证无效，请重新上传")
        }
        guard ticket.status == status else {
            throw DesktopWebAPIError(code: 40008, message: "上传凭证已失效，请重新上传")
        }
        guard ticket.expiresAt > now else {
            throw DesktopWebAPIError(code: 40008, message: "上传凭证已过期，请重新选择图片")
        }
        return ticket
    }

    private func enqueueCleanupTask(
        _ store: inout Store,
        ticketID: String,
        objectKey: String,
        now: Int64
    ) {
        let key = objectKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        if let index = store.cleanupTasks.firstIndex(where: {
            $0.ticketID == ticketID && $0.objectKey == key
        }) {
            store.cleanupTasks[index].updatedAt = now
            store.cleanupTasks[index].nextRetryAt = min(store.cleanupTasks[index].nextRetryAt, now)
            return
        }
        store.cleanupTasks.append(CleanupTask(
            ticketID: ticketID,
            objectKey: key,
            createdAt: now,
            updatedAt: now,
            attemptCount: 0,
            nextRetryAt: now
        ))
    }

    /// 每次公开上传操作前推进到期对象清理；远端删除在锁外等待，结果回写仍受同一 store 锁保护。
    private func drainCleanupTasks() async {
        // NOTE(ANDROID-WEB-075): Android 没有后台清理调度器，只有再次调用上传相关接口时
        // 才会推进孤儿对象重试；iOS 为保持生命周期合同采用相同触发方式。
        let now = currentTimeMillis()
        let dueTasks: [CleanupTask] = withStore { store, _ in
            cleanup(&store, now: now)
            return store.cleanupTasks.filter { $0.nextRetryAt <= now }
        }
        for task in dueTasks {
            let deleted: Bool
            do {
                try await uploadRepository.deleteObject(path: task.objectKey)
                deleted = true
            } catch {
                deleted = false
            }
            withStore { store, _ in
                guard let index = store.cleanupTasks.firstIndex(where: {
                    $0.ticketID == task.ticketID && $0.objectKey == task.objectKey
                }) else { return }
                if deleted {
                    if var ticket = store.tickets[task.ticketID],
                       ticket.status == .releasedPendingCleanup {
                        ticket.status = ticket.uploadedURL?.isEmpty == false ? .released : .expired
                        ticket.updatedAt = now
                        store.tickets[task.ticketID] = ticket
                    }
                    store.cleanupTasks.remove(at: index)
                    return
                }
                store.cleanupTasks[index].attemptCount += 1
                store.cleanupTasks[index].updatedAt = now
                let attempts = store.cleanupTasks[index].attemptCount
                if attempts >= Self.maxCleanupRetryCount {
                    if var ticket = store.tickets[task.ticketID],
                       ticket.status == .releasedPendingCleanup {
                        ticket.status = .cleanupFailed
                        ticket.updatedAt = now
                        store.tickets[task.ticketID] = ticket
                    }
                    store.cleanupTasks.remove(at: index)
                } else {
                    let multiplier: Int64 = switch attempts {
                    case ...1: 1
                    case 2: 2
                    case 3: 4
                    case 4: 8
                    default: 16
                    }
                    store.cleanupTasks[index].nextRetryAt =
                        now + Self.cleanupRetryBaseDelay * multiplier
                }
            }
        }
    }

    static func validateImage(_ file: DesktopWebUploadedFile) throws -> (data: Data, mimeType: String) {
        guard !file.data.isEmpty else { throw DesktopWebAPIError(code: 40001, message: "文件不能为空") }
        guard file.data.count <= 10 * 1_024 * 1_024 else {
            throw DesktopWebAPIError(code: 40001, message: "文件大小不能超过 10MB")
        }
        let mime: String
        if file.data.starts(with: [0xff, 0xd8, 0xff]) { mime = "image/jpeg" }
        else if file.data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) { mime = "image/png" }
        else if file.data.starts(with: Data("GIF87a".utf8)) || file.data.starts(with: Data("GIF89a".utf8)) { mime = "image/gif" }
        else if file.data.count >= 12, String(decoding: file.data[0..<4], as: UTF8.self) == "RIFF",
                String(decoding: file.data[8..<12], as: UTF8.self) == "WEBP" { mime = "image/webp" }
        else { throw DesktopWebAPIError(code: 40001, message: "仅支持 JPEG、PNG、GIF、WebP 格式的图片") }
        if let declared = file.contentType, !declared.isEmpty,
           declared.caseInsensitiveCompare(mime) != .orderedSame,
           !declared.lowercased().hasPrefix("image/") {
            throw DesktopWebAPIError(code: 40001, message: "仅支持图片文件上传")
        }
        guard UIImage(data: file.data) != nil else {
            throw DesktopWebAPIError(code: 40001, message: "无法识别图片内容，请重新选择")
        }
        return (file.data, mime)
    }

    static func writeTemporary(_ data: Data, mimeType: String) throws -> URL {
        // NOTE(ANDROID-WEB-077): Android 虽允许 JPEG/GIF/WebP，却把所有 COS object key 固定为 .png；
        // iOS 有意保留检测到的扩展名，避免对象元数据与实际字节格式冲突。
        let ext: String = switch mimeType {
        case "image/jpeg": "jpg"
        case "image/png": "png"
        case "image/gif": "gif"
        case "image/webp": "webp"
        default: "img"
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "web_upload_\(UUID().uuidString).\(ext)")
        try data.write(to: url, options: .atomic)
        return url
    }

    static func savedCountKey(now: Int64) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "noteImageSavedCount_\(formatter.string(from: Date(timeIntervalSince1970: Double(now) / 1_000)))"
    }
}
