/**
 * [INPUT]: 依赖 RepositoryContainer 注入在线搜索仓储，依赖 BookCollectionCoverSearchViewModel 驱动封面匹配状态，依赖 XMBookCover 渲染候选封面
 * [OUTPUT]: 对外提供 BookCollectionCoverSearchSheet，承载书单内书籍编辑时的在线封面匹配与封面链接回填
 * [POS]: Book 模块业务 Sheet，仅负责封面候选选择，不直接保存书籍元信息或写入数据库
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书单内书籍在线封面匹配 Sheet；选择候选后只回填封面链接，保存仍由元信息编辑面板统一提交。
struct BookCollectionCoverSearchSheet: View {
    let initialTitle: String
    let currentCoverURL: String
    let onSelect: (String) -> Void

    @Environment(RepositoryContainer.self) private var repositories
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: BookCollectionCoverSearchViewModel?
    @State private var loadingGate = LoadingGate()

    var body: some View {
        XMSheetScaffold(
            title: "在线匹配封面",
            subtitle: normalizedInitialTitle,
            onClose: { dismiss() }
        ) {
            if let viewModel {
                content(viewModel)
                    .onAppear {
                        syncLoadingGate(viewModel)
                    }
                    .onChange(of: viewModel.status) { _, _ in
                        syncLoadingGate(viewModel)
                    }
            } else {
                LoadingStateView("正在准备封面搜索…", style: .card)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, Spacing.screenEdge)
                    .padding(.top, Spacing.section)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .task {
            guard viewModel == nil else { return }
            let model = BookCollectionCoverSearchViewModel(
                initialTitle: initialTitle,
                repository: repositories.bookSearchRepository
            )
            viewModel = model
            if !model.trimmedQuery.isEmpty {
                model.search()
            }
        }
        .onDisappear {
            loadingGate.hideImmediately()
        }
    }

    private var normalizedInitialTitle: String? {
        let value = initialTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func content(_ viewModel: BookCollectionCoverSearchViewModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            searchControls(viewModel)
            resultsSection(viewModel)
        }
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.bottom, Spacing.contentEdge)
    }

    private func searchControls(_ viewModel: BookCollectionCoverSearchViewModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            Text("搜索书名")
                .font(AppTypography.captionMedium)
                .foregroundStyle(Color.textSecondary)

            HStack(spacing: Spacing.cozy) {
                TextField(
                    "输入书名匹配封面",
                    text: Binding(
                        get: { viewModel.query },
                        set: { viewModel.updateQuery($0) }
                    )
                )
                .font(AppTypography.body)
                .foregroundStyle(Color.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit {
                    viewModel.search()
                }
                .padding(.horizontal, Spacing.base)
                .frame(minHeight: 48)
                .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                        .stroke(Color.surfaceBorderSubtle, lineWidth: StrokeWidth.hairline)
                }

                Button {
                    viewModel.search()
                } label: {
                    TopBarActionIcon(
                        systemName: "magnifyingglass",
                        foregroundColor: canSearch(viewModel) ? Color.iconPrimary : Color.textHint,
                        hitShape: .circle
                    )
                }
                .buttonStyle(.plain)
                .disabled(!canSearch(viewModel))
                .accessibilityLabel("搜索封面")
            }

            sourceMenu(viewModel)
        }
    }

    private func sourceMenu(_ viewModel: BookCollectionCoverSearchViewModel) -> some View {
        Menu {
            Picker(
                "搜索来源",
                selection: Binding(
                    get: { viewModel.selectedSource },
                    set: { viewModel.updateSource($0) }
                )
            ) {
                ForEach(viewModel.availableSources, id: \.self) { source in
                    Text(source.title)
                        .tag(source)
                }
            }
        } label: {
            HStack(spacing: Spacing.half) {
                Image(systemName: "network")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textHint)

                Text(viewModel.selectedSource.title)
                    .font(AppTypography.subheadlineMedium)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(AppTypography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.textHint)
            }
            .padding(.horizontal, Spacing.base)
            .frame(minHeight: 36)
            .background(Color.surfaceNested, in: Capsule())
        }
        .buttonStyle(.plain)
        .xmMenuNeutralTint()
        .accessibilityLabel("搜索来源，当前\(viewModel.selectedSource.title)")
    }

    @ViewBuilder
    private func resultsSection(_ viewModel: BookCollectionCoverSearchViewModel) -> some View {
        switch viewModel.status {
        case .idle:
            XMCompactStateView(
                role: .instruction,
                title: "输入书名开始匹配",
                message: "会从当前在线来源查找有封面的候选结果",
                systemImage: "photo.on.rectangle",
                style: .card
            )
        case .loading:
            loadingSection
        case .results:
            LazyVStack(alignment: .leading, spacing: Spacing.cozy) {
                ForEach(viewModel.results) { result in
                    Button {
                        select(result.coverURL)
                    } label: {
                        BookCollectionCoverSearchResultRow(
                            result: result,
                            isCurrent: isCurrentCover(result.coverURL)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("book.collection.cover.result.\(result.id)")
                }
            }
        case .empty:
            XMCompactStateView(
                role: .noResults,
                title: "没有匹配到封面",
                style: .card
            )
        case .failure:
            XMCompactStateView(
                role: .failure,
                title: "搜索失败",
                style: .card
            )
        }
    }

    @ViewBuilder
    private var loadingSection: some View {
        if loadingGate.isVisible {
            LoadingStateView("正在匹配在线封面…", style: .inline)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, Spacing.section)
        } else {
            Color.clear
                .frame(maxWidth: .infinity, minHeight: Spacing.section * 2)
                .accessibilityHidden(true)
        }
    }

    private func canSearch(_ viewModel: BookCollectionCoverSearchViewModel) -> Bool {
        !viewModel.trimmedQuery.isEmpty && !viewModel.status.isLoading
    }

    private func syncLoadingGate(_ viewModel: BookCollectionCoverSearchViewModel) {
        loadingGate.update(intent: viewModel.status.isLoading ? .read : .none)
    }

    private func isCurrentCover(_ coverURL: String) -> Bool {
        coverURL.trimmingCharacters(in: .whitespacesAndNewlines) == currentCoverURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func select(_ coverURL: String) {
        onSelect(coverURL.trimmingCharacters(in: .whitespacesAndNewlines))
        dismiss()
    }
}

private struct BookCollectionCoverSearchResultRow: View {
    let result: BookSearchResult
    let isCurrent: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.base) {
            XMBookCover.fixedWidth(
                52,
                urlString: result.coverURL,
                cornerRadius: CornerRadius.inlaySmall,
                border: .init(color: .surfaceBorderSubtle, width: StrokeWidth.hairline),
                placeholderIconSize: .small,
                surfaceStyle: .spine
            )

            VStack(alignment: .leading, spacing: Spacing.micro) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.half) {
                    Text(result.title)
                        .font(AppTypography.subheadlineSemibold)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(2)

                    if isCurrent {
                        Text("当前")
                            .font(AppTypography.captionMedium)
                            .foregroundStyle(Color.selectionAccent.opacity(0.9))
                            .padding(.horizontal, Spacing.half)
                            .frame(minHeight: 22)
                            .background(Color.selectionAccent.opacity(0.12), in: Capsule())
                    }
                }

                Text(detailText)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(result.source.title)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textHint)
            }

            Spacer(minLength: Spacing.base)

            Image(systemName: "checkmark.circle")
                .font(AppTypography.title3)
                .foregroundStyle(Color.selectionAccent.opacity(0.76))
        }
        .padding(Spacing.base)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                .stroke(isCurrent ? Color.selectionAccent.opacity(0.42) : Color.surfaceBorderSubtle, lineWidth: StrokeWidth.hairline)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(result.title)，\(detailText)，来自\(result.source.title)")
    }

    private var detailText: String {
        let author = result.author.trimmingCharacters(in: .whitespacesAndNewlines)
        let press = result.press.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (author.isEmpty, press.isEmpty) {
        case (false, false):
            return "\(author) / \(press)"
        case (false, true):
            return author
        case (true, false):
            return press
        case (true, true):
            return "暂无作者信息"
        }
    }
}
