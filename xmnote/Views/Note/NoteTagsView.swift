//
//  NoteTagsView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/9.
//

import SwiftUI

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
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.item))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.item)
                .stroke(Color.cardBorder, lineWidth: CardStyle.borderWidth)
        )
        .contentShape(Rectangle())
    }

    // MARK: - Search Highlight

    private func highlightedName(_ name: String) -> Text {
        guard !viewModel.searchText.isEmpty,
              let range = name.range(of: viewModel.searchText, options: .caseInsensitive)
        else {
            return Text(name)
        }
        let before = name[name.startIndex..<range.lowerBound]
        let match = name[range]
        let after = name[range.upperBound..<name.endIndex]
        return Text(before) + Text(match).foregroundStyle(Color.accentColor) + Text(after)
    }
}

#Preview {
    NoteTagsView(viewModel: NoteViewModel(database: try! .empty()))
}
