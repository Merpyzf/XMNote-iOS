/**
 * [INPUT]: 依赖 ContentRepositoryProtocol 读取/保存相关内容草稿，依赖 RichTextBridge 完成 HTML 与富文本互转
 * [OUTPUT]: 对外提供 RelevantEditorViewModel，驱动相关内容最小编辑页的加载与保存
 * [POS]: Content 模块相关内容编辑状态源，承接 viewer → editor 的最小可用编辑链路
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

@MainActor
@Observable
/// 相关内容编辑状态源，负责标题/正文/URL 的加载、保存与错误反馈。
final class RelevantEditorViewModel {
    let contentId: Int64

    var draft: RelevantEditorDraft?
    var title = ""
    var url = ""
    var contentText = NSAttributedString()
    var activeFormats = Set<RichTextFormat>()
    var isLoading = false
    var isSaving = false
    var errorMessage: String?

    private let repository: any ContentRepositoryProtocol

    /// 注入相关内容 ID 与内容仓储，初始化编辑页上下文。
    init(contentId: Int64, repository: any ContentRepositoryProtocol) {
        self.contentId = contentId
        self.repository = repository
    }

    var imageURLs: [String] {
        draft?.imageURLs ?? []
    }

    /// 加载相关内容草稿并转换成编辑器可消费的状态。
    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            guard let draft = try await repository.fetchRelevantEditorDraft(contentId: contentId) else {
                errorMessage = "相关内容不存在或已删除"
                return
            }
            self.draft = draft
            title = draft.title
            url = draft.url
            contentText = RichTextBridge.htmlToAttributed(draft.contentHTML)
        } catch {
            errorMessage = "加载失败：\(error.localizedDescription)"
        }
    }

    /// 保存当前相关内容标题、正文 HTML 与链接。
    func save() async -> Bool {
        guard var draft else {
            errorMessage = "相关内容不存在或已删除"
            return false
        }

        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        draft.title = title
        draft.url = url
        draft.contentHTML = RichTextBridge.attributedToHtml(contentText)

        do {
            try await repository.saveRelevantEditorDraft(draft)
            self.draft = draft
            return true
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)"
            return false
        }
    }
}
