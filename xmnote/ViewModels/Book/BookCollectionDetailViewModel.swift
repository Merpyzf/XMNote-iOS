/**
 * [INPUT]: 依赖 BookshelfRepositoryProtocol 的书单详情观察流与 collection_book 写入能力，依赖 S3UploadRepositoryProtocol 承接书单内封面图片上传，依赖 XMCoverImageLoading 与 AppTypography 生成分享图真实封面和排版
 * [OUTPUT]: 对外提供 BookCollectionDetailViewModel，驱动书单详情、添加书籍、移除、relation 文本编辑、书籍元信息编辑与真实封面分享反馈
 * [POS]: ViewModels/Book 的书单详情状态编排器，被 BookCollectionDetailView 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Photos
import UIKit

/// 书单内 relation 文本编辑弹窗状态。
struct BookCollectionRecommendEdit: Identifiable, Hashable {
    let item: BookCollectionBookItem

    var id: Int64 { item.id }
}

/// 书单内书籍元信息编辑弹窗状态，支持有效书与占位书复用同一编辑入口。
struct BookCollectionBookMetadataEdit: Identifiable, Hashable {
    let item: BookCollectionBookItem

    var id: Int64 { item.id }
}

/// 从相册选择的封面图片数据，保存时由 ViewModel 上传后回填远端链接。
struct BookCollectionBookCoverSelection: Hashable, Sendable {
    let data: Data
    let fileExtension: String
}

/// 书单内书籍元信息编辑草稿，对齐 Android 编辑页可改字段。
struct BookCollectionBookMetadataEditDraft: Hashable, Sendable {
    let title: String
    let author: String
    let press: String
    let pubDate: String
    let coverURL: String
    let recommend: String
    let selectedCover: BookCollectionBookCoverSelection?
}

/// 书单内书籍元信息编辑的本地前置错误，避免上传能力缺失时写入半成品封面链接。
enum BookCollectionBookMetadataEditError: LocalizedError {
    case missingCoverUploadConfiguration

    var errorDescription: String? {
        switch self {
        case .missingCoverUploadConfiguration:
            return "封面上传服务暂不可用，请稍后再试"
        }
    }
}

/// 书单分享图固定画布的排版 owner，集中保留既有字号、字重与信息层级。
@MainActor
private enum BookCollectionShareImageTypography {
    private static let canvasTraits = UITraitCollection(preferredContentSizeCategory: .large)

    /// 固定分享画布的字体保持默认 Large 尺寸，避免设备辅助功能字号改变导出排版。
    private static func font(
        size: CGFloat,
        textStyle: UIFont.TextStyle,
        weight: UIFont.Weight = .regular
    ) -> UIFont {
        AppTypography.uiFixed(
            baseSize: size,
            textStyle: textStyle,
            weight: weight,
            minimumPointSize: size,
            compatibleWith: canvasTraits
        )
    }

    static var title: UIFont {
        font(size: 48, textStyle: .largeTitle, weight: .semibold)
    }

    static var subtitle: UIFont {
        font(size: 28, textStyle: .title3)
    }

    static var pageSubtitle: UIFont {
        font(size: 26, textStyle: .title3, weight: .medium)
    }

    static var pageNumber: UIFont {
        font(size: 24, textStyle: .caption1)
    }

    static var bookTitle: UIFont {
        font(size: 32, textStyle: .title2, weight: .semibold)
    }

    static var bookMetadata: UIFont {
        font(size: 23, textStyle: .subheadline)
    }

    static var rating: UIFont {
        font(size: 22, textStyle: .subheadline, weight: .semibold)
    }

    static var relationNote: UIFont {
        font(size: 22, textStyle: .body)
    }

    static var coverInitial: UIFont {
        font(size: 26, textStyle: .title3, weight: .semibold)
    }
}

/// 书单内移除书籍确认状态。
struct BookCollectionBookRemoveConfirmation: Identifiable, Hashable {
    let item: BookCollectionBookItem

    var id: Int64 { item.id }
}

/// 年度书单本体说明编辑状态，区别于单本书年度点评。
struct BookCollectionAnnualDescriptionEdit: Identifiable, Hashable {
    let detail: BookCollectionDetail

    var id: Int64 { detail.id }
}

/// 书单详情状态编排器，所有 UI 状态均在主线程更新。
@MainActor
@Observable
final class BookCollectionDetailViewModel {
    let collectionID: Int64
    var detail: BookCollectionDetail?
    var contentState: BookCollectionContentState = .loading
    var activeAction: BookCollectionPendingAction?
    var actionFeedback: BookshelfActionFeedback?
    var activeForm: BookCollectionFormPresentation?
    var recommendEdit: BookCollectionRecommendEdit?
    var metadataEdit: BookCollectionBookMetadataEdit?
    var annualDescriptionEdit: BookCollectionAnnualDescriptionEdit?
    var removeConfirmation: BookCollectionBookRemoveConfirmation?
    var deleteConfirmation: BookCollectionDeleteConfirmation?
    var generatedFile: BookCollectionGeneratedFile?
    var shouldDismissAfterDelete = false

    private let repository: any BookshelfRepositoryProtocol
    private let s3UploadRepository: (any S3UploadRepositoryProtocol)?
    private let coverImageLoader: any XMCoverImageLoading
    private var observationTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private var feedbackClearTask: Task<Void, Never>?

    var isManual: Bool {
        detail?.kind == .manual
    }

    var canEditCollection: Bool {
        isManual && activeAction == nil
    }

    /// 注入书单 ID、仓储与外部图片能力，并启动详情观察。
    init(
        collectionID: Int64,
        repository: any BookshelfRepositoryProtocol,
        s3UploadRepository: (any S3UploadRepositoryProtocol)? = nil,
        coverImageLoader: any XMCoverImageLoading
    ) {
        self.collectionID = collectionID
        self.repository = repository
        self.s3UploadRepository = s3UploadRepository
        self.coverImageLoader = coverImageLoader
        startObservation()
    }

    /// 取消详情观察与写入任务。
    isolated deinit {
        observationTask?.cancel()
        writeTask?.cancel()
        feedbackClearTask?.cancel()
    }

    /// 将 BookPicker 返回的本地、在线与手动创建结果统一加入当前手动书单。
    func addPickerResult(_ result: BookPickerResult) {
        let selections: [BookCollectionBookSelectionInput]
        switch result {
        case .cancelled, .addFlowRequested, .editorRequested:
            selections = []
        case .single(let selection):
            selections = Self.selectionInput(from: selection).map { [$0] } ?? []
        case .multiple(let selections):
            self.addBookSelections(selections.compactMap(Self.selectionInput(from:)))
            return
        }
        addBookSelections(selections)
    }

    /// 打开 relation 文本编辑弹窗。
    func presentRecommendEdit(for item: BookCollectionBookItem) {
        guard activeAction == nil else { return }
        recommendEdit = BookCollectionRecommendEdit(item: item)
    }

    /// 打开书单内书籍元信息编辑面板；占位书可在恢复前直接修正基础信息。
    func presentMetadataEdit(for item: BookCollectionBookItem) {
        guard activeAction == nil else { return }
        metadataEdit = BookCollectionBookMetadataEdit(item: item)
    }

    /// 生成书单分享图片，并打开系统分享载体。
    func shareCurrentCollectionImage() {
        guard detail != nil, activeAction == nil else { return }
        writeTask?.cancel()
        writeTask = Task { [repository, collectionID] in
            setActiveAction(.share, message: "正在加载封面并生成分享图…")
            do {
                let snapshot = try await repository.fetchBookCollectionExportSnapshot(collectionID: collectionID)
                guard !snapshot.books.isEmpty else {
                    finishAction(message: "书单里还没有可分享的书籍")
                    return
                }
                let prepared = try Self.preparedDetail(snapshot) ?? snapshot
                let result = try await makeShareImageFile(from: prepared)
                generatedFile = result.file
                finishAction(message: result.successMessage)
            } catch {
                failAction(error)
            }
        }
    }

    /// 打开书单标题与简介编辑面板；年度书单成员自动同步，不开放书单本体编辑。
    func presentEditForm() {
        guard let detail, detail.kind == .manual, activeAction == nil else { return }
        activeForm = BookCollectionFormPresentation(
            mode: .edit(listItem(from: detail))
        )
    }

    /// 打开年度书单本体说明编辑面板，不影响单本书年度点评。
    func presentAnnualDescriptionEdit() {
        guard let detail, detail.kind == .annual, activeAction == nil else { return }
        annualDescriptionEdit = BookCollectionAnnualDescriptionEdit(detail: detail)
    }

    /// 打开移除关系确认弹窗。
    func presentRemoveConfirmation(for item: BookCollectionBookItem) {
        guard isManual, activeAction == nil else { return }
        removeConfirmation = BookCollectionBookRemoveConfirmation(item: item)
    }

    /// 打开删除书单确认弹窗。
    func presentDeleteConfirmation() {
        guard let detail, detail.kind == .manual, activeAction == nil else { return }
        deleteConfirmation = BookCollectionDeleteConfirmation(item: listItem(from: detail))
    }

    /// 提交详情页书单标题与简介编辑。
    func submitForm(_ presentation: BookCollectionFormPresentation, title: String, description: String) {
        guard activeAction == nil else { return }
        guard case .edit(let item) = presentation.mode else { return }
        writeTask?.cancel()
        writeTask = Task { [repository] in
            setActiveAction(.update, message: "正在保存书单…")
            do {
                try await repository.updateBookCollection(
                    collectionID: item.id,
                    input: BookCollectionFormInput(title: title, description: description)
                )
                finishAction(message: "书单已保存")
            } catch {
                failAction(error)
            }
        }
    }

    /// 保存年度书单本体说明；标题、年份和成员仍由年度同步逻辑维护。
    func submitAnnualDescription(_ edit: BookCollectionAnnualDescriptionEdit, description: String) {
        guard activeAction == nil else { return }
        writeTask?.cancel()
        writeTask = Task { [repository] in
            setActiveAction(.update, message: "正在保存年度说明…")
            do {
                try await repository.updateAnnualBookCollectionDescription(
                    collectionID: edit.detail.id,
                    description: description
                )
                finishAction(message: "年度说明已保存")
            } catch {
                failAction(error)
            }
        }
    }

    /// 在主线程启动 relation 文本写入任务；新提交会取消上一条写入，保存成功后按调用页语义反馈收藏理由或年度点评。
    func submitRecommend(
        _ edit: BookCollectionRecommendEdit,
        recommend: String,
        savingMessage: String = "正在保存收藏理由…",
        savedMessage: String = "收藏理由已保存"
    ) {
        guard activeAction == nil else { return }
        writeTask?.cancel()
        writeTask = Task { [repository] in
            setActiveAction(.update, message: savingMessage)
            do {
                try await repository.updateCollectionBookRecommend(collectionBookID: edit.item.id, recommend: recommend)
                finishAction(message: savedMessage)
            } catch {
                failAction(error)
            }
        }
    }

    /// 保存书单内单本书籍元信息；如选择了本地封面，先上传封面再写入书籍与 relation 字段。
    func submitBookMetadata(_ edit: BookCollectionBookMetadataEdit, draft: BookCollectionBookMetadataEditDraft) {
        guard activeAction == nil else { return }
        writeTask?.cancel()
        writeTask = Task { [repository, s3UploadRepository] in
            do {
                let coverURL: String
                if let selectedCover = draft.selectedCover {
                    setActiveAction(.update, message: "正在上传封面…")
                    coverURL = try await Self.uploadSelectedCover(
                        selectedCover,
                        using: s3UploadRepository
                    )
                } else {
                    coverURL = draft.coverURL
                }

                setActiveAction(.update, message: "正在保存书籍信息…")
                try await repository.updateCollectionBookMetadata(
                    BookCollectionBookMetadataEditInput(
                        collectionBookID: edit.item.id,
                        bookID: edit.item.book.id,
                        title: draft.title,
                        author: draft.author,
                        press: draft.press,
                        pubDate: draft.pubDate,
                        coverURL: coverURL,
                        recommend: draft.recommend
                    )
                )
                finishAction(message: "书籍信息已保存")
            } catch {
                failAction(error)
            }
        }
    }

    /// 确认从书单移除单本书籍 relation。
    func confirmRemove(_ confirmation: BookCollectionBookRemoveConfirmation) {
        guard activeAction == nil else { return }
        writeTask?.cancel()
        writeTask = Task { [repository] in
            setActiveAction(.delete, message: "正在移出书籍…")
            do {
                try await repository.removeBooksFromCollection(collectionBookIDs: [confirmation.item.id])
                finishAction(message: "已移出书单")
            } catch {
                failAction(error)
            }
        }
    }

    /// 将书单占位书恢复到书架，并刷新当前书单展示状态。
    func restorePlaceholderBook(_ item: BookCollectionBookItem) {
        guard item.isPlaceholder, activeAction == nil else { return }
        writeTask?.cancel()
        writeTask = Task { [repository] in
            setActiveAction(.restore, message: "正在加入书架…")
            do {
                try await repository.restoreCollectionPlaceholderBook(bookID: item.book.id)
                finishAction(message: "已加入书架")
            } catch {
                failAction(error)
            }
        }
    }

    /// 确认删除当前手动书单。
    func confirmDelete(_ confirmation: BookCollectionDeleteConfirmation) {
        guard activeAction == nil else { return }
        writeTask?.cancel()
        writeTask = Task { [repository] in
            setActiveAction(.delete, message: "正在删除书单…")
            do {
                try await repository.deleteBookCollection(collectionID: confirmation.item.id)
                finishAction(message: "书单已删除")
                shouldDismissAfterDelete = true
            } catch {
                failAction(error)
            }
        }
    }

    /// 按拖拽后的 relation 顺序提交书单内排序。
    func submitBookOrder(_ relationIDs: [Int64]) {
        guard isManual, activeAction == nil else { return }
        writeTask?.cancel()
        writeTask = Task { [repository, collectionID] in
            setActiveAction(.reorder, message: "正在更新排序…")
            do {
                try await repository.updateBooksInCollectionOrder(collectionID: collectionID, relationIDs: relationIDs)
                finishAction(message: "排序已更新")
            } catch {
                failAction(error)
            }
        }
    }

    private func addBookSelections(_ selections: [BookCollectionBookSelectionInput]) {
        guard isManual, activeAction == nil, !selections.isEmpty else { return }
        writeTask?.cancel()
        writeTask = Task { [repository, collectionID] in
            setActiveAction(.create, message: "正在加入书单…")
            do {
                try await repository.addBookSelections(selections, toCollection: collectionID)
                finishAction(message: "已加入书单")
            } catch {
                failAction(error)
            }
        }
    }

    private func startObservation() {
        observationTask?.cancel()
        contentState = .loading
        observationTask = Task { [repository, collectionID] in
            do {
                for try await detail in repository.observeBookCollectionDetail(collectionID: collectionID) {
                    guard !Task.isCancelled else { return }
                    let preparedDetail = try await Self.preparedDetailOffMain(detail)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        self.detail = preparedDetail
                        if let preparedDetail {
                            self.contentState = preparedDetail.books.isEmpty ? .empty : .content
                        } else {
                            self.contentState = .error("未能查询到书单")
                        }
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.contentState = .error(error.localizedDescription)
                }
            }
        }
    }

    /// 在非主线程预处理书单内书籍简介纯文本；父任务取消时同步取消后台解析任务，避免列表滚动路径重复解析 HTML。
    nonisolated private static func preparedDetailOffMain(_ detail: BookCollectionDetail?) async throws -> BookCollectionDetail? {
        let task = Task.detached(priority: .userInitiated) {
            try preparedDetail(detail)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// 为书单详情生成稳定简介预览，保持主线程只接收已准备好的展示模型。
    nonisolated private static func preparedDetail(_ detail: BookCollectionDetail?) throws -> BookCollectionDetail? {
        guard let detail else { return nil }
        try Task.checkCancellation()
        let preparedBooks = try detail.books.map { item in
            try Task.checkCancellation()
            return BookCollectionBookItem(
                id: item.id,
                collectionID: item.collectionID,
                book: item.book,
                summary: item.summary,
                summaryPlainText: plainTextPreview(from: item.summary),
                recommend: item.recommend,
                isPlaceholder: item.isPlaceholder,
                order: item.order,
                createdDate: item.createdDate,
                updatedDate: item.updatedDate
            )
        }
        return BookCollectionDetail(
            id: detail.id,
            title: detail.title,
            description: detail.description,
            kind: detail.kind,
            order: detail.order,
            year: detail.year,
            targetReadCount: detail.targetReadCount,
            books: preparedBooks
        )
    }

    /// 将 Android Knife HTML 简介裁剪成列表可读纯文本，空白统一交由展示层兜底。
    nonisolated private static func plainTextPreview(from html: String) -> String {
        RichTextPlainTextExtractor.plainText(from: html)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func setActiveAction(_ action: BookCollectionPendingAction, message: String) {
        activeAction = action
        actionFeedback = BookshelfActionFeedback(kind: .processing, message: message)
    }

    private func finishAction(message: String) {
        activeAction = nil
        activeForm = nil
        recommendEdit = nil
        metadataEdit = nil
        annualDescriptionEdit = nil
        removeConfirmation = nil
        deleteConfirmation = nil
        actionFeedback = BookshelfActionFeedback(kind: .success, message: message)
        scheduleFeedbackClear()
    }

    private func failAction(_ error: Error) {
        activeAction = nil
        actionFeedback = BookshelfActionFeedback(kind: .error, message: error.localizedDescription)
        scheduleFeedbackClear()
    }

    private func scheduleFeedbackClear() {
        feedbackClearTask?.cancel()
        feedbackClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            await MainActor.run {
                guard self?.activeAction == nil else { return }
                self?.actionFeedback = nil
            }
        }
    }

    private static func selectionInput(from selection: BookPickerSelection) -> BookCollectionBookSelectionInput? {
        switch selection {
        case .local(let book):
            return .localBook(id: book.id)
        case .remote(let remoteSelection):
            return .placeholder(BookCollectionPlaceholderBookDraft(remoteSelection: remoteSelection))
        }
    }

    /// 将相册封面写入临时文件并交给 S3 仓储上传；任务取消时清理临时文件，避免残留大图。
    private static func uploadSelectedCover(
        _ selection: BookCollectionBookCoverSelection,
        using repository: (any S3UploadRepositoryProtocol)?
    ) async throws -> String {
        guard let repository else {
            throw BookCollectionBookMetadataEditError.missingCoverUploadConfiguration
        }
        try Task.checkCancellation()
        let fileExtension = selection.fileExtension.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "jpg"
            : selection.fileExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("book_collection_cover_\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
        try selection.data.write(to: url, options: .atomic)
        defer {
            try? FileManager.default.removeItem(at: url)
        }
        let result = try await repository.uploadFile(localURL: url, prefix: "book_cover", progress: nil)
        return result.remoteURL.absoluteString
    }

    private func listItem(from detail: BookCollectionDetail) -> BookCollectionListItem {
        BookCollectionListItem(
            id: detail.id,
            title: detail.title,
            description: detail.description,
            kind: detail.kind,
            order: detail.order,
            year: detail.year,
            bookCount: detail.bookCount,
            finishedCount: detail.finishedCount,
            targetReadCount: detail.targetReadCount,
            representativeCovers: detail.books.prefix(5).map(\.book.cover)
        )
    }

    private func makeShareImageFile(from detail: BookCollectionDetail) async throws -> BookCollectionShareImageBuildResult {
        let books = detail.books
        let (coverImages, fallbackCoverCount) = await loadShareCoverImages(for: books)
        let pages = Self.shareImagePages(for: books)
        let images = pages.map { page in
            Self.renderShareImage(from: detail, page: page, coverImages: coverImages)
        }
        let urls = try Self.writeShareImages(images, title: Self.displayTitle(for: detail))
        try await Self.saveImagesToPhotoLibrary(fileURLs: urls)
        let file = BookCollectionGeneratedFile(title: "分享书单", urls: urls, kind: .shareImage)
        return BookCollectionShareImageBuildResult(
            file: file,
            fallbackCoverCount: fallbackCoverCount,
            imageCount: urls.count
        )
    }

    private static let shareImageWidth: CGFloat = 1240
    private static let shareImageRowHeight: CGFloat = 168
    private static let shareImageRowsStartY: CGFloat = 316
    private static let shareImageFooterHeight: CGFloat = 76
    private static let shareImageMaximumPageHeight: CGFloat = 12_000

    private func loadShareCoverImages(
        for books: [BookCollectionBookItem]
    ) async -> ([Int64: UIImage], Int) {
        var images: [Int64: UIImage] = [:]
        var fallbackCount = 0

        for item in books {
            let cover = item.book.cover.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cover.isEmpty else { continue }
            guard let url = XMImageRequestBuilder.normalizedURL(from: cover) else {
                fallbackCount += 1
                continue
            }
            do {
                images[item.id] = try await coverImageLoader.loadImage(
                    for: XMImageLoadRequest(url: url, priority: .high)
                )
            } catch {
                fallbackCount += 1
            }
        }

        return (images, fallbackCount)
    }

    @MainActor
    private static func renderShareImage(
        from detail: BookCollectionDetail,
        page: BookCollectionShareImagePage,
        coverImages: [Int64: UIImage]
    ) -> UIImage {
        let width = shareImageWidth
        let rowHeight = shareImageRowHeight
        let height = shareImageRowsStartY + CGFloat(page.books.count) * rowHeight + shareImageFooterHeight
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        return renderer.image { context in
            let cg = context.cgContext
            UIColor.systemBackground.setFill()
            cg.fill(CGRect(x: 0, y: 0, width: width, height: height))
            UIColor.secondarySystemBackground.setFill()
            UIBezierPath(roundedRect: CGRect(x: 56, y: 56, width: width - 112, height: height - 112), cornerRadius: 44).fill()

            draw(displayTitle(for: detail), at: CGPoint(x: 104, y: 104), width: width - 208, font: BookCollectionShareImageTypography.title, color: .label)
            let subtitle = detail.description.trimmingCharacters(in: .whitespacesAndNewlines)
            if !subtitle.isEmpty {
                draw(subtitle, at: CGPoint(x: 104, y: 174), width: width - 208, font: BookCollectionShareImageTypography.subtitle, color: .secondaryLabel)
            }
            draw(page.subtitle(for: detail), at: CGPoint(x: 104, y: 244), width: width - 208, font: BookCollectionShareImageTypography.pageSubtitle, color: .secondaryLabel)

            var y = shareImageRowsStartY
            for item in page.books {
                drawBookRow(
                    item,
                    detailKind: detail.kind,
                    coverImage: coverImages[item.id],
                    atY: y,
                    width: width
                )
                y += rowHeight
            }
            if page.pageCount > 1 {
                draw("第 \(page.pageIndex + 1) / \(page.pageCount) 页", at: CGPoint(x: 104, y: y + 16), width: width - 208, font: BookCollectionShareImageTypography.pageNumber, color: .tertiaryLabel)
            }
        }
    }

    private static func shareImagePages(
        for books: [BookCollectionBookItem]
    ) -> [BookCollectionShareImagePage] {
        let availableHeight = shareImageMaximumPageHeight - shareImageRowsStartY - shareImageFooterHeight
        let rowsPerPage = max(1, Int(floor(availableHeight / shareImageRowHeight)))
        let chunks = stride(from: 0, to: books.count, by: rowsPerPage).map { startIndex in
            Array(books[startIndex..<min(startIndex + rowsPerPage, books.count)])
        }
        let pageCount = max(1, chunks.count)
        return chunks.enumerated().map { index, books in
            BookCollectionShareImagePage(
                books: books,
                pageIndex: index,
                pageCount: pageCount
            )
        }
    }

    private static func writeShareImages(
        _ images: [UIImage],
        title: String
    ) throws -> [URL] {
        var urls: [URL] = []
        let safeTitle = safeFileName(title)
        for (index, image) in images.enumerated() {
            guard let data = image.pngData() else {
                throw BookCollectionShareImageError.imageEncodingFailed
            }
            let suffix = images.count == 1 ? "" : "-\(String(format: "%02d", index + 1))"
            let fileName = "\(safeTitle)-书单分享图\(suffix).png"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
            try data.write(to: url, options: .atomic)
            urls.append(url)
        }
        return urls
    }

    @MainActor
    private static func drawBookRow(
        _ item: BookCollectionBookItem,
        detailKind: BookCollectionKind,
        coverImage: UIImage?,
        atY y: CGFloat,
        width: CGFloat
    ) {
        let coverRect = CGRect(x: 104, y: y, width: 76, height: 112)
        drawCover(coverImage, title: item.book.title, in: coverRect)

        let textX = coverRect.maxX + 32
        let titleWidth = width - textX - 104
        draw(
            item.book.title.isEmpty ? "未命名书籍" : item.book.title,
            at: CGPoint(x: textX, y: y + 2),
            width: titleWidth,
            font: BookCollectionShareImageTypography.bookTitle,
            color: .label,
            maxLines: 1
        )

        var metadataY = y + 44
        let bookInfo = bookInfoLine(for: item.book)
        if !bookInfo.isEmpty {
            draw(
                bookInfo,
                at: CGPoint(x: textX, y: metadataY),
                width: titleWidth,
                font: BookCollectionShareImageTypography.bookMetadata,
                color: .secondaryLabel,
                maxLines: 1
            )
            metadataY += 31
        }
        if item.book.score > 0 {
            draw(
                "评分 \(ratingText(for: item.book.score))",
                at: CGPoint(x: textX, y: metadataY),
                width: titleWidth,
                font: BookCollectionShareImageTypography.rating,
                color: UIColor.xmSRGB(red: 1, green: 197.0 / 255.0, blue: 0, alpha: 1),
                maxLines: 1
            )
            metadataY += 31
        }
        let note = item.recommend.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty {
            draw(
                "\(relationNoteTitle(for: detailKind))：\(note)",
                at: CGPoint(x: textX, y: metadataY),
                width: titleWidth,
                font: BookCollectionShareImageTypography.relationNote,
                color: .secondaryLabel,
                maxLines: 2
            )
        }
    }

    @MainActor
    private static func drawCover(_ image: UIImage?, title: String, in rect: CGRect) {
        let path = UIBezierPath(roundedRect: rect, cornerRadius: 12)
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        path.addClip()
        if let image, image.size.width > 0, image.size.height > 0 {
            drawAspectFill(image, in: rect)
        } else {
            UIColor.systemBackground.setFill()
            UIRectFill(rect)
            let initial = String((title.first ?? Character("书")))
            draw(
                initial,
                at: CGPoint(x: rect.minX + 18, y: rect.minY + 36),
                width: 40,
                font: BookCollectionShareImageTypography.coverInitial,
                color: .secondaryLabel,
                maxLines: 1
            )
        }
        context.restoreGState()
        UIColor.separator.setStroke()
        path.stroke()
    }

    @MainActor
    private static func drawAspectFill(_ image: UIImage, in rect: CGRect) {
        let scale = max(rect.width / image.size.width, rect.height / image.size.height)
        let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let drawOrigin = CGPoint(
            x: rect.midX - drawSize.width / 2,
            y: rect.midY - drawSize.height / 2
        )
        image.draw(in: CGRect(origin: drawOrigin, size: drawSize))
    }

    @MainActor
    private static func draw(
        _ text: String,
        at origin: CGPoint,
        width: CGFloat,
        font: UIFont,
        color: UIColor,
        maxLines: Int = 2
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        (text as NSString).draw(
            with: CGRect(
                x: origin.x,
                y: origin.y,
                width: width,
                height: font.lineHeight * CGFloat(maxLines) * 1.15
            ),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: attributes,
            context: nil
        )
    }

    private static func bookInfoLine(for book: BookshelfBookListItem) -> String {
        [
            book.author,
            book.press,
            book.pubDateText
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: " / ")
    }

    private static func ratingText(for score: Int64) -> String {
        String(format: "%.1f", Double(score) / 10.0)
    }

    private static func saveImagesToPhotoLibrary(fileURLs: [URL]) async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let resolvedStatus: PHAuthorizationStatus
        if status == .notDetermined {
            resolvedStatus = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        } else {
            resolvedStatus = status
        }

        guard resolvedStatus == .authorized || resolvedStatus == .limited else {
            throw BookCollectionShareImageError.photoLibraryPermissionDenied
        }

        try await PHPhotoLibrary.shared().performChanges {
            for fileURL in fileURLs {
                PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: fileURL)
            }
        }
    }

    private static func displayTitle(for detail: BookCollectionDetail) -> String {
        let title = detail.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.kind == .annual, title.isEmpty, let year = detail.year {
            return "\(year) 年阅读"
        }
        return title.isEmpty ? "未命名书单" : title
    }

    private static func relationNoteTitle(for kind: BookCollectionKind) -> String {
        kind == .annual ? "年度点评" : "收藏理由"
    }

    private static func safeFileName(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        return value
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum BookCollectionShareImageError: LocalizedError {
    case imageEncodingFailed
    case photoLibraryPermissionDenied

    var errorDescription: String? {
        switch self {
        case .imageEncodingFailed:
            return "分享图生成失败，请稍后重试"
        case .photoLibraryPermissionDenied:
            return "没有相册写入权限，无法保存分享图"
        }
    }
}

private struct BookCollectionShareImageBuildResult {
    let file: BookCollectionGeneratedFile
    let fallbackCoverCount: Int
    let imageCount: Int

    var successMessage: String {
        let imageCountText = imageCount > 1 ? "分享图已保存为 \(imageCount) 张并写入相册" : "分享图已保存到相册"
        if fallbackCoverCount > 0 {
            return "\(imageCountText)，部分封面使用占位图"
        }
        return imageCountText
    }
}

private struct BookCollectionShareImagePage {
    let books: [BookCollectionBookItem]
    let pageIndex: Int
    let pageCount: Int

    func subtitle(for detail: BookCollectionDetail) -> String {
        let base = "收录 \(detail.bookCount) 本 · 已读 \(detail.finishedCount) 本"
        guard pageCount > 1 else { return base }
        return "\(base) · 第 \(pageIndex + 1) / \(pageCount) 页"
    }
}
