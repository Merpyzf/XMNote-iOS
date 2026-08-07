/**
 * [INPUT]: 依赖 ContentRepositoryProtocol 读取/保存书评草稿，依赖 RichTextBridge 完成 HTML 与富文本互转
 * [OUTPUT]: 对外提供 ReviewEditorViewModel，驱动书评创建/编辑页的加载与保存
 * [POS]: Content 模块书评编辑状态源，承接工作台创建与 viewer 编辑链路
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

@MainActor
@Observable
/// 书评编辑状态源，负责标题/正文富文本的加载、保存与错误反馈。
final class ReviewEditorViewModel {
    let mode: ReviewEditorMode

    var draft: ReviewEditorDraft?
    var title = ""
    var contentText = NSAttributedString()
    var activeFormats = Set<RichTextFormat>()
    var isLoading = false
    var isSaving = false
    var errorMessage: String?

    private let repository: any ContentRepositoryProtocol
    private var baselineTitle = ""
    private var baselineContentText = NSAttributedString()

    /// 注入书评创建/编辑模式与内容仓储，初始化编辑页上下文。
    init(mode: ReviewEditorMode, repository: any ContentRepositoryProtocol) {
        self.mode = mode
        self.repository = repository
    }

    var imageURLs: [String] {
        draft?.imageURLs ?? []
    }

    /// 标识当前编辑内容是否偏离最近一次加载或保存基线，用于阻止误退出。
    var hasUnsavedChanges: Bool {
        guard draft != nil else { return false }
        return title != baselineTitle || !contentText.isEqual(to: baselineContentText)
    }

    /// 加载书评草稿并转换成富文本编辑器可消费的状态。
    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            guard let draft = try await repository.fetchReviewEditorDraft(mode: mode) else {
                errorMessage = mode.isCreating ? "无法为当前书籍创建书评" : "书评不存在或已删除"
                return
            }
            self.draft = draft
            title = draft.title
            contentText = RichTextBridge.htmlToAttributed(draft.contentHTML)
            updateBaseline()
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
            let savedID = try await repository.saveReviewEditorDraft(draft)
            self.draft = ReviewEditorDraft(
                reviewId: savedID,
                sourceBookId: draft.sourceBookId,
                bookTitle: draft.bookTitle,
                title: draft.title,
                contentHTML: draft.contentHTML,
                imageURLs: draft.imageURLs
            )
            updateBaseline()
            return true
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)"
            return false
        }
    }

    /// 将当前表单状态记录为已保存基线。
    private func updateBaseline() {
        baselineTitle = title
        baselineContentText = contentText.copy() as? NSAttributedString ?? NSAttributedString()
    }
}
