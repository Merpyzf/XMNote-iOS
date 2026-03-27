//
//  NoteCollectionView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/9.
//

/**
 * [INPUT]: 依赖 NoteViewModel 提供分类与笔记列表状态
 * [OUTPUT]: 对外提供 NoteCollectionView，分类切换与内容分发
 * [POS]: Note 模块分类展示层，被 NoteContainerView 嵌入
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// NoteCollectionView 负责笔记页“分类切换 + 内容区分发”，根据当前分类展示标签列表或占位内容。
struct NoteCollectionView: View {
    @Bindable var viewModel: NoteViewModel

    var body: some View {
        VStack(spacing: Spacing.none) {
            categoryPills
            Divider()
            categoryContent
        }
    }

    // MARK: - Category Pills

    private var categoryPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.tight) {
                ForEach(NoteCategory.allCases) { category in
                    categoryPill(category)
                }
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.tight)
        }
    }

    /// 封装categoryPill对应的业务步骤，确保调用方可以稳定复用该能力。
    private func categoryPill(_ category: NoteCategory) -> some View {
        let isSelected = viewModel.selectedCategory == category
        return Button {
            withAnimation(.snappy) {
                viewModel.selectedCategory = category
            }
        } label: {
            Text(category.title)
                .font(AppTypography.subheadline)
                .padding(.horizontal, Spacing.screenEdge)
                .padding(.vertical, Spacing.cozy)
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

    /// 组装placeholderContent对应的界面片段，保持页面层级与信息结构清晰。
    private func placeholderContent(_ title: String) -> some View {
        EmptyStateView(icon: "doc.text", message: title)
    }
}

#Preview {
    let repositories = RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty()))
    NoteCollectionView(viewModel: NoteViewModel(repository: repositories.noteRepository))
}
