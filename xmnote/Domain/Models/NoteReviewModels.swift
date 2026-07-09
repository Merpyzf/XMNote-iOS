/**
 * [INPUT]: 依赖 Foundation 基础类型，承接 Android 书摘回顾设置与卡片数据语义
 * [OUTPUT]: 对外提供 NoteReviewSettings、NoteReviewCardItem、NoteReviewTagOption 与标签编辑快照等跨层模型
 * [POS]: Domain/Models 的书摘回顾领域模型，供 Repository、ViewModel 与回顾页面共享
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 书摘回顾的数据排序规则，对齐 Android 的随机与顺序两种模式。
nonisolated enum NoteReviewSortRule: String, CaseIterable, Codable, Hashable, Sendable {
    case random
    case ordered

    var title: String {
        switch self {
        case .random:
            return "随机回顾"
        case .ordered:
            return "按书籍顺序"
        }
    }

    var systemImage: String {
        switch self {
        case .random:
            return "shuffle"
        case .ordered:
            return "text.line.first.and.arrowtriangle.forward"
        }
    }
}

/// 标签筛选匹配规则，承接 Android “任一标签/全部标签”语义。
nonisolated enum NoteReviewTagMatchRule: String, CaseIterable, Codable, Hashable, Sendable {
    case any
    case all

    var title: String {
        switch self {
        case .any:
            return "任一标签"
        case .all:
            return "全部标签"
        }
    }
}

/// 回顾卡片配色预设；UI 层负责将语义枚举映射到实际颜色。
nonisolated enum NoteReviewPalette: String, CaseIterable, Codable, Hashable, Sendable {
    case paper
    case dark
    case lightGray
    case mistBlue
    case sageGreen
    case rose

    var title: String {
        switch self {
        case .paper:
            return "纸页"
        case .dark:
            return "深色"
        case .lightGray:
            return "浅灰"
        case .mistBlue:
            return "雾蓝"
        case .sageGreen:
            return "青绿"
        case .rose:
            return "胭粉"
        }
    }
}

/// 回顾卡片文本对齐方式，保留 Android 的三种阅读布局能力。
nonisolated enum NoteReviewTextAlignment: String, CaseIterable, Codable, Hashable, Sendable {
    case leading
    case center
    case trailing

    var title: String {
        switch self {
        case .leading:
            return "靠左"
        case .center:
            return "居中"
        case .trailing:
            return "靠右"
        }
    }
}

/// 书摘回顾设置快照，集中描述会影响数据读取和外观渲染的全部用户偏好。
nonisolated struct NoteReviewSettings: Codable, Hashable, Sendable {
    var selectedBookIDs: [Int64]
    var selectedTagIDs: [Int64]
    var tagMatchRule: NoteReviewTagMatchRule
    var sortRule: NoteReviewSortRule
    var palette: NoteReviewPalette
    var textAlignment: NoteReviewTextAlignment

    static let defaultValue = NoteReviewSettings(
        selectedBookIDs: [],
        selectedTagIDs: [],
        tagMatchRule: .any,
        sortRule: .random,
        palette: .paper,
        textAlignment: .leading
    )

    /// 判断设置变化是否会改变数据库查询结果，用于区分重载和纯外观刷新。
    func hasSameDataScope(as other: NoteReviewSettings) -> Bool {
        selectedBookIDs == other.selectedBookIDs
            && selectedTagIDs == other.selectedTagIDs
            && tagMatchRule == other.tagMatchRule
            && sortRule == other.sortRule
    }
}

/// 书摘回顾分页请求上下文，隔离顺序分页和随机排除两种读取参数。
nonisolated struct NoteReviewPageRequest: Hashable, Sendable {
    let settings: NoteReviewSettings
    let offset: Int
    let excludedNoteIDs: [Int64]
    let limit: Int
}

/// 回顾卡片展示项，保留卡堆、标签区与详情跳转所需的稳定字段。
nonisolated struct NoteReviewCardItem: Identifiable, Sendable {
    let id: Int64
    let bookID: Int64
    let bookTitle: String
    let bookAuthor: String
    let bookCoverURL: String
    let chapterTitle: String
    let contentHTML: String
    let ideaHTML: String
    let position: String
    let positionUnit: Int64
    let includeTime: Bool
    let createdDate: Int64
    let imageURLs: [String]
    let tags: [NoteEditorTagOption]
    let weReadOriginalURL: String?

    /// 返回仅替换标签集合的新卡片，用于回顾页标签编辑保存后的本地同步。
    func replacingTags(_ nextTags: [NoteEditorTagOption]) -> NoteReviewCardItem {
        NoteReviewCardItem(
            id: id,
            bookID: bookID,
            bookTitle: bookTitle,
            bookAuthor: bookAuthor,
            bookCoverURL: bookCoverURL,
            chapterTitle: chapterTitle,
            contentHTML: contentHTML,
            ideaHTML: ideaHTML,
            position: position,
            positionUnit: positionUnit,
            includeTime: includeTime,
            createdDate: createdDate,
            imageURLs: imageURLs,
            tags: nextTags,
            weReadOriginalURL: weReadOriginalURL
        )
    }
}

/// 回顾设置中的书摘标签选项，带计数用于辅助用户理解筛选范围。
nonisolated struct NoteReviewTagOption: Identifiable, Hashable, Codable, Sendable {
    let id: Int64
    let title: String
    let noteCount: Int
}

/// 当前回顾卡片编辑标签所需的完整标签快照。
nonisolated struct NoteReviewTagEditSnapshot: Sendable {
    let availableTags: [NoteEditorTagOption]
    let selectedTags: [NoteEditorTagOption]
}
