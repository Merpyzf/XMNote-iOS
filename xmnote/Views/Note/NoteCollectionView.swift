//
//  NoteCollectionView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/9.
//

import SwiftUI

struct NoteCollectionView: View {
    @Bindable var viewModel: NoteViewModel

    var body: some View {
        VStack(spacing: 0) {
            categoryPills
            Divider()
            categoryContent
        }
    }

    // MARK: - Category Pills

    private var categoryPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(NoteCategory.allCases) { category in
                    categoryPill(category)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
    }

    private func categoryPill(_ category: NoteCategory) -> some View {
        let isSelected = viewModel.selectedCategory == category
        return Button {
            withAnimation(.snappy) {
                viewModel.selectedCategory = category
            }
        } label: {
            Text(category.title)
                .font(.subheadline)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    isSelected ? AnyShapeStyle(Color.brand) : AnyShapeStyle(Color.tagBackground),
                    in: Capsule()
                )
                .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Category Content

    @ViewBuilder
    private var categoryContent: some View {
        switch viewModel.selectedCategory {
        case .excerpts:
            NoteTagsView(viewModel: viewModel)
        case .related:
            placeholderContent("相关")
        case .reviews:
            placeholderContent("书评")
        }
    }

    private func placeholderContent(_ title: String) -> some View {
        EmptyStateView(icon: "doc.text", message: title)
    }
}

#Preview {
    NoteCollectionView(viewModel: NoteViewModel())
}
