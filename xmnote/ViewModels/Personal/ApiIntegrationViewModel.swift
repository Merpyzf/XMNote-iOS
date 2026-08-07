/**
 * [INPUT]: 依赖 ExternalAppIntegrationRepositoryProtocol 读取和保存关联应用配置
 * [OUTPUT]: 对外提供 ApiIntegrationViewModel，驱动 API 集成设置页状态概览、单项编辑草稿、字段错误与保存反馈
 * [POS]: ViewModels/Personal 的 API 集成设置状态编排器，被 ApiIntegrationView 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// API 集成设置页反馈事件，供 View 消费后展示统一 Toast。
struct ApiIntegrationFeedback: Identifiable, Equatable {
    enum Role: Equatable {
        case success
        case error
    }

    let id = UUID()
    let role: Role
    let message: String
}

@MainActor
@Observable
/// API 集成设置状态源，负责三方配置草稿、保存、清空、字段错误与反馈事件。
final class ApiIntegrationViewModel {
    var settings: ExternalAppIntegrationSettings = .empty
    var draftSettings: ExternalAppIntegrationSettings = .empty
    var feedback: ApiIntegrationFeedback?
    var fieldErrors: [ExternalAppDestination: String] = [:]

    private let repository: any ExternalAppIntegrationRepositoryProtocol

    /// 注入关联应用仓储，保证设置页只通过 Repository 访问本地配置。
    init(repository: any ExternalAppIntegrationRepositoryProtocol) {
        self.repository = repository
    }

    /// 读取已保存配置并同步到表单草稿。
    func load() {
        let stored = repository.fetchSettings()
        settings = stored
        draftSettings = stored
        fieldErrors.removeAll()
    }

    /// 更新指定目标的表单草稿。
    func updateDraft(_ value: String, for destination: ExternalAppDestination) {
        draftSettings = draftSettings.settingValue(value, for: destination)
        fieldErrors[destination] = nil
    }

    /// 将指定目标草稿重置为已保存值，用于 Sheet 打开和取消关闭时隔离未提交编辑。
    func resetDraft(for destination: ExternalAppDestination) {
        draftSettings = draftSettings.settingValue(settings.value(for: destination), for: destination)
        fieldErrors[destination] = nil
    }

    /// 判断指定目标是否存在可提交的非空变更，避免无意义保存或用保存动作隐式清空配置。
    func canSave(_ destination: ExternalAppDestination) -> Bool {
        let draftValue = draftSettings.normalized.value(for: destination)
        let storedValue = settings.normalized.value(for: destination)
        return !draftValue.isEmpty && draftValue != storedValue
    }

    /// 判断指定目标是否可以清空，覆盖已保存配置或当前编辑中的临时输入。
    func canClear(_ destination: ExternalAppDestination) -> Bool {
        settings.isConfigured(destination) || !draftSettings.normalized.value(for: destination).isEmpty
    }

    /// 返回指定目标最近一次保存校验错误，供编辑 Sheet 就近展示。
    func fieldError(for destination: ExternalAppDestination) -> String? {
        fieldErrors[destination]
    }

    /// 保存单个目标配置；其他目标保持已保存值，避免未保存草稿互相影响。
    @discardableResult
    func save(_ destination: ExternalAppDestination) -> Bool {
        let next = settings.settingValue(draftSettings.value(for: destination), for: destination)
        do {
            try repository.saveSettings(next)
            settings = repository.fetchSettings()
            draftSettings = draftSettings.settingValue(settings.value(for: destination), for: destination)
            fieldErrors[destination] = nil
            feedback = ApiIntegrationFeedback(role: .success, message: "\(destination.titleForFeedback) 已保存")
            return true
        } catch {
            let message = error.localizedDescription
            fieldErrors[destination] = message
            feedback = ApiIntegrationFeedback(role: .error, message: message)
            return false
        }
    }

    /// 清空单个目标配置，并同步表单草稿。
    @discardableResult
    func clear(_ destination: ExternalAppDestination) -> Bool {
        let next = settings.settingValue("", for: destination)
        do {
            try repository.saveSettings(next)
            settings = repository.fetchSettings()
            draftSettings = draftSettings.settingValue("", for: destination)
            fieldErrors[destination] = nil
            feedback = ApiIntegrationFeedback(role: .success, message: "\(destination.titleForFeedback) 已清空")
            return true
        } catch {
            let message = error.localizedDescription
            fieldErrors[destination] = message
            feedback = ApiIntegrationFeedback(role: .error, message: message)
            return false
        }
    }

    /// 清除已消费的反馈事件。
    func consumeFeedback() {
        feedback = nil
    }
}

private extension ExternalAppDestination {
    var titleForFeedback: String {
        switch self {
        case .flomo:
            return "Flomo"
        case .writeathon:
            return "Writeathon"
        case .inbox:
            return "Inbox"
        }
    }
}
