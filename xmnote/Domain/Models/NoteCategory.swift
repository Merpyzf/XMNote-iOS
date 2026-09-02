/**
 * [INPUT]: 依赖 Foundation
 * [OUTPUT]: 对外提供 NoteCategory 与 NoteExcerptGroupSort，描述首页四分类及书摘分组排序协议
 * [POS]: Domain/Models 的笔记分类定义，被 NoteViewModel 与笔记列表视图消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 笔记列表一级分类，对应书摘、星标章节、相关与书评四种分组。
nonisolated enum NoteCategory: String, CaseIterable, Identifiable, Hashable, Sendable, Codable {
    case excerpts
    case starredChapters
    case related
    case reviews

    var id: String { rawValue }

    var title: String {
        switch self {
        case .excerpts: "书摘"
        case .starredChapters: "星标章节"
        case .related: "相关"
        case .reviews: "书评"
        }
    }
}

/// 书摘聚合入口的稳定排序协议；持久化使用 rawValue，不绑定中文展示文案。
nonisolated enum NoteExcerptGroupSort: String, CaseIterable, Identifiable, Hashable, Sendable, Codable {
    case countAscending
    case countDescending
    case customOrder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .countAscending: "书摘数量 • 由少到多"
        case .countDescending: "书摘数量 • 由多到少"
        case .customOrder: "自定义顺序"
        }
    }
}
