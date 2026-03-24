import Foundation

/**
 * [INPUT]: 依赖 Foundation 提供跨层数据结构
 * [OUTPUT]: 对外提供 NoteDetailPayload、NoteEditor* 编辑模型族、BackupServerFormInput
 * [POS]: Domain 层仓储输入输出模型，隔离 ViewModel 与 Infra 细节
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 笔记详情读取模型，承载编辑页所需正文、想法和位置信息。
struct NoteDetailPayload {
    let contentHTML: String
    let ideaHTML: String
    let position: String
    let positionUnit: Int64
    let includeTime: Bool
    let createdDate: Int64
}

/// 书摘编辑模式，区分新建与编辑既有书摘两条事务路径。
enum NoteEditorMode: Hashable, Codable, Sendable {
    case create
    case edit(noteId: Int64)

    var noteID: Int64 {
        switch self {
        case .create:
            return 0
        case .edit(let noteId):
            return noteId
        }
    }
}

/// 新建书摘时的外部种子，承接预选书籍、章节与正文预填场景。
struct NoteEditorSeed: Hashable, Codable, Sendable {
    var bookId: Int64?
    var chapterId: Int64?
    var contentHTML: String
    var ideaHTML: String

    static let empty = Self(
        bookId: nil,
        chapterId: nil,
        contentHTML: "",
        ideaHTML: ""
    )
}

/// 书摘编辑页的书籍选项，承载书卡展示与页码校验所需字段。
struct NoteEditorBookOption: Identifiable, Hashable, Codable, Sendable {
    let id: Int64
    let title: String
    let author: String
    let coverURL: String
    let positionUnit: Int64
    let totalPosition: Int64
    let totalPagination: Int64
}

/// 书摘编辑页的章节候选项。
struct NoteEditorChapterOption: Identifiable, Hashable, Codable, Sendable {
    let id: Int64
    let title: String
}

/// 书摘编辑页的标签候选项。
struct NoteEditorTagOption: Identifiable, Hashable, Codable, Sendable {
    let id: Int64
    let title: String
}

/// 书摘附图条目的统一模型，兼容远端已保存图与本地暂存图。
struct NoteEditorImageItem: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let remoteURL: String?
    let localFilePath: String?
    let createdDate: Int64

    var previewPath: String? {
        localFilePath ?? remoteURL
    }

    var isStagedLocally: Bool {
        remoteURL == nil && localFilePath?.isEmpty == false
    }
}

/// 书摘编辑页当前草稿快照，作为自动保存、恢复与保存事务的统一输入。
struct NoteEditorDraft: Equatable, Codable, Sendable {
    var noteId: Int64
    var bookId: Int64
    var bookTitle: String
    var bookAuthor: String
    var bookCoverURL: String
    var bookPositionUnit: Int64
    var bookTotalPosition: Int64
    var bookTotalPagination: Int64
    var contentHTML: String
    var ideaHTML: String
    var position: String
    var positionUnit: Int64
    var includeTime: Bool
    var createdDate: Int64
    var chapterId: Int64
    var chapterTitle: String
    var selectedTags: [NoteEditorTagOption]
    var imageItems: [NoteEditorImageItem]
    var lastAutoSaveTime: Int64
}

/// 书摘编辑页首屏引导数据，聚合基础草稿、恢复草稿与可选项。
struct NoteEditorBootstrap: Sendable {
    let mode: NoteEditorMode
    let baseDraft: NoteEditorDraft
    let recoveredDraft: NoteEditorDraft?
    let books: [NoteEditorBookOption]
    let tags: [NoteEditorTagOption]
    let chapters: [NoteEditorChapterOption]
}

/// 书摘编辑错误，统一收口表单校验、标签规则与 OCR 失败语义。
enum NoteEditorError: LocalizedError, Equatable {
    case noteNotFound
    case bookRequired
    case contentRequired
    case duplicateTagName
    case invalidTagName
    case invalidReadPosition(String)
    case invalidImageData

    var errorDescription: String? {
        switch self {
        case .noteNotFound:
            return "书摘不存在或已删除"
        case .bookRequired:
            return "请先选择一本书"
        case .contentRequired:
            return "书摘内容、想法和附图不能同时为空"
        case .duplicateTagName:
            return "标签名称已存在"
        case .invalidTagName:
            return "标签名称不能为空，且长度不能超过 100 个字符"
        case .invalidReadPosition(let message):
            return message
        case .invalidImageData:
            return "当前图片无法读取，请重新选择后再试"
        }
    }
}

/// WebDAV 服务器表单输入模型，用于新增/编辑时提交地址与凭据。
struct BackupServerFormInput: Equatable {
    let title: String
    let address: String
    let account: String
    let password: String
}
