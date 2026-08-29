import Foundation
import UIKit

/**
 * [INPUT]: 依赖 NoteRepositoryProtocol 读写笔记详情，依赖 RichTextBridge 做 HTML <-> 富文本转换
 * [OUTPUT]: 对外提供 NoteDetailViewModel、NoteDetailLoadState 与 Metadata，驱动详情页加载/编辑/保存状态
 * [POS]: Note 模块笔记详情状态编排器，被 NoteDetailView 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 笔记详情的读取阶段，区分内容失效与可恢复失败，避免未加载数据被误当成空编辑器。
enum NoteDetailLoadState: Equatable {
    case idle
    case loading
    case content
    case missing
    case failure(String)
}

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
            if let positionText = NotePositionUnitFormatter.footerText(position: position, unit: positionUnit) {
                parts.append(positionText)
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
    private(set) var loadState: NoteDetailLoadState = .idle
    var isSaving = false
    private(set) var saveErrorMessage: String?

    private let repository: any NoteRepositoryProtocol

    /// 注入笔记 ID 与仓储，初始化详情编辑数据。
    init(noteId: Int64, repository: any NoteRepositoryProtocol) {
        self.noteId = noteId
        self.repository = repository
    }

    var isLoading: Bool { loadState == .loading }

    /// 加载笔记详情并转换为富文本编辑器可消费的数据结构。
    func load() async {
        guard !isLoading else { return }
        loadState = .loading
        saveErrorMessage = nil

        do {
            let payload = try await repository.fetchNoteDetail(noteId: noteId)
            guard let payload else {
                clearLoadedContent()
                loadState = .missing
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
            loadState = .content
        } catch {
            clearLoadedContent()
            loadState = .failure("暂时无法加载笔记")
        }
    }

    /// 将当前编辑内容序列化为 HTML 并提交保存。
    func save() async -> Bool {
        isSaving = true
        saveErrorMessage = nil
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
            saveErrorMessage = "笔记保存失败"
            return false
        }
    }

    private func clearLoadedContent() {
        contentText = NSAttributedString()
        ideaText = NSAttributedString()
        metadata = nil
    }
}
