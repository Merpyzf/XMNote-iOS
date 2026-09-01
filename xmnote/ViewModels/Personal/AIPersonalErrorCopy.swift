/**
 * [INPUT]: 依赖 AIRepositoryError 与 Personal AI 配置、提示词流程的用户任务上下文
 * [OUTPUT]: 对 Personal AI 展示层提供不暴露网络、HTTP 与存储细节的统一错误文案
 * [POS]: ViewModels/Personal 的 AI 错误展示边界，被配置、编辑、测试与书摘选择状态源消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// Personal AI 配置与提示词流程的展示层错误文案，统一隔离底层实现细节。
nonisolated enum AIPersonalErrorCopy {
    /// 失败发生的用户任务，用于在未知错误与空响应时给出准确的恢复动作。
    enum Context: Equatable, Sendable {
        case readConfiguration
        case refreshPrompts
        case saveConfiguration
        case deleteAPIKey
        case readPrompt
        case savePrompt
        case previewPrompt
        case optimizePrompt
        case generateTrial
        case readExcerpts

        var fallback: String {
            switch self {
            case .readConfiguration:
                String(localized: "无法读取 AI 配置，请重试")
            case .refreshPrompts:
                String(localized: "提示词状态未更新，请稍后重试")
            case .saveConfiguration:
                String(localized: "无法保存 AI 配置，请重试")
            case .deleteAPIKey:
                String(localized: "无法移除 API Key，请重试")
            case .readPrompt:
                String(localized: "无法读取提示词，请重试")
            case .savePrompt:
                String(localized: "无法保存提示词，请重试")
            case .previewPrompt:
                String(localized: "无法生成预览，请检查提示词")
            case .optimizePrompt:
                String(localized: "无法优化提示词，请重试")
            case .generateTrial:
                String(localized: "无法生成结果，请重试")
            case .readExcerpts:
                String(localized: "无法读取书摘，请重试")
            }
        }
    }

    /// 将任意底层错误压缩为当前用户任务可恢复、且不暴露实现细节的展示文案。
    static func message(for error: Error, context: Context) -> String {
        guard let repositoryError = error as? AIRepositoryError else {
            return context.fallback
        }

        switch repositoryError {
        case .disabled:
            return String(localized: "AI 功能未启用，请先在“AI 配置”中开启")
        case .missingAPIKey(let provider):
            return String(localized: "未配置 \(provider.displayName) API Key，请先在“AI 配置”中填写")
        case .unauthorized:
            return String(localized: "API Key 无效，请检查后重试")
        case .forbidden:
            return String(localized: "当前账户无法使用所选模型，请检查余额或模型权限")
        case .rateLimited:
            return String(localized: "请求过于频繁，请稍后重试")
        case .service:
            return String(localized: "AI 服务暂时不可用，请稍后重试")
        case .network:
            return String(localized: "网络连接失败，请检查网络后重试")
        case .emptyResponse:
            return context == .optimizePrompt
                ? String(localized: "未生成有效内容，请重新优化")
                : String(localized: "未生成有效内容，请重新生成")
        case .invalidAutoTagResponse:
            return String(localized: "标签结果格式有误，请重新生成")
        case .noteNotFound:
            return String(localized: "书摘不存在或已删除")
        case .noTagsSelected:
            return String(localized: "请至少选择一个标签")
        case .credentialStore:
            return String(localized: "无法读取 API Key，请重新配置")
        case .invalidConfiguration:
            return context.fallback
        }
    }
}
