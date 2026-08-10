/**
 * [INPUT]: 依赖 Foundation，承接关联应用配置、发送载荷、发送结果与错误语义
 * [OUTPUT]: 对外提供 ExternalAppDestination、ExternalAppIntegrationSettings、ExternalAppIntegrationError、ExternalAppIntegrationNotePayload、ExternalAppIntegrationSendPayload、ExternalAppIntegrationSendResult
 * [POS]: Domain/Models 的关联应用集成模型，供 Repository、ViewModel 与发送入口共享
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 外部关联应用目标，当前对齐 Android 的 flomo、writeathon 与 inBox 三个发送入口。
nonisolated enum ExternalAppDestination: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case flomo
    case writeathon
    case inbox

    var id: String { rawValue }

    /// 设置页与错误文案中展示的应用名称。
    var displayName: String {
        switch self {
        case .flomo:
            return "flomo"
        case .writeathon:
            return "writeathon"
        case .inbox:
            return "inBox"
        }
    }

    /// 设置页输入项标题，区分 URL 与 token 两类配置。
    var configurationTitle: String {
        switch self {
        case .flomo:
            return "Webhook URL"
        case .writeathon:
            return "Token"
        case .inbox:
            return "API URL"
        }
    }

    /// 设置页中使用的系统图标，保持原生设置风格而不引入外部图标资源。
    var systemImageName: String {
        switch self {
        case .flomo:
            return "f.square"
        case .writeathon:
            return "w.square"
        case .inbox:
            return "tray"
        }
    }

    /// 设置页说明文案，帮助用户识别需要粘贴的配置类型。
    var configurationHint: String {
        switch self {
        case .flomo:
            return "粘贴 flomo Incoming Webhook 完整地址。"
        case .writeathon:
            return "粘贴 writeathon 个人访问 token。"
        case .inbox:
            return "粘贴 inBox 接收内容的 API 地址。"
        }
    }
}

/// 关联应用三项配置快照，按 Android SharedPreferences 语义允许任一项独立为空。
nonisolated struct ExternalAppIntegrationSettings: Codable, Equatable, Sendable {
    var flomoWebhookURL: String
    var writeathonToken: String
    var inboxWebhookURL: String

    static let empty = ExternalAppIntegrationSettings(
        flomoWebhookURL: "",
        writeathonToken: "",
        inboxWebhookURL: ""
    )

    /// 返回去除首尾空白后的设置快照，避免输入框中的换行或空格进入持久化与发送链路。
    var normalized: ExternalAppIntegrationSettings {
        ExternalAppIntegrationSettings(
            flomoWebhookURL: flomoWebhookURL.trimmingCharacters(in: .whitespacesAndNewlines),
            writeathonToken: writeathonToken.trimmingCharacters(in: .whitespacesAndNewlines),
            inboxWebhookURL: inboxWebhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// 读取指定目标的原始配置值，供设置页和仓储校验共用。
    func value(for destination: ExternalAppDestination) -> String {
        switch destination {
        case .flomo:
            return flomoWebhookURL
        case .writeathon:
            return writeathonToken
        case .inbox:
            return inboxWebhookURL
        }
    }

    /// 返回更新指定目标后的新配置快照，调用方负责随后保存。
    func settingValue(_ value: String, for destination: ExternalAppDestination) -> ExternalAppIntegrationSettings {
        var next = self
        switch destination {
        case .flomo:
            next.flomoWebhookURL = value
        case .writeathon:
            next.writeathonToken = value
        case .inbox:
            next.inboxWebhookURL = value
        }
        return next
    }

    /// 判断指定目标是否已有非空配置。
    func isConfigured(_ destination: ExternalAppDestination) -> Bool {
        !normalized.value(for: destination).isEmpty
    }

    /// 返回当前已配置的目标列表，顺序保持设置页与 Android 入口一致。
    var configuredDestinations: [ExternalAppDestination] {
        ExternalAppDestination.allCases.filter { isConfigured($0) }
    }
}

/// 关联应用仓储错误，统一覆盖配置缺失、配置非法、内容为空、远端业务失败与网络失败。
nonisolated enum ExternalAppIntegrationError: LocalizedError, Equatable, Sendable {
    case missingConfiguration(ExternalAppDestination)
    case invalidConfiguration(ExternalAppDestination, message: String)
    case noteNotFound(noteID: Int64)
    case emptyContent(noteID: Int64)
    case unauthorized(ExternalAppDestination)
    case invalidResponse(ExternalAppDestination, message: String)
    case networkFailure(ExternalAppDestination, statusCode: Int?, message: String)
    case persistenceFailure(message: String)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration(let destination):
            return "尚未配置 \(destination.displayName)"
        case .invalidConfiguration(let destination, let message):
            return "\(destination.displayName) 配置不可用：\(message)"
        case .noteNotFound:
            return "书摘不存在或已删除"
        case .emptyContent:
            return "发送内容为空"
        case .unauthorized(let destination):
            return "\(destination.displayName) 鉴权失败，请检查配置"
        case .invalidResponse(let destination, let message):
            return "\(destination.displayName) 返回异常：\(message)"
        case .networkFailure(let destination, let statusCode, let message):
            if let statusCode {
                return "\(destination.displayName) 网络请求失败（\(statusCode)）：\(message)"
            }
            return "\(destination.displayName) 网络请求失败：\(message)"
        case .persistenceFailure(let message):
            return "保存配置失败：\(message)"
        }
    }
}

/// 从数据库读取并归一化后的书摘发送载荷，保留模板渲染所需全部业务字段。
nonisolated struct ExternalAppIntegrationNotePayload: Equatable, Sendable {
    let noteID: Int64
    let bookID: Int64
    let bookTitle: String
    let bookAuthor: String
    let chapterTitle: String
    let positionText: String
    let contentText: String
    let ideaText: String
    let tagNames: [String]
    let imageURLs: [String]
    let createdDate: Date?

    /// 判断书摘是否有真正可发送的正文、想法或图片内容；仅有元信息时视为空内容。
    var hasSendableContent: Bool {
        !contentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !ideaText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !imageURLs.isEmpty
    }
}

/// 准备发送给外部应用的最终请求载荷。
nonisolated struct ExternalAppIntegrationSendPayload: Equatable, Sendable {
    let destination: ExternalAppDestination
    let note: ExternalAppIntegrationNotePayload
    let requestURL: URL
    let content: String
}

/// 外部应用发送成功后的结果摘要，供未来发送入口展示或埋点复用。
nonisolated struct ExternalAppIntegrationSendResult: Equatable, Sendable {
    let destination: ExternalAppDestination
    let noteID: Int64
    let statusCode: Int?
    let message: String
    let sentAt: Date
}
