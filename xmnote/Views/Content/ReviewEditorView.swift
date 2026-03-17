/**
 * [INPUT]: 依赖 RepositoryContainer 注入内容仓储，依赖 ReviewEditorViewModel 驱动书评最小编辑状态
 * [OUTPUT]: 对外提供 ReviewEditorView，承接书评标题/正文的最小编辑与保存
 * [POS]: Content 模块书评编辑壳层，被通用 viewer 的编辑动作推入
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书评最小编辑页，只提供标题与正文的修改能力，图片保持只读展示。
struct ReviewEditorView: View {
    let reviewId: Int64

    @Environment(RepositoryContainer.self) private var repositories
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: ReviewEditorViewModel?

    var body: some View {
        Group {
            if let viewModel {
                ReviewEditorLoadedView(viewModel: viewModel) {
                    dismiss()
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.surfacePage)
            }
        }
        .task {
            guard viewModel == nil else { return }
            let newViewModel = ReviewEditorViewModel(
                reviewId: reviewId,
                repository: repositories.contentRepository
            )
            viewModel = newViewModel
            await newViewModel.load()
        }
    }
}

private struct ReviewEditorLoadedView: View {
    @Bindable var viewModel: ReviewEditorViewModel
    let onSaved: () -> Void

    var body: some View {
        ZStack {
            Color.surfacePage.ignoresSafeArea()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.base) {
                    if let draft = viewModel.draft {
                        ContentViewerHeroCard(
                            title: draft.bookTitle,
                            subtitle: "编辑书评"
                        ) {
                            Text("图片先保留只读展示，正文和标题支持修改。")
                                .font(AppTypography.caption)
                                .foregroundStyle(.secondary)
                        }

                        CardContainer {
                            VStack(alignment: .leading, spacing: Spacing.base) {
                                Text("标题")
                                    .font(AppTypography.subheadlineSemibold)
                                    .foregroundStyle(.secondary)

                                TextField("输入书评标题", text: $viewModel.title)
                                    .textFieldStyle(.roundedBorder)
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
                                                id: "review-editor-img-\(index)",
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
        .navigationTitle("编辑书评")
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
        ReviewEditorView(reviewId: 1)
    }
    .environment(RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty())))
}
