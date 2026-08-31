/**
 * [INPUT]: 依赖 AIRepositoryProtocol 读取 iOS 产品投影、保存 AI 配置并更新本机偏好中的 DeepSeek 凭据
 * [OUTPUT]: 对外提供 AIConfigurationViewModel 与 AIConfigurationFeedback，驱动 DeepSeek 模型/密钥设置并同步三类 Prompt 的默认或自定义状态
 * [POS]: ViewModels/Personal 的 AI 设置状态编排器，被 AIConfigurationView 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// AI 设置页的一次性反馈事件，页面消费后映射到项目统一 Toast。
nonisolated struct AIConfigurationFeedback: Identifiable, Equatable, Sendable {
    enum Role: Equatable, Sendable {
        case success
        case error
    }

    let id = UUID()
    let role: Role
    let message: String
}

@MainActor
@Observable
/// AI 设置状态源；iOS 当前只编辑 DeepSeek，SiliconFlow 由领域与存储层兼容保留，明文 API Key 不从持久化快照回填。
final class AIConfigurationViewModel {
    var configuration: AIConfiguration = .androidAlignedDefault
    var apiKeyDraft = ""
    var providersWithStoredKey = Set<AIProvider>()
    var isLoading = false
    var isSaving = false
    var feedback: AIConfigurationFeedback?

    private var persistedConfiguration: AIConfiguration = .androidAlignedDefault
    private let repository: any AIRepositoryProtocol

    /// 注入 AI 仓储，确保设置页不直接访问 UserDefaults 或网络客户端。
    init(repository: any AIRepositoryProtocol) {
        self.repository = repository
    }

    var selectedProvider: AIProvider {
        configuration.provider
    }

    var selectedModelID: String {
        configuration.selectedModelID
    }

    var selectedBaseURL: String {
        configuration.provider.baseURLString
    }

    var selectedProviderHasStoredKey: Bool {
        providersWithStoredKey.contains(configuration.provider)
    }

    var hasPendingChanges: Bool {
        configuration != persistedConfiguration
            || !apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canSave: Bool {
        !isLoading && !isSaving && hasPendingChanges && validationMessage == nil
    }

    /// 判断单任务提示词是否偏离产品默认组合，供设置入口显示“默认/已自定义”。
    func isPromptCustomized(_ kind: AIPromptKind) -> Bool {
        configuration.prompts.template(for: kind)
            != AIPromptConfiguration.androidAlignedDefault.template(for: kind)
    }

    var validationMessage: String? {
        if configuration.selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "请选择模型"
        }
        for kind in AIPromptKind.allCases {
            let template = configuration.prompts.template(for: kind)
            if let issue = AIPromptValidator.blockingIssue(in: template, kind: kind) {
                return "\(kind.title)：\(issue.message)"
            }
        }
        if configuration.isEnabled,
           !selectedProviderHasStoredKey,
           apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "启用前请填写 \(selectedProvider.displayName) API Key"
        }
        return nil
    }

    /// 读取配置快照；调用任务取消后不再回写页面状态。
    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let snapshot = try await repository.fetchConfiguration()
            try Task.checkCancellation()
            apply(snapshot)
        } catch is CancellationError {
            return
        } catch {
            feedback = AIConfigurationFeedback(
                role: .error,
                message: "读取 AI 配置失败：\(error.localizedDescription)"
            )
        }
    }

    /// 从独立编辑页返回时只合并已持久化 Prompt，不覆盖模型、开关或 API Key 的上层未保存草稿。
    func refreshPrompts() async {
        guard !isLoading, !isSaving else { return }
        do {
            let snapshot = try await repository.fetchConfiguration()
            try Task.checkCancellation()
            configuration.prompts = snapshot.configuration.prompts
            persistedConfiguration.prompts = snapshot.configuration.prompts
        } catch is CancellationError {
            return
        } catch {
            feedback = AIConfigurationFeedback(
                role: .error,
                message: "刷新提示词状态失败：\(error.localizedDescription)"
            )
        }
    }

    /// 更新当前供应商模型，其他供应商已选模型不受影响。
    func selectModel(_ modelID: String) {
        configuration.setModelID(modelID, for: configuration.provider)
    }

    /// 更新指定 Prompt 草稿；最终由页面统一保存，避免 Sheet 关闭即产生隐式持久化。
    func updatePrompt(_ template: AIPromptTemplate, for kind: AIPromptKind) {
        configuration.prompts.setTemplate(template, for: kind)
    }

    /// 恢复单类 Prompt 的 Android 同源默认值，仍需用户点击页面保存后才持久化。
    func resetPrompt(_ kind: AIPromptKind) {
        configuration.prompts.reset(kind)
    }

    /// 校验并保存配置与可选新密钥；成功后立即清空界面明文并重读凭据存在状态。
    @discardableResult
    func save() async -> Bool {
        guard !isSaving else { return false }
        if let validationMessage {
            feedback = AIConfigurationFeedback(role: .error, message: validationMessage)
            return false
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let trimmedKey = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            try await repository.saveConfiguration(
                configuration,
                apiKey: trimmedKey.isEmpty ? nil : trimmedKey
            )
            let snapshot = try await repository.fetchConfiguration()
            try Task.checkCancellation()
            apiKeyDraft = ""
            apply(snapshot)
            feedback = AIConfigurationFeedback(role: .success, message: "AI 配置已保存")
            return true
        } catch is CancellationError {
            return false
        } catch {
            feedback = AIConfigurationFeedback(role: .error, message: error.localizedDescription)
            return false
        }
    }

    /// 删除当前供应商凭据；若它正被使用，同时关闭功能以避免残留“已启用但无凭据”状态。
    @discardableResult
    func deleteSelectedProviderKey() async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            let provider = configuration.provider
            try await repository.deleteAPIKey(for: provider)
            if configuration.isEnabled {
                configuration.isEnabled = false
                try await repository.saveConfiguration(configuration, apiKey: nil)
            }
            let snapshot = try await repository.fetchConfiguration()
            try Task.checkCancellation()
            apiKeyDraft = ""
            apply(snapshot)
            feedback = AIConfigurationFeedback(
                role: .success,
                message: "\(provider.displayName) API Key 已移除"
            )
            return true
        } catch is CancellationError {
            return false
        } catch {
            feedback = AIConfigurationFeedback(role: .error, message: error.localizedDescription)
            return false
        }
    }

    /// 清除页面已展示的一次性反馈，避免 Observation 重绘时重复提示。
    func consumeFeedback() {
        feedback = nil
    }

    private func apply(_ snapshot: AIConfigurationSnapshot) {
        let normalized = snapshot.configuration.iOSProductNormalized
        configuration = normalized
        persistedConfiguration = normalized
        providersWithStoredKey = snapshot.providersWithStoredKey
    }
}
