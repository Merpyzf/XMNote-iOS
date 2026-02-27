//
//  BookViewModel.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/11.
//

import Foundation

/**
 * [INPUT]: 依赖 BookRepositoryProtocol 提供书籍数据流，依赖 BookItem/ReadStatusFilter 进行状态表达
 * [OUTPUT]: 对外提供 BookViewModel，驱动书籍页过滤与展示状态
 * [POS]: Presentation 层书籍列表状态编排器，被 BookContainerView/BookGridView 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

// MARK: - ReadStatusFilter

enum ReadStatusFilter: CaseIterable, Identifiable {
    case all, unread, reading, finished, onHold

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "全部"
        case .unread: "未读"
        case .reading: "在读"
        case .finished: "已读"
        case .onHold: "搁置"
        }
    }

    /// 对应 read_status 表的 id：1=未读 2=在读 3=已读 4=搁置
    var statusId: Int64? {
        switch self {
        case .all: nil
        case .unread: 1
        case .reading: 2
        case .finished: 3
        case .onHold: 4
        }
    }
}

// MARK: - BookViewModel

@Observable
class BookViewModel {
    var books: [BookItem] = []
    var selectedFilter: ReadStatusFilter = .all

    private let repository: any BookRepositoryProtocol
    private var observationTask: Task<Void, Never>?

    init(repository: any BookRepositoryProtocol) {
        self.repository = repository
        startObservation()
    }

    var filteredBooks: [BookItem] {
        guard let statusId = selectedFilter.statusId else { return books }
        return books.filter { $0.readStatusId == statusId }
    }

    deinit {
        observationTask?.cancel()
    }

    // MARK: - Observation

    private func startObservation() {
        observationTask = Task {
            do {
                for try await items in repository.observeBooks() {
                    guard !Task.isCancelled else { return }
                    await MainActor.run { self.books = items }
                }
            } catch {
                print("BookViewModel observation error: \(error)")
            }
        }
    }
}
