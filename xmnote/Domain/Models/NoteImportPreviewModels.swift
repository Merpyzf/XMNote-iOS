/**
 * [INPUT]: 依赖统一导入 Draft 与书籍编辑值类型，保留来源状态、筛选条件和显式资料修改
 * [OUTPUT]: 提供导入功能专用的能力、筛选方案、目标匹配与资料补丁
 * [POS]: Domain/Models 的导入预览契约，不持有数据库或 UI 生命周期
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 来源实际提供的状态；未知和未读完不借用本地书库的默认状态。
nonisolated enum NoteImportReadingStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case wantRead, reading, finished, abandoned, onHold, unfinished, unavailable
    var id: String { rawValue }
    var title: String {
        switch self {
        case .wantRead: "想读"
        case .reading: "在读"
        case .finished: "读完"
        case .abandoned: "弃读"
        case .onHold: "搁置"
        case .unfinished: "未读完"
        case .unavailable: "未提供"
        }
    }

    /// 仅由确实存在的来源字段建立状态，不读取数据库默认值。
    init?(sourceValue: Int64?) {
        switch sourceValue {
        case 1: self = .wantRead
        case 2: self = .reading
        case 3: self = .finished
        case 4: self = .abandoned
        case 5: self = .onHold
        default: return nil
        }
    }
}

/// 内容筛选按条目是否存在判断，想法和图片仍隶属于原书摘。
nonisolated enum NoteImportContentKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case note, idea, review, image, readingRecord
    var id: String { rawValue }
    var title: String {
        switch self {
        case .note: "有书摘"
        case .idea: "有想法"
        case .review: "有书评"
        case .image: "有图片"
        case .readingRecord: "有阅读记录"
        }
    }
}

/// 日期维度使用来源真实时间，筛选书籍而不裁剪书摘。
nonisolated enum NoteImportDateField: String, Codable, CaseIterable, Identifiable, Sendable {
    case note, review, readingRecord, readingStatus, bookmark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .note: "书摘日期"
        case .review: "书评日期"
        case .readingRecord: "阅读日期"
        case .readingStatus: "状态修改日期"
        case .bookmark: "阅读位置日期"
        }
    }
}

/// 存放目标筛选独立于内容是否曾经导入。
nonisolated enum NoteImportPlacement: String, Codable, CaseIterable, Identifiable, Sendable {
    case newBook, existingBook, unresolved
    var id: String { rawValue }
    var title: String {
        switch self {
        case .newBook: "新建书籍"
        case .existingBook: "已有书籍"
        case .unresolved: "待确认"
        }
    }
}

/// 只改变列表顺序，不改变条目身份与提交顺序。
nonisolated enum NoteImportSort: String, Codable, CaseIterable, Identifiable, Sendable {
    case source, title, contentCount
    var id: String { rawValue }
    var title: String {
        switch self {
        case .source: "来源顺序"
        case .title: "书名"
        case .contentCount: "笔记数量"
        }
    }
}

/// 偏好仅包含一次性导入中有价值的条件；状态不跨批次恢复。
nonisolated struct NoteImportFilter: Codable, Equatable, Sendable {
    var statuses: Set<NoteImportReadingStatus> = []
    var onlyWithNotes = false
    var duration: NoteImportDurationFilter = .all
    var sort: NoteImportSort = .source
    var additionalCount: Int { (onlyWithNotes ? 1 : 0) + (duration == .all ? 0 : 1) }
    var statusTitle: String { statuses.first?.title ?? "全部" }
    var summary: String {
        var values: [String] = []
        if onlyWithNotes { values.append("有笔记") }
        if duration != .all { values.append(duration.title) }
        return values.joined(separator: "、")
    }
}

/// 当前批次提供的真实能力，用于隐藏不成立的条件并验证方案兼容性。
nonisolated struct NoteImportCapabilities: Equatable, Sendable {
    var statuses: Set<NoteImportReadingStatus> = []
    var contents: Set<NoteImportContentKind> = []
    var dateFields: Set<NoteImportDateField> = []

    /// 遍历不可变来源快照，不受关联、编辑或当前筛选影响。
    init(books: [NoteImportDraftBook]) {
        let provided = books.compactMap(\.sourceReadingStatus)
        if !provided.isEmpty {
            if books.contains(where: \.usesCompletionReadingStatus) {
                statuses.formUnion([.finished, .unfinished])
            }
            if books.contains(where: { $0.sourceReadingStatus != nil && !$0.usesCompletionReadingStatus }) {
                statuses.formUnion([.wantRead, .reading, .finished, .abandoned, .onHold])
            }
            if provided.count < books.count { statuses.insert(.unavailable) }
        }
        for book in books {
            contents.formUnion(book.previewContentKinds)
            for field in NoteImportDateField.allCases where !book.previewDates(for: field).isEmpty {
                dateFields.insert(field)
            }
        }
    }

}

/// 预览可编辑资料；原始来源名称、位置单位和时长不由资料表单重写。
nonisolated struct NoteImportBookMetadata: Equatable, Sendable {
    var title: String
    var author: String
    var translator: String
    var authorIntro: String
    var press: String
    var isbn: String
    var publicationDate: String
    var summary: String
    var coverURL: String
    var readingStatusID: Int64
    var groupName: String
    var tagNames: [String]

    /// 为新书建立独立资料快照，后续修改不改变原始导入身份。
    init(source: NoteImportDraftBook) {
        title = source.name; author = source.author; translator = source.translator
        authorIntro = source.authorIntro; press = source.press; isbn = source.isbn
        publicationDate = source.pubDate; summary = source.summary; coverURL = source.cover
        readingStatusID = source.readStatusID
        groupName = source.group?.name ?? source.groups.first?.name ?? ""
        tagNames = source.tags.map(\.name)
    }

    /// 从现有编辑仓储的只读结果建立目标资料快照。
    init(editor: BookEditorDraft) {
        title = editor.title; author = editor.author; translator = editor.translator
        authorIntro = editor.authorIntro; press = editor.press; isbn = editor.isbn
        publicationDate = editor.pubDate; summary = editor.summary; coverURL = editor.coverURL
        readingStatusID = editor.readingStatus.rawValue
        groupName = editor.groupName; tagNames = editor.tagNames
    }

    var validationMessage: String? {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "书名不能为空" }
        if !coverURL.isEmpty {
            guard let url = URL(string: coverURL), ["https", "http", "file"].contains(url.scheme?.lowercased() ?? "") else {
                return "封面地址无效"
            }
        }
        return nil
    }
}

/// 比较初始值与最终值，仅提交用户明确更改的字段，允许显式清空。
nonisolated struct NoteImportMetadataPatch: Equatable, Sendable {
    let original: NoteImportBookMetadata
    var edited: NoteImportBookMetadata
    var changedAt: Int64
    var hasChanges: Bool { original != edited }
}

/// 可信来源身份允许自动关联；名称候选必须由用户确认。
nonisolated enum NoteImportTargetMatch: Sendable {
    case none
    case automatic(Int64)
    case candidate
}

nonisolated extension NoteImportDraftBook {
    var previewContentKinds: Set<NoteImportContentKind> {
        var result: Set<NoteImportContentKind> = []
        if !notes.isEmpty { result.insert(.note) }
        if notes.contains(where: { !$0.idea.isEmpty }) { result.insert(.idea) }
        if !reviews.isEmpty { result.insert(.review) }
        if notes.contains(where: { !$0.attachments.isEmpty || !$0.failedAttachmentURLs.isEmpty })
            || reviews.contains(where: { !$0.images.isEmpty }) { result.insert(.image) }
        if readingRecordCount > 0 { result.insert(.readingRecord) }
        return result
    }

    var readingRecordCount: Int {
        (preciseReadingDurations?.count ?? 0) + (fuzzyReadingDurations?.count ?? 0) + (wereadReadingDurations?.count ?? 0)
            + (hasPreviewReadingPosition ? 1 : 0)
    }

    var hasPreviewReadingPosition: Bool { bookmarkModifiedTime > 0 && readPosition > 0 }

    /// 只返回有效毫秒时间；没有来源日期的条目不会被赋予导入时间。
    func previewDates(for field: NoteImportDateField) -> [Int64] {
        let values: [Int64]
        switch field {
        case .note: values = notes.filter(\.isIncludeTime).map(\.createdTime)
        case .review: values = reviews.map(\.createdTime)
        case .readingRecord:
            values = (preciseReadingDurations ?? []).compactMap(\.startTime)
                + (fuzzyReadingDurations ?? []).compactMap(\.date)
                + (wereadReadingDurations ?? []).compactMap(\.date)
        case .readingStatus: values = [readStatusChangedDate]
        case .bookmark: values = [bookmarkModifiedTime]
        }
        return values.filter { $0 > 0 }
    }
}
