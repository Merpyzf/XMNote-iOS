/**
 * [INPUT]: 依赖 Foundation，承接三联凭证恢复及保存偏好
 * [OUTPUT]: 提供三联登录表单恢复快照，不持有界面或存储实现
 * [POS]: Domain/Models 的三联导入私有业务契约
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 恢复三联登录表单，并将可恢复的凭证存储问题交给页面提示。
nonisolated struct LifeWeekLoginState: Sendable {
    var phoneNumber = ""
    var password = ""
    var remembersPassword = true
    var storageMessage: String?
}
