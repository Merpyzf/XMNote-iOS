/**
 * [INPUT]: 依赖 Foundation 提供字符串、值语义与错误描述
 * [OUTPUT]: 对外提供章节批量录入草稿、解析器、导入结果与结构恢复快照
 * [POS]: Domain/Models 的章节批量录入与移动撤销领域模型，供 Repository、ViewModel 与 SwiftUI Sheet 共享
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 批量录入中的单行章节；临时 ID 只在本次草稿内关联父子关系。
nonisolated struct ChapterBatchImportEntry: Identifiable, Hashable, Sendable {
    let id: Int
    let sourceLineNumber: Int
    let parentEntryID: Int?
    let title: String
    let remark: String
    let level: Int
    let siblingOrder: Int64
    let isImported: Bool
    let sourceType: Int64
    let sourceUID: String?
    let sourceAnchor: String?
    let sourceOrder: Int64
    let pathTitles: [String]
}

/// 一次手工目录录入草稿；entries 按用户输入的先序顺序排列。
nonisolated struct ChapterBatchImportDraft: Hashable, Sendable {
    let entries: [ChapterBatchImportEntry]

    var rootCount: Int {
        entries.lazy.filter { $0.parentEntryID == nil }.count
    }
}

/// 批量录入的事务结果；页面用首个根章节定位，创建/复用数量用于诊断冲突合并。
nonisolated struct ChapterBatchImportResult: Hashable, Sendable {
    let importedChapterIDs: [Int64]
    let createdChapterCount: Int
    let reusedChapterCount: Int

    var firstRootChapterID: Int64? {
        importedChapterIDs.first
    }
}

/// 对选中行增加一级缩进后的全文与 UTF-16 选区，便于 TextEditor 稳定恢复光标。
nonisolated struct ChapterBatchIndentResult: Hashable, Sendable {
    let text: String
    let selectionLocation: Int
    let selectionLength: Int
}

/// 结构写入前后的一条章节位置，用于对移动和重排执行并发安全的真实撤销。
nonisolated struct ChapterStructurePosition: Hashable, Sendable {
    let chapterID: Int64
    let parentID: Int64
    let order: Int64
}

/// Repository 在结构写事务内生成的撤销令牌；恢复前必须仍匹配 expectedCurrentPositions。
nonisolated struct ChapterStructureRestoreSnapshot: Hashable, Sendable {
    let bookID: Int64
    let restorePositions: [ChapterStructurePosition]
    let expectedCurrentPositions: [ChapterStructurePosition]
}

/// 手工批量目录解析错误，行号采用用户可见的一基编号。
nonisolated enum ChapterBatchImportError: LocalizedError, Hashable, Sendable {
    case emptyInput
    case exceedsMaximumDepth(lineNumber: Int)
    case cannotIncreaseMaximumDepth(lineNumber: Int)
    case missingParent(lineNumber: Int, level: Int)
    case invalidDraft

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "请先输入至少一个章节。"
        case .exceedsMaximumDepth(let lineNumber):
            return "第 \(lineNumber) 行超过 \(ChapterManagementPolicy.maximumDepth) 级目录，请减少缩进。"
        case .cannotIncreaseMaximumDepth(let lineNumber):
            return "第 \(lineNumber) 行已是第 \(ChapterManagementPolicy.maximumDepth) 级，不能继续增加层级。"
        case .missingParent(let lineNumber, let level):
            return "第 \(lineNumber) 行是第 \(level) 级目录，但前面缺少第 \(level - 1) 级父章节。"
        case .invalidDraft:
            return "目录预览已失效，请修改输入后重试。"
        }
    }
}

/// Android BatchAddChapterTextHelper 的纯值语义对齐实现。
nonisolated enum ChapterBatchImportParser {
    static let indentUnit = "\u{3000}\u{3000}"
    static let catalogImportSourceType: Int64 = 2

    /// 把“每行一个章节”的文本解析为最多五层的先序草稿，并保留同级顺序与导入元数据。
    static func parse(_ text: String) throws -> ChapterBatchImportDraft {
        var entries: [ChapterBatchImportEntry] = []
        var entryByLevel: [Int: ChapterBatchImportEntry] = [:]
        var siblingOrderByLevel: [Int: Int64] = [:]

        for (offset, rawLine) in text.components(separatedBy: "\n").enumerated() {
            let lineNumber = offset + 1
            let line = normalizeCatalogLine(rawLine)
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            let level = resolveCatalogLineLevel(line)
            guard level <= ChapterManagementPolicy.maximumDepth else {
                throw ChapterBatchImportError.exceedsMaximumDepth(lineNumber: lineNumber)
            }
            let title = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let parent = level == 1 ? nil : entryByLevel[level - 1]
            if level > 1, parent == nil {
                throw ChapterBatchImportError.missingParent(lineNumber: lineNumber, level: level)
            }

            let siblingOrder = (siblingOrderByLevel[level] ?? 0) + 1
            siblingOrderByLevel[level] = siblingOrder
            siblingOrderByLevel.keys.filter { $0 > level }.forEach {
                siblingOrderByLevel.removeValue(forKey: $0)
            }
            let pathTitles = (parent?.pathTitles ?? []) + [title]
            let entry = ChapterBatchImportEntry(
                id: lineNumber,
                sourceLineNumber: lineNumber,
                parentEntryID: parent?.id,
                title: title,
                remark: "",
                level: level,
                siblingOrder: siblingOrder,
                isImported: true,
                sourceType: catalogImportSourceType,
                sourceUID: "",
                sourceAnchor: "",
                sourceOrder: 0,
                pathTitles: pathTitles
            )
            entries.append(entry)
            entryByLevel[level] = entry
            entryByLevel.keys.filter { $0 > level }.forEach {
                entryByLevel.removeValue(forKey: $0)
            }
        }

        guard !entries.isEmpty else { throw ChapterBatchImportError.emptyInput }
        return ChapterBatchImportDraft(entries: entries)
    }

    /// 将全文句点统一为中文或英文形态；调用方负责把结果纳入文本撤销历史。
    static func normalizePeriods(in text: String, toChinese: Bool) -> String {
        toChinese
            ? text.replacingOccurrences(of: ".", with: "。")
            : text.replacingOccurrences(of: "。", with: ".")
    }

    /// 为光标所在行或连续选中行增加一个双全角缩进，选区边界与 Android EditText 一样按 UTF-16 计数。
    static func increaseIndent(
        in text: String,
        selectionLocation: Int,
        selectionLength: Int
    ) throws -> ChapterBatchIndentResult? {
        let source = text as NSString
        guard source.length > 0 else { return nil }
        let rangeStart = min(max(0, selectionLocation), source.length)
        let safeLength = min(max(0, selectionLength), source.length - rangeStart)
        let rangeEnd = rangeStart + safeLength

        var firstLineStart = rangeStart
        while firstLineStart > 0, source.character(at: firstLineStart - 1) != 0x0A {
            firstLineStart -= 1
        }

        var candidateLineStarts = [firstLineStart]
        if rangeStart != rangeEnd {
            var searchStart = firstLineStart
            while searchStart < rangeEnd {
                let searchRange = NSRange(location: searchStart, length: source.length - searchStart)
                let lineBreakRange = source.range(of: "\n", options: [], range: searchRange)
                guard lineBreakRange.location != NSNotFound else { break }
                let nextLineStart = lineBreakRange.location + lineBreakRange.length
                if nextLineStart < rangeEnd {
                    candidateLineStarts.append(nextLineStart)
                }
                searchStart = nextLineStart
            }
        }

        let targetLineStarts = candidateLineStarts.filter { lineStart in
            let remainingRange = NSRange(location: lineStart, length: source.length - lineStart)
            let lineBreakRange = source.range(of: "\n", options: [], range: remainingRange)
            let lineEnd = lineBreakRange.location == NSNotFound ? source.length : lineBreakRange.location
            let line = source.substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))
            return !normalizeCatalogLine(line).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !targetLineStarts.isEmpty else { return nil }

        for lineStart in targetLineStarts {
            let remainingRange = NSRange(location: lineStart, length: source.length - lineStart)
            let lineBreakRange = source.range(of: "\n", options: [], range: remainingRange)
            let lineEnd = lineBreakRange.location == NSNotFound ? source.length : lineBreakRange.location
            let line = normalizeCatalogLine(
                source.substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))
            )
            guard resolveCatalogLineLevel(line) < ChapterManagementPolicy.maximumDepth else {
                let precedingText = source.substring(to: lineStart)
                let lineNumber = precedingText.components(separatedBy: "\n").count
                throw ChapterBatchImportError.cannotIncreaseMaximumDepth(lineNumber: lineNumber)
            }
        }

        let mutableText = NSMutableString(string: text)
        for lineStart in targetLineStarts.reversed() {
            mutableText.insert(indentUnit, at: lineStart)
        }
        let indentLength = (indentUnit as NSString).length
        let shiftedStart = rangeStart + targetLineStarts.filter { $0 <= rangeStart }.count * indentLength
        let shiftedEnd = rangeEnd + targetLineStarts.filter { $0 <= rangeEnd }.count * indentLength
        return ChapterBatchIndentResult(
            text: mutableText as String,
            selectionLocation: shiftedStart,
            selectionLength: max(0, shiftedEnd - shiftedStart)
        )
    }

    /// 归一 OCR/复制文本中的不换行空格，并移除 Android 同样忽略的首个零宽连接符。
    private static func normalizeCatalogLine(_ line: String) -> String {
        var normalized = line.replacingOccurrences(of: "\u{00A0}", with: " ")
        if let joinerRange = normalized.range(of: "\u{200D}") {
            normalized.removeSubrange(joinerRange)
        }
        return normalized
    }

    /// 双全角空格、Tab 或双半角空格各增加一级；零散前导空格只作为对齐噪音忽略。
    private static func resolveCatalogLineLevel(_ line: String) -> Int {
        let scalars = Array(line.unicodeScalars)
        var level = 1
        var index = 0
        while index < scalars.count {
            switch scalars[index].value {
            case 0x3000 where index + 1 < scalars.count && scalars[index + 1].value == 0x3000:
                level += 1
                index += 2
            case 0x09:
                level += 1
                index += 1
            case 0x20 where index + 1 < scalars.count && scalars[index + 1].value == 0x20:
                level += 1
                index += 2
            case 0x20, 0x3000:
                index += 1
            default:
                return level
            }
        }
        return level
    }
}
