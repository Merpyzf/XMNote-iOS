/**
 * [INPUT]: 依赖 Foundation
 * [OUTPUT]: 对外提供 NoteCategory 枚举（书摘/相关/书评三分类）
 * [POS]: Domain/Models 的笔记分类定义，被 NoteViewModel 与笔记列表视图消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

enum NoteCategory: String, CaseIterable, Identifiable {
    case excerpts
    case related
    case reviews

    var id: String { rawValue }

    var title: String {
        switch self {
        case .excerpts: "书摘"
        case .related: "相关"
        case .reviews: "书评"
        }
    }
}
