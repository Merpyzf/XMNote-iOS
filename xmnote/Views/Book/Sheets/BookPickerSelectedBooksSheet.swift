/**
 * [INPUT]: 依赖外层共享 BookPickerViewModel 的选择草稿，以及系统搜索、XMScrollEdgeChrome 与统一书籍行
 * [OUTPUT]: 对外提供带系统返回、UISearchBar 和顶部/底部 soft scroll-edge 的 BookPickerSelectedBooksScreen
 * [POS]: BookPicker 同一 NavigationStack 内的已选管理子页，只修改外层草稿，不单独创建 Sheet 或承担业务提交
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 已选管理作为书籍选择 NavigationStack 的下一级页面，保留系统返回和单一层级关系。
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
        XMSystemSearchBar(
            text: $query,
            isActive: $isSearchActive,
            prompt: "搜索已选书籍",
            accessibilityIdentifier: "book.picker.selected.search",
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
