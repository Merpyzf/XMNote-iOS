/**
 * [INPUT]: 依赖 NoteExcerptListItem、BookPickerBook、NoteEditorTagOption 与 NoteEditorImageItem 复用现有书摘编辑领域数据
 * [OUTPUT]: 对外提供 NoteBatchEditBootstrap、NoteMergePreviewRequest、NoteMergeDraft 与 NoteBatchMutationError
 * [POS]: Domain/Models 的书摘批量编辑与合并模型，隔离二级列表 UI 和 Repository 事务细节
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 批量操作首屏快照，保留已失效 ID 以便页面解释并发删除后的选择收缩。
nonisolated struct NoteBatchEditBootstrap: Hashable, Sendable {
    let requestedNoteIDs: [Int64]
    let notes: [NoteExcerptListItem]
    let unavailableNoteIDs: [Int64]
    let books: [BookPickerBook]
    let tags: [NoteEditorTagOption]
}

/// 合并正文或想法时的段落连接规则，对齐 Android 的“跟随/换行/换两行”。
nonisolated enum NoteMergeLineBreakRule: Int, CaseIterable, Hashable, Codable, Sendable {
    case follow = 0
    case oneLine = 1
    case twoLines = 2

    /// 生成规则对应的原始换行符，富文本内容保持原样，不额外清理标签。
    var separator: String {
        switch self {
        case .follow: ""
        case .oneLine: "\n"
        case .twoLines: "\n\n"
        }
    }
}

/// 合并预览请求；正文和想法各自维护顺序，未列入对应顺序的空字段不会进入拼接结果。
nonisolated struct NoteMergePreviewRequest: Hashable, Codable, Sendable {
    let sourceNoteIDs: [Int64]
    let contentNoteIDs: [Int64]
    let ideaNoteIDs: [Int64]
    let contentRule: NoteMergeLineBreakRule
    let ideaRule: NoteMergeLineBreakRule

    /// 创建默认预览时沿用来源顺序；重新排序时可分别传入正文与想法 ID。
    init(
        sourceNoteIDs: [Int64],
        contentNoteIDs: [Int64]? = nil,
        ideaNoteIDs: [Int64]? = nil,
        contentRule: NoteMergeLineBreakRule = .oneLine,
        ideaRule: NoteMergeLineBreakRule = .oneLine
    ) {
        self.sourceNoteIDs = sourceNoteIDs
        self.contentNoteIDs = contentNoteIDs ?? sourceNoteIDs
        self.ideaNoteIDs = ideaNoteIDs ?? sourceNoteIDs
        self.contentRule = contentRule
        self.ideaRule = ideaRule
    }
}

/// 合并页可编辑草稿；Repository 生成预览，页面只修改最终字段，提交时再次校验来源和关联对象。
nonisolated struct NoteMergeDraft: Equatable, Sendable {
    let sourceNoteIDs: [Int64]
    let sourceNotes: [NoteExcerptListItem]
    let book: BookPickerBook
    var contentNoteIDs: [Int64]
    var ideaNoteIDs: [Int64]
    var contentRule: NoteMergeLineBreakRule
    var ideaRule: NoteMergeLineBreakRule
    var contentHTML: String
    var ideaHTML: String
    var position: String
    var positionUnit: Int64
    var includeTime: Bool
    var createdDate: Int64
    var chapterID: Int64
    var chapterTitle: String
    var selectedTags: [NoteEditorTagOption]
    var imageItems: [NoteEditorImageItem]
}

/// 批量写入与合并的领域错误，供页面统一转换为系统弹窗或列表刷新提示。
nonisolated enum NoteBatchMutationError: LocalizedError, Equatable {
    case emptySelection
    case noteNotFound
    case bookNotFound
    case tagNotFound
    case chapterNotFound
    case chapterBookMismatch
    case invalidChapterTitle
    case notesFromDifferentBooks
    case invalidChapterDepth
    case invalidMergeDraft

    var errorDescription: String? {
        switch self {
        case .emptySelection: "请至少选择一条书摘"
        case .noteNotFound: "部分书摘已被删除，请刷新后重试"
        case .bookNotFound: "目标书籍不存在或已删除"
        case .tagNotFound: "部分标签已被删除，请刷新后重试"
        case .chapterNotFound: "目标章节不存在或已删除"
        case .chapterBookMismatch: "目标章节不属于当前书籍"
        case .invalidChapterTitle: "章节名称不能为空，且长度不能超过 100 个字符"
        case .notesFromDifferentBooks: "只能合并同一本书中的书摘"
        case .invalidChapterDepth: "章节层级不能超过 5 层"
        case .invalidMergeDraft: "合并内容已失效，请重新生成预览"
        }
    }
}
