/**
 * [INPUT]: 依赖 RepositoryContainer 注入搜索仓储，依赖 BookSearchViewModel 驱动远端查询状态，依赖 XMBookCover 统一渲染封面
 * [OUTPUT]: 对外提供 BookSearchView，承载首页加号进入的完整书籍搜索体验
 * [POS]: Book 模块搜索页壳层，负责六书源切换、最近搜索与结果进入录入页
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书籍搜索页入口，负责承接首页新增书籍主链路。
struct BookSearchView: View {
    @Environment(RepositoryContainer.self) private var repositories
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isSearchFieldFocused: Bool

    @State private var viewModel: BookSearchViewModel?
    @State private var navigationSeed: BookEditorSeed?
    @State private var isPreparingSeed = false

    var body: some View {
        Group {
            if let viewModel {
                content(viewModel)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.surfacePage)
            }
        }
        .task {
            guard viewModel == nil else { return }
            viewModel = BookSearchViewModel(repository: repositories.bookSearchRepository)
            isSearchFieldFocused = true
        }
        .navigationDestination(item: $navigationSeed) { seed in
            BookEditorView(seed: seed)
        }
    }

    private func content(_ viewModel: BookSearchViewModel) -> some View {
        ZStack {
            Color.surfacePage.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.section) {
                    heroHeader(viewModel)
                    sourcePills(viewModel)
                    recentQueries(viewModel)
                    resultsSection(viewModel)
                }
                .padding(.horizontal, Spacing.screenEdge)
                .padding(.top, Spacing.section)
                .padding(.bottom, Spacing.double)
            }
            .scrollIndicators(.hidden)

            if isPreparingSeed {
                Color.overlay.ignoresSafeArea()
                ProgressView("正在补全书籍信息…")
                    .padding(Spacing.contentEdge)
                    .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private func heroHeader(_ viewModel: BookSearchViewModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            HStack(alignment: .top) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Color.iconPrimary)
                        .frame(width: 36, height: 36)
                        .background(Color.surfaceCard, in: Circle())
                }
                .buttonStyle(.plain)

                Spacer()

                Button("手动创建") {
                    navigationSeed = .manual
                }
                .font(
                    SemanticTypography.font(
                        baseSize: SemanticTypography.defaultPointSize(for: .subheadline),
                        relativeTo: .subheadline,
                        weight: .semibold
                    )
                )
                .foregroundStyle(Color.brand)
            }

            VStack(alignment: .leading, spacing: Spacing.cozy) {
                Text("添加书籍")
                    .font(.brandDisplay(size: 28, relativeTo: .title2))
                    .foregroundStyle(Color.textPrimary)

                Text("以更轻的方式搜索，再进入完整录入页确认信息。")
                    .font(
                        SemanticTypography.font(
                            baseSize: SemanticTypography.defaultPointSize(for: .subheadline),
                            relativeTo: .subheadline
                        )
                    )
                    .foregroundStyle(Color.textSecondary)
            }

            searchBar(viewModel)
        }
    }

    private func searchBar(_ viewModel: BookSearchViewModel) -> some View {
        CardContainer(cornerRadius: CornerRadius.containerMedium, showsBorder: false) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                HStack(spacing: Spacing.base) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Color.textSecondary)

                    TextField("书名、作者、ISBN", text: Binding(
                        get: { viewModel.query },
                        set: { viewModel.query = $0 }
                    ))
                    .focused($isSearchFieldFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit {
                        Task { await viewModel.search() }
                    }

                    if !viewModel.query.isEmpty {
                        Button {
                            viewModel.query = ""
                            viewModel.results = []
                            viewModel.errorMessage = nil
                            viewModel.hasSearched = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Color.textHint)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Button {
                    Task { await viewModel.search() }
                } label: {
                    HStack {
                        if viewModel.isSearching {
                            ProgressView()
                                .tint(.white)
                        }
                        Text(viewModel.isSearching ? "搜索中…" : "开始搜索")
                    }
                    .font(
                        SemanticTypography.font(
                            baseSize: SemanticTypography.defaultPointSize(for: .headline),
                            relativeTo: .headline,
                            weight: .semibold
                        )
                    )
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.tight)
                    .background(Color.brand, in: RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isSearching)
            }
            .padding(Spacing.contentEdge)
        }
    }

    private func sourcePills(_ viewModel: BookSearchViewModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.cozy) {
                ForEach(BookSearchSource.allCases) { source in
                    let isSelected = source == viewModel.selectedSource
                    Button {
                        withAnimation(.snappy) {
                            viewModel.selectedSource = source
                        }
                    } label: {
                        Text(source.title)
                            .font(
                                SemanticTypography.font(
                                    baseSize: SemanticTypography.defaultPointSize(for: .subheadline),
                                    relativeTo: .subheadline,
                                    weight: .medium
                                )
                            )
                            .foregroundStyle(isSelected ? .white : Color.textPrimary)
                            .padding(.horizontal, Spacing.base)
                            .padding(.vertical, Spacing.cozy)
                            .background(
                                isSelected ? AnyShapeStyle(Color.brand) : AnyShapeStyle(Color.surfaceCard),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func recentQueries(_ viewModel: BookSearchViewModel) -> some View {
        if viewModel.shouldShowRecentQueries {
            VStack(alignment: .leading, spacing: Spacing.cozy) {
                Text("最近搜索")
                    .font(
                        SemanticTypography.font(
                            baseSize: SemanticTypography.defaultPointSize(for: .headline),
                            relativeTo: .headline,
                            weight: .semibold
                        )
                    )
                    .foregroundStyle(Color.textPrimary)

                FlowLayout(spacing: Spacing.cozy, lineSpacing: Spacing.cozy) {
                    ForEach(viewModel.recentQueries, id: \.self) { query in
                        HStack(spacing: Spacing.compact) {
                            Button(query) {
                                Task { await viewModel.search(withRecentQuery: query) }
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.textPrimary)

                            Button {
                                viewModel.removeRecentQuery(query)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Color.textHint)
                            }
                            .buttonStyle(.plain)
                        }
                        .font(
                            SemanticTypography.font(
                                baseSize: SemanticTypography.defaultPointSize(for: .subheadline),
                                relativeTo: .subheadline
                            )
                        )
                        .padding(.horizontal, Spacing.base)
                        .padding(.vertical, Spacing.cozy)
                        .background(Color.surfaceCard, in: Capsule())
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func resultsSection(_ viewModel: BookSearchViewModel) -> some View {
        if let errorMessage = viewModel.errorMessage {
            CardContainer(cornerRadius: CornerRadius.containerMedium, showsBorder: false) {
                VStack(alignment: .leading, spacing: Spacing.cozy) {
                    Text("搜索失败")
                        .font(
                            SemanticTypography.font(
                                baseSize: SemanticTypography.defaultPointSize(for: .headline),
                                relativeTo: .headline,
                                weight: .semibold
                            )
                        )
                        .foregroundStyle(Color.feedbackError)
                    Text(errorMessage)
                        .font(
                            SemanticTypography.font(
                                baseSize: SemanticTypography.defaultPointSize(for: .subheadline),
                                relativeTo: .subheadline
                            )
                        )
                        .foregroundStyle(Color.textSecondary)
                }
                .padding(Spacing.contentEdge)
            }
        } else if viewModel.isSearching {
            VStack(spacing: Spacing.base) {
                ForEach(0..<3, id: \.self) { _ in
                    searchResultSkeleton
                }
            }
        } else if viewModel.shouldShowEmptyState {
            CardContainer(cornerRadius: CornerRadius.containerMedium, showsBorder: false) {
                EmptyStateView(icon: "books.vertical", message: "没有找到匹配结果")
                    .frame(minHeight: 220)
            }
        } else if !viewModel.results.isEmpty {
            VStack(spacing: Spacing.base) {
                ForEach(viewModel.results) { result in
                    searchResultRow(result, viewModel: viewModel)
                }
            }
        }
    }

    private func searchResultRow(_ result: BookSearchResult, viewModel: BookSearchViewModel) -> some View {
        Button {
            Task {
                isPreparingSeed = true
                defer { isPreparingSeed = false }
                do {
                    navigationSeed = try await viewModel.prepareSeed(for: result)
                } catch {
                    viewModel.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        } label: {
            CardContainer(cornerRadius: CornerRadius.containerMedium, showsBorder: false) {
                HStack(alignment: .top, spacing: Spacing.base) {
                    XMBookCover.fixedWidth(
                        74,
                        urlString: result.coverURL,
                        cornerRadius: CornerRadius.inlayHairline,
                        border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth),
                        placeholderIconSize: .medium,
                        surfaceStyle: .spine
                    )

                    VStack(alignment: .leading, spacing: Spacing.half) {
                        HStack(alignment: .top) {
                            Text(result.title)
                                .font(
                                    SemanticTypography.font(
                                        baseSize: SemanticTypography.defaultPointSize(for: .headline),
                                        relativeTo: .headline,
                                        weight: .semibold
                                    )
                                )
                                .foregroundStyle(Color.textPrimary)
                                .multilineTextAlignment(.leading)
                                .lineLimit(2)

                            Spacer(minLength: 0)

                            Text(result.source.title)
                                .font(
                                    SemanticTypography.font(
                                        baseSize: SemanticTypography.defaultPointSize(for: .caption1),
                                        relativeTo: .caption,
                                        weight: .medium
                                    )
                                )
                                .foregroundStyle(Color.brand)
                        }

                        if !result.author.isEmpty {
                            Text(result.author)
                                .font(
                                    SemanticTypography.font(
                                        baseSize: SemanticTypography.defaultPointSize(for: .subheadline),
                                        relativeTo: .subheadline
                                    )
                                )
                                .foregroundStyle(Color.textSecondary)
                                .lineLimit(1)
                        }

                        if !result.subtitle.isEmpty {
                            Text(result.subtitle)
                                .font(
                                    SemanticTypography.font(
                                        baseSize: SemanticTypography.defaultPointSize(for: .footnote),
                                        relativeTo: .footnote
                                    )
                                )
                                .foregroundStyle(Color.textHint)
                                .lineLimit(2)
                        }

                        if !result.summary.isEmpty {
                            Text(result.summary)
                                .font(
                                    SemanticTypography.font(
                                        baseSize: SemanticTypography.defaultPointSize(for: .footnote),
                                        relativeTo: .footnote
                                    )
                                )
                                .foregroundStyle(Color.textSecondary)
                                .lineLimit(3)
                                .padding(.top, Spacing.cozy)
                        }
                    }
                }
                .padding(Spacing.contentEdge)
            }
        }
        .buttonStyle(.plain)
    }

    private var searchResultSkeleton: some View {
        RoundedRectangle(cornerRadius: CornerRadius.containerMedium, style: .continuous)
            .fill(Color.surfaceCard)
            .frame(height: 132)
            .overlay {
                RoundedRectangle(cornerRadius: CornerRadius.containerMedium, style: .continuous)
                    .fill(Color.white.opacity(0.0001))
                    .redacted(reason: .placeholder)
                    .overlay(alignment: .leading) {
                        HStack(spacing: Spacing.base) {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.surfaceNested)
                                .frame(width: 74, height: 106)
                            VStack(alignment: .leading, spacing: Spacing.cozy) {
                                RoundedRectangle(cornerRadius: 4).fill(Color.surfaceNested).frame(height: 16)
                                RoundedRectangle(cornerRadius: 4).fill(Color.surfaceNested).frame(width: 120, height: 14)
                                RoundedRectangle(cornerRadius: 4).fill(Color.surfaceNested).frame(height: 12)
                                RoundedRectangle(cornerRadius: 4).fill(Color.surfaceNested).frame(height: 12)
                            }
                        }
                        .padding(Spacing.contentEdge)
                    }
            }
    }
}

private struct FlowLayout<Content: View>: View {
    let spacing: CGFloat
    let lineSpacing: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: lineSpacing) {
            content
        }
    }
}

#Preview {
    NavigationStack {
        BookSearchView()
    }
    .environment(RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty())))
}
