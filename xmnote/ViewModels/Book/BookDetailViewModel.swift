//
//  BookDetailViewModel.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/12.
//

import Foundation
#if DEBUG
import os
#endif

/**
 * [INPUT]: 依赖 BookDetailRepositoryProtocol 提供书籍详情与四域观察流，依赖 ContentRepositoryProtocol 提供排序/分类/相关写入，依赖 ReadCalendarColorRepositoryProtocol 提取克制头部色彩
 * [OUTPUT]: 对外提供 BookDetailViewModel，输出 book、目录、书摘、相关、书评、分类、持久化排序、头部色彩及可显式启停的观察与写入生命周期
 * [POS]: Book 模块单书内容工作台状态编排器，被 BookDetailView 与阅读详情页消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

// MARK: - BookDetailViewModel

/// 标识一条书摘已完成纯文本派生时对应的源内容，避免数据库无关字段更新后重复解析 HTML。
nonisolated private struct BookNoteContentSignature: Hashable, Sendable {
    let content: String
    let idea: String
}

/// 单书内容工作台状态源，负责资料与四域内容订阅；所有 UI 状态均在主线程更新。
@MainActor
@Observable
final class BookDetailViewModel {
#if DEBUG
    private static let notesLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "xmnote",
        category: "BookWorkspaceNotes"
    )
#endif

    var book: BookDetail?
    var notes: [NoteExcerpt] = []
    var notesLoadState: BookNotesLoadState = .loading
    var loadedNotesCount: Int?
    var relatedCategories: [BookRelatedCategory] = []
    var related: [BookRelatedExcerpt] = []
    var reviews: [BookReviewExcerpt] = []
    var headerTintRGBAHex: UInt32?
    var errorMessage: String?
    var workspace: BookContentWorkspaceSnapshot = .empty
    var isWorkspaceLoading = true
    var workspaceErrorMessage: String?
    var isWorkspaceWriting = false
    var workspaceActionErrorMessage: String?
    private(set) var isRatingWriting = false

    private let bookId: Int64
    private let repository: any BookDetailRepositoryProtocol
    private let contentRepository: any ContentRepositoryProtocol
    private let colorRepository: any ReadCalendarColorRepositoryProtocol
    private var observationTasks: [Task<Void, Never>] = []
    private var notesPreparationTask: Task<Void, Never>?
    private var notesPreparationRevision: UInt64 = 0
    private var preparedNoteSignatures: [Int64: BookNoteContentSignature] = [:]
    private var colorTask: Task<Void, Never>?
    private var resolvedColorSignature: String?
    private var workspaceTask: Task<Void, Never>?
    private var workspaceWriteTask: Task<Void, Never>?

    /// 注入目标书籍 ID、内容仓储与封面取色仓储，初始化工作台数据观察。
    init(
        bookId: Int64,
        repository: any BookDetailRepositoryProtocol,
        contentRepository: any ContentRepositoryProtocol,
        colorRepository: any ReadCalendarColorRepositoryProtocol
    ) {
        self.bookId = bookId
        self.repository = repository
        self.contentRepository = contentRepository
        self.colorRepository = colorRepository
    }

    var hasNotes: Bool { !notes.isEmpty }

    /// 建立详情、书摘、相关分类、相关内容与书评观察任务；取消页面任务时所有子流同步结束。
    func startObservation() {
        guard observationTasks.isEmpty else { return }
        observationTasks = [
            Task { await observeDetail() },
            Task { await observeNotes() },
            Task { await observeRelatedCategories() },
            Task { await observeRelated() },
            Task { await observeReviews() }
        ]
        startWorkspaceObservation()
    }

    /// 停止当前页面建立的全部观察与展示派生；重复调用安全，重新出现时可再次启动。
    func stopObservation() {
        observationTasks.forEach { $0.cancel() }
        observationTasks.removeAll()
        workspaceTask?.cancel()
        workspaceTask = nil
        workspaceWriteTask?.cancel()
        workspaceWriteTask = nil
        isWorkspaceWriting = false

        notesPreparationRevision &+= 1
        if notesPreparationTask != nil {
#if DEBUG
            Self.notesLogger.debug(
                "[book.workspace.notes.projection.cancel.requested] bookID=\(self.bookId) revision=\(self.notesPreparationRevision)"
            )
#endif
        }
        notesPreparationTask?.cancel()
        notesPreparationTask = nil

        colorTask?.cancel()
        colorTask = nil
        resolvedColorSignature = nil
    }

    /// 更新当前书籍评分；写入期间拒绝重复提交，成功结果由详情观察流刷新。
    func updateBookRating(score: Int64) async throws {
        guard !isRatingWriting else { throw BookDetailRatingError.operationInProgress }
        isRatingWriting = true
        defer { isRatingWriting = false }
        try await repository.updateBookRating(bookId: bookId, score: score)
        try Task.checkCancellation()
    }

    /// 添加一本有效本地书作为当前书籍的相关书。
    func addRelatedBook(bookID relatedBookID: Int64) {
        let repository = contentRepository
        let sourceBookID = bookId
        performWorkspaceWrite {
            try await repository.addRelatedBook(sourceBookID: sourceBookID, relatedBookID: relatedBookID)
        }
    }

    /// 将在线候选保存为引用占位书并建立相关关系，不改变有效书架集合。
    func addRelatedBook(remoteSelection: BookPickerRemoteSelection) {
        let repository = contentRepository
        let sourceBookID = bookId
        let seed = remoteSelection.seed
        performWorkspaceWrite {
            try await repository.addRelatedBookPlaceholder(sourceBookID: sourceBookID, seed: seed)
        }
    }

    /// 将相关书占位记录恢复到有效书架。
    func restoreRelatedBookPlaceholder(bookID: Int64) {
        let repository = contentRepository
        performWorkspaceWrite {
            try await repository.restoreRelatedBookPlaceholder(bookID: bookID)
        }
    }

    /// 按 Android 软删除语义移除一条普通相关内容或相关书籍关系。
    func deleteRelatedRelation(relationID: Int64) {
        let repository = contentRepository
        performWorkspaceWrite {
            try await repository.deleteRelatedRelation(relationID: relationID)
        }
    }

    /// 软删除指定书评及其附图，结果由书评观察流从当前工作台移除。
    func deleteReview(reviewID: Int64) {
        let repository = contentRepository
        performWorkspaceWrite {
            try await repository.delete(itemID: .review(reviewID))
        }
    }

    /// 读取相关书籍关系编辑草稿；读取任务由调用方持有并响应页面取消。
    func fetchRelatedBookRelationDraft(relationID: Int64) async throws -> RelatedBookRelationDraft? {
        try await contentRepository.fetchRelatedBookRelationDraft(relationID: relationID)
    }

    /// 保存相关书籍关系并维持写入门闩；失败由编辑 Sheet 原位展示，不吞掉错误。
    func saveRelatedBookRelationDraft(_ draft: RelatedBookRelationDraft) async throws {
        guard !isWorkspaceWriting else { throw BookDetailWorkspaceError.operationInProgress }
        isWorkspaceWriting = true
        defer { isWorkspaceWriting = false }
        try await contentRepository.saveRelatedBookRelationDraft(draft)
        try Task.checkCancellation()
    }

    /// 新建当前书私有或全部书共享的相关分类。
    func createRelatedCategory(title: String, scope: BookContentCategoryScope) {
        let repository = contentRepository
        let sourceBookID = bookId
        performWorkspaceWrite {
            try await repository.createBookRelatedCategory(bookID: sourceBookID, title: title, scope: scope)
        }
    }

    /// 重命名当前书可管理的相关分类。
    func renameRelatedCategory(categoryID: Int64, title: String) {
        let repository = contentRepository
        let sourceBookID = bookId
        performWorkspaceWrite {
            try await repository.renameBookRelatedCategory(bookID: sourceBookID, categoryID: categoryID, title: title)
        }
    }

    /// 删除当前书可管理的相关分类及其关联内容。
    func deleteRelatedCategory(categoryID: Int64) {
        let repository = contentRepository
        let sourceBookID = bookId
        performWorkspaceWrite {
            try await repository.deleteBookRelatedCategory(bookID: sourceBookID, categoryID: categoryID)
        }
    }

    /// 切换固定默认分类的全局隐藏状态。
    func setDefaultRelatedCategoryHidden(categoryID: Int64, isHidden: Bool) {
        let repository = contentRepository
        performWorkspaceWrite {
            try await repository.setDefaultBookRelatedCategoryHidden(categoryID: categoryID, isHidden: isHidden)
        }
    }

    /// 按管理页最终顺序写入相关分类排序。
    func reorderRelatedCategories(categoryIDs: [Int64]) {
        let repository = contentRepository
        let sourceBookID = bookId
        performWorkspaceWrite {
            try await repository.updateBookRelatedCategoryOrder(bookID: sourceBookID, categoryIDs: categoryIDs)
        }
    }

    /// 写入当前书指定内容类型的唯一持久化排序规则。
    func updateContentSort(type: BookContentSortType, rule: BookContentSortRule) {
        guard workspace.sortPreferences.rule(for: type) != rule else { return }
        let repository = contentRepository
        let sourceBookID = bookId
        performWorkspaceWrite {
            try await repository.updateBookContentSortRule(bookID: sourceBookID, type: type, rule: rule)
        }
    }

    /// 清除已展示的工作区写入错误。
    func consumeWorkspaceActionError() {
        workspaceActionErrorMessage = nil
    }

    /// 串行执行单个工作区写操作；页面离场取消任务，避免旧结果回写新现场。
    private func performWorkspaceWrite(_ operation: @escaping () async throws -> Void) {
        guard !isWorkspaceWriting else { return }
        workspaceActionErrorMessage = nil
        isWorkspaceWriting = true
        workspaceWriteTask = Task { [weak self] in
            defer {
                self?.isWorkspaceWriting = false
                self?.workspaceWriteTask = nil
            }
            do {
                try await operation()
            } catch is CancellationError {
                return
            } catch {
                self?.workspaceActionErrorMessage = error.localizedDescription
            }
        }
    }

    /// 观察内容工作区元数据，向原生展示壳提供持久化排序与分类管理真值。
    private func startWorkspaceObservation() {
        guard workspaceTask == nil else { return }
        isWorkspaceLoading = true
        workspaceErrorMessage = nil
        let stream = contentRepository.observeBookContentWorkspace(bookID: bookId)
        workspaceTask = Task { [weak self] in
            do {
                for try await snapshot in stream {
                    guard !Task.isCancelled else { return }
                    self?.workspace = snapshot
                    self?.workspaceErrorMessage = nil
                    self?.isWorkspaceLoading = false
                }
            } catch is CancellationError {
                return
            } catch {
                self?.workspaceErrorMessage = error.localizedDescription
                self?.isWorkspaceLoading = false
                self?.workspaceTask = nil
            }
        }
    }

    /// 订阅书籍身份与阅读状态，并在封面变化时重新提取低饱和头部基色。
    private func observeDetail() async {
        do {
            for try await detail in repository.observeBookDetail(bookId: bookId) {
                guard !Task.isCancelled else { return }
                let preparedBook = try await Self.preparedBookOffMain(detail)
                guard !Task.isCancelled else { return }
                self.book = preparedBook
                resolveHeaderTintIfNeeded(for: preparedBook)
            }
        } catch is CancellationError {
            return
        } catch {
            recordObservationError(error)
        }
    }

    /// 订阅章节化书摘；数据库首值立即结束 loading，纯文本仅作为可取消的后续展示派生。
    private func observeNotes() async {
        var didReceiveValue = false

        do {
            for try await items in repository.observeBookNotes(bookId: bookId) {
                guard !Task.isCancelled else { return }
                let isFirstValue = !didReceiveValue
                didReceiveValue = true
#if DEBUG
                if isFirstValue {
                    Self.notesLogger.debug(
                        "[book.workspace.notes.stream.first] bookID=\(self.bookId) count=\(items.count)"
                    )
                }
#endif
                acceptLoadedNotes(items)
            }

            guard didReceiveValue || Task.isCancelled else {
                notesLoadState = .failed
                errorMessage = "部分内容加载失败：书摘数据流未返回内容。"
#if DEBUG
                Self.notesLogger.error(
                    "[book.workspace.notes.stream.finished_without_value] bookID=\(self.bookId)"
                )
#endif
                return
            }
        } catch is CancellationError {
            return
        } catch {
            notesLoadState = .failed
#if DEBUG
            Self.notesLogger.error(
                "[book.workspace.notes.stream.failed] bookID=\(self.bookId) error=\(error.localizedDescription, privacy: .public)"
            )
#endif
            recordObservationError(error)
        }
    }

    /// 立即提交 Repository 真值，并为新增或内容发生变化的条目启动独立纯文本派生。
    private func acceptLoadedNotes(_ items: [NoteExcerpt]) {
        notesPreparationTask?.cancel()
        notesPreparationTask = nil
        notesPreparationRevision &+= 1
        let revision = notesPreparationRevision

        let validIDs = Set(items.map(\.id))
        preparedNoteSignatures = preparedNoteSignatures.filter { validIDs.contains($0.key) }

        let previousByID = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
        var pendingItems: [NoteExcerpt] = []
        let immediatelyVisibleItems = items.map { item in
            let signature = Self.contentSignature(for: item)
            guard preparedNoteSignatures[item.id] == signature,
                  let previous = previousByID[item.id] else {
                pendingItems.append(item)
                return item
            }
            return Self.copyingPlainText(from: previous, to: item)
        }

        applyLoadedNotes(immediatelyVisibleItems)
#if DEBUG
        Self.notesLogger.debug(
            "[book.workspace.notes.raw.committed] bookID=\(self.bookId) count=\(immediatelyVisibleItems.count) pending=\(pendingItems.count) revision=\(revision)"
        )
#endif
        scheduleNotesPreparation(pendingItems, revision: revision)
    }

    /// 在主线程一次性提交书摘数组与其加载阶段，避免列表把初始空数组误判成真实空态。
    private func applyLoadedNotes(_ items: [NoteExcerpt]) {
        notes = items
        loadedNotesCount = items.count
        notesLoadState = .loaded
    }

    /// 派生待处理书摘的纯文本；只允许最新 revision 回写，失败不会逆转已完成的数据加载状态。
    private func scheduleNotesPreparation(_ items: [NoteExcerpt], revision: UInt64) {
        guard !items.isEmpty else { return }
        let bookID = bookId
#if DEBUG
        Self.notesLogger.debug(
            "[book.workspace.notes.projection.started] bookID=\(bookID) count=\(items.count) revision=\(revision)"
        )
#endif
        notesPreparationTask = Task { [weak self] in
            do {
                let preparedItems = try await Self.preparedNotesOffMain(items)
                guard !Task.isCancelled else { throw CancellationError() }
                guard let self else { return }
                guard self.notesPreparationRevision == revision else {
#if DEBUG
                    Self.notesLogger.debug(
                        "[book.workspace.notes.projection.discarded] bookID=\(bookID) revision=\(revision) current=\(self.notesPreparationRevision)"
                    )
#endif
                    return
                }
                self.applyPreparedNotes(preparedItems)
                self.notesPreparationTask = nil
#if DEBUG
                Self.notesLogger.debug(
                    "[book.workspace.notes.projection.completed] bookID=\(bookID) count=\(preparedItems.count) revision=\(revision)"
                )
#endif
            } catch is CancellationError {
#if DEBUG
                Self.notesLogger.debug(
                    "[book.workspace.notes.projection.cancelled] bookID=\(bookID) revision=\(revision)"
                )
#endif
            } catch {
#if DEBUG
                Self.notesLogger.error(
                    "[book.workspace.notes.projection.failed] bookID=\(bookID) revision=\(revision) error=\(error.localizedDescription, privacy: .public)"
                )
#endif
            }
        }
    }

    /// 将纯文本结果合并进当前同 revision 列表，保持条目身份与顺序不变。
    private func applyPreparedNotes(_ preparedItems: [NoteExcerpt]) {
        let preparedByID = Dictionary(uniqueKeysWithValues: preparedItems.map { ($0.id, $0) })
        notes = notes.map { preparedByID[$0.id] ?? $0 }
        for item in preparedItems {
            preparedNoteSignatures[item.id] = Self.contentSignature(for: item)
        }
    }

    /// 订阅相关分类，供工作台筛选与创建前分类选择使用。
    private func observeRelatedCategories() async {
        do {
            for try await items in repository.observeBookRelatedCategories(bookId: bookId) {
                guard !Task.isCancelled else { return }
                relatedCategories = items
            }
        } catch is CancellationError {
            return
        } catch {
            recordObservationError(error)
        }
    }

    /// 订阅相关内容并在后台生成普通相关笔记的稳定纯文本预览。
    private func observeRelated() async {
        do {
            for try await items in repository.observeBookRelated(bookId: bookId) {
                guard !Task.isCancelled else { return }
                let preparedItems = try await Self.preparedRelatedOffMain(items)
                guard !Task.isCancelled else { return }
                related = preparedItems
            }
        } catch is CancellationError {
            return
        } catch {
            recordObservationError(error)
        }
    }

    /// 订阅书评并在后台生成正文的稳定纯文本预览。
    private func observeReviews() async {
        do {
            for try await items in repository.observeBookReviews(bookId: bookId) {
                guard !Task.isCancelled else { return }
                let preparedItems = try await Self.preparedReviewsOffMain(items)
                guard !Task.isCancelled else { return }
                reviews = preparedItems
            }
        } catch is CancellationError {
            return
        } catch {
            recordObservationError(error)
        }
    }

    /// 仅在书名或封面来源变化时启动一次封面取色；新请求会取消旧请求，避免竞态覆盖。
    private func resolveHeaderTintIfNeeded(for book: BookDetail?) {
        guard let book else { return }
        let signature = "\(book.id)|\(book.name)|\(book.cover)"
        guard resolvedColorSignature != signature else { return }
        resolvedColorSignature = signature
        colorTask?.cancel()
        colorTask = Task {
            let color = await colorRepository.resolveEventColor(
                bookId: book.id,
                bookName: book.name,
                coverURL: book.cover
            )
            guard !Task.isCancelled else { return }
            headerTintRGBAHex = color.backgroundRGBAHex
        }
    }

    /// 收敛观察流失败为页面级可感知错误，不因单个域失败终止其余内容展示。
    private func recordObservationError(_ error: Error) {
        errorMessage = "部分内容加载失败：\(error.localizedDescription)"
    }

    /// 在非主线程预处理书籍详情纯文本；父任务取消时同步取消后台解析任务。
    nonisolated private static func preparedBookOffMain(_ detail: BookDetail?) async throws -> BookDetail? {
        let task = Task.detached(priority: .userInitiated) {
            try preparedBook(detail)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// 在非主线程预处理书摘纯文本；批量转换过程中定期检查取消，避免页面退出后继续占用 CPU。
    nonisolated private static func preparedNotesOffMain(_ items: [NoteExcerpt]) async throws -> [NoteExcerpt] {
        let task = Task.detached(priority: .userInitiated) {
            try preparedNotes(items)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// 为书籍工作台生成稳定纯文本预览，避免 SwiftUI 渲染路径重复解析富文本 HTML。
    nonisolated private static func preparedBook(_ detail: BookDetail?) throws -> BookDetail? {
        guard let detail else { return nil }
        try Task.checkCancellation()
        return BookDetail(
            id: detail.id,
            name: detail.name,
            author: detail.author,
            cover: detail.cover,
            press: detail.press,
            score: detail.score,
            noteCount: detail.noteCount,
            relatedCount: detail.relatedCount,
            reviewCount: detail.reviewCount,
            readStatusID: detail.readStatusID,
            readStatusName: detail.readStatusName,
            readStatusBadgeTitle: detail.readStatusBadgeTitle,
            totalReadingSeconds: detail.totalReadingSeconds,
            readingProgressFraction: detail.readingProgressFraction,
            readingProgressText: detail.readingProgressText,
            bookmarkText: detail.bookmarkText,
            summary: detail.summary,
            summaryPlainText: plainTextPreview(from: detail.summary),
            authorIntro: detail.authorIntro,
            authorIntroPlainText: plainTextPreview(from: detail.authorIntro),
            attributes: detail.attributes,
            chapters: detail.chapters
        )
    }

    /// 为书摘列表生成稳定纯文本预览，避免滚动时反复做 HTML 到富文本的转换。
    nonisolated private static func preparedNotes(_ items: [NoteExcerpt]) throws -> [NoteExcerpt] {
        try items.map { note in
            try Task.checkCancellation()
            return copying(
                note,
                contentPlainText: plainTextPreview(from: note.content),
                ideaPlainText: plainTextPreview(from: note.idea)
            )
        }
    }

    /// 返回书摘源内容签名，展示元信息变化不会触发 HTML 重解析。
    nonisolated private static func contentSignature(for note: NoteExcerpt) -> BookNoteContentSignature {
        BookNoteContentSignature(content: note.content, idea: note.idea)
    }

    /// 把既有纯文本移植到同源的新记录上，同时保留数据库刚返回的其它最新字段。
    nonisolated private static func copyingPlainText(
        from prepared: NoteExcerpt,
        to current: NoteExcerpt
    ) -> NoteExcerpt {
        copying(
            current,
            contentPlainText: prepared.contentPlainText,
            ideaPlainText: prepared.ideaPlainText
        )
    }

    /// 复制书摘并替换展示纯文本，集中维护 NoteExcerpt 的完整值语义。
    nonisolated private static func copying(
        _ note: NoteExcerpt,
        contentPlainText: String,
        ideaPlainText: String
    ) -> NoteExcerpt {
        NoteExcerpt(
            id: note.id,
            chapterID: note.chapterID,
            chapterTitle: note.chapterTitle,
            chapterOrder: note.chapterOrder,
            chapterLevel: note.chapterLevel,
            content: note.content,
            contentPlainText: contentPlainText,
            idea: note.idea,
            ideaPlainText: ideaPlainText,
            imageURLs: note.imageURLs,
            tagNames: note.tagNames,
            position: note.position,
            positionUnit: note.positionUnit,
            includeTime: note.includeTime,
            createdDate: note.createdDate
        )
    }

    /// 在非主线程预处理相关内容纯文本；父任务取消时同步取消后台解析任务。
    nonisolated private static func preparedRelatedOffMain(_ items: [BookRelatedExcerpt]) async throws -> [BookRelatedExcerpt] {
        let task = Task.detached(priority: .userInitiated) {
            try items.map { item in
                try Task.checkCancellation()
                return BookRelatedExcerpt(
                    id: item.id,
                    categoryID: item.categoryID,
                    categoryTitle: item.categoryTitle,
                    title: item.title,
                    content: item.content,
                    contentPlainText: plainTextPreview(from: item.content),
                    url: item.url,
                    linkedBookID: item.linkedBookID,
                    linkedBookTitle: item.linkedBookTitle,
                    linkedBookAuthor: item.linkedBookAuthor,
                    linkedBookCover: item.linkedBookCover,
                    isLinkedBookPlaceholder: item.isLinkedBookPlaceholder,
                    createdDate: item.createdDate
                )
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// 在非主线程预处理书评正文纯文本；父任务取消时同步取消后台解析任务。
    nonisolated private static func preparedReviewsOffMain(_ items: [BookReviewExcerpt]) async throws -> [BookReviewExcerpt] {
        let task = Task.detached(priority: .userInitiated) {
            try items.map { item in
                try Task.checkCancellation()
                return BookReviewExcerpt(
                    id: item.id,
                    title: item.title,
                    content: item.content,
                    contentPlainText: plainTextPreview(from: item.content),
                    createdDate: item.createdDate
                )
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// 使用轻量纯文本解析器生成预览文案，不触碰 UIKit/TextKit 主线程路径。
    nonisolated private static func plainTextPreview(from html: String) -> String {
        RichTextPlainTextExtractor.plainText(from: html)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 释放书籍模块运行过程持有的资源与观察任务。
    isolated deinit {
        observationTasks.forEach { $0.cancel() }
        notesPreparationTask?.cancel()
        colorTask?.cancel()
        workspaceTask?.cancel()
        workspaceWriteTask?.cancel()
    }
}

/// 详情页评分并发门闩错误，供评分面板转换为系统失败反馈。
private nonisolated enum BookDetailRatingError: LocalizedError {
    case operationInProgress

    var errorDescription: String? {
        "评分正在保存，请稍后再试"
    }
}

/// 单书内容写入互斥门闩错误，防止两个编辑 Sheet 同时覆盖关系或排序状态。
private nonisolated enum BookDetailWorkspaceError: LocalizedError {
    case operationInProgress

    var errorDescription: String? {
        "另一项内容操作正在保存，请稍后再试"
    }
}
