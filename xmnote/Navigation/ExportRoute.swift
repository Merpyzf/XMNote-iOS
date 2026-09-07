/**
 * [INPUT]: 依赖 ExportKind 与 ExportScope，接收各业务入口冻结的初始导出上下文
 * [OUTPUT]: 对外提供可编码、可恢复的 ExportRoute
 * [POS]: Navigation 的导出浏览路由；只保存类型、范围和配置上下文，不保存任务、凭据、临时文件或进度
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 原生导出流程的可恢复配置步骤；运行中任务和结果不会编码进导航状态。
nonisolated enum ExportConfigurationStep: Int, CaseIterable, Codable, Sendable {
    case scope
    case target
    case configuration
    case preflight

    var title: String {
        switch self {
        case .scope: "范围"
        case .target: "目标"
        case .configuration: "配置"
        case .preflight: "确认"
        }
    }
}

/// 当前 Tab 内导出页面的可恢复路由参数。
nonisolated struct ExportRoute: Hashable, Codable, Sendable {
    let scope: ExportScope
    let initialKind: ExportKind
    let initialTarget: ExportTarget?
    let searchQuery: String
    let initialStep: ExportConfigurationStep

    init(
        scope: ExportScope,
        initialKind: ExportKind = .noteExcerpt,
        initialTarget: ExportTarget? = nil,
        searchQuery: String = "",
        initialStep: ExportConfigurationStep = .scope
    ) {
        self.scope = scope
        self.initialKind = initialKind
        self.initialTarget = initialTarget
        self.searchQuery = searchQuery
        self.initialStep = initialStep
    }
}
