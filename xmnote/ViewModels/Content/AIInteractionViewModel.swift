/**
 * [INPUT]: 依赖 AIRepositoryProtocol 执行流式释义/AI 标签及标签确认写回，依赖 AIMarkdownPlainTextConverter 准备编辑器想法草稿
 * [OUTPUT]: 对外提供 AITextResultRequest、AIExplanationIdeaEditRequest、AITextResultViewModel 与分阶段 AIAutoTagViewModel，驱动 Content 业务 Sheet、编辑器交接、模型切换与生成完成态
 * [POS]: ViewModels/Content 的 AI 交互状态层，被 viewer、书评详情与相关内容详情复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// AI 文本结果请求，锁定触发时业务主键或选中文本上下文，避免横向翻页后串用数据。
nonisolated enum AITextResultRequest: Equatable, Sendable {
    case noteExplanation(noteID: Int64, bookTitle: String)
    case textLookup(AITextLookupInput)

    var noteIDForIdeaEditor: Int64? {
        guard case .noteExplanation(let noteID, _) = self else { return nil }
        return noteID
    }
}

/// 可由 `.sheet(item:)` 使用的稳定 AI 文本结果会话。
nonisolated struct AITextResultPresentation: Identifiable, Equatable, Sendable {
    let id = UUID()
    let request: AITextResultRequest
}

/// AI Sheet 退场后交给来源页的一次性编辑请求，只携带目标书摘与已转换的可见纯文本。
nonisolated struct AIExplanationIdeaEditRequest: Equatable, Sendable {
    let noteID: Int64
    let explanationText: String
}

/// 可由 `.sheet(item:)` 使用的稳定自动标签会话。
nonisolated struct AIAutoTagPresentation: Identifiable, Equatable, Sendable {
    let id = UUID()
    let noteID: Int64
    let bookTitle: String
}

@MainActor
@Observable
/// 流式 AI 文本结果状态源；统一持有配置、模型切换和生成任务，并用 revision 隔离已取消流的迟到结果。
final class AITextResultViewModel {
    let request: AITextResultRequest

    var content = ""
    var isGenerating = false
    var isSwitchingModel = false
    var hasCompletedSuccessfully = false
    var isPreparingIdeaEditor = false
    var errorMessage: String?
    var modelSwitchErrorMessage: String?
    private(set) var configuration: AIConfiguration?
    private(set) var providersWithStoredKey = Set<AIProvider>()
    private(set) var generationRevision = 0

    private let repository: any AIRepositoryProtocol
    private var generationTask: Task<Void, Never>?
    private var modelSwitchTask: Task<Void, Never>?

    /// 注入稳定请求与 AI 仓储；初始化不发起网络，便于 Sheet 完成呈现后再加载。
    init(request: AITextResultRequest, repository: any AIRepositoryProtocol) {
        self.request = request
        self.repository = repository
    }

    isolated deinit {
        generationTask?.cancel()
        modelSwitchTask?.cancel()
    }

    var availableProviders: [AIProvider] {
        AIProvider.allCases.filter { providersWithStoredKey.contains($0) }
    }

    var modelDescription: String {
        guard let configuration else { return "" }
        return "\(configuration.provider.displayName) · \(configuration.selectedModelTitle)"
    }

    var canOpenIdeaEditor: Bool {
        request.noteIDForIdeaEditor != nil
            && !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isGenerating
            && !isSwitchingModel
            && hasCompletedSuccessfully
            && !isPreparingIdeaEditor
    }

    var canRetryGeneration: Bool {
        !isGenerating && !isSwitchingModel && !hasCompletedSuccessfully
    }

    /// 判断菜单项是否对应当前持久化配置，供系统菜单显示中性勾选状态。
    func isCurrentModel(provider: AIProvider, modelID: String) -> Bool {
        configuration?.provider == provider && configuration?.selectedModelID == modelID
    }

    /// 启动或重试流式生成；每轮先递增 revision，再取消旧任务，确保取消后的迟到回调无法串写新结果。
    func startGeneration() {
        generationTask?.cancel()
        generationRevision &+= 1
        let revision = generationRevision
        content = ""
        errorMessage = nil
        hasCompletedSuccessfully = false
        isGenerating = true

        let repository = repository
        let request = request
        generationTask = Task { [weak self] in
            do {
                let snapshot = try await repository.fetchConfiguration()
                try Task.checkCancellation()
                guard let self, self.generationRevision == revision else { return }
                self.apply(snapshot)

                let stream: AsyncThrowingStream<String, Error>
                switch request {
                case .noteExplanation(let noteID, _):
                    stream = repository.streamNoteExplanation(noteID: noteID)
                case .textLookup(let input):
                    stream = repository.streamTextLookup(input: input)
                }

                for try await accumulated in stream {
                    try Task.checkCancellation()
                    guard self.generationRevision == revision else { return }
                    self.content = accumulated
                }
                try Task.checkCancellation()
                guard self.generationRevision == revision else { return }
                guard !self.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AIRepositoryError.emptyResponse
                }
                self.isGenerating = false
                self.hasCompletedSuccessfully = true
                self.generationTask = nil
            } catch is CancellationError {
                guard let self, self.generationRevision == revision else { return }
                self.isGenerating = false
                self.generationTask = nil
            } catch {
                guard let self,
                      !Task.isCancelled,
                      self.generationRevision == revision else { return }
                self.isGenerating = false
                self.hasCompletedSuccessfully = false
                self.generationTask = nil
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// 立即取消旧流并保存新供应商/模型；保存成功后清空旧结果并重新生成，失败则恢复原配置与正文。
    func switchModel(provider: AIProvider, modelID: String) {
        guard !isSwitchingModel,
              providersWithStoredKey.contains(provider),
              provider.modelOptions.contains(where: { $0.id == modelID }),
              let originalConfiguration = configuration,
              !isCurrentModel(provider: provider, modelID: modelID) else { return }

        generationTask?.cancel()
        generationTask = nil
        generationRevision &+= 1
        let switchRevision = generationRevision
        isGenerating = false
        isSwitchingModel = true
        modelSwitchErrorMessage = nil

        var updatedConfiguration = originalConfiguration
        updatedConfiguration.provider = provider
        updatedConfiguration.setModelID(modelID, for: provider)

        let repository = repository
        modelSwitchTask?.cancel()
        modelSwitchTask = Task { [weak self] in
            do {
                try await repository.saveConfiguration(updatedConfiguration, apiKey: nil)
                try Task.checkCancellation()
                guard let self, self.generationRevision == switchRevision else { return }
                self.configuration = updatedConfiguration.normalized
                self.isSwitchingModel = false
                self.modelSwitchTask = nil
                self.startGeneration()
            } catch is CancellationError {
                guard let self, self.generationRevision == switchRevision else { return }
                self.configuration = originalConfiguration
                self.isSwitchingModel = false
                self.modelSwitchTask = nil
            } catch {
                guard let self,
                      !Task.isCancelled,
                      self.generationRevision == switchRevision else { return }
                self.configuration = originalConfiguration
                self.isSwitchingModel = false
                self.modelSwitchTask = nil
                self.modelSwitchErrorMessage = "切换模型失败：\(error.localizedDescription)"
            }
        }
    }

    /// 清除页面已消费的模型切换错误，避免 Observation 重绘时重复反馈。
    func consumeModelSwitchError() {
        modelSwitchErrorMessage = nil
    }

    /// 关闭 Sheet 时同时取消生成和模型保存任务；revision 递增后所有迟到回调都只可退出、不可回写。
    func cancelGeneration() {
        generationRevision &+= 1
        generationTask?.cancel()
        generationTask = nil
        modelSwitchTask?.cancel()
        modelSwitchTask = nil
        isGenerating = false
        isSwitchingModel = false
    }

    /// 把完整 Markdown 转为可编辑纯文本并生成一次性交接请求；取消或失败时不触碰数据库。
    func prepareIdeaEditorRequest() async -> AIExplanationIdeaEditRequest? {
        guard let noteID = request.noteIDForIdeaEditor, canOpenIdeaEditor else { return nil }
        isPreparingIdeaEditor = true
        errorMessage = nil
        defer { isPreparingIdeaEditor = false }
        do {
            let plainText = try await AIMarkdownPlainTextConverter.plainText(from: content)
            let normalized = plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { throw AIRepositoryError.emptyResponse }
            try Task.checkCancellation()
            return AIExplanationIdeaEditRequest(
                noteID: noteID,
                explanationText: normalized
            )
        } catch is CancellationError {
            return nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// 接收 Repository 快照并只保留密钥存在状态，明文凭据不会进入页面状态。
    private func apply(_ snapshot: AIConfigurationSnapshot) {
        configuration = snapshot.configuration.normalized
        providersWithStoredKey = snapshot.providersWithStoredKey
    }
}

@MainActor
@Observable
/// AI 标签状态源，负责累计流消费、最终候选选择与确认写入；页面只消费业务阶段，不接触解析或数据库。
final class AIAutoTagViewModel {
    /// 单次 AI 标签会话阶段；流式失败保留最后快照，候选只在 Repository 完成解析后进入 ready。
    enum Phase: Equatable {
        case idle
        case connecting
        case streaming(String)
        case ready([AIAutoTagSuggestion])
        case empty
        case failed(message: String, partialContent: String?)
    }

    /// 供页面绑定结构动画的稳定阶段分类，避免每个流式片段触发整页过渡。
    enum PhaseKind: Equatable {
        case idle
        case connecting
        case streaming
        case ready
        case empty
        case failed
    }

    let noteID: Int64
    let bookTitle: String

    var phase: Phase = .idle
    var isApplying = false
    var applyErrorMessage: String?

    private let repository: any AIRepositoryProtocol
    private var generationTask: Task<Void, Never>?
    private var generationRevision = 0

    /// 注入书摘主键与 AI 仓储；建议在 Sheet 呈现后加载，避免未展示页面占用请求。
    init(noteID: Int64, bookTitle: String, repository: any AIRepositoryProtocol) {
        self.noteID = noteID
        self.bookTitle = bookTitle
        self.repository = repository
    }

    isolated deinit {
        generationTask?.cancel()
    }

    var phaseKind: PhaseKind {
        switch phase {
        case .idle:
            .idle
        case .connecting:
            .connecting
        case .streaming:
            .streaming
        case .ready:
            .ready
        case .empty:
            .empty
        case .failed:
            .failed
        }
    }

    var suggestions: [AIAutoTagSuggestion] {
        guard case .ready(let suggestions) = phase else { return [] }
        return suggestions
    }

    var streamingContent: String {
        switch phase {
        case .streaming(let content):
            content
        case .failed(_, let partialContent):
            partialContent ?? ""
        default:
            ""
        }
    }

    var generationErrorMessage: String? {
        guard case .failed(let message, _) = phase else { return nil }
        return message
    }

    var isGenerating: Bool {
        phaseKind == .connecting || phaseKind == .streaming
    }

    var hasSelectedSuggestion: Bool {
        suggestions.contains(where: \.isSelected)
    }

    /// 启动或重试 AI 标签流；revision 隔离已取消任务，迟到内容和完成事件都不可覆盖新会话。
    func startLoading() {
        generationTask?.cancel()
        generationRevision &+= 1
        let revision = generationRevision
        phase = .connecting
        applyErrorMessage = nil
        let repository = repository
        let noteID = noteID
        generationTask = Task { [weak self] in
            var latestContent = ""
            var didComplete = false
            do {
                for try await event in repository.streamTagSuggestions(noteID: noteID) {
                    try Task.checkCancellation()
                    guard let self, self.generationRevision == revision else { return }
                    switch event {
                    case .content(let content):
                        guard content != latestContent else { continue }
                        latestContent = content
                        self.phase = .streaming(content)
                    case .completed(let suggestions):
                        didComplete = true
                        self.phase = suggestions.isEmpty ? .empty : .ready(suggestions)
                    }
                }
                try Task.checkCancellation()
                guard let self, self.generationRevision == revision else { return }
                guard didComplete else { throw AIRepositoryError.emptyResponse }
                self.generationTask = nil
            } catch is CancellationError {
                guard let self, self.generationRevision == revision else { return }
                self.generationTask = nil
            } catch {
                guard let self,
                      !Task.isCancelled,
                      self.generationRevision == revision else { return }
                let partialContent = latestContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil
                    : latestContent
                self.phase = .failed(
                    message: error.localizedDescription,
                    partialContent: partialContent
                )
                self.generationTask = nil
            }
        }
    }

    /// 切换单个候选选择态，使用稳定 UUID 避免列表重排误操作。
    func toggleSuggestion(id: UUID) {
        guard case .ready(var suggestions) = phase,
              let index = suggestions.firstIndex(where: { $0.id == id }) else { return }
        suggestions[index].isSelected.toggle()
        phase = .ready(suggestions)
        applyErrorMessage = nil
    }

    /// 将已选建议提交给仓储；仓储负责创建缺失标签并与书摘现有标签取并集。
    @discardableResult
    func applySelectedSuggestions() async -> Bool {
        let suggestions = suggestions
        guard !isApplying, suggestions.contains(where: \.isSelected) else { return false }
        isApplying = true
        applyErrorMessage = nil
        defer { isApplying = false }
        do {
            try await repository.applyAutoTags(noteID: noteID, suggestions: suggestions)
            try Task.checkCancellation()
            return true
        } catch is CancellationError {
            return false
        } catch {
            applyErrorMessage = error.localizedDescription
            return false
        }
    }

    /// 关闭 Sheet 时终止当前会话并递增 revision，确保流取消后的任何迟到事件只能退出。
    func cancelLoading() {
        generationRevision &+= 1
        generationTask?.cancel()
        generationTask = nil
        phase = .idle
    }
}
