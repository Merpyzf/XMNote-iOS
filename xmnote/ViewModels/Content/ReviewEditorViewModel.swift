/**
 * [INPUT]: 依赖 ContentRepositoryProtocol 读取/保存书评草稿，依赖 RichTextBridge 完成 HTML 与富文本互转
 * [OUTPUT]: 对外提供 ReviewEditorViewModel，驱动书评最小编辑页的加载与保存
 * [POS]: Content 模块书评编辑状态源，承接 viewer → editor 的最小可用编辑链路
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

@MainActor
@Observable
/// 书评编辑状态源，负责标题/正文富文本的加载、保存与错误反馈。
final class ReviewEditorViewModel {
    let reviewId: Int64

    var draft: ReviewEditorDraft?
    var title = ""
    var contentText = NSAttributedString()
    var activeFormats = Set<RichTextFormat>()
    var isLoading = false
    var isSaving = false
    var errorMessage: String?

    private let repository: any ContentRepositoryProtocol

    /// 注入书评 ID 与内容仓储，初始化编辑页上下文。
    init(reviewId: Int64, repository: any ContentRepositoryProtocol) {
        self.reviewId = reviewId
        self.repository = repository
    }

    var imageURLs: [String] {
        draft?.imageURLs ?? []
    }

    /// 加载书评草稿并转换成富文本编辑器可消费的状态。
    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            guard let draft = try await repository.fetchReviewEditorDraft(reviewId: reviewId) else {
                errorMessage = "书评不存在或已删除"
                return
            }
            self.draft = draft
            title = draft.title
            contentText = RichTextBridge.htmlToAttributed(draft.contentHTML)
        } catch {
            errorMessage = "加载失败：\(error.localizedDescription)"
        }
    }

    /// 保存当前书评标题与正文 HTML。
    func save() async -> Bool {
        guard var draft else {
            errorMessage = "书评不存在或已删除"
            return false
        }

        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        draft.title = title
        draft.contentHTML = RichTextBridge.attributedToHtml(contentText)

        do {
            try await repository.saveReviewEditorDraft(draft)
            self.draft = draft
            return true
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)"
            return false
        }
    }
}
