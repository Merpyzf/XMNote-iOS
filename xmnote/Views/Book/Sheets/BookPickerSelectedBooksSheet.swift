/**
 * [INPUT]: 依赖外层共享 BookPickerViewModel 的选择草稿、统一 Sheet 骨架、XMSearchBar 与 XMBookCover
 * [OUTPUT]: 对外提供 BookPickerSelectedBooksSheet，以连续分组表面查看、搜索并即时取消已选本地或远端书籍
 * [POS]: BookPicker 页面私有管理 Sheet，只修改外层草稿，不承担业务提交
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 已选书籍管理页与外层共用同一个 ViewModel，关闭或下滑只结束查看任务。
struct BookPickerSelectedBooksSheet: View {
    let viewModel: BookPickerViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var isSearchActive = false

    var body: some View {
        settingsScaffold
    }

    private var settingsScaffold: some View {
        XMSettingsPageScaffold(
            title: "已选书籍",
            subtitle: subtitle,
            onClose: { dismiss() },
            scrollEdgePresentation: .overlaySoft,
            contentTopBar: {
                searchBar
            }
        ) {
            content
                .padding(.horizontal, Spacing.screenEdge)
                .padding(.bottom, Spacing.section)
        }
        .presentationDragIndicator(.visible)
    }

    private var subtitle: String {
        viewModel.selectedCount > 0 ? "共 \(viewModel.selectedCount) 本" : "还没有选择书籍"
    }

    private var searchBar: some View {
        XMSearchBar(
            text: $query,
            isActive: $isSearchActive,
            prompt: "搜索已选书籍"
        )
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.bottom, Spacing.section)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.selectedItemsInSelectionOrder.isEmpty {
            emptySelection
                .transition(.opacity)
        } else if filteredItems.isEmpty {
            ContentUnavailableView(
                "没有找到“\(query.trimmingCharacters(in: .whitespacesAndNewlines))”",
                systemImage: "magnifyingglass",
                description: Text("可以修改关键词后继续查找已选书籍。")
            )
            .frame(maxWidth: .infinity, minHeight: BookPickerGroupedSurfaceLayout.unavailableMinimumHeight)
            .transition(.opacity)
        } else {
            selectedBookList
                .transition(.opacity)
        }
    }

    private var selectedBookList: some View {
        BookPickerGroupedSurface {
            LazyVStack(alignment: .leading, spacing: Spacing.none) {
                ForEach(filteredItems.enumerated(), id: \.element.id) { index, item in
                    Button {
                        remove(item)
                    } label: {
                        BookPickerSelectedBookRow(item: item)
                    }
                    .buttonStyle(BookPickerGroupedRowButtonStyle())
                    .accessibilityLabel("取消选择《\(item.title)》")
                    .accessibilityHint("从当前选择中移除这本书")
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))

                    if index < filteredItems.count - 1 {
                        BookPickerGroupedDivider(
                            leadingInset: BookPickerGroupedSurfaceLayout.compactBookTextInset
                        )
                    }
                }
            }
        }
    }

    private var emptySelection: some View {
        ContentUnavailableView {
            Label("还没有选择书籍", systemImage: "books.vertical")
        } description: {
            Text("返回书籍列表，继续选择需要的书籍。")
        } actions: {
            Button("继续选择") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.brand)
        }
        .frame(maxWidth: .infinity, minHeight: BookPickerGroupedSurfaceLayout.unavailableMinimumHeight)
    }

    private var filteredItems: [BookPickerSelectedItem] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            return viewModel.selectedItemsInSelectionOrder
        }
        return viewModel.selectedItemsInSelectionOrder.filter { item in
            item.title.localizedCaseInsensitiveContains(normalizedQuery)
                || item.author.localizedCaseInsensitiveContains(normalizedQuery)
                || item.detail.localizedCaseInsensitiveContains(normalizedQuery)
        }
    }

    /// 行移除使用克制结构动画；Reduce Motion 下直接提交同一份共享草稿。
    private func remove(_ item: BookPickerSelectedItem) {
        if reduceMotion {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                viewModel.removeSelection(item)
            }
        } else {
            withAnimation(.snappy(duration: 0.18)) {
                viewModel.removeSelection(item)
            }
        }
    }
}

/// 管理页行保持与外层相同的封面、文字层级和中性多选指示器。
private struct BookPickerSelectedBookRow: View {
    let item: BookPickerSelectedItem

    var body: some View {
        HStack(spacing: Spacing.base) {
            XMBookCover.fixedWidth(
                44,
                urlString: item.coverURL,
                cornerRadius: CornerRadius.inlayHairline,
                border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth),
                placeholderIconSize: .small,
                surfaceStyle: .spine
            )

            VStack(alignment: .leading, spacing: Spacing.cozy) {
                Text(item.title)
                    .font(AppTypography.subheadlineSemibold)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)

                if !item.author.isEmpty {
                    Text(item.author)
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                }

                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: Spacing.none)

            XMSelectionIndicator(
                style: .checkbox,
                isSelected: true,
                font: AppTypography.body,
                showsUnselectedBase: true
            )
        }
        .padding(Spacing.contentEdge)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isSelected)
    }
}
