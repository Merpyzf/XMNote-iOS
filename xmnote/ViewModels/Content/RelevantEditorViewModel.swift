/**
 * [INPUT]: 依赖 ContentRepositoryProtocol 读取/保存相关内容草稿，依赖 RichTextBridge 完成 HTML 与富文本互转
 * [OUTPUT]: 对外提供 RelevantEditorViewModel，驱动相关内容创建/编辑页的加载与保存
 * [POS]: Content 模块相关内容编辑状态源，承接工作台创建与 viewer 编辑链路
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

@MainActor
@Observable
/// 相关内容编辑状态源，负责标题/正文/URL 的加载、保存与错误反馈。
final class RelevantEditorViewModel {
    let mode: RelevantEditorMode

    var draft: RelevantEditorDraft?
    var title = ""
    var url = ""
    var contentText = NSAttributedString()
    var activeFormats = Set<RichTextFormat>()
    var isLoading = false
    var isSaving = false
    var errorMessage: String?

    private let repository: any ContentRepositoryProtocol
    private var baselineTitle = ""
    private var baselineURL = ""
    private var baselineContentText = NSAttributedString()

    /// 注入相关内容创建/编辑模式与内容仓储，初始化编辑页上下文。
    init(mode: RelevantEditorMode, repository: any ContentRepositoryProtocol) {
        self.mode = mode
        self.repository = repository
    }

    var imageURLs: [String] {
        draft?.imageURLs ?? []
    }

    /// 标识当前编辑内容是否偏离最近一次加载或保存基线，用于阻止误退出。
    var hasUnsavedChanges: Bool {
        guard draft != nil else { return false }
        return title != baselineTitle
            || url != baselineURL
            || !contentText.isEqual(to: baselineContentText)
    }

    /// 加载相关内容草稿并转换成编辑器可消费的状态。
    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            guard let draft = try await repository.fetchRelevantEditorDraft(mode: mode) else {
                errorMessage = mode.isCreating ? "无法在当前分类创建相关内容" : "相关内容不存在或已删除"
                return
            }
            self.draft = draft
            title = draft.title
            url = draft.url
            contentText = RichTextBridge.htmlToAttributed(draft.contentHTML)
            updateBaseline()
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
            let savedID = try await repository.saveRelevantEditorDraft(draft)
            self.draft = RelevantEditorDraft(
                contentId: savedID,
                sourceBookId: draft.sourceBookId,
                categoryId: draft.categoryId,
                bookTitle: draft.bookTitle,
                categoryTitle: draft.categoryTitle,
                title: draft.title,
                contentHTML: draft.contentHTML,
                url: draft.url,
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
        baselineURL = url
        baselineContentText = contentText.copy() as? NSAttributedString ?? NSAttributedString()
    }
}
