/**
 * [INPUT]: 依赖 AIRepositoryProtocol 执行流式释义/书摘解读、自动标签建议及确认写回
 * [OUTPUT]: 对外提供 AITextResultRequest、AITextResultViewModel 与 AIAutoTagViewModel，驱动 Content 业务 Sheet
 * [POS]: ViewModels/Content 的 AI 交互状态层，被 viewer、书评详情与相关内容详情复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// AI 文本结果请求，锁定触发时业务主键或选中文本上下文，避免横向翻页后串用数据。
nonisolated enum AITextResultRequest: Equatable, Sendable {
    case noteExplanation(noteID: Int64, bookTitle: String)
    case textLookup(AITextLookupInput)

    var navigationTitle: String {
        switch self {
        case .noteExplanation:
            "AI 解读"
        case .textLookup:
            "AI 释义"
        }
    }

    var contextTitle: String {
        switch self {
        case .noteExplanation(_, let bookTitle):
            bookTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "当前书摘" : bookTitle
        case .textLookup(let input):
            "“\(input.queryText)”"
        }
    }

    var noteIDForAppending: Int64? {
        guard case .noteExplanation(let noteID, _) = self else { return nil }
        return noteID
    }
}

/// 可由 `.sheet(item:)` 使用的稳定 AI 文本结果会话。
nonisolated struct AITextResultPresentation: Identifiable, Equatable, Sendable {
    let id = UUID()
    let request: AITextResultRequest
}

/// 可由 `.sheet(item:)` 使用的稳定自动标签会话。
nonisolated struct AIAutoTagPresentation: Identifiable, Equatable, Sendable {
    let id = UUID()
    let noteID: Int64
    let bookTitle: String
}

@MainActor
@Observable
/// 流式 AI 文本结果状态源；生成任务由对象持有，关闭 Sheet 会显式取消底层 URLSession 流。
final class AITextResultViewModel {
    let request: AITextResultRequest

    var content = ""
    var modelDescription = ""
    var isGenerating = false
    var isAppending = false
    var errorMessage: String?

    private let repository: any AIRepositoryProtocol
    private var generationTask: Task<Void, Never>?

    /// 注入稳定请求与 AI 仓储；初始化不发起网络，便于 Sheet 完成呈现后再加载。
    init(request: AITextResultRequest, repository: any AIRepositoryProtocol) {
        self.request = request
        self.repository = repository
    }

    isolated deinit {
        generationTask?.cancel()
    }

    var canAppendToIdea: Bool {
        request.noteIDForAppending != nil
            && !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isGenerating
            && !isAppending
    }

    /// 启动或重试流式生成；新任务先取消旧任务，网络流结束后才发布最终状态。
    func startGeneration() {
        generationTask?.cancel()
        content = ""
        errorMessage = nil
        isGenerating = true

        let repository = repository
        let request = request
        generationTask = Task { [weak self] in
            do {
                let snapshot = try await repository.fetchConfiguration()
                try Task.checkCancellation()
                self?.modelDescription = "\(snapshot.configuration.provider.displayName) · \(snapshot.configuration.selectedModelID)"

                let stream: AsyncThrowingStream<String, Error>
                switch request {
                case .noteExplanation(let noteID, _):
                    stream = repository.streamNoteExplanation(noteID: noteID)
                case .textLookup(let input):
                    stream = repository.streamTextLookup(input: input)
                }

                for try await accumulated in stream {
                    try Task.checkCancellation()
                    self?.content = accumulated
                }
                guard !Task.isCancelled else { return }
                self?.isGenerating = false
                self?.generationTask = nil
            } catch is CancellationError {
                self?.isGenerating = false
                self?.generationTask = nil
            } catch {
                guard !Task.isCancelled else { return }
                self?.isGenerating = false
                self?.generationTask = nil
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    /// 取消当前生成；AsyncThrowingStream 终止回调会继续向下取消 URLSession 读取。
    func cancelGeneration() {
        generationTask?.cancel()
        generationTask = nil
        isGenerating = false
    }

    /// 把书摘解读原子追加到最新想法；选词释义请求不开放此写入动作。
    @discardableResult
    func appendToIdea() async -> Bool {
        guard let noteID = request.noteIDForAppending, canAppendToIdea else { return false }
        isAppending = true
        defer { isAppending = false }
        do {
            try await repository.appendExplanationToIdea(noteID: noteID, explanation: content)
            try Task.checkCancellation()
            return true
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

@MainActor
@Observable
/// 自动标签状态源，负责建议加载、用户选择与确认写入；页面只消费业务状态，不接触数据库。
final class AIAutoTagViewModel {
    let noteID: Int64
    let bookTitle: String

    var suggestions: [AIAutoTagSuggestion] = []
    var isLoading = false
    var isApplying = false
    var errorMessage: String?

    private let repository: any AIRepositoryProtocol
    private var suggestionTask: Task<Void, Never>?

    /// 注入书摘主键与 AI 仓储；建议在 Sheet 呈现后加载，避免未展示页面占用请求。
    init(noteID: Int64, bookTitle: String, repository: any AIRepositoryProtocol) {
        self.noteID = noteID
        self.bookTitle = bookTitle
        self.repository = repository
    }

    isolated deinit {
        suggestionTask?.cancel()
    }

    var hasSelectedSuggestion: Bool {
        suggestions.contains(where: \.isSelected)
    }

    /// 启动或重试标签建议；新任务取消旧任务并丢弃其迟到结果。
    func startLoading() {
        suggestionTask?.cancel()
        suggestions = []
        errorMessage = nil
        isLoading = true
        let repository = repository
        let noteID = noteID
        suggestionTask = Task { [weak self] in
            do {
                let suggestions = try await repository.suggestTags(noteID: noteID)
                try Task.checkCancellation()
                self?.suggestions = suggestions
                self?.isLoading = false
                self?.suggestionTask = nil
            } catch is CancellationError {
                self?.isLoading = false
                self?.suggestionTask = nil
            } catch {
                guard !Task.isCancelled else { return }
                self?.isLoading = false
                self?.suggestionTask = nil
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    /// 切换单个候选选择态，使用稳定 UUID 避免列表重排误操作。
    func toggleSuggestion(id: UUID) {
        guard let index = suggestions.firstIndex(where: { $0.id == id }) else { return }
        suggestions[index].isSelected.toggle()
    }

    /// 将已选建议提交给仓储；仓储负责创建缺失标签并与书摘现有标签取并集。
    @discardableResult
    func applySelectedSuggestions() async -> Bool {
        guard !isApplying, hasSelectedSuggestion else { return false }
        isApplying = true
        defer { isApplying = false }
        do {
            try await repository.applyAutoTags(noteID: noteID, suggestions: suggestions)
            try Task.checkCancellation()
            return true
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// 关闭 Sheet 时取消尚未结束的建议请求。
    func cancelLoading() {
        suggestionTask?.cancel()
        suggestionTask = nil
        isLoading = false
    }
}
