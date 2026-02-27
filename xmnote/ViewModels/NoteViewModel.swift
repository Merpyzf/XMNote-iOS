//
//  NoteViewModel.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/9.
//

import Foundation

/**
 * [INPUT]: 依赖 NoteRepositoryProtocol 提供标签分组数据流，依赖 NoteCategory/TagSection 进行筛选
 * [OUTPUT]: 对外提供 NoteViewModel，输出标签分类、搜索结果与选中状态
 * [POS]: Presentation 层笔记首页状态编排器，被 NoteContainerView/NoteCollectionView 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

@Observable
class NoteViewModel {
    var selectedCategory: NoteCategory = .excerpts
    var searchText: String = ""
    var tagSections: [TagSection] = []

    private let repository: any NoteRepositoryProtocol
    private var observationTask: Task<Void, Never>?

    init(repository: any NoteRepositoryProtocol) {
        self.repository = repository
        startObservation()
    }

    var filteredSections: [TagSection] {
        guard !searchText.isEmpty else { return tagSections }
        return tagSections.compactMap { section in
            let filtered = section.tags.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
            }
            guard !filtered.isEmpty else { return nil }
            return TagSection(id: section.id, title: section.title, tags: filtered)
        }
    }

    deinit {
        observationTask?.cancel()
    }

    // MARK: - Observation

    private func startObservation() {
        observationTask = Task {
            do {
                for try await sections in repository.observeTagSections() {
                    guard !Task.isCancelled else { return }
                    await MainActor.run { self.tagSections = sections }
                }
            } catch {
                // observation 被取消时静默处理
            }
        }
    }
}
