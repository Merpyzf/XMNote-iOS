/**
 * [INPUT]: 依赖 Foundation FileManager 与 App Groups shared container，接收 Share Extension 写入的微信读书书单链接 payload
 * [OUTPUT]: 对外提供 BookCollectionShareImportHandoffStore，用单文件 handoff 在扩展进程与主 App 间传递待导入书单链接
 * [POS]: Infra/ShareImport 的跨进程轻量交接层，不直接触碰业务数据库，主 App 消费后再进入 Repository 导入流程
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// Share Extension 与主 App 共用的微信读书书单导入交接存储。
nonisolated struct BookCollectionShareImportHandoffStore {
    static let appGroupIdentifier = "group.com.merpyzf.xmnote"

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// 使用系统文件管理器构造交接存储，编码格式保持稳定以便主 App 与扩展跨版本读取。
    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    /// 将系统分享收到的链接写入 App Group 容器；同一时间只保留最新一次分享导入请求。
    func save(link: String) throws {
        guard let normalizedLink = WereadCollectionLinkExtractor.extractLink(from: link) else {
            throw BookCollectionShareImportHandoffError.invalidWereadLink
        }
        let payload = Payload(
            id: UUID(),
            link: normalizedLink,
            source: "share-extension",
            receivedAt: Date().timeIntervalSince1970
        )
        let data = try encoder.encode(payload)
        let url = try payloadFileURL()
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    /// 读取待处理的分享导入请求；先移动源文件再解码，确保同一请求不会因 App 重新激活被重复消费。
    func consumePendingPayload() throws -> Payload? {
        let url = try payloadFileURL()
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let processingURL = processingPayloadFileURL(for: url)
        try fileManager.moveItem(at: url, to: processingURL)
        let data = try Data(contentsOf: processingURL)
        let payload = try decoder.decode(Payload.self, from: data)
        try? fileManager.removeItem(at: processingURL)
        return payload
    }

    private func payloadFileURL() throws -> URL {
        guard let containerURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) else {
            throw BookCollectionShareImportHandoffError.missingAppGroupContainer
        }
        return containerURL
            .appendingPathComponent("ShareImport", isDirectory: true)
            .appendingPathComponent("book_collection_import.json")
    }

    private func processingPayloadFileURL(for payloadURL: URL) -> URL {
        payloadURL
            .deletingLastPathComponent()
            .appendingPathComponent("book_collection_import_processing_\(UUID().uuidString).json")
    }

    /// 扩展写入、主 App 消费的待导入书单 payload。
    struct Payload: Codable, Hashable, Sendable {
        let id: UUID
        let link: String
        let source: String
        let receivedAt: TimeInterval
    }
}

/// 分享导入交接层的本地错误，向扩展 UI 和主 App 路由提供可读失败原因。
nonisolated enum BookCollectionShareImportHandoffError: LocalizedError {
    case invalidWereadLink
    case missingAppGroupContainer

    var errorDescription: String? {
        switch self {
        case .invalidWereadLink:
            return "没有识别到微信读书书单链接"
        case .missingAppGroupContainer:
            return "分享导入容器暂不可用，请检查 App Group 配置"
        }
    }
}
