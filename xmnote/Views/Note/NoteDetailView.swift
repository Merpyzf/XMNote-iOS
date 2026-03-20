/**
 * [INPUT]: 依赖 RepositoryContainer 注入仓储，依赖 NoteDetailViewModel 驱动状态
 * [OUTPUT]: 对外提供 NoteDetailView，笔记详情阅读与编辑页面
 * [POS]: Note 模块详情壳层，通过导航接收 noteId 参数
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 笔记详情页入口，支持查看与编辑模式切换。
struct NoteDetailView: View {
    let noteId: Int64
    var startInEditing: Bool = false

    @Environment(RepositoryContainer.self) private var repositories
    @State private var viewModel: NoteDetailViewModel?
    @State private var isEditing = false
    @State private var bootstrapLoadingGate = LoadingGate()

    var body: some View {
        ZStack {
            if let viewModel {
                NoteDetailContentView(
                    viewModel: viewModel,
                    isEditing: isEditing
                )
            } else {
                Color.surfacePage.ignoresSafeArea()
                if bootstrapLoadingGate.isVisible {
                    LoadingStateView("正在加载笔记…", style: .card)
                }
            }
        }
        .background(Color.surfacePage)
        .navigationTitle(isEditing ? "编辑笔记" : "笔记详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task {
            guard viewModel == nil else { return }
            bootstrapLoadingGate.update(intent: .read)
            let vm = NoteDetailViewModel(noteId: noteId, repository: repositories.noteRepository)
            viewModel = vm
            bootstrapLoadingGate.update(intent: .none)
            isEditing = startInEditing
            await vm.load()
        }
        .onDisappear {
            bootstrapLoadingGate.hideImmediately()
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
    @State private var readLoadingGate = LoadingGate()

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.base) {
                if let footer = viewModel.metadata?.footerText, !footer.isEmpty {
                    CardContainer {
                        Text(footer)
                            .font(AppTypography.caption)
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
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                            .stroke(Color.surfaceBorderDefault, lineWidth: CardStyle.borderWidth)
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
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                            .stroke(Color.surfaceBorderDefault, lineWidth: CardStyle.borderWidth)
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
                            .font(AppTypography.footnote)
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
            if readLoadingGate.isVisible {
                LoadingStateView("加载中…")
            }
        }
        .onAppear {
            syncReadLoadingVisibility()
        }
        .onChange(of: viewModel.isLoading) { _, _ in
            syncReadLoadingVisibility()
        }
        .onDisappear {
            readLoadingGate.hideImmediately()
        }
    }

    @ViewBuilder
    private func sectionCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text(title)
                    .font(AppTypography.subheadlineSemibold)
                    .foregroundStyle(.secondary)
                content()
            }
            .padding(Spacing.contentEdge)
        }
    }

    private func syncReadLoadingVisibility() {
        readLoadingGate.update(intent: viewModel.isLoading ? .read : .none)
    }
}

#Preview {
    NavigationStack {
        NoteDetailView(noteId: 1)
    }
    .environment(RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty())))
}
