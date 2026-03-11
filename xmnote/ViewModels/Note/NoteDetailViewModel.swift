import Foundation
import UIKit

/**
 * [INPUT]: 依赖 NoteRepositoryProtocol 读写笔记详情，依赖 RichTextBridge 做 HTML <-> 富文本转换
 * [OUTPUT]: 对外提供 NoteDetailViewModel 与 Metadata，驱动详情页加载/编辑/保存状态
 * [POS]: Note 模块笔记详情状态编排器，被 NoteDetailView 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

@MainActor
@Observable
/// 笔记详情状态源，负责详情加载、富文本编辑态与保存流程。
class NoteDetailViewModel {
    /// 笔记元信息，供详情页底部展示位置与创建时间。
    struct Metadata {
        let position: String
        let positionUnit: Int64
        let includeTime: Bool
        let createdDate: Int64

        var footerText: String {
            var parts: [String] = []
            if !position.isEmpty {
                let unit = switch positionUnit {
                case 1: "位置"
                case 2: "%"
                default: "页"
                }
                parts.append(positionUnit == 2 ? "\(position)\(unit)" : "第\(position)\(unit)")
            }
            if includeTime, createdDate > 0 {
                parts.append(Self.formatDate(createdDate))
            }
            return parts.joined(separator: " | ")
        }

        private static func formatDate(_ timestamp: Int64) -> String {
            let date = Date(timeIntervalSince1970: Double(timestamp) / 1000.0)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy/MM/dd"
            return formatter.string(from: date)
        }
    }

    let noteId: Int64

    var contentText = NSAttributedString()
    var ideaText = NSAttributedString()
    var contentFormats = Set<RichTextFormat>()
    var ideaFormats = Set<RichTextFormat>()
    var selectedHighlightARGB: UInt32 = HighlightColors.defaultHighlightColor

    var metadata: Metadata?
    var isLoading = false
    var isSaving = false
    var errorMessage: String?

    private let repository: any NoteRepositoryProtocol

    /// 注入笔记 ID 与仓储，初始化详情编辑数据。
    init(noteId: Int64, repository: any NoteRepositoryProtocol) {
        self.noteId = noteId
        self.repository = repository
    }

    /// 加载笔记详情并转换为富文本编辑器可消费的数据结构。
    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let payload = try await repository.fetchNoteDetail(noteId: noteId)
            guard let payload else {
                errorMessage = "笔记不存在或已删除"
                return
            }

            contentText = RichTextBridge.htmlToAttributed(payload.contentHTML)
            ideaText = RichTextBridge.htmlToAttributed(payload.ideaHTML)
            metadata = Metadata(
                position: payload.position,
                positionUnit: payload.positionUnit,
                includeTime: payload.includeTime,
                createdDate: payload.createdDate
            )
        } catch {
            errorMessage = "加载失败：\(error.localizedDescription)"
        }
    }

    /// 将当前编辑内容序列化为 HTML 并提交保存。
    func save() async -> Bool {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        let contentHTML = RichTextBridge.attributedToHtml(contentText)
        let ideaHTML = RichTextBridge.attributedToHtml(ideaText)

        do {
            try await repository.saveNoteDetail(
                noteId: noteId,
                contentHTML: contentHTML,
                ideaHTML: ideaHTML
            )
            return true
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)"
            return false
        }
    }
}
