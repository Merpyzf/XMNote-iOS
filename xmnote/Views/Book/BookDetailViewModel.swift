//
//  BookDetailViewModel.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/12.
//

import Foundation

/**
 * [INPUT]: 依赖 BookRepositoryProtocol 提供书籍详情与书摘观察流
 * [OUTPUT]: 对外提供 BookDetailViewModel，输出 book/notes/hasNotes 状态
 * [POS]: Book 模块书籍详情状态编排器，被 BookDetailView 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

// MARK: - BookDetailViewModel

@Observable
class BookDetailViewModel {
    var book: BookDetail?
    var notes: [NoteExcerpt] = []

    private let bookId: Int64
    private let repository: any BookRepositoryProtocol
    private var detailTask: Task<Void, Never>?
    private var notesTask: Task<Void, Never>?

    init(bookId: Int64, repository: any BookRepositoryProtocol) {
        self.bookId = bookId
        self.repository = repository
    }

    var hasNotes: Bool { !notes.isEmpty }

    func startObservation() {
        detailTask = Task {
            do {
                for try await detail in repository.observeBookDetail(bookId: bookId) {
                    guard !Task.isCancelled else { return }
                    await MainActor.run { self.book = detail }
                }
            } catch {
                print("BookDetailViewModel detail observation error: \(error)")
            }
        }

        notesTask = Task {
            do {
                for try await items in repository.observeBookNotes(bookId: bookId) {
                    guard !Task.isCancelled else { return }
                    await MainActor.run { self.notes = items }
                }
            } catch {
                print("BookDetailViewModel notes observation error: \(error)")
            }
        }
    }

    deinit {
        detailTask?.cancel()
        notesTask?.cancel()
    }
}
