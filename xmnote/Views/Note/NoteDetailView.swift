/**
 * [INPUT]: 依赖 RepositoryContainer 注入仓储，依赖 NoteDetailViewModel 驱动状态
 * [OUTPUT]: 对外提供 NoteDetailView，笔记详情阅读与编辑页面
 * [POS]: Note 模块详情壳层，通过导航接收 noteId 参数
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

struct NoteDetailView: View {
    let noteId: Int64
    var startInEditing: Bool = false

    @Environment(RepositoryContainer.self) private var repositories
    @State private var viewModel: NoteDetailViewModel?
    @State private var isEditing = false

    var body: some View {
        Group {
            if let viewModel {
                NoteDetailContentView(
                    viewModel: viewModel,
                    isEditing: isEditing
                )
            } else {
                ProgressView()
            }
        }
        .background(Color.windowBackground)
        .navigationTitle(isEditing ? "编辑笔记" : "笔记详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task {
            guard viewModel == nil else { return }
            let vm = NoteDetailViewModel(noteId: noteId, repository: repositories.noteRepository)
            viewModel = vm
            isEditing = startInEditing
            await vm.load()
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if let viewModel {
                if isEditing {
                    if viewModel.isSaving {
                        ProgressView()
                    } else {
                        Button("保存") {
                            Task {
                                let saved = await viewModel.save()
                                if saved {
                                    withAnimation(.snappy) { isEditing = false }
                                }
                            }
                        }
                        .disabled(viewModel.isLoading)
                    }
                } else {
                    Button("编辑") {
                        withAnimation(.snappy) { isEditing = true }
                    }
                    .disabled(viewModel.isLoading)
                }
            }
        }
    }
}

private struct NoteDetailContentView: View {
    @Bindable var viewModel: NoteDetailViewModel
    let isEditing: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.base) {
                if let footer = viewModel.metadata?.footerText, !footer.isEmpty {
                    CardContainer {
                        Text(footer)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Spacing.contentEdge)
                    }
                }

                sectionCard(title: "书摘内容") {
                    RichTextEditor(
                        attributedText: $viewModel.contentText,
                        activeFormats: $viewModel.contentFormats,
                        isEditable: isEditing,
                        highlightARGB: viewModel.selectedHighlightARGB
                    )
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.blockMedium))
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.blockMedium)
                            .stroke(Color.cardBorder, lineWidth: CardStyle.borderWidth)
                    )
                }

                sectionCard(title: "想法") {
                    RichTextEditor(
                        attributedText: $viewModel.ideaText,
                        activeFormats: $viewModel.ideaFormats,
                        isEditable: isEditing,
                        highlightARGB: viewModel.selectedHighlightARGB
                    )
                    .frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.blockMedium))
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.blockMedium)
                            .stroke(Color.cardBorder, lineWidth: CardStyle.borderWidth)
                    )
                }

                if isEditing {
                    sectionCard(title: "高亮色板") {
                        HighlightColorPicker(selectedARGB: $viewModel.selectedHighlightARGB)
                    }
                }

                if let errorMessage = viewModel.errorMessage {
                    CardContainer {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Spacing.contentEdge)
                    }
                }
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
            .safeAreaPadding(.bottom)
        }
        .overlay {
            if viewModel.isLoading {
                ProgressView("加载中...")
            }
        }
    }

    @ViewBuilder
    private func sectionCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                content()
            }
            .padding(Spacing.contentEdge)
        }
    }
}

#Preview {
    NavigationStack {
        NoteDetailView(noteId: 1)
    }
    .environment(RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty())))
}
