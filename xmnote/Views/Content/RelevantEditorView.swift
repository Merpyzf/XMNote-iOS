/**
 * [INPUT]: 依赖 RepositoryContainer 注入内容仓储，依赖 RelevantEditorViewModel 驱动相关内容最小编辑状态
 * [OUTPUT]: 对外提供 RelevantEditorView，承接相关内容标题/正文/URL 的最小编辑与保存
 * [POS]: Content 模块相关内容编辑壳层，被通用 viewer 的编辑动作推入
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 相关内容最小编辑页，只提供标题、正文与 URL 的修改能力，图片保持只读展示。
struct RelevantEditorView: View {
    let contentId: Int64

    @Environment(RepositoryContainer.self) private var repositories
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: RelevantEditorViewModel?
    @State private var bootstrapLoadingGate = LoadingGate()

    var body: some View {
        ZStack {
            if let viewModel {
                RelevantEditorLoadedView(viewModel: viewModel) {
                    dismiss()
                }
            } else {
                Color.surfacePage.ignoresSafeArea()
                if bootstrapLoadingGate.isVisible {
                    LoadingStateView("正在准备相关内容编辑页…", style: .card)
                }
            }
        }
        .task {
            guard viewModel == nil else { return }
            bootstrapLoadingGate.update(intent: .read)
            let newViewModel = RelevantEditorViewModel(
                contentId: contentId,
                repository: repositories.contentRepository
            )
            viewModel = newViewModel
            bootstrapLoadingGate.update(intent: .none)
            await newViewModel.load()
        }
        .onDisappear {
            bootstrapLoadingGate.hideImmediately()
        }
    }
}

private struct RelevantEditorLoadedView: View {
    @Bindable var viewModel: RelevantEditorViewModel
    let onSaved: () -> Void

    var body: some View {
        ZStack {
            Color.surfacePage.ignoresSafeArea()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.base) {
                    if let draft = viewModel.draft {
                        ContentViewerHeroCard(
                            title: draft.bookTitle,
                            subtitle: draft.categoryTitle.isEmpty ? "编辑相关内容" : draft.categoryTitle
                        ) {
                            Text("图片先保留只读展示，正文、标题和链接支持修改。")
                                .font(AppTypography.caption)
                                .foregroundStyle(.secondary)
                        }

                        CardContainer {
                            VStack(alignment: .leading, spacing: Spacing.base) {
                                Text("标题")
                                    .font(AppTypography.subheadlineSemibold)
                                    .foregroundStyle(.secondary)

                                TextField("输入相关内容标题", text: $viewModel.title)
                                    .textFieldStyle(.roundedBorder)
                            }
                            .padding(Spacing.contentEdge)
                        }

                        CardContainer {
                            VStack(alignment: .leading, spacing: Spacing.base) {
                                Text("链接")
                                    .font(AppTypography.subheadlineSemibold)
                                    .foregroundStyle(.secondary)

                                TextField("输入链接地址", text: $viewModel.url)
                                    .textFieldStyle(.roundedBorder)
                                    .keyboardType(.URL)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled(true)
                            }
                            .padding(Spacing.contentEdge)
                        }

                        CardContainer {
                            VStack(alignment: .leading, spacing: Spacing.base) {
                                Text("正文")
                                    .font(AppTypography.subheadlineSemibold)
                                    .foregroundStyle(.secondary)

                                RichTextEditor(
                                    attributedText: $viewModel.contentText,
                                    activeFormats: $viewModel.activeFormats
                                )
                                .frame(minHeight: 280)
                                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                                        .stroke(Color.surfaceBorderDefault, lineWidth: CardStyle.borderWidth)
                                )
                            }
                            .padding(Spacing.contentEdge)
                        }

                        if !viewModel.imageURLs.isEmpty {
                            CardContainer {
                                VStack(alignment: .leading, spacing: Spacing.base) {
                                    Text("图片")
                                        .font(AppTypography.subheadlineSemibold)
                                        .foregroundStyle(.secondary)

                                    XMJXImageWall(
                                        items: viewModel.imageURLs.enumerated().map { index, url in
                                            XMJXGalleryItem(
                                                id: "relevant-editor-img-\(index)",
                                                thumbnailURL: url,
                                                originalURL: url
                                            )
                                        },
                                        columnCount: viewModel.imageURLs.count == 1 ? 1 : 3
                                    )
                                }
                                .padding(Spacing.contentEdge)
                            }
                        }
                    }

                    if let errorMessage = viewModel.errorMessage, !errorMessage.isEmpty {
                        viewerMessageCard(text: errorMessage)
                    }
                }
                .padding(.horizontal, Spacing.screenEdge)
                .padding(.vertical, Spacing.base)
            }

            if viewModel.isSaving {
                Color.overlay.ignoresSafeArea()
                ProgressView("正在保存…")
                    .padding(Spacing.contentEdge)
                    .background(
                        Color.surfaceCard,
                        in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                    )
            }
        }
        .navigationTitle("编辑相关内容")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if viewModel.isSaving {
                    ProgressView()
                } else {
                    Button("保存") {
                        Task {
                            if await viewModel.save() {
                                onSaved()
                            }
                        }
                    }
                    .disabled(viewModel.isLoading)
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        RelevantEditorView(contentId: 1)
    }
    .environment(RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty())))
}
