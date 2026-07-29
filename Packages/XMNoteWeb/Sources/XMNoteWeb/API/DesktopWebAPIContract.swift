/**
 * [INPUT]: 依赖 App 注入的访问授权与会员只读判定，不依赖任何 App 数据库或 UI 类型
 * [OUTPUT]: 提供 Web API 运行依赖、跨模块错误语义与 Android 兼容响应封装
 * [POS]: XMNoteWeb 的业务 API 公共边界；仅暴露平台无关协议和值类型
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Hummingbird

/// 为 Web 请求提供访问授权与写能力判断，具体状态仍由 App 侧 Adapter 持有。
public protocol DesktopWebRequestGatePort: Sendable {
    /// 异步校验请求携带的访问码；实现自行串行保护设置读取，调用任务取消时不得继续产生副作用。
    func isAccessAuthorized(_ accessCode: String?) async -> Bool

    /// 异步返回当前是否应拦截核心写请求；实现只读取会员能力，不得在查询时触发登录或购买流程。
    func isDesktopReadOnly() async -> Bool
}

/// 承载 Web 专属设置的 JSON 值，在保持数字与 null 语义的同时避免 App 依赖 HTTP 类型。
public enum DesktopWebJSONValue: Codable, Sendable, Equatable {
    case object([String: DesktopWebJSONValue])
    case array([DesktopWebJSONValue])
    case string(String)
    case integer(Int64)
    case number(Double)
    case boolean(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([DesktopWebJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: DesktopWebJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "不支持的 Web JSON 值"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .boolean(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    public var objectValue: [String: DesktopWebJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var integerValue: Int64? {
        switch self {
        case .integer(let value):
            return value
        case .number(let value) where value.rounded() == value:
            return Int64(exactly: value)
        default:
            return nil
        }
    }

    public var booleanValue: Bool? {
        guard case .boolean(let value) = self else { return nil }
        return value
    }
}

/// 网页访问授权状态；访问码本身只在 App 页面展示，不通过该接口返回。
public struct DesktopWebAccessAuthSettings: Codable, Sendable, Equatable {
    public let enabled: Bool
    public let headerName: String

    public init(enabled: Bool, headerName: String) {
        self.enabled = enabled
        self.headerName = headerName
    }
}

/// 网页写能力快照，字段与 Android MembershipCapabilityDto 保持一致。
public struct DesktopWebMembershipCapability: Codable, Sendable, Equatable {
    public let isPremium: Bool
    public let desktopReadOnly: Bool
    public let canWriteCoreData: Bool
    public let upgradeActionAvailable: Bool

    public init(
        isPremium: Bool,
        desktopReadOnly: Bool,
        canWriteCoreData: Bool,
        upgradeActionAvailable: Bool
    ) {
        self.isPremium = isPremium
        self.desktopReadOnly = desktopReadOnly
        self.canWriteCoreData = canWriteCoreData
        self.upgradeActionAvailable = upgradeActionAvailable
    }
}

/// 原生动作受理结果；accepted 只表示 App 是否接受请求，不代表用户已经完成开通。
public struct DesktopWebNativeActionResult: Codable, Sendable, Equatable {
    public let accepted: Bool
    public let message: String?

    public init(accepted: Bool, message: String? = nil) {
        self.accepted = accepted
        self.message = message
    }
}

/// 隔离设置持久化、会员能力和原生导航，路由只处理 HTTP DTO 与 Android 包络。
public protocol DesktopWebSettingsPort: Sendable {
    /// 读取完整 Web 设置快照；实现负责并发一致性，调用取消时不修改持久化状态。
    func webSettings() async throws -> DesktopWebJSONValue

    /// 按 Android 的局部 Patch 与归一化规则更新 Web 设置；取消后不得继续提交未完成写入。
    func updateWebSettings(_ patch: DesktopWebJSONValue) async throws

    /// 读取访问授权开关，不返回本地访问码。
    func accessAuthSettings() async -> DesktopWebAccessAuthSettings

    /// 读取完整导出设置，包括 Android 合同中现有的明文凭据字段。
    func exportSettings() async throws -> DesktopWebJSONValue

    /// 按 Android 的可选字段规则更新导出设置；实现应原子保存同一请求中的字段。
    func updateExportSettings(_ patch: DesktopWebJSONValue) async throws

    /// 读取当前 Web 写能力快照，不在查询中触发购买或登录流程。
    func membershipCapability() async -> DesktopWebMembershipCapability

    /// 请求 App 打开高级版页面；主线程切换由 App Adapter 负责。
    func openPremiumUpgrade() async -> DesktopWebNativeActionResult
}

/// 组合 Web API 的跨模块运行依赖，避免路由直接接触 App 的 Repository 容器。
public struct DesktopWebAPIDependencies: Sendable {
    let requestGate: any DesktopWebRequestGatePort
    let settings: (any DesktopWebSettingsPort)?
    let source: (any DesktopWebSourcePort)?
    let tag: (any DesktopWebTagPort)?
    let group: (any DesktopWebGroupPort)?
    let book: (any DesktopWebBookPort)?
    let bookshelf: (any DesktopWebBookshelfPort)?
    let calendar: (any DesktopWebCalendarPort)?
    let chapter: (any DesktopWebChapterPort)?
    let note: (any DesktopWebNotePort)?
    let related: (any DesktopWebRelatedPort)?
    let review: (any DesktopWebReviewPort)?
    let readingRecord: (any DesktopWebReadingRecordPort)?
    let search: (any DesktopWebSearchPort)?
    let statistics: (any DesktopWebStatisticsPort)?
    let ai: (any DesktopWebAIPort)?
    let onlineBook: (any DesktopWebOnlineBookPort)?
    let bookCover: (any DesktopWebBookCoverPort)?
    let export: (any DesktopWebExportPort)?
    let importTask: (any DesktopWebImportPort)?
    let upload: (any DesktopWebUploadPort)?

    /// 保存 App 注入的请求门禁端口；端口必须由自身并发模型保护可变状态。
    public init(
        requestGate: any DesktopWebRequestGatePort,
        settings: (any DesktopWebSettingsPort)? = nil,
        source: (any DesktopWebSourcePort)? = nil,
        tag: (any DesktopWebTagPort)? = nil,
        group: (any DesktopWebGroupPort)? = nil,
        book: (any DesktopWebBookPort)? = nil,
        bookshelf: (any DesktopWebBookshelfPort)? = nil,
        calendar: (any DesktopWebCalendarPort)? = nil,
        chapter: (any DesktopWebChapterPort)? = nil,
        note: (any DesktopWebNotePort)? = nil,
        related: (any DesktopWebRelatedPort)? = nil,
        review: (any DesktopWebReviewPort)? = nil,
        readingRecord: (any DesktopWebReadingRecordPort)? = nil,
        search: (any DesktopWebSearchPort)? = nil,
        statistics: (any DesktopWebStatisticsPort)? = nil,
        ai: (any DesktopWebAIPort)? = nil,
        onlineBook: (any DesktopWebOnlineBookPort)? = nil,
        bookCover: (any DesktopWebBookCoverPort)? = nil,
        export: (any DesktopWebExportPort)? = nil,
        importTask: (any DesktopWebImportPort)? = nil,
        upload: (any DesktopWebUploadPort)? = nil
    ) {
        self.requestGate = requestGate
        self.settings = settings
        self.source = source
        self.tag = tag
        self.group = group
        self.book = book
        self.bookshelf = bookshelf
        self.calendar = calendar
        self.chapter = chapter
        self.note = note
        self.related = related
        self.review = review
        self.readingRecord = readingRecord
        self.search = search
        self.statistics = statistics
        self.ai = ai
        self.onlineBook = onlineBook
        self.bookCover = bookCover
        self.export = export
        self.importTask = importTask
        self.upload = upload
    }
}

/// 允许 App Adapter 将已归类的业务失败传回 Web 层，同时不泄漏 HTTP 框架类型。
public struct DesktopWebAPIError: Error, LocalizedError, Sendable {
    public let code: Int
    public let message: String

    /// 创建使用 Android Web 错误码和用户可见消息的业务失败。
    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? {
        message
    }
}

struct DesktopWebAPIEnvelope<Payload: Encodable>: Encodable {
    let code: Int
    let message: String
    let data: Payload?

    private enum CodingKeys: String, CodingKey {
        case code
        case message = "msg"
        case data
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(message, forKey: .message)
        if let data {
            try container.encode(data, forKey: .data)
        }
    }
}

enum DesktopWebAPIResponse {
    static let jsonContentType = "application/json;charset=UTF-8"

    private struct EmptyPayload: Encodable {}
    private static let androidFloatingPointFieldPattern = try! NSRegularExpression(
        pattern: #""(?:position|price|ratio|readPosition|totalMoney)"\s*:\s*-?(?:0|[1-9][0-9]*)(?=\s*[,}])"#
    )

    /// 将业务数据编码为 Android 的 code/msg/data 成功包络，编码失败继续交由异常中间件统一处理。
    static func success<Payload: Encodable>(_ data: Payload?) throws -> Response {
        try makeResponse(
            DesktopWebAPIEnvelope(code: 200, message: "success", data: data)
        )
    }

    /// 将业务错误编码为 HTTP 200 的 Android 包络；默认 Gson 语义会省略 nil data 字段。
    static func error(code: Int, message: String) throws -> Response {
        try makeResponse(
            DesktopWebAPIEnvelope<EmptyPayload>(code: code, message: message, data: nil)
        )
    }

    private static func makeResponse<Payload: Encodable>(
        _ envelope: DesktopWebAPIEnvelope<Payload>
    ) throws -> Response {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encodedData = try encoder.encode(envelope)
        let data = androidFloatingPointLexemes(in: encodedData)
        return Response(
            status: .ok,
            headers: [.contentType: jsonContentType],
            body: .init(byteBuffer: ByteBuffer(bytes: data))
        )
    }

    /// 将 Foundation 对整数值 Double/Float 的 `0` 编码改为 Gson 的 `0.0`，只触及 Android DTO 中声明为浮点数的字段。
    private static func androidFloatingPointLexemes(in data: Data) -> Data {
        guard let source = String(data: data, encoding: .utf8) else { return data }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        let result = androidFloatingPointFieldPattern.stringByReplacingMatches(
            in: source,
            range: range,
            withTemplate: "$0.0"
        )
        return Data(result.utf8)
    }
}
