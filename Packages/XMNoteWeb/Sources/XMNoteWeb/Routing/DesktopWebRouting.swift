/**
 * [INPUT]: 依赖 Hummingbird Router、请求体流和 Package 内部路由注册约定
 * [OUTPUT]: 提供 /health、严格 JSON/Android 表单解析与供大文件接口复用的流式请求体消费能力
 * [POS]: XMNoteWeb 的内部路由基础设施；不公开 Hummingbird 类型，也不注册业务 API
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Hummingbird

protocol DesktopWebRouteCollection: Sendable {
    func register(on router: Router<BasicRequestContext>)
}

extension Request {
    /// 严格按 JSON 语法收集并解码 DTO，拒绝 Foundation 宽松接受的尾随逗号且不泄漏解码器技术文案。
    func decodeStrictJSON<Value: Decodable>(
        as type: Value.Type,
        context: BasicRequestContext
    ) async throws -> Value {
        let buffer = try await body.collect(upTo: context.maxUploadSize)
        let data = Data(buffer.readableBytesView)
        guard !data.isEmpty,
              !data.allSatisfy({ byte in
                  byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
              }) else {
            throw DesktopWebAPIError(code: 40001, message: "请求体不能为空")
        }
        guard DesktopWebStrictJSONParser.isValid(data) else {
            throw DesktopWebAPIError(code: 40001, message: "请求体 JSON 格式错误")
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw DesktopWebAPIError(code: 40001, message: "请求体 JSON 格式错误")
        }
    }
}

private struct DesktopWebStrictJSONParser {
    private let bytes: [UInt8]
    private var index = 0

    static func isValid(_ data: Data) -> Bool {
        var parser = Self(bytes: Array(data))
        parser.skipWhitespace()
        guard parser.parseValue() else { return false }
        parser.skipWhitespace()
        return parser.index == parser.bytes.count
    }

    private mutating func parseValue() -> Bool {
        guard index < bytes.count else { return false }
        switch bytes[index] {
        case 0x7B:
            return parseObject()
        case 0x5B:
            return parseArray()
        case 0x22:
            return parseString()
        case 0x74:
            return consumeLiteral([0x74, 0x72, 0x75, 0x65])
        case 0x66:
            return consumeLiteral([0x66, 0x61, 0x6C, 0x73, 0x65])
        case 0x6E:
            return consumeLiteral([0x6E, 0x75, 0x6C, 0x6C])
        case 0x2D, 0x30...0x39:
            return parseNumber()
        default:
            return false
        }
    }

    private mutating func parseObject() -> Bool {
        index += 1
        skipWhitespace()
        if consume(0x7D) { return true }
        while true {
            guard parseString() else { return false }
            skipWhitespace()
            guard consume(0x3A) else { return false }
            skipWhitespace()
            guard parseValue() else { return false }
            skipWhitespace()
            if consume(0x7D) { return true }
            guard consume(0x2C) else { return false }
            skipWhitespace()
        }
    }

    private mutating func parseArray() -> Bool {
        index += 1
        skipWhitespace()
        if consume(0x5D) { return true }
        while true {
            guard parseValue() else { return false }
            skipWhitespace()
            if consume(0x5D) { return true }
            guard consume(0x2C) else { return false }
            skipWhitespace()
        }
    }

    private mutating func parseString() -> Bool {
        guard consume(0x22) else { return false }
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == 0x22 { return true }
            if byte < 0x20 { return false }
            guard byte == 0x5C else { continue }
            guard index < bytes.count else { return false }
            let escape = bytes[index]
            index += 1
            if [0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74].contains(escape) {
                continue
            }
            guard escape == 0x75, index + 4 <= bytes.count else { return false }
            for hex in bytes[index..<(index + 4)] {
                guard (0x30...0x39).contains(hex)
                    || (0x41...0x46).contains(hex)
                    || (0x61...0x66).contains(hex) else {
                    return false
                }
            }
            index += 4
        }
        return false
    }

    private mutating func parseNumber() -> Bool {
        _ = consume(0x2D)
        guard index < bytes.count else { return false }
        if consume(0x30) {
            if index < bytes.count, (0x30...0x39).contains(bytes[index]) {
                return false
            }
        } else {
            guard consumeDigit(in: 0x31...0x39) else { return false }
            while consumeDigit(in: 0x30...0x39) {}
        }
        if consume(0x2E) {
            guard consumeDigit(in: 0x30...0x39) else { return false }
            while consumeDigit(in: 0x30...0x39) {}
        }
        if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
            index += 1
            if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D {
                index += 1
            }
            guard consumeDigit(in: 0x30...0x39) else { return false }
            while consumeDigit(in: 0x30...0x39) {}
        }
        return true
    }

    private mutating func consumeLiteral(_ literal: [UInt8]) -> Bool {
        guard index + literal.count <= bytes.count,
              Array(bytes[index..<(index + literal.count)]) == literal else {
            return false
        }
        index += literal.count
        return true
    }

    private mutating func consume(_ expected: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == expected else { return false }
        index += 1
        return true
    }

    private mutating func consumeDigit(in range: ClosedRange<UInt8>) -> Bool {
        guard index < bytes.count, range.contains(bytes[index]) else { return false }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while index < bytes.count,
              bytes[index] == 0x20 || bytes[index] == 0x09
                || bytes[index] == 0x0A || bytes[index] == 0x0D {
            index += 1
        }
    }
}

struct DesktopWebHealthRoutes: DesktopWebRouteCollection {
    /// 注册只用于判断 HTTP 基础设施存活的健康检查，不暴露业务状态。
    func register(on router: Router<BasicRequestContext>) {
        router.get("/health") { _, _ in "ok" }
    }
}

enum DesktopWebAndroidFormQuery {
    /// 按 AndServer 的查询规则读取参数；其 URL 重建缺陷只会拼接第一个参数名的重复值。
    static func value(
        named name: String,
        in request: Request
    ) -> String? {
        guard let query = request.uri.query else {
            return nil
        }
        var firstName: String?
        var valuesByName: [String: [String]] = [:]
        for component in query.split(
            separator: "&",
            omittingEmptySubsequences: false
        ) {
            let pair = component.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard pair.count == 2 else {
                continue
            }
            let rawName = String(pair[0])
            let rawValue = String(pair[1])
            guard !rawName.isEmpty, !rawValue.isEmpty else {
                continue
            }
            if firstName == nil {
                firstName = rawName
            }
            valuesByName[rawName, default: []].append(decodeComponent(rawValue))
        }
        guard let values = valuesByName[name], let firstValue = values.first else {
            return nil
        }
        guard firstName == name, values.count > 1 else {
            return firstValue
        }
        return values.dropFirst().reduce(firstValue) { partialResult, value in
            partialResult + name + "=" + value
        }
    }

    /// 复刻必填 Kotlin Long 的缺失与解析失败合同，不对原始文本做 trim。
    static func requiredInt64(
        named name: String,
        in request: Request
    ) throws -> Int64 {
        guard let rawValue = value(named: name, in: request),
              !rawValue.isEmpty else {
            throw DesktopWebAPIError(
                code: 40001,
                message: "Missing param [\(name)] for method parameter."
            )
        }
        guard let value = Int64(rawValue) else {
            throw DesktopWebAPIError(
                code: 40001,
                message: "For input string: \"\(rawValue)\""
            )
        }
        return value
    }

    /// 复刻带默认值 Kotlin Int 查询参数：缺失或空值使用默认值，非法值泄露 Java 整数解析文本。
    static func optionalInt32(
        named name: String,
        default defaultValue: Int,
        in request: Request
    ) throws -> Int {
        guard let rawValue = value(named: name, in: request),
              !rawValue.isEmpty else {
            return defaultValue
        }
        guard let value = Int32(rawValue) else {
            throw DesktopWebAPIError(
                code: 40001,
                message: "For input string: \"\(rawValue)\""
            )
        }
        return Int(value)
    }

    /// 复刻带默认值 Kotlin Long 查询参数：缺失或空值使用默认值，非法值泄露 Java Long 解析文本。
    static func optionalInt64(
        named name: String,
        default defaultValue: Int64,
        in request: Request
    ) throws -> Int64 {
        guard let rawValue = value(named: name, in: request),
              !rawValue.isEmpty else {
            return defaultValue
        }
        guard let value = Int64(rawValue) else {
            throw DesktopWebAPIError(
                code: 40001,
                message: "For input string: \"\(rawValue)\""
            )
        }
        return value
    }

    /// 复刻带 defaultValue 的 String 查询参数；空值回退默认值，并保留 AndServer 的首键拼接缺陷。
    static func optionalString(
        named name: String,
        default defaultValue: String,
        in request: Request
    ) -> String {
        guard let rawValue = value(named: name, in: request),
              !rawValue.isEmpty else {
            return defaultValue
        }
        return rawValue
    }

    /// 复刻生成 Handler 的 `Boolean.valueOf`：只有忽略大小写的 `true` 为真，其余文本均为假。
    static func optionalBoolean(
        named name: String,
        default defaultValue: Bool,
        in request: Request
    ) -> Bool {
        let rawValue = optionalString(
            named: name,
            default: defaultValue ? "true" : "false",
            in: request
        )
        return rawValue.lowercased() == "true"
    }

    /// 先应用 `application/x-www-form-urlencoded` 的加号规则，再执行百分号解码。
    private static func decodeComponent(_ value: String) -> String {
        let replacingPlus = value.replacingOccurrences(of: "+", with: " ")
        return replacingPlus.removingPercentEncoding ?? replacingPlus
    }
}

enum DesktopWebAndroidPath {
    /// 复刻 AndServer Long 路径绑定：先百分号解码，再暴露 Java `Long.valueOf` 的解析错误文本。
    static func int64(_ rawValue: String) throws -> Int64 {
        let decoded = rawValue.removingPercentEncoding ?? rawValue
        guard let value = Int64(decoded) else {
            throw DesktopWebAPIError(
                code: 40001,
                message: "For input string: \"\(decoded)\""
            )
        }
        return value
    }
}

enum DesktopWebStreamingBody {
    /// 逐块消费请求体；调用任务取消时停止继续读取，当前不解析 multipart。
    static func consume(
        _ request: Request,
        handler: @escaping @Sendable (ByteBuffer) async throws -> Void
    ) async throws {
        for try await buffer in request.body {
            try Task.checkCancellation()
            try await handler(buffer)
        }
    }
}

enum DesktopWebRawResponse {
    /// 将端口返回的状态、头和字节映射为 Hummingbird 响应，框架类型不越过 Package 边界。
    static func make(_ value: DesktopWebRawHTTPResponse) -> Response {
        var headers = HTTPFields()
        for (name, value) in value.headers {
            if let fieldName = HTTPFields.Key(name) {
                headers[fieldName] = value
            }
        }
        let body: ResponseBody
        switch value.body {
        case .data(let data):
            body = .init(byteBuffer: ByteBuffer(bytes: data))
        case .stream(let stream):
            body = .init { writer in
                do {
                    for try await data in stream {
                        try await writer.write(ByteBuffer(bytes: data))
                    }
                    try await writer.finish(nil)
                } catch {
                    try? await writer.finish(nil)
                    throw error
                }
            }
        }
        return Response(status: .init(code: value.statusCode), headers: headers, body: body)
    }
}

struct DesktopWebMultipartForm: Sendable {
    let fields: [String: String]
    let files: [String: DesktopWebUploadedFile]

    /// 收集受全局上传大小限制约束的 multipart body；调用方可保留 Android 参数绑定的缺失文案。
    static func decode(
        _ request: Request,
        maxBytes: Int = 10 * 1_024 * 1_024 + 64 * 1_024,
        missingMultipartMessage: String = "请求必须使用 multipart/form-data"
    ) async throws -> Self {
        guard let contentType = request.headers[.contentType],
              let boundary = boundary(from: contentType) else {
            throw DesktopWebAPIError(code: 40001, message: missingMultipartMessage)
        }
        let buffer = try await request.body.collect(upTo: maxBytes)
        return try parse(Data(buffer.readableBytesView), boundary: boundary)
    }

    private static func boundary(from contentType: String) -> String? {
        for component in contentType.split(separator: ";").dropFirst() {
            let pair = component.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if pair.count == 2, pair[0].lowercased() == "boundary" {
                return pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return nil
    }

    private static func parse(_ data: Data, boundary: String) throws -> Self {
        let marker = Data("--\(boundary)".utf8)
        let separator = Data("\r\n\r\n".utf8)
        let lineBreak = Data("\r\n".utf8)
        var fields: [String: String] = [:]
        var files: [String: DesktopWebUploadedFile] = [:]
        var cursor = data.startIndex

        while let markerRange = data.range(of: marker, in: cursor..<data.endIndex) {
            var partStart = markerRange.upperBound
            if data[partStart...].starts(with: Data("--".utf8)) { break }
            if data[partStart...].starts(with: lineBreak) { partStart += lineBreak.count }
            guard let nextMarker = data.range(of: marker, in: partStart..<data.endIndex),
                  let headerEnd = data.range(of: separator, in: partStart..<nextMarker.lowerBound) else {
                break
            }
            let headerData = data[partStart..<headerEnd.lowerBound]
            var bodyEnd = nextMarker.lowerBound
            if bodyEnd >= lineBreak.count,
               data[(bodyEnd - lineBreak.count)..<bodyEnd] == lineBreak {
                bodyEnd -= lineBreak.count
            }
            let body = Data(data[headerEnd.upperBound..<bodyEnd])
            let headers = String(decoding: headerData, as: UTF8.self)
            if let disposition = headers.split(separator: "\r\n").first(where: {
                $0.lowercased().hasPrefix("content-disposition:")
            }), let name = parameter("name", in: String(disposition)) {
                let contentType = headers.split(separator: "\r\n").first(where: {
                    $0.lowercased().hasPrefix("content-type:")
                }).map { line in
                    String(line.split(separator: ":", maxSplits: 1).last ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let fileName = parameter("filename", in: String(disposition)) {
                    files[name] = DesktopWebUploadedFile(
                        fileName: URL(fileURLWithPath: fileName).lastPathComponent,
                        contentType: contentType,
                        data: body
                    )
                } else {
                    fields[name] = String(decoding: body, as: UTF8.self)
                }
            }
            cursor = nextMarker.lowerBound
        }
        return .init(fields: fields, files: files)
    }

    private static func parameter(_ name: String, in disposition: String) -> String? {
        for component in disposition.split(separator: ";").dropFirst() {
            let pair = component.split(separator: "=", maxSplits: 1)
            guard pair.count == 2,
                  pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == name else {
                continue
            }
            return pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }
}
