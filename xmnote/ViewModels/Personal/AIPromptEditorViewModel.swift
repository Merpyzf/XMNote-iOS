/**
 * [INPUT]: 依赖 AIRepositoryProtocol 读取与原子保存单任务 Prompt，生成离线预览并执行显式试运行或字段优化
 * [OUTPUT]: 对外提供 AIPromptEditorViewModel，统一管理双字段草稿、校验、恢复、预览、试运行与优化建议
 * [POS]: ViewModels/Personal 的提示词编辑状态源，被独立 push 编辑页及其三个按需 Sheet 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 提示词编辑状态源；网络任务在调用方结构化 Task 中运行，取消后不回写过期页面状态。
@MainActor
@Observable
final class AIPromptEditorViewModel {
    let kind: AIPromptKind

    var activeField: AIPromptEditorField = .taskTemplate
    var template = AIPromptTemplate(system: "", user: "")
    var isLoading = false
    var isSaving = false
    var errorMessage: String?

    var preview: AIPromptRequestPreview?
    var recentSample: AIPromptSampleContext?
    var isLoadingRecentSample = false

    var trialResult: AIPromptTrialResult?
    var isRunningTrial = false
    var trialErrorMessage: String?

    var optimizationInstruction = ""
    private(set) var optimizationSuggestion: String?
    var isOptimizing = false
    var optimizationErrorMessage: String?

    private var persistedTemplate = AIPromptTemplate(system: "", user: "")
    private var activeTrialRequestID: UUID?
    private var activeOptimizationRequest: OptimizationRequest?
    private var optimizationSuggestionRequest: OptimizationRequest?
    private let repository: any AIRepositoryProtocol

    /// 一次字段优化锁定的输入快照；请求身份阻止已取消或过期结果覆盖新的编辑现场。
    private struct OptimizationRequest {
        let id: UUID
        let field: AIPromptEditorField
        let template: AIPromptTemplate
        let sourceText: String
        let instruction: String
    }

    /// 注入当前任务与仓储；ViewModel 不直接访问 UserDefaults、数据库或网络客户端。
    init(kind: AIPromptKind, repository: any AIRepositoryProtocol) {
        self.kind = kind
        self.repository = repository
    }

    var currentText: String {
        get {
            switch activeField {
            case .taskTemplate:
                template.user
            case .roleRules:
                template.system
            }
        }
        set {
            guard currentText != newValue else { return }
            switch activeField {
            case .taskTemplate:
                template.user = newValue
            case .roleRules:
                template.system = newValue
            }
            preview = nil
            trialResult = nil
            trialErrorMessage = nil
            optimizationSuggestion = nil
            optimizationSuggestionRequest = nil
            optimizationErrorMessage = nil
        }
    }

    var variables: [AIPromptVariableDefinition] {
        AIPromptVariableCatalog.definitions(for: kind)
    }

    var defaultTemplate: AIPromptTemplate {
        AIPromptConfiguration.androidAlignedDefault.template(for: kind)
    }

    var allIssues: [AIPromptValidationIssue] {
        AIPromptValidator.issues(in: template, kind: kind)
    }

    var currentIssues: [AIPromptValidationIssue] {
        AIPromptValidator.issues(in: currentText, field: activeField, kind: kind)
    }

    var hasBlockingIssues: Bool {
        allIssues.contains(where: \.blocksSaving)
    }

    var hasUnsavedChanges: Bool {
        template != persistedTemplate
    }

    var canSave: Bool {
        !isLoading && !isSaving && hasUnsavedChanges && !hasBlockingIssues
    }

    var canRunTrial: Bool {
        !isLoading && !isSaving && !isRunningTrial && !hasBlockingIssues
    }

    var optimizationSourceText: String? {
        optimizationSuggestionRequest?.sourceText
    }

    /// 读取当前持久化组合；任务取消或读取失败时保留当前编辑现场。
    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let snapshot = try await repository.fetchConfiguration()
            try Task.checkCancellation()
            let loaded = snapshot.configuration.prompts.template(for: kind)
            template = loaded
            persistedTemplate = loaded
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "读取失败：\(error.localizedDescription)"
        }
    }

    /// 原子保存发起时的 System/User 快照；保存期间出现的新输入继续保持 dirty，调用方不得自动退出。
    @discardableResult
    func save() async -> Bool {
        guard canSave else { return false }
        let savedSnapshot = template
        isSaving = true
        defer { isSaving = false }
        do {
            try await repository.savePromptTemplate(savedSnapshot, for: kind)
            try Task.checkCancellation()
            persistedTemplate = savedSnapshot
            errorMessage = nil
            return template == savedSnapshot
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = "无法保存，请重试"
            return false
        }
    }

    /// 恢复当前可见字段的产品默认值；只修改草稿，用户保存前不会影响正式配置。
    func resetCurrentField() {
        let defaults = AIPromptConfiguration.androidAlignedDefault.template(for: kind)
        switch activeField {
        case .taskTemplate:
            template.user = defaults.user
        case .roleRules:
            template.system = defaults.system
        }
        clearDerivedResults()
    }

    /// 恢复当前任务的两个字段；只修改草稿，仍需显式保存。
    func resetAllFields() {
        applyDraftTemplate(defaultTemplate)
    }

    /// 原子替换双字段草稿并清理过期派生结果；供整模板撤销与重做共用。
    func applyDraftTemplate(_ template: AIPromptTemplate) {
        guard self.template != template else { return }
        self.template = template
        clearDerivedResults()
    }

    /// 使用内置样例生成不联网的真实消息预览。
    func preparePreview() {
        do {
            preview = try repository.makePromptPreview(
                kind: kind,
                template: template,
                sample: AIPromptRequestBuilder.builtInSample(for: kind)
            )
            errorMessage = nil
        } catch {
            preview = nil
            errorMessage = error.localizedDescription
        }
    }

    /// 按需读取最近书摘样例；不存在或读取失败时仍可继续使用内置样例。
    func loadRecentSample() async {
        guard !isLoadingRecentSample else { return }
        isLoadingRecentSample = true
        defer { isLoadingRecentSample = false }
        do {
            let sample = try await repository.fetchRecentPromptSample(for: kind)
            try Task.checkCancellation()
            recentSample = sample
        } catch is CancellationError {
            return
        } catch {
            trialErrorMessage = "最近书摘读取失败：\(error.localizedDescription)"
        }
    }

    /// 显式执行一次或两次网络请求；取消或新请求会使旧 request ID 失效，旧结果不得回写页面。
    func runTrial(sample: AIPromptSampleContext, comparesDefault: Bool) async {
        guard !isRunningTrial else { return }
        let requestID = UUID()
        let templateSnapshot = template
        activeTrialRequestID = requestID
        isRunningTrial = true
        trialResult = nil
        trialErrorMessage = nil
        defer {
            if activeTrialRequestID == requestID {
                activeTrialRequestID = nil
                isRunningTrial = false
            }
        }
        do {
            let result = try await repository.runPromptTrial(
                kind: kind,
                template: templateSnapshot,
                sample: sample,
                comparesDefault: comparesDefault
            )
            try Task.checkCancellation()
            guard activeTrialRequestID == requestID,
                  template == templateSnapshot else {
                return
            }
            trialResult = result
        } catch is CancellationError {
            return
        } catch {
            guard activeTrialRequestID == requestID else { return }
            trialErrorMessage = error.localizedDescription
        }
    }

    /// 使当前运行请求失效；调用方同时取消其结构化 Task，避免 Sheet 关闭后继续产生网络消耗。
    func cancelTrial() {
        activeTrialRequestID = nil
        isRunningTrial = false
    }

    /// 请求优化发起时锁定字段、双字段草稿和指令；取消、切换或草稿变化后均不接纳旧响应。
    func optimizeCurrentField() async {
        guard !isOptimizing else { return }
        let request = OptimizationRequest(
            id: UUID(),
            field: activeField,
            template: template,
            sourceText: currentText,
            instruction: optimizationInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        activeOptimizationRequest = request
        isOptimizing = true
        optimizationSuggestion = nil
        optimizationSuggestionRequest = nil
        optimizationErrorMessage = nil
        defer {
            if activeOptimizationRequest?.id == request.id {
                activeOptimizationRequest = nil
                isOptimizing = false
            }
        }
        do {
            let suggestion = try await repository.optimizePrompt(
                kind: kind,
                field: request.field,
                currentText: request.sourceText,
                instruction: request.instruction
            )
            try Task.checkCancellation()
            guard activeOptimizationRequest?.id == request.id else { return }
            guard activeField == request.field,
                  template == request.template else {
                optimizationErrorMessage = "提示词已变化，请重新生成建议"
                return
            }
            optimizationSuggestion = suggestion
            optimizationSuggestionRequest = request
        } catch is CancellationError {
            return
        } catch {
            guard activeOptimizationRequest?.id == request.id else { return }
            optimizationErrorMessage = error.localizedDescription
        }
    }

    /// 使当前优化请求失效；调用方同时取消其 Task，旧响应即使晚到也不会进入建议状态。
    func cancelOptimization() {
        activeOptimizationRequest = nil
        isOptimizing = false
    }

    /// 仅把与当前字段及完整草稿快照一致的建议写回其原始字段，避免 currentText 指向发生漂移。
    @discardableResult
    func applyOptimizationSuggestion() -> Bool {
        guard let optimizationSuggestion,
              let request = optimizationSuggestionRequest,
              activeField == request.field,
              template == request.template else {
            self.optimizationSuggestion = nil
            optimizationSuggestionRequest = nil
            optimizationErrorMessage = "提示词已变化，请重新生成建议"
            return false
        }
        switch request.field {
        case .taskTemplate:
            template.user = optimizationSuggestion
        case .roleRules:
            template.system = optimizationSuggestion
        }
        self.optimizationSuggestion = nil
        optimizationSuggestionRequest = nil
        optimizationInstruction = ""
        preview = nil
        trialResult = nil
        return true
    }

    /// 切换字段时清除过期优化结果，避免把旧字段建议误应用到新字段。
    func didChangeField() {
        activeOptimizationRequest = nil
        optimizationSuggestion = nil
        optimizationSuggestionRequest = nil
        isOptimizing = false
        optimizationErrorMessage = nil
        optimizationInstruction = ""
    }

    private func clearDerivedResults() {
        preview = nil
        trialResult = nil
        optimizationSuggestion = nil
        optimizationSuggestionRequest = nil
        optimizationErrorMessage = nil
    }
}
