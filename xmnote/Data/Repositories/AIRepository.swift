/**
 * [INPUT]: 依赖 DatabaseManager 读取书摘并原子追加想法，依赖 NoteRepositoryProtocol 复用标签事务，依赖 AIConfigurationStore/OpenAICompatibleClient 管理凭据与请求
 * [OUTPUT]: 对外提供 AIRepository，实现配置、书摘流式解读、选词流式释义、非流式自动标签及业务写回
 * [POS]: Data 层 AI 仓储实现，是 ViewModel 获取 AI/本地数据与提交业务结果的唯一入口
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB

/// AI 仓储实现；配置和请求均为结构化并发，类本身无可变业务状态，可安全复用为 App 级单例依赖。
final class AIRepository: AIRepositoryProtocol, @unchecked Sendable {
    private let databaseManager: DatabaseManager
    private let noteRepository: any NoteRepositoryProtocol
    private let configurationStore: AIConfigurationStore
    private let client: OpenAICompatibleClient

    /// 注入数据库、标签仓储、配置安全存储与 OpenAI-compatible 客户端。
    init(
        databaseManager: DatabaseManager,
        noteRepository: any NoteRepositoryProtocol,
        configurationStore: AIConfigurationStore = .shared,
        client: OpenAICompatibleClient = OpenAICompatibleClient()
    ) {
        self.databaseManager = databaseManager
        self.noteRepository = noteRepository
        self.configurationStore = configurationStore
        self.client = client
    }

    /// 读取设置页快照；API Key 只返回存在状态。
    func fetchConfiguration() async throws -> AIConfigurationSnapshot {
        try await configurationStore.fetchSnapshot()
    }

    /// 校验模型、Prompt 与启用态凭据后保存配置，空密钥输入保留 Keychain 现值。
    func saveConfiguration(_ configuration: AIConfiguration, apiKey: String?) async throws {
        let normalized = configuration.normalized
        try validate(normalized)
        if normalized.isEnabled {
            let providedKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if providedKey.isEmpty {
                let snapshot = try await configurationStore.fetchSnapshot()
                guard snapshot.hasStoredKey(for: normalized.provider) else {
                    throw AIRepositoryError.missingAPIKey(normalized.provider)
                }
            }
        }
        try await configurationStore.save(normalized, apiKey: apiKey)
    }

    /// 删除指定供应商密钥，保持另一供应商凭据与全部非敏感设置不变。
    func deleteAPIKey(for provider: AIProvider) async throws {
        try await configurationStore.deleteCredential(for: provider)
    }

    /// 读取稳定书摘上下文后启动 SSE 解读；外层流取消会同时取消上下文读取和底层网络流。
    func streamNoteExplanation(noteID: Int64) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let note = try await fetchNoteContext(noteID: noteID)
                    let credentials = try await requestCredentials()
                    let prompt = credentials.configuration.prompts.noteExplanation
                    let userPrompt = Self.render(
                        prompt.user,
                        replacements: [
                            "${摘录}": note.contentText,
                            "${想法}": note.ideaText,
                            "${章节}": note.chapterTitle,
                            "${书籍名}": note.bookTitle,
                            "${作者名}": note.bookAuthor,
                        ]
                    )
                    let request = makeRequest(
                        credentials: credentials,
                        messages: [
                            OpenAIChatMessage(role: "system", content: prompt.system),
                            OpenAIChatMessage(role: "user", content: userPrompt),
                        ],
                        responseFormat: .text,
                        isStreaming: true,
                        frequencyPenalty: 0.2,
                        presencePenalty: 0.3,
                        temperature: 0.85,
                        topP: 0.95
                    )
                    for try await content in client.streamCompletion(request) {
                        try Task.checkCancellation()
                        continuation.yield(content)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// 对触发时锁定的选中文本和上下文执行 SSE 释义，不依赖当前 Viewer 翻页状态。
    func streamTextLookup(input: AITextLookupInput) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let query = input.queryText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !query.isEmpty else {
                        throw AIRepositoryError.invalidConfiguration("请先选择需要释义的文字。")
                    }
                    let credentials = try await requestCredentials()
                    let prompt = credentials.configuration.prompts.wordLookup
                    let userPrompt = Self.render(
                        prompt.user,
                        replacements: [
                            "${查询文本}": query,
                            "${上下文}": input.queryContext,
                            "${书籍名}": input.bookTitle,
                        ]
                    )
                    let request = makeRequest(
                        credentials: credentials,
                        messages: [
                            OpenAIChatMessage(role: "system", content: prompt.system),
                            OpenAIChatMessage(role: "user", content: userPrompt),
                        ],
                        responseFormat: .text,
                        isStreaming: true,
                        frequencyPenalty: 0.2,
                        presencePenalty: 0.3,
                        temperature: 0.85,
                        topP: 0.95
                    )
                    for try await content in client.streamCompletion(request) {
                        try Task.checkCancellation()
                        continuation.yield(content)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// 使用非流式 JSON 响应生成自动标签，并以数据库真实标签集合校准 isExisting。
    func suggestTags(noteID: Int64) async throws -> [AIAutoTagSuggestion] {
        async let noteContext = fetchNoteContext(noteID: noteID)
        async let tagOptions = noteRepository.fetchNoteReviewTagOptions()
        let (note, tags) = try await (noteContext, tagOptions)
        try Task.checkCancellation()

        let credentials = try await requestCredentials()
        let prompt = credentials.configuration.prompts.autoTag
        let existingNames = tags.map(\.title)
        let userPrompt = Self.render(
            prompt.user,
            replacements: [
                "${书摘内容}": note.contentText,
                "${书籍名}": note.bookTitle,
                "${作者名}": note.bookAuthor,
                "${章节}": note.chapterTitle,
                "${已有标签}": existingNames.isEmpty ? "暂无已创建的标签" : existingNames.joined(separator: "、"),
            ]
        )
        let request = makeRequest(
            credentials: credentials,
            messages: [
                OpenAIChatMessage(role: "system", content: prompt.system),
                OpenAIChatMessage(role: "user", content: userPrompt),
            ],
            responseFormat: .jsonObject,
            isStreaming: false,
            frequencyPenalty: 0,
            presencePenalty: 0,
            temperature: 0.7,
            topP: 0.9
        )
        let response = try await client.completion(request)
        try Task.checkCancellation()
        return try parseAutoTagResponse(response, existingTagNames: Set(existingNames))
    }

    /// 创建缺失标签并与书摘现有标签取并集；关系替换复用 NoteRepository 的硬删除事务语义。
    func applyAutoTags(noteID: Int64, suggestions: [AIAutoTagSuggestion]) async throws {
        let selectedNames = Self.uniqueNormalizedNames(
            suggestions.filter(\.isSelected).map(\.name)
        )
        guard !selectedNames.isEmpty else {
            throw AIRepositoryError.noTagsSelected
        }

        var snapshot = try await noteRepository.fetchNoteReviewTagEditSnapshot(noteID: noteID)
        var availableByName = Dictionary(
            uniqueKeysWithValues: snapshot.availableTags.map { ($0.title, $0) }
        )
        var tagsToApply: [NoteEditorTagOption] = []

        for name in selectedNames {
            try Task.checkCancellation()
            if let existing = availableByName[name] {
                tagsToApply.append(existing)
                continue
            }
            do {
                let created = try await noteRepository.createNoteTag(named: name)
                availableByName[name] = created
                tagsToApply.append(created)
            } catch {
                // 处理另一入口并发创建同名标签：重新读取真实快照，命中后继续，否则保留原错误。
                snapshot = try await noteRepository.fetchNoteReviewTagEditSnapshot(noteID: noteID)
                availableByName = Dictionary(
                    uniqueKeysWithValues: snapshot.availableTags.map { ($0.title, $0) }
                )
                guard let racedTag = availableByName[name] else { throw error }
                tagsToApply.append(racedTag)
            }
        }

        var seen = Set<Int64>()
        let finalTags = (snapshot.selectedTags + tagsToApply).filter { seen.insert($0.id).inserted }
        try Task.checkCancellation()
        _ = try await noteRepository.replaceNoteReviewTags(noteID: noteID, tags: finalTags)
    }

    /// 在单一写事务中读取最新想法并追加 AI HTML 块，避免覆盖 AI 生成期间发生的正文编辑。
    func appendExplanationToIdea(noteID: Int64, explanation: String) async throws {
        let normalized = explanation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw AIRepositoryError.emptyResponse }
        try await databaseManager.database.dbPool.write { db in
            // SQL 目的：读取追加动作发生时书摘的最新想法，避免使用 AI 请求启动时的陈旧快照覆盖用户编辑。
            // 涉及表：note。
            // 关键过滤：按 note.id 精确命中并排除 is_deleted=1。
            // 时间字段：读取不转换时间；后续 UPDATE 写入本地当前 Android 毫秒时间戳。
            // 返回字段用途：在同一事务中构造“原想法 + AI 解读”HTML。
            let readSQL = """
                SELECT idea
                FROM note
                WHERE id = ? AND is_deleted = 0
                LIMIT 1
                """
            guard let currentIdea = try String.fetchOne(db, sql: readSQL, arguments: [noteID]) else {
                throw AIRepositoryError.noteNotFound
            }

            let aiBlock = Self.aiExplanationHTML(normalized)
            let updatedIdea = currentIdea.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? aiBlock
                : "\(currentIdea)\n\(aiBlock)"
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            // SQL 目的：把明确确认的 AI 解读追加到书摘想法，并刷新更新时间。
            // 涉及表：note。
            // 关键过滤：按同一 note.id 精确更新且再次排除 is_deleted=1，防止事务期间写入失效记录。
            // 时间字段：updated_date 使用本地当前 Android 毫秒时间戳，不做时区换算。
            // 副作用：只更新 idea/updated_date，不改正文、标签、章节或附图。
            let updateSQL = """
                UPDATE note
                SET idea = ?, updated_date = ?
                WHERE id = ? AND is_deleted = 0
                """
            try db.execute(sql: updateSQL, arguments: [updatedIdea, now, noteID])
            guard db.changesCount > 0 else { throw AIRepositoryError.noteNotFound }
        }
    }
}

private extension AIRepository {
    nonisolated struct RequestCredentials {
        let configuration: AIConfiguration
        let apiKey: String
    }

    nonisolated struct NoteContext {
        let contentText: String
        let ideaText: String
        let bookTitle: String
        let bookAuthor: String
        let chapterTitle: String
    }

    nonisolated struct AutoTagEnvelope: Decodable {
        nonisolated struct Tag: Decodable {
            let name: String
            let isExisting: Bool?
            let reason: String?
        }

        let tags: [Tag]
    }

    func validate(_ configuration: AIConfiguration) throws {
        let selectedModel = configuration.selectedModelID
        guard configuration.provider.modelOptions.contains(where: { $0.id == selectedModel }) else {
            throw AIRepositoryError.invalidConfiguration("请选择当前供应商支持的模型。")
        }
        for kind in AIPromptKind.allCases {
            let prompt = configuration.prompts.template(for: kind)
            guard !prompt.system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !prompt.user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AIRepositoryError.invalidConfiguration("\(kind.title) Prompt 不能为空。")
            }
        }
    }

    func requestCredentials() async throws -> RequestCredentials {
        let snapshot = try await configurationStore.fetchSnapshot()
        let configuration = snapshot.configuration.normalized
        try validate(configuration)
        guard configuration.isEnabled else { throw AIRepositoryError.disabled }
        guard let apiKey = try await configurationStore.credential(for: configuration.provider),
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIRepositoryError.missingAPIKey(configuration.provider)
        }
        return RequestCredentials(configuration: configuration, apiKey: apiKey)
    }

    func makeRequest(
        credentials: RequestCredentials,
        messages: [OpenAIChatMessage],
        responseFormat: OpenAICompletionRequest.ResponseFormat,
        isStreaming: Bool,
        frequencyPenalty: Double,
        presencePenalty: Double,
        temperature: Double,
        topP: Double
    ) -> OpenAICompletionRequest {
        OpenAICompletionRequest(
            baseURLString: credentials.configuration.provider.baseURLString,
            apiKey: credentials.apiKey,
            modelID: credentials.configuration.selectedModelID,
            messages: messages,
            responseFormat: responseFormat,
            isStreaming: isStreaming,
            frequencyPenalty: frequencyPenalty,
            presencePenalty: presencePenalty,
            temperature: temperature,
            topP: topP
        )
    }

    func fetchNoteContext(noteID: Int64) async throws -> NoteContext {
        try await databaseManager.database.dbPool.read { db in
            // SQL 目的：读取书摘 AI 解读/自动标签所需的正文、想法、书籍、作者和章节路径。
            // 涉及表：note LEFT JOIN book/chapter；书籍或章节缺失时保留书摘并回退为空上下文。
            // 关键过滤：按 note.id 精确命中，排除 note.is_deleted=1；关联对象仅接收有效记录。
            // 时间字段：本查询不读取或转换时间字段。
            // 返回字段用途：正文/想法转纯文本后进入 Prompt，source_path 优先作为 Android 对齐章节展示路径。
            let sql = """
                SELECT n.content,
                       n.idea,
                       COALESCE(b.name, '') AS book_name,
                       COALESCE(b.author, '') AS book_author,
                       COALESCE(NULLIF(c.source_path, ''), c.title, '') AS chapter_title
                FROM note n
                LEFT JOIN book b ON b.id = n.book_id AND b.is_deleted = 0
                LEFT JOIN chapter c ON c.id = n.chapter_id AND c.is_deleted = 0
                WHERE n.id = ? AND n.is_deleted = 0
                LIMIT 1
                """
            guard let row = try Row.fetchOne(db, sql: sql, arguments: [noteID]) else {
                throw AIRepositoryError.noteNotFound
            }
            return NoteContext(
                contentText: Self.plainText(row["content"] ?? ""),
                ideaText: Self.plainText(row["idea"] ?? ""),
                bookTitle: row["book_name"] ?? "",
                bookAuthor: row["book_author"] ?? "",
                chapterTitle: row["chapter_title"] ?? ""
            )
        }
    }

    func parseAutoTagResponse(
        _ response: String,
        existingTagNames: Set<String>
    ) throws -> [AIAutoTagSuggestion] {
        let json = Self.extractedJSONObject(from: response)
        guard let data = json.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(AutoTagEnvelope.self, from: data) else {
            throw AIRepositoryError.invalidAutoTagResponse
        }
        var seen = Set<String>()
        let normalizedTags = envelope.tags.compactMap { tag -> (String, String)? in
            let name = tag.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 100, seen.insert(name).inserted else { return nil }
            let reason = tag.reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (name, reason)
        }
        return normalizedTags.prefix(3).enumerated().map { index, tag in
            AIAutoTagSuggestion(
                name: tag.0,
                isExisting: existingTagNames.contains(tag.0),
                reason: tag.1,
                isSelected: index == 0
            )
        }
    }

    nonisolated static func render(_ template: String, replacements: [String: String]) -> String {
        replacements.reduce(template) { result, replacement in
            result.replacingOccurrences(of: replacement.key, with: replacement.value)
        }
    }

    nonisolated static func plainText(_ html: String) -> String {
        RichTextPlainTextExtractor
            .plainText(from: html)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func uniqueNormalizedNames(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.compactMap { value in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }

    nonisolated static func extractedJSONObject(from response: String) -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.firstIndex(of: "{"),
              let last = trimmed.lastIndex(of: "}"),
              first <= last else {
            return trimmed
        }
        return String(trimmed[first...last])
    }

    nonisolated static func aiExplanationHTML(_ explanation: String) -> String {
        let escaped = explanation
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
            .replacingOccurrences(of: "\n", with: "<br>")
        return "<p>🔮 \(escaped)</p>"
    }
}
