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
        GridItem(.flexible(), spacing: Spacing.base),
        GridItem(.flexible(), spacing: Spacing.base),
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
        LazyVStack(alignment: .leading, spacing: Spacing.section, pinnedViews: []) {
            ForEach(sections) { section in
                sectionView(section)
            }
        }
        .padding(.horizontal, Spacing.screenEdge)
    }

    private func sectionView(_ section: TagSection) -> some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            sectionHeader(section.title)
            LazyVGrid(columns: columns, spacing: Spacing.base) {
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
                .font(AppTypography.headline)
            Spacer()
            if title == "我的标签" {
                Button("管理") {}
                    .font(AppTypography.subheadline)
            }
        }
    }

    // MARK: - Tag Cell

    private func tagCell(_ tag: Tag) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: Spacing.compact) {
                highlightedName(tag.name)
                    .font(AppTypography.subheadline)
                Text("\(tag.noteCount) 条")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.brand.opacity(0.7))
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(AppTypography.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(Spacing.base)
        .background(Color.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                .stroke(Color.surfaceBorderDefault, lineWidth: CardStyle.borderWidth)
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
