import Foundation

/**
 * [INPUT]: 依赖 Foundation 提供跨层数据结构
 * [OUTPUT]: 对外提供 NoteDetailPayload、BackupServerFormInput
 * [POS]: Domain 层仓储输入输出模型，隔离 ViewModel 与 Infra 细节
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

struct NoteDetailPayload {
    let contentHTML: String
    let ideaHTML: String
    let position: String
    let positionUnit: Int64
    let includeTime: Bool
    let createdDate: Int64
}

struct BackupServerFormInput: Equatable {
    let title: String
    let address: String
    let account: String
    let password: String
}
