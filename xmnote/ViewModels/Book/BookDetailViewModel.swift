//
//  BookDetailViewModel.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/12.
//

import Foundation

/**
 * [INPUT]: 依赖 BookDetailRepositoryProtocol 提供书籍详情与书摘观察流
 * [OUTPUT]: 对外提供 BookDetailViewModel，输出 book/notes/hasNotes 状态
 * [POS]: Book 模块书籍详情状态编排器，被 BookDetailView 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

// MARK: - BookDetailViewModel

/// 书籍详情状态源，负责书籍详情与书摘列表双通道订阅；所有 UI 状态均在主线程更新。
@MainActor
@Observable
final class BookDetailViewModel {
    var book: BookDetail?
    var notes: [NoteExcerpt] = []

    private let bookId: Int64
    private let repository: any BookDetailRepositoryProtocol
    private var detailTask: Task<Void, Never>?
    private var notesTask: Task<Void, Never>?

    /// 注入目标书籍 ID 与仓储，初始化详情页数据观察。
    init(bookId: Int64, repository: any BookDetailRepositoryProtocol) {
        self.bookId = bookId
        self.repository = repository
    }

    var hasNotes: Bool { !notes.isEmpty }

    /// 建立详情与书摘双通道观察任务；HTML 纯文本预处理在后台任务执行，回写统一回到主线程。
    func startObservation() {
        guard detailTask == nil, notesTask == nil else { return }
        detailTask = Task {
            do {
                for try await detail in repository.observeBookDetail(bookId: bookId) {
                    guard !Task.isCancelled else { return }
                    let preparedBook = try await Self.preparedBookOffMain(detail)
                    guard !Task.isCancelled else { return }
                    self.book = preparedBook
                }
            } catch is CancellationError {
                return
            } catch {
                print("BookDetailViewModel detail observation error: \(error)")
            }
        }

        notesTask = Task {
            do {
                for try await items in repository.observeBookNotes(bookId: bookId) {
                    guard !Task.isCancelled else { return }
                    let preparedNotes = try await Self.preparedNotesOffMain(items)
                    guard !Task.isCancelled else { return }
                    self.notes = preparedNotes
                }
            } catch is CancellationError {
                return
            } catch {
                print("BookDetailViewModel notes observation error: \(error)")
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

    /// 使用轻量纯文本解析器生成预览文案，不触碰 UIKit/TextKit 主线程路径。
    nonisolated private static func plainTextPreview(from html: String) -> String {
        RichTextPlainTextExtractor.plainText(from: html)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 释放书籍模块运行过程持有的资源与观察任务。
    isolated deinit {
        detailTask?.cancel()
        notesTask?.cancel()
    }
}
