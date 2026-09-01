/**
 * [INPUT]: 依赖 DatabaseManager 读取书摘上下文，依赖 NoteRepositoryProtocol/AIConfigurationStore/OpenAICompatibleClient 管理标签、凭据与请求
 * [OUTPUT]: 对外提供 AIRepository，实现配置、单任务 Prompt 原子保存、统一请求预览/流式试运行/优化、流式释义/AI 标签及标签写回
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

    /// 校验模型、Prompt 与启用态凭据后保存配置，空密钥输入保留当前供应商已有值。
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

    /// 校验 System/User 组合后只持久化当前任务，设置页中的其他未保存草稿不会参与本次写入。
    func savePromptTemplate(_ template: AIPromptTemplate, for kind: AIPromptKind) async throws {
        if let issue = AIPromptValidator.blockingIssue(in: template, kind: kind) {
            throw AIRepositoryError.invalidConfiguration("\(kind.title)：\(issue.message)")
        }
        try await configurationStore.savePromptTemplate(template, for: kind)
    }

    /// 使用正式请求构建器生成离线预览，确保应用固定规则与变量替换不存在第二套逻辑。
    func makePromptPreview(
        kind: AIPromptKind,
        template: AIPromptTemplate,
        sample: AIPromptSampleContext
    ) throws -> AIPromptRequestPreview {
        try AIPromptRequestBuilder.preview(
            kind: kind,
            template: template,
            replacements: sample.replacements
        )
    }

    /// 使用生产请求参数流式试运行草稿；对照模式共享上下文并发执行，单侧失败不取消另一侧。
    func streamPromptTrial(
        kind: AIPromptKind,
        template: AIPromptTemplate,
        sample: AIPromptSampleContext,
        comparesDefault: Bool
    ) -> AsyncThrowingStream<AIPromptTrialEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let credentials = try await requestCredentials()
                    try Task.checkCancellation()

                    let currentPreview = try makePromptPreview(
                        kind: kind,
                        template: template,
                        sample: sample
                    )
                    var requests: [(AIPromptTrialTarget, OpenAICompletionRequest)] = [
                        (
                            .current,
                            makeBusinessRequest(
                                credentials: credentials,
                                preview: currentPreview,
                                isStreaming: true
                            )
                        ),
                    ]
                    if comparesDefault {
                        let defaultPreview = try makePromptPreview(
                            kind: kind,
                            template: AIPromptConfiguration.androidAlignedDefault.template(for: kind),
                            sample: sample
                        )
                        requests.append(
                            (
                                .appDefault,
                                makeBusinessRequest(
                                    credentials: credentials,
                                    preview: defaultPreview,
                                    isStreaming: true
                                )
                            )
                        )
                    }

                    let client = client
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        for (target, request) in requests {
                            group.addTask {
                                do {
                                    for try await markdown in client.streamCompletion(request) {
                                        try Task.checkCancellation()
                                        continuation.yield(.content(target: target, markdown: markdown))
                                    }
                                    try Task.checkCancellation()
                                    continuation.yield(.completed(target: target))
                                } catch is CancellationError {
                                    throw CancellationError()
                                } catch {
                                    continuation.yield(
                                        .failed(
                                            target: target,
                                            error: Self.trialError(from: error)
                                        )
                                    )
                                }
                            }
                        }
                        try await group.waitForAll()
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

    /// 只把当前字段和用户期望交给模型，要求原样保留受控变量并返回可直接比较的纯文本建议。
    func optimizePrompt(
        kind: AIPromptKind,
        field: AIPromptEditorField,
        currentText: String,
        instruction: String
    ) async throws -> String {
        let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInstruction.isEmpty else {
            throw AIRepositoryError.invalidConfiguration("请先说明希望怎样调整")
        }
        let credentials = try await requestCredentials()
        try Task.checkCancellation()
        let allowedVariables = AIPromptVariableCatalog.definitions(for: kind)
            .map(\.placeholder)
            .joined(separator: "、")
        let messages = [
            OpenAIChatMessage(
                role: "system",
                content: """
                你是提示词编辑助手。只优化用户提供的一个提示词字段。
                保持原意和必要约束，删除重复表达，不添加解释、标题或代码围栏。
                若文本包含 `${变量}`，必须原样保留；不得发明白名单之外的变量。
                只返回优化后的完整字段文本。
                """
            ),
            OpenAIChatMessage(
                role: "user",
                content: """
                任务：\(kind.title)
                字段：\(field.technicalTitle)
                允许的变量：\(allowedVariables.isEmpty ? "无" : allowedVariables)
                调整期望：\(trimmedInstruction)

                当前文本：
                \(currentText)
                """
            ),
        ]
        let request = makeRequest(
            credentials: credentials,
            messages: messages,
            responseFormat: .text,
            isStreaming: false,
            frequencyPenalty: 0.1,
            presencePenalty: 0,
            temperature: 0.4,
            topP: 0.9
        )
        try Task.checkCancellation()
        return try await client.completion(request)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
                    let preview = try AIPromptRequestBuilder.preview(
                        kind: .noteExplanation,
                        template: credentials.configuration.prompts.noteExplanation,
                        replacements: [
                            "摘录": note.contentText,
                            "想法": note.ideaText,
                            "章节": note.chapterTitle,
                            "书籍名": note.bookTitle,
                            "作者名": note.bookAuthor,
                        ]
                    )
                    let request = makeBusinessRequest(
                        credentials: credentials,
                        preview: preview,
                        isStreaming: true
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
                        throw AIRepositoryError.invalidConfiguration("请先选择需要释义的文字")
                    }
                    let credentials = try await requestCredentials()
                    let preview = try AIPromptRequestBuilder.preview(
                        kind: .wordLookup,
                        template: credentials.configuration.prompts.wordLookup,
                        replacements: [
                            "查询文本": query,
                            "上下文": input.queryContext,
                            "书籍名": input.bookTitle,
                        ]
                    )
                    let request = makeBusinessRequest(
                        credentials: credentials,
                        preview: preview,
                        isStreaming: true
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

    /// 生成 AI 标签累计内容，并仅在 SSE 完成后解析 JSON、去重和校准已有标签状态。
    func streamTagSuggestions(
        noteID: Int64
    ) -> AsyncThrowingStream<AIAutoTagGenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    async let noteContext = fetchNoteContext(noteID: noteID)
                    async let tagOptions = noteRepository.fetchNoteReviewTagOptions()
                    let (note, tags) = try await (noteContext, tagOptions)
                    try Task.checkCancellation()

                    let credentials = try await requestCredentials()
                    let existingNames = tags.map(\.title)
                    let preview = try AIPromptRequestBuilder.preview(
                        kind: .autoTag,
                        template: credentials.configuration.prompts.autoTag,
                        replacements: [
                            "书摘内容": note.contentText,
                            "书籍名": note.bookTitle,
                            "作者名": note.bookAuthor,
                            "章节": note.chapterTitle,
                            "已有标签": existingNames.isEmpty
                                ? "暂无已创建的标签"
                                : existingNames.joined(separator: "、"),
                        ]
                    )
                    let request = makeBusinessRequest(
                        credentials: credentials,
                        preview: preview,
                        isStreaming: true
                    )

                    var finalContent = ""
                    for try await accumulated in client.streamCompletion(request) {
                        try Task.checkCancellation()
                        guard accumulated != finalContent else { continue }
                        finalContent = accumulated
                        continuation.yield(.content(accumulated))
                    }
                    try Task.checkCancellation()
                    let suggestions = try parseAutoTagResponse(
                        finalContent,
                        existingTagNames: Set(existingNames)
                    )
                    continuation.yield(.completed(suggestions))
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

    /// 创建缺失标签并与书摘现有标签取并集；关系替换复用 NoteRepository 的完整关系集事务语义。
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
            throw AIRepositoryError.invalidConfiguration("请选择当前供应商支持的模型")
        }
        for kind in AIPromptKind.allCases {
            let prompt = configuration.prompts.template(for: kind)
            if let issue = AIPromptValidator.blockingIssue(in: prompt, kind: kind) {
                throw AIRepositoryError.invalidConfiguration("\(kind.title)：\(issue.message)")
            }
        }
    }

    func requestCredentials() async throws -> RequestCredentials {
        let snapshot = try await configurationStore.fetchSnapshot()
        try Task.checkCancellation()
        let configuration = snapshot.configuration.normalized
        try validate(configuration)
        guard configuration.isEnabled else { throw AIRepositoryError.disabled }
        let apiKey = try await configurationStore.credential(for: configuration.provider)
        try Task.checkCancellation()
        guard let apiKey,
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
            thinkingMode: credentials.configuration.provider == .deepSeek ? .disabled : nil,
            responseFormat: responseFormat,
            isStreaming: isStreaming,
            frequencyPenalty: frequencyPenalty,
            presencePenalty: presencePenalty,
            temperature: temperature,
            topP: topP
        )
    }

    /// 把统一预览转换为生产请求；每类任务只在这里选择生成参数与 response format。
    func makeBusinessRequest(
        credentials: RequestCredentials,
        preview: AIPromptRequestPreview,
        isStreaming: Bool
    ) -> OpenAICompletionRequest {
        let messages = [
            OpenAIChatMessage(role: "system", content: preview.systemPrompt),
            OpenAIChatMessage(role: "user", content: preview.userPrompt),
        ]
        switch preview.kind {
        case .noteExplanation, .wordLookup:
            return makeRequest(
                credentials: credentials,
                messages: messages,
                responseFormat: .text,
                isStreaming: isStreaming,
                frequencyPenalty: 0.2,
                presencePenalty: 0.3,
                temperature: 0.85,
                topP: 0.95
            )
        case .autoTag:
            return makeRequest(
                credentials: credentials,
                messages: messages,
                responseFormat: .jsonObject,
                isStreaming: isStreaming,
                frequencyPenalty: 0,
                presencePenalty: 0,
                temperature: 0.7,
                topP: 0.9
            )
        }
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

    /// 把意外的底层错误收敛为仓储错误，确保单侧失败事件保持 Sendable 且具备用户可读说明。
    nonisolated static func trialError(from error: Error) -> AIRepositoryError {
        if let repositoryError = error as? AIRepositoryError {
            return repositoryError
        }
        return .network(error.localizedDescription)
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

}
