//
//  BookDetailViewModel.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/12.
//

import Foundation

/**
 * [INPUT]: 依赖 BookDetailRepositoryProtocol 提供书籍详情、书摘观察流与单本评分写入，依赖 ContentRepositoryProtocol 提供工作区快照与单书内容排序写入
 * [OUTPUT]: 对外提供 BookDetailViewModel，输出 book/notes/workspace、持久化排序与单本评分门闩及对应加载、错误状态
 * [POS]: Book 模块书籍详情状态编排器，被 BookDetailView 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

// MARK: - BookDetailViewModel

/// 书籍详情状态源，负责详情、书摘与笔记工作区三通道订阅；所有 UI 状态均在主线程更新。
@MainActor
@Observable
final class BookDetailViewModel {
    var book: BookDetail?
    var notes: [NoteExcerpt] = []
    var isDetailLoading = true
    var detailErrorMessage: String?
    var workspace: BookContentWorkspaceSnapshot = .empty
    var isWorkspaceLoading = true
    var workspaceErrorMessage: String?
    var isWorkspaceWriting = false
    var workspaceActionErrorMessage: String?
    private(set) var isRatingWriting = false

    private let bookId: Int64
    private let repository: any BookDetailRepositoryProtocol
    private let contentRepository: any ContentRepositoryProtocol
    private var detailTask: Task<Void, Never>?
    private var notesTask: Task<Void, Never>?
    private var workspaceTask: Task<Void, Never>?
    private var workspaceWriteTask: Task<Void, Never>?

    /// 注入目标书籍 ID、详情仓储与内容仓储，初始化三个彼此独立的数据库观察通道。
    init(
        bookId: Int64,
        repository: any BookDetailRepositoryProtocol,
        contentRepository: any ContentRepositoryProtocol
    ) {
        self.bookId = bookId
        self.repository = repository
        self.contentRepository = contentRepository
    }

    var hasNotes: Bool { !notes.isEmpty }

    /// 建立详情、书摘与内容工作区观察任务；重复调用只补建缺失通道，所有回写统一回到主线程。
    func startObservation() {
        startDetailObservation()

        if notesTask == nil {
            let stream = repository.observeBookNotes(bookId: bookId)
            notesTask = Task { [weak self] in
                do {
                    for try await items in stream {
                        guard !Task.isCancelled else { return }
                        let preparedNotes = try await Self.preparedNotesOffMain(items)
                        guard !Task.isCancelled else { return }
                        self?.notes = preparedNotes
                    }
                } catch is CancellationError {
                    return
                } catch {
                    print("BookDetailViewModel notes observation error: \(error)")
                }
            }
        }
        startWorkspaceObservation()
    }

    /// 取消失效的详情订阅并重新读取；对象不存在与读取失败都会退出加载态并提供可感知结果。
    func retryDetailObservation() {
        detailTask?.cancel()
        detailTask = nil
        startDetailObservation()
    }

    /// 取消失败或陈旧的工作区订阅并重新观察；新任务会立即恢复读取态，旧任务取消后不再回写。
    func retryWorkspaceObservation() {
        workspaceTask?.cancel()
        workspaceTask = nil
        startWorkspaceObservation()
    }

    /// 更新当前书籍评分；写入期间拒绝重复提交，成功结果由详情观察流刷新，不额外制造成功提示。
    func updateBookRating(score: Int64) async throws {
        guard !isRatingWriting else {
            throw BookDetailRatingError.operationInProgress
        }
        isRatingWriting = true
        defer { isRatingWriting = false }
        try await repository.updateBookRating(bookId: bookId, score: score)
        try Task.checkCancellation()
    }

    /// 添加一本本地相关书；写入期间即时禁用重复操作，成功结果由数据库观察流表达。
    func addRelatedBook(bookID relatedBookID: Int64) {
        let repository = contentRepository
        let sourceBookID = bookId
        performWorkspaceWrite {
            try await repository.addRelatedBook(
                sourceBookID: sourceBookID,
                relatedBookID: relatedBookID
            )
        }
    }

    /// 将在线候选作为引用占位书加入相关内容，不改变书架有效书集合。
    func addRelatedBook(remoteSelection: BookPickerRemoteSelection) {
        let repository = contentRepository
        let sourceBookID = bookId
        let seed = remoteSelection.seed
        performWorkspaceWrite {
            try await repository.addRelatedBookPlaceholder(sourceBookID: sourceBookID, seed: seed)
        }
    }

    /// 将用户确认的相关书占位记录恢复到书架，观察流随后把卡片切换为正常详情入口。
    func restoreRelatedBookPlaceholder(bookID: Int64) {
        let repository = contentRepository
        performWorkspaceWrite {
            try await repository.restoreRelatedBookPlaceholder(bookID: bookID)
        }
    }

    /// 物理移除单条相关内容或相关书籍关系；占位书清理由 ContentRepository 事务统一处理。
    func deleteRelatedRelation(relationID: Int64) {
        let repository = contentRepository
        performWorkspaceWrite {
            try await repository.deleteRelatedRelation(relationID: relationID)
        }
    }

    /// 新建书内私有相关分类，业务校验与事务均由 ContentRepository 完成。
    func createRelatedCategory(title: String, scope: BookContentCategoryScope) {
        let repository = contentRepository
        let sourceBookID = bookId
        performWorkspaceWrite {
            try await repository.createBookRelatedCategory(
                bookID: sourceBookID,
                title: title,
                scope: scope
            )
        }
    }

    /// 重命名书内私有相关分类；系统默认分类不会通过 Repository 所有权门闩。
    func renameRelatedCategory(categoryID: Int64, title: String) {
        let repository = contentRepository
        let sourceBookID = bookId
        performWorkspaceWrite {
            try await repository.renameBookRelatedCategory(
                bookID: sourceBookID,
                categoryID: categoryID,
                title: title
            )
        }
    }

    /// 物理删除书内私有相关分类及子内容，完成后依赖观察流刷新分区。
    func deleteRelatedCategory(categoryID: Int64) {
        let repository = contentRepository
        let sourceBookID = bookId
        performWorkspaceWrite {
            try await repository.deleteBookRelatedCategory(
                bookID: sourceBookID,
                categoryID: categoryID
            )
        }
    }

    /// 切换固定默认分类隐藏状态；全局影响由管理 Sheet 的说明提前告知用户。
    func setDefaultRelatedCategoryHidden(categoryID: Int64, isHidden: Bool) {
        let repository = contentRepository
        performWorkspaceWrite {
            try await repository.setDefaultBookRelatedCategoryHidden(
                categoryID: categoryID,
                isHidden: isHidden
            )
        }
    }

    /// 按管理 Sheet 的最终顺序写入全部私有分类；失败时页面保留错误供回滚说明。
    func reorderRelatedCategories(categoryIDs: [Int64]) {
        let repository = contentRepository
        let sourceBookID = bookId
        performWorkspaceWrite {
            try await repository.updateBookRelatedCategoryOrder(
                bookID: sourceBookID,
                categoryIDs: categoryIDs
            )
        }
    }

    /// 写入当前书指定内容类型的排序规则；成功后由 sort 表观察驱动列表重排，失败保持旧偏好并展示系统错误。
    func updateContentSort(type: BookContentSortType, rule: BookContentSortRule) {
        guard workspace.sortPreferences.rule(for: type) != rule else { return }
        let repository = contentRepository
        let sourceBookID = bookId
        performWorkspaceWrite {
            try await repository.updateBookContentSortRule(
                bookID: sourceBookID,
                type: type,
                rule: rule
            )
        }
    }

    /// 清除已向用户展示的工作区写入错误，避免同一系统弹窗重复出现。
    func consumeWorkspaceActionError() {
        workspaceActionErrorMessage = nil
    }

    /// 串行执行单个工作区写操作；Task 仅弱持有 ViewModel，页面退出后不会形成自持有环。
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

    /// 建立书评与相关内容观察；流失败时保留已加载快照并向页面暴露可重试错误。
    private func startWorkspaceObservation() {
        guard workspaceTask == nil else { return }
        isWorkspaceLoading = true
        workspaceErrorMessage = nil
        let stream = contentRepository.observeBookContentWorkspace(bookID: bookId)
        workspaceTask = Task { [weak self] in
            do {
                for try await snapshot in stream {
                    guard !Task.isCancelled else { return }
                    let preparedSnapshot = try await Self.preparedWorkspaceOffMain(snapshot)
                    guard !Task.isCancelled else { return }
                    self?.workspace = preparedSnapshot
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

    /// 建立单书详情观察；nil 表示对象已不存在或不再属于有效书架，错误则保留底层可读信息。
    private func startDetailObservation() {
        guard detailTask == nil else { return }
        if book == nil {
            isDetailLoading = true
        }
        detailErrorMessage = nil
        let stream = repository.observeBookDetail(bookId: bookId)
        detailTask = Task { [weak self] in
            do {
                for try await detail in stream {
                    guard !Task.isCancelled else { return }
                    let preparedBook = try await Self.preparedBookOffMain(detail)
                    guard !Task.isCancelled else { return }
                    self?.book = preparedBook
                    self?.detailErrorMessage = preparedBook == nil
                        ? "书籍不存在、已被删除，或尚未加入书架"
                        : nil
                    self?.isDetailLoading = false
                }
            } catch is CancellationError {
                return
            } catch {
                self?.detailErrorMessage = error.localizedDescription
                self?.isDetailLoading = false
                self?.detailTask = nil
            }
        }
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

    /// 在非主线程为书评与普通相关内容生成纯文本预览；取消父任务时同步停止批量转换。
    nonisolated private static func preparedWorkspaceOffMain(
        _ snapshot: BookContentWorkspaceSnapshot
    ) async throws -> BookContentWorkspaceSnapshot {
        let task = Task.detached(priority: .userInitiated) {
            try preparedWorkspace(snapshot)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// 为详情页生成稳定纯文本预览，避免 SwiftUI 渲染路径重复解析富文本 HTML。
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
            readStatusName: detail.readStatusName,
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
            return NoteExcerpt(
                id: note.id,
                content: note.content,
                contentPlainText: plainTextPreview(from: note.content),
                idea: note.idea,
                ideaPlainText: plainTextPreview(from: note.idea),
                position: note.position,
                positionUnit: note.positionUnit,
                includeTime: note.includeTime,
                createdDate: note.createdDate
            )
        }
    }

    /// 预计算工作区长文本的可见摘要，避免列表滚动期间重复解析富文本 HTML。
    nonisolated private static func preparedWorkspace(
        _ snapshot: BookContentWorkspaceSnapshot
    ) throws -> BookContentWorkspaceSnapshot {
        let reviews = try snapshot.reviews.map { item in
            try Task.checkCancellation()
            return BookContentReviewItem(
                id: item.id,
                title: item.title,
                contentHTML: item.contentHTML,
                contentPlainText: plainTextPreview(from: item.contentHTML),
                createdDate: item.createdDate
            )
        }
        let relatedSections = try snapshot.relatedSections.map { section in
            let items = try section.items.map { item in
                try Task.checkCancellation()
                return BookContentRelatedItem(
                    id: item.id,
                    destination: item.destination,
                    title: item.title,
                    subtitle: item.subtitle,
                    contentHTML: item.contentHTML,
                    contentPlainText: plainTextPreview(from: item.contentHTML),
                    coverURL: item.coverURL,
                    createdDate: item.createdDate,
                    isPlaceholder: item.isPlaceholder
                )
            }
            return BookContentRelatedSection(id: section.id, title: section.title, items: items)
        }
        return BookContentWorkspaceSnapshot(
            reviews: reviews,
            relatedSections: relatedSections,
            categories: snapshot.categories,
            sortPreferences: snapshot.sortPreferences
        )
    }

    /// 使用轻量纯文本解析器生成预览文案，不触碰 UIKit/TextKit 主线程路径。
    nonisolated private static func plainTextPreview(from html: String) -> String {
        RichTextPlainTextExtractor.plainText(from: html)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 释放书籍模块运行过程持有的资源与观察任务。
    isolated deinit {
        detailTask?.cancel()
        notesTask?.cancel()
        workspaceTask?.cancel()
        workspaceWriteTask?.cancel()
    }
}

/// 详情页评分并发门闩错误，供评分 Sheet 转换为系统失败反馈。
private nonisolated enum BookDetailRatingError: LocalizedError {
    case operationInProgress

    var errorDescription: String? {
        "评分正在保存，请稍后再试"
    }
}
