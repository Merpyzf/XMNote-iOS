/**
 * [INPUT]: 依赖 ExportRequest、ExportProgress、ExportResult 与 ExportSettingsSnapshot 领域模型
 * [OUTPUT]: 对外提供统一导出仓储协议，供原生界面与 Desktop Web 共享同一业务入口
 * [POS]: Domain/Repositories 的导出能力边界；ViewModel 不直接访问数据库、网络或文件生成器
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 导出仓储抽象；每次执行先冻结数据库和设置快照，再生成文件或串行写入远端。
protocol ExportRepositoryProtocol: Sendable {
    func settings() async throws -> ExportSettingsSnapshot
    func saveSettings(_ settings: ExportSettingsSnapshot) async throws
    func saveCredential(_ value: String, for credential: ExportCredential) async throws
    func hasCredential(_ credential: ExportCredential) async -> Bool
    func connectNotion() async throws
    func connectOneNote() async throws
    func export(
        _ request: ExportRequest,
        progress: @escaping @Sendable (ExportProgress) -> Void
    ) async -> ExportResult
}

extension ExportRepositoryProtocol {
    func connectNotion() async throws {
        throw ExportConnectionError.unavailable
    }

    func connectOneNote() async throws {
        throw ExportConnectionError.unavailable
    }
}

enum ExportConnectionError: LocalizedError {
    case unavailable

    var errorDescription: String? { "当前导出仓储不支持账户连接" }
}

/// Keychain 中的稳定凭据账户名，只覆盖当前产品支持的远端目标。
nonisolated enum ExportCredential: String, CaseIterable, Sendable {
    case yuqueToken = "yuque_token"
    case notionAccessToken = "notion_access_token"
    case notionRefreshToken = "notion_refresh_token"
    case oneNoteAccount = "one_note_account"
    case siYuanToken = "si_yuan_token"
    case obsidianAPIKey = "obsidian_api_key"
}
