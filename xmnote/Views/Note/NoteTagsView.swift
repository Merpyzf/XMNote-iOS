//
//  NoteTagsView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/9.
//

/**
 * [INPUT]: 依赖 NoteViewModel 提供标签分组数据
 * [OUTPUT]: 对外提供 NoteTagsView，标签分组网格展示
 * [POS]: Note 模块标签展示层，被 NoteCollectionView 在标签分类下嵌入
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 笔记标签分组视图，负责渲染标签分区网格与空搜索态。
struct NoteTagsView: View {
    @Bindable var viewModel: NoteViewModel

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        let sections = viewModel.filteredSections

        if sections.isEmpty {
            emptyStateView
        } else {
            tagSectionsView(sections)
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        ContentUnavailableView.search(text: viewModel.searchText)
    }

    // MARK: - Sections

    private func tagSectionsView(_ sections: [TagSection]) -> some View {
        LazyVStack(alignment: .leading, spacing: 20, pinnedViews: []) {
            ForEach(sections) { section in
                sectionView(section)
            }
        }
        .padding(.horizontal)
    }

    private func sectionView(_ section: TagSection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(section.title)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(section.tags) { tag in
                    tagCell(tag)
                }
            }
        }
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.headline)
            Spacer()
            if title == "我的标签" {
                Button("管理") {}
                    .font(.subheadline)
            }
        }
    }

    // MARK: - Tag Cell

    private func tagCell(_ tag: Tag) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                highlightedName(tag.name)
                    .font(.subheadline)
                Text("\(tag.noteCount) 条")
                    .font(.caption)
                    .foregroundStyle(Color.brand.opacity(0.7))
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(Color.contentBackground)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.blockMedium))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.blockMedium)
                .stroke(Color.cardBorder, lineWidth: CardStyle.borderWidth)
        )
        .contentShape(Rectangle())
    }

    // MARK: - Search Highlight

    private func highlightedName(_ name: String) -> Text {
        guard !viewModel.searchText.isEmpty else {
            return Text(name)
        }
        var attributed = AttributedString(name)
        guard let range = attributed.range(of: viewModel.searchText, options: .caseInsensitive) else {
            return Text(name)
        }
        attributed[range].foregroundColor = .accentColor
        return Text(attributed)
    }
}

#Preview {
    let repositories = RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty()))
    NoteTagsView(viewModel: NoteViewModel(repository: repositories.noteRepository))
}
