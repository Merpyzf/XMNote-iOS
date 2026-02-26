//
//  BookGridView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/11.
//

import SwiftUI

struct BookGridView: View {
    @Bindable var viewModel: BookViewModel

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 16),
        count: 3
    )

    var body: some View {
        VStack(spacing: 0) {
            filterPills
            Divider()
            gridContent
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Filter Pills

    private var filterPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(ReadStatusFilter.allCases) { filter in
                    filterPill(filter)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
    }

    private func filterPill(_ filter: ReadStatusFilter) -> some View {
        let isSelected = viewModel.selectedFilter == filter
        return Button {
            withAnimation(.snappy) {
                viewModel.selectedFilter = filter
            }
        } label: {
            Text(filter.title)
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

    // MARK: - Grid Content

    @ViewBuilder
    private var gridContent: some View {
        let items = viewModel.filteredBooks
        if items.isEmpty {
            EmptyStateView(icon: "book", message: "暂无书籍")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(items) { book in
                        NavigationLink(value: BookRoute.detail(bookId: book.id)) {
                            BookGridItemView(book: book)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Spacing.screenEdge)
                .padding(.vertical, Spacing.base)
            }
        }
    }
}

#Preview {
    NavigationStack {
        BookGridView(viewModel: BookViewModel(database: try! .empty()))
    }
}
