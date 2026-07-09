/**
 * [INPUT]: 依赖 DatabaseManager 读取书摘发送载荷，依赖 ExternalAppIntegrationSettingStore 持久化配置，依赖 NetworkClient 执行外部 API 请求
 * [OUTPUT]: 对外提供 ExternalAppIntegrationRepository（ExternalAppIntegrationRepositoryProtocol 的实现）
 * [POS]: Data 层关联应用集成仓储，统一封装 Flomo、Writeathon 与 Inbox 的配置、模板和网络发送
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Alamofire
import Foundation
import GRDB

/// 关联应用集成仓储实现，负责按书摘 ID 读取本地数据并发送到外部工具。
struct ExternalAppIntegrationRepository: ExternalAppIntegrationRepositoryProtocol {
    private let databaseManager: DatabaseManager
    private let settingStore: ExternalAppIntegrationSettingStore
    private let networkClient: NetworkClient
    private let jsonDecoder = JSONDecoder()

    /// 注入数据库、配置存储和无认证网络客户端。
    init(
        databaseManager: DatabaseManager,
        settingStore: ExternalAppIntegrationSettingStore = .shared,
        networkClient: NetworkClient = NetworkClient(requestTimeout: 30)
    ) {
        self.databaseManager = databaseManager
        self.settingStore = settingStore
        self.networkClient = networkClient
    }

    /// 读取当前关联应用配置。
    func fetchSettings() -> ExternalAppIntegrationSettings {
        settingStore.fetchSettings()
    }

    /// 保存关联应用配置，写入前校验非空 URL 是否符合 Android 端格式。
    func saveSettings(_ settings: ExternalAppIntegrationSettings) throws {
        let normalized = settings.normalized
        try validateSettings(normalized)
        try settingStore.save(normalized)
    }

    /// 基于当前配置计算已启用目标，供菜单构建与设置页状态展示。
    func configuredDestinations() -> [ExternalAppDestination] {
        fetchSettings().configuredDestinations
    }

    /// 按书摘 ID 读取载荷并发送到指定外部工具。
    func send(noteID: Int64, to destination: ExternalAppDestination) async throws -> ExternalAppIntegrationSendResult {
        let settings = fetchSettings()
        let note = try await fetchNotePayload(noteID: noteID)
        guard note.hasSendableContent else {
            throw ExternalAppIntegrationError.emptyContent(noteID: noteID)
        }
        let sendPayload = try makeSendPayload(destination: destination, settings: settings, note: note)

        switch destination {
        case .flomo:
            return try await sendJSONContent(sendPayload)
        case .writeathon:
            return try await sendToWriteathon(sendPayload, token: settings.normalized.writeathonToken)
        case .inbox:
            return try await sendToInbox(sendPayload)
        }
    }
}

private extension ExternalAppIntegrationRepository {
    enum Constants {
        static let writeathonBaseURL = "https://api.writeathon.cn"
    }

    func validateSettings(_ settings: ExternalAppIntegrationSettings) throws {
        if !settings.flomoWebhookURL.isEmpty {
            _ = try validatedURL(settings.flomoWebhookURL, for: .flomo)
        }
        if !settings.inboxWebhookURL.isEmpty {
            _ = try validatedURL(settings.inboxWebhookURL, for: .inbox)
        }
    }

    func makeSendPayload(
        destination: ExternalAppDestination,
        settings: ExternalAppIntegrationSettings,
        note: ExternalAppIntegrationNotePayload
    ) throws -> ExternalAppIntegrationSendPayload {
        let normalized = settings.normalized
        let requestURL: URL
        switch destination {
        case .flomo:
            guard !normalized.flomoWebhookURL.isEmpty else {
                throw ExternalAppIntegrationError.missingConfiguration(destination)
            }
            requestURL = try validatedURL(normalized.flomoWebhookURL, for: destination)
        case .writeathon:
            guard !normalized.writeathonToken.isEmpty else {
                throw ExternalAppIntegrationError.missingConfiguration(destination)
            }
            guard let url = URL(string: Constants.writeathonBaseURL) else {
                throw ExternalAppIntegrationError.invalidConfiguration(destination, message: "Writeathon 基础地址无效")
            }
            requestURL = url
        case .inbox:
            guard !normalized.inboxWebhookURL.isEmpty else {
                throw ExternalAppIntegrationError.missingConfiguration(destination)
            }
            requestURL = try validatedURL(normalized.inboxWebhookURL, for: destination)
        }

        let content = renderDefaultTemplate(note: note, destination: destination)
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ExternalAppIntegrationError.emptyContent(noteID: note.noteID)
        }
        return ExternalAppIntegrationSendPayload(
            destination: destination,
            note: note,
            requestURL: requestURL,
            content: content
        )
    }

    func validatedURL(_ rawValue: String, for destination: ExternalAppDestination) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "https",
              let host = url.host?.lowercased() else {
            throw ExternalAppIntegrationError.invalidConfiguration(destination, message: "请输入 https 开头的完整地址")
        }

        switch destination {
        case .flomo:
            guard host == "flomoapp.com", url.path.hasPrefix("/iwh/"), url.pathComponents.count >= 4 else {
                throw ExternalAppIntegrationError.invalidConfiguration(destination, message: "地址格式应类似 https://flomoapp.com/iwh/…/…/")
            }
        case .inbox:
            guard host == "api.gudong.site", url.path.hasPrefix("/inbox/") else {
                throw ExternalAppIntegrationError.invalidConfiguration(destination, message: "地址格式应类似 https://api.gudong.site/inbox/…")
            }
        case .writeathon:
            break
        }

        return url
    }

    func fetchNotePayload(noteID: Int64) async throws -> ExternalAppIntegrationNotePayload {
        try await databaseManager.database.dbPool.read { db in
            try fetchNotePayload(db, noteID: noteID)
        }
    }

    nonisolated func fetchNotePayload(_ db: Database, noteID: Int64) throws -> ExternalAppIntegrationNotePayload {
        // SQL 目的：读取外部应用发送所需的单条书摘、书籍和章节基础信息。
        // 涉及表：note 为主表，book/chapter 补充书名、作者和章节标题。
        // 关键过滤：按 note.id 精确命中，并排除 note.is_deleted=1；book/chapter 软删除时仅回退为空展示字段，不阻断书摘发送。
        // 时间字段：note.created_date 为 Android 毫秒时间戳，转换为 Date 仅用于默认模板展示。
        // 返回字段用途：构建 ExternalAppIntegrationNotePayload，后续标签和附图通过独立批量语义查询补齐。
        let sql = """
            SELECT n.id, n.book_id, n.content, n.idea, n.position, n.position_unit, n.created_date,
                   COALESCE(b.name, '') AS book_name,
                   COALESCE(b.author, '') AS book_author,
                   COALESCE(c.title, '') AS chapter_title
            FROM note n
            LEFT JOIN book b ON b.id = n.book_id AND b.is_deleted = 0
            LEFT JOIN chapter c ON c.id = n.chapter_id AND c.is_deleted = 0
            WHERE n.id = ? AND n.is_deleted = 0
            LIMIT 1
            """
        guard let row = try Row.fetchOne(db, sql: sql, arguments: [noteID]) else {
            throw ExternalAppIntegrationError.noteNotFound(noteID: noteID)
        }

        let tags = try fetchTagNames(db, noteID: noteID)
        let images = try fetchImageURLs(db, noteID: noteID)
        let createdMillis: Int64 = row["created_date"] ?? 0
        return ExternalAppIntegrationNotePayload(
            noteID: noteID,
            bookID: row["book_id"] ?? 0,
            bookTitle: row["book_name"] ?? "",
            bookAuthor: row["book_author"] ?? "",
            chapterTitle: row["chapter_title"] ?? "",
            positionText: NotePositionUnitFormatter.labeledFooterText(
                position: row["position"] ?? "",
                unit: row["position_unit"] ?? 0
            ) ?? "",
            contentText: plainText(row["content"] ?? ""),
            ideaText: plainText(row["idea"] ?? ""),
            tagNames: tags,
            imageURLs: images,
            createdDate: createdMillis > 0 ? Date(timeIntervalSince1970: Double(createdMillis) / 1000.0) : nil
        )
    }

    nonisolated func fetchTagNames(_ db: Database, noteID: Int64) throws -> [String] {
        // SQL 目的：读取单条书摘关联的有效书摘标签名称。
        // 涉及表：tag_note INNER JOIN tag。
        // 关键过滤：限定当前 note_id，排除 tag_note/tag 软删除记录，并限制 tag.type=1。
        // 时间字段：不涉及时间字段。
        // 返回字段用途：生成外部应用默认发送模板中的标签行。
        let sql = """
            SELECT t.name
            FROM tag_note tn
            JOIN tag t ON t.id = tn.tag_id AND t.is_deleted = 0 AND t.type = 1
            WHERE tn.is_deleted = 0 AND tn.note_id = ?
            ORDER BY t.tag_order ASC, tn.id ASC
            """
        return try Row.fetchAll(db, sql: sql, arguments: [noteID]).compactMap { row in
            guard let name: String = row["name"] else { return nil }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    nonisolated func fetchImageURLs(_ db: Database, noteID: Int64) throws -> [String] {
        // SQL 目的：读取单条书摘关联的有效附图 URL。
        // 涉及表：attach_image。
        // 关键过滤：限定当前 note_id，排除 attach_image.is_deleted=1。
        // 时间字段：不读取时间字段；按 id ASC 保持 Android 附图顺序。
        // 返回字段用途：生成外部应用默认发送模板中的附图链接行。
        let sql = """
            SELECT image_url
            FROM attach_image
            WHERE is_deleted = 0 AND note_id = ?
            ORDER BY id ASC
            """
        return try Row.fetchAll(db, sql: sql, arguments: [noteID]).compactMap { row in
            guard let url: String = row["image_url"] else { return nil }
            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    nonisolated func plainText(_ html: String) -> String {
        RichTextPlainTextExtractor
            .plainText(from: html)
            .collapsingWhitespaceForExternalApp()
    }

    nonisolated func renderDefaultTemplate(
        note: ExternalAppIntegrationNotePayload,
        destination: ExternalAppDestination
    ) -> String {
        var lines: [String] = []
        let title = note.bookTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            lines.append("《\(title)》")
        }
        let author = note.bookAuthor.trimmingCharacters(in: .whitespacesAndNewlines)
        if !author.isEmpty {
            lines.append("作者：\(author)")
        }
        if !note.chapterTitle.isEmpty {
            lines.append("章节：\(note.chapterTitle)")
        }
        if !note.positionText.isEmpty {
            lines.append(note.positionText)
        }
        if let createdDate = note.createdDate {
            lines.append("时间：\(createdDateText(createdDate))")
        }

        let metadata = lines.joined(separator: "\n")
        var body: [String] = []
        if !metadata.isEmpty {
            body.append(metadata)
        }
        if !note.contentText.isEmpty {
            body.append(note.contentText)
        }
        if !note.ideaText.isEmpty {
            body.append("想法：\(note.ideaText)")
        }
        if !note.tagNames.isEmpty {
            body.append("标签：\(note.tagNames.joined(separator: " / "))")
        }
        if !note.imageURLs.isEmpty {
            body.append("附图：\n\(note.imageURLs.joined(separator: "\n"))")
        }
        return body.joined(separator: "\n\n")
    }

    nonisolated func createdDateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    func sendJSONContent(_ payload: ExternalAppIntegrationSendPayload) async throws -> ExternalAppIntegrationSendResult {
        let response = await networkClient.session.request(
            payload.requestURL,
            method: .post,
            parameters: ["content": payload.content],
            encoding: JSONEncoding.default
        )
        .serializingData()
        .response
        try validateHTTPResponse(response, destination: payload.destination)
        return ExternalAppIntegrationSendResult(
            destination: payload.destination,
            noteID: payload.note.noteID,
            statusCode: response.response?.statusCode,
            message: "ok",
            sentAt: Date()
        )
    }

    func sendToInbox(_ payload: ExternalAppIntegrationSendPayload) async throws -> ExternalAppIntegrationSendResult {
        let response = await networkClient.session.request(
            payload.requestURL,
            method: .post,
            parameters: ["content": payload.content],
            encoding: JSONEncoding.default
        )
        .serializingData()
        .response
        let data = try validateHTTPResponse(response, destination: payload.destination)
        if let inbox = try? jsonDecoder.decode(InboxResponse.self, from: data), !inbox.isSuccess {
            throw ExternalAppIntegrationError.invalidResponse(payload.destination, message: inbox.msg ?? "code=\(inbox.code ?? -1)")
        }
        return ExternalAppIntegrationSendResult(
            destination: payload.destination,
            noteID: payload.note.noteID,
            statusCode: response.response?.statusCode,
            message: "ok",
            sentAt: Date()
        )
    }

    func sendToWriteathon(
        _ payload: ExternalAppIntegrationSendPayload,
        token: String
    ) async throws -> ExternalAppIntegrationSendResult {
        let headers: HTTPHeaders = ["x-writeathon-token": token]
        let meURL = payload.requestURL.appendingPathComponent("v1/me")
        let meResponse = await networkClient.session.request(meURL, method: .get, headers: headers)
            .serializingData()
            .response
        let meData = try validateHTTPResponse(meResponse, destination: .writeathon)
        let user = try decodeWriteathonUser(meData)
        guard let userID = user.data?.id?.trimmingCharacters(in: .whitespacesAndNewlines), !userID.isEmpty else {
            throw ExternalAppIntegrationError.invalidResponse(.writeathon, message: "用户 ID 为空")
        }

        let cardURL = payload.requestURL
            .appendingPathComponent("v1/users")
            .appendingPathComponent(userID)
            .appendingPathComponent("cards")
        let cardResponse = await networkClient.session.request(
            cardURL,
            method: .post,
            parameters: ["content": payload.content],
            encoding: JSONEncoding.default,
            headers: headers
        )
        .serializingData()
        .response
        let cardData = try validateHTTPResponse(cardResponse, destination: .writeathon)
        let card = try decodeWriteathonCard(cardData)
        guard card.success else {
            throw ExternalAppIntegrationError.invalidResponse(
                .writeathon,
                message: card.message ?? "errorCode=\(card.errorCode ?? -1)"
            )
        }
        return ExternalAppIntegrationSendResult(
            destination: .writeathon,
            noteID: payload.note.noteID,
            statusCode: cardResponse.response?.statusCode,
            message: card.message ?? "ok",
            sentAt: Date()
        )
    }

    @discardableResult
    func validateHTTPResponse(
        _ response: DataResponse<Data, AFError>,
        destination: ExternalAppDestination
    ) throws -> Data {
        if let statusCode = response.response?.statusCode, statusCode == 401 {
            throw ExternalAppIntegrationError.unauthorized(destination)
        }
        if let error = response.error {
            throw ExternalAppIntegrationError.networkFailure(
                destination,
                statusCode: response.response?.statusCode,
                message: error.localizedDescription
            )
        }
        guard let statusCode = response.response?.statusCode else {
            throw ExternalAppIntegrationError.invalidResponse(destination, message: "缺少 HTTP 状态码")
        }
        guard (200..<300).contains(statusCode) else {
            let message = response.data.flatMap { String(data: $0, encoding: .utf8) } ?? HTTPURLResponse.localizedString(forStatusCode: statusCode)
            throw ExternalAppIntegrationError.networkFailure(destination, statusCode: statusCode, message: message)
        }
        return response.data ?? Data()
    }

    func decodeWriteathonUser(_ data: Data) throws -> WriteathonUserResponse {
        do {
            let dto = try jsonDecoder.decode(WriteathonUserResponse.self, from: data)
            guard dto.success else {
                throw ExternalAppIntegrationError.invalidResponse(
                    .writeathon,
                    message: dto.message ?? "errorCode=\(dto.errorCode ?? -1)"
                )
            }
            return dto
        } catch let error as ExternalAppIntegrationError {
            throw error
        } catch {
            throw ExternalAppIntegrationError.invalidResponse(.writeathon, message: error.localizedDescription)
        }
    }

    func decodeWriteathonCard(_ data: Data) throws -> WriteathonCardResponse {
        do {
            return try jsonDecoder.decode(WriteathonCardResponse.self, from: data)
        } catch {
            throw ExternalAppIntegrationError.invalidResponse(.writeathon, message: error.localizedDescription)
        }
    }
}

private struct WriteathonUserResponse: Decodable {
    let success: Bool
    let data: User?
    let message: String?
    let errorCode: Int?

    struct User: Decodable {
        let id: String?
    }
}

private struct WriteathonCardResponse: Decodable {
    let success: Bool
    let message: String?
    let errorCode: Int?
}

private struct InboxResponse: Decodable {
    let code: Int?
    let msg: String?

    var isSuccess: Bool {
        code == 0
    }
}

private extension String {
    nonisolated func collapsingWhitespaceForExternalApp() -> String {
        components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
