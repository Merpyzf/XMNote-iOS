/**
 * [INPUT]: 依赖 AIRepositoryProtocol、提示词试运行书摘/流式事件与当前提示词模板快照
 * [OUTPUT]: 对外提供 AIPromptTrialSessionViewModel 与分目标生成阶段，统一维护一次测试 Sheet 会话的输入、结果和取消边界
 * [POS]: ViewModels/Personal 的提示词试运行会话状态源，被准备页与 Push 结果页共同消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 单个提示词目标的试运行阶段；失败保留已生成 Markdown，供界面继续展示可信的部分结果。
nonisolated enum AIPromptTrialPhase: Equatable, Sendable {
    case idle
    case connecting
    case streaming(String)
    case completed(String)
    case failed(message: String, partialContent: String)

    var content: String {
        switch self {
        case .streaming(let content), .completed(let content):
            content
        case .failed(_, let partialContent):
            partialContent
        case .idle, .connecting:
            ""
        }
    }

    var isStreaming: Bool {
        if case .streaming = self { return true }
        return false
    }

    var hasStarted: Bool {
        if case .idle = self { return false }
        return true
    }
}

/// 一次提示词测试 Sheet 的共享状态源；输入页与结果页共用同一实例，Push/Pop 不改变网络任务生命周期。
@MainActor
@Observable
final class AIPromptTrialSessionViewModel {
    let kind: AIPromptKind
    let template: AIPromptTemplate

    var excerpt: AIPromptTrialExcerpt
    var excerptText: String {
        didSet {
            guard excerptText != oldValue else { return }
            selectedQuery = nil
            invalidateResultsForInputChange()
        }
    }
    private(set) var selectedQuery: String?
    var selectedResultTarget = AIPromptTrialTarget.current

    private(set) var phases: [AIPromptTrialTarget: AIPromptTrialPhase] = [
        .current: .idle,
        .appDefault: .idle,
    ]
    private(set) var isRunning = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let repository: any AIRepositoryProtocol
    @ObservationIgnored private var activeRequestID: UUID?
    @ObservationIgnored private var generationTask: Task<Void, Never>?

    /// 使用打开 Sheet 时的提示词快照创建隔离会话；默认书摘只存在于当前会话，不写入本地数据。
    init(
        kind: AIPromptKind,
        template: AIPromptTemplate,
        repository: any AIRepositoryProtocol
    ) {
        self.kind = kind
        self.template = template
        self.repository = repository
        excerpt = .hundredYearsOfSolitude
        excerptText = AIPromptTrialExcerpt.hundredYearsOfSolitude.originalText
    }

    isolated deinit {
        generationTask?.cancel()
    }

    var comparesDefault: Bool {
        template != AIPromptConfiguration.androidAlignedDefault.template(for: kind)
    }

    var hasStarted: Bool {
        errorMessage != nil || phases.values.contains(where: \.hasStarted)
    }

    var canStart: Bool {
        guard !isRunning,
              !excerptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return kind != .wordLookup || selectedQuery != nil
    }

    var startDisabledReason: String? {
        if excerptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "请先输入测试书摘"
        }
        if kind == .wordLookup, selectedQuery == nil {
            return "请在书摘中选中要查询的文字"
        }
        return nil
    }

    /// 选择本地书摘后替换当前快照并让旧结果失效；运行期间界面已锁定，方法仍做防御性阻断。
    func selectExcerpt(_ note: NoteExcerptListItem) {
        guard !isRunning else { return }
        let selectedExcerpt = AIPromptTrialExcerpt(note: note)
        excerpt = selectedExcerpt
        excerptText = selectedExcerpt.originalText
        selectedQuery = nil
        invalidateResultsForInputChange()
    }

    /// 更新 AI 查词的有效连续选区；只有真正改变请求变量时才使旧结果失效。
    func updateSelectedQuery(_ query: String?) {
        guard selectedQuery != query else { return }
        selectedQuery = query
        invalidateResultsForInputChange()
    }

    /// 启动新一轮流式生成；先使旧请求身份失效并取消消费任务，迟到事件无法覆盖新会话状态。
    @discardableResult
    func start() -> Bool {
        guard canStart else { return false }
        invalidateActiveRequest()

        let requestID = UUID()
        let sample = excerpt.sampleContext(
            for: kind,
            editedText: excerptText,
            selectedQuery: selectedQuery
        )
        let shouldCompareDefault = comparesDefault

        activeRequestID = requestID
        selectedResultTarget = .current
        errorMessage = nil
        isRunning = true
        phases = [
            .current: .connecting,
            .appDefault: shouldCompareDefault ? .connecting : .idle,
        ]

        generationTask = Task { @MainActor [weak self] in
            await self?.consumeStream(
                requestID: requestID,
                sample: sample,
                comparesDefault: shouldCompareDefault
            )
        }
        return true
    }

    /// 返回指定目标阶段，避免页面直接处理字典缺值。
    func phase(for target: AIPromptTrialTarget) -> AIPromptTrialPhase {
        phases[target] ?? .idle
    }

    /// 整个 Sheet 离场时统一取消网络并丢弃会话结果；取消会经 AsyncStream termination 传播到底层 SSE。
    func cancelAndDiscard() {
        invalidateActiveRequest()
        phases = [.current: .idle, .appDefault: .idle]
        errorMessage = nil
        selectedResultTarget = .current
    }

    /// 消费仓储流时同时校验 Task 取消和请求身份；Push/Pop 不调用本方法的取消路径。
    private func consumeStream(
        requestID: UUID,
        sample: AIPromptSampleContext,
        comparesDefault: Bool
    ) async {
        defer {
            if activeRequestID == requestID {
                activeRequestID = nil
                generationTask = nil
                isRunning = false
            }
        }

        do {
            let stream = repository.streamPromptTrial(
                kind: kind,
                template: template,
                sample: sample,
                comparesDefault: comparesDefault
            )
            for try await event in stream {
                try Task.checkCancellation()
                guard activeRequestID == requestID else { return }
                apply(event)
            }
        } catch is CancellationError {
            return
        } catch {
            guard activeRequestID == requestID else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// 输入由非 UI 路径意外改动时也先取消活动生成，确保结果与当前书摘始终属于同一快照。
    private func invalidateResultsForInputChange() {
        invalidateActiveRequest()
        phases = [.current: .idle, .appDefault: .idle]
        errorMessage = nil
        selectedResultTarget = .current
    }

    /// 先清空身份再取消 Task，避免取消竞态中的最后一个事件回写会话。
    private func invalidateActiveRequest() {
        activeRequestID = nil
        generationTask?.cancel()
        generationTask = nil
        isRunning = false
    }

    /// 将分目标事件归并到累计阶段；完成或失败都保留此前已发布的 Markdown。
    private func apply(_ event: AIPromptTrialEvent) {
        switch event {
        case .content(let target, let markdown):
            phases[target] = .streaming(markdown)
        case .completed(let target):
            let content = phase(for: target).content
            if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                phases[target] = .failed(
                    message: AIRepositoryError.emptyResponse.localizedDescription,
                    partialContent: ""
                )
            } else {
                phases[target] = .completed(content)
            }
        case .failed(let target, let error):
            phases[target] = .failed(
                message: error.localizedDescription,
                partialContent: phase(for: target).content
            )
        }
    }
}
