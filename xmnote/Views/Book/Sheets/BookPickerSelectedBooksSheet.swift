/**
 * [INPUT]: 依赖外层共享 BookPickerViewModel 的选择草稿，按展示样式组合 XMSheetScaffold/XMInlineSearchField，或原生导航/UISearchBar、XMScrollEdgeChrome 与统一书籍行
 * [OUTPUT]: 对外提供当前标准 BookPickerSelectedBooksSheet，以及带系统顶部/底部 soft scroll-edge 的 Apple 推荐 BookPickerSelectedBooksScreen
 * [POS]: BookPicker 页面私有已选管理界面，只修改外层草稿，不承担业务提交
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
        sheetScaffold
    }

    private var sheetScaffold: some View {
        XMSheetScaffold(
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
        XMInlineSearchField(
            text: $query,
            isActive: $isSearchActive,
            prompt: "搜索已选书籍",
            cancelPresentation: .hidden
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
            XMCompactStateView(
                role: .noResults,
                title: "没有找到匹配的书",
                message: "可以修改关键词后继续查找已选书籍",
                systemImage: "magnifyingglass",
                style: .card
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
        XMCompactStateView(
            role: .empty,
            title: "还没有选择书籍",
            message: "返回书籍列表，继续选择需要的书籍",
            systemImage: "books.vertical",
            action: XMStateAction("继续选择", systemImage: "chevron.backward") {
                dismiss()
            },
            style: .card
        )
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

/// Apple 推荐样式把已选管理作为同一 NavigationStack 的下一级页面，保留系统返回和单一层级关系。
struct BookPickerSelectedBooksScreen: View {
    let viewModel: BookPickerViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var isSearchActive = false

    var body: some View {
        XMScrollEdgeChrome(
            presentation: .overlaySoft,
            edges: [.top, .bottom],
            topBar: {
                searchBar
            },
            bottomBar: {
                bottomEdgeBar
            }
        ) {
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.surfaceSheet.ignoresSafeArea())
        .navigationTitle("已选书籍")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var searchBar: some View {
        BookPickerSystemSearchBar(
            text: $query,
            isActive: $isSearchActive,
            prompt: "搜索已选书籍",
            isEnabled: !viewModel.selectedItemsInSelectionOrder.isEmpty
        )
        .padding(.horizontal, Spacing.cozy)
        .padding(.top, Spacing.cozy)
        .padding(.bottom, Spacing.half)
    }

    private var bottomEdgeBar: some View {
        Color.surfaceSheet
            .frame(height: Spacing.half)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.selectedItemsInSelectionOrder.isEmpty {
            XMContentStateView(
                role: .empty,
                title: "还没有选择书籍",
                message: "返回书籍列表，继续选择需要的书籍",
                systemImage: "books.vertical",
                action: XMStateAction("继续选择", systemImage: "chevron.backward") {
                    dismiss()
                }
            )
        } else if filteredItems.isEmpty {
            XMContentStateView(
                role: .noResults,
                title: "没有找到匹配的书",
                message: "可以修改关键词后继续查找已选书籍",
                systemImage: "magnifyingglass",
                action: XMStateAction("清除搜索", systemImage: "xmark.circle") {
                    query = ""
                }
            )
        } else {
            List(filteredItems) { item in
                Button {
                    remove(item)
                } label: {
                    BookPickerAppleBookRow(
                        title: item.title,
                        author: item.author,
                        detail: item.detail,
                        coverURL: item.coverURL,
                        keyword: query,
                        isSelected: true,
                        showsSelectionIndicator: true,
                        statusText: nil
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("取消选择《\(item.title)》")
                .accessibilityHint("从当前选择中移除这本书")
                .modifier(
                    BookPickerAppleListRowModifier(
                        showsSeparator: item.id != filteredItems.last?.id
                    )
                )
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.surfaceSheet)
            .scrollBounceBehavior(.always)
        }
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

    /// 行移除使用可中断的结构动画；Reduce Motion 下直接更新同一份共享选择草稿。
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
                border: .init(color: .surfaceBorderSubtle, width: StrokeWidth.hairline),
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
