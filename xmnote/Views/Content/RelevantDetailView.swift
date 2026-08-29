/**
 * [INPUT]: 依赖 RepositoryContainer 注入内容/AI 仓储，依赖 RelevantDetailViewModel 驱动相关详情状态
 * [OUTPUT]: 对外提供 RelevantDetailView，承接相关内容单页查看、选区 AI 释义与顶部操作
 * [POS]: Content 模块相关查看壳层，被时间线点击链路推入
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 相关内容单页详情页，对齐 Android 的 toolbar + 单页滚动结构。
struct RelevantDetailView: View {
    let contentId: Int64

    @Environment(RepositoryContainer.self) private var repositories
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: RelevantDetailViewModel?
    @State private var showsDeleteDialog = false
    @State private var bootstrapLoadingGate = LoadingGate()

    var body: some View {
        ZStack {
            if let viewModel {
                RelevantDetailLoadedView(
                    viewModel: viewModel,
                    showsDeleteDialog: $showsDeleteDialog
                )
                .onChange(of: viewModel.dismissalRequestToken) { _, newToken in
                    guard newToken > 0 else { return }
                    dismiss()
                }
            } else {
                Color.surfacePage.ignoresSafeArea()
                if bootstrapLoadingGate.isVisible {
                    LoadingStateView("正在加载相关内容…", style: .card)
                }
            }
        }
        .task {
            guard viewModel == nil else { return }
            bootstrapLoadingGate.update(intent: .read)
            let newViewModel = RelevantDetailViewModel(
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

private struct RelevantDetailLoadedView: View {
    @Bindable var viewModel: RelevantDetailViewModel
    @Binding var showsDeleteDialog: Bool
    @Environment(RepositoryContainer.self) private var repositories
    @Environment(AppNavigationCoordinator.self) private var navigationCoordinator
    @State private var readLoadingGate = LoadingGate()
    @State private var aiTextPresentation: AITextResultPresentation?

    var body: some View {
        Group {
            if let detail = viewModel.detail {
                detailContent(detail)
            } else if viewModel.isMissing {
                XMContentStateView(
                    role: .instruction,
                    title: "相关内容不存在或已删除",
                    systemImage: "questionmark.circle"
                )
            } else if viewModel.loadErrorMessage != nil {
                XMContentStateView(
                    role: .failure,
                    title: "暂时无法加载相关内容",
                    action: XMStateAction(
                        "重试",
                        perform: retryLoad
                    )
                )
            } else {
                Color.clear
            }
        }
        .background(Color.surfacePage)
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .confirmationDialog("删除当前相关内容？", isPresented: $showsDeleteDialog) {
            Button("删除", role: .destructive) {
                Task { await viewModel.deleteCurrentRelevant() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后将从当前内容中移除")
        }
        .overlay {
            if viewModel.isDeleting {
                LoadingStateView("正在删除…", style: .card)
            } else if readLoadingGate.isVisible {
                LoadingStateView("正在加载…")
            }
        }
        .sheet(item: $aiTextPresentation) { presentation in
            AITextResultSheet(
                presentation: presentation,
                repository: repositories.aiRepository
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .onAppear {
            syncReadLoadingVisibility()
            Task { await viewModel.load() }
        }
        .onChange(of: viewModel.isLoading) { _, _ in
            syncReadLoadingVisibility()
        }
        .onDisappear {
            readLoadingGate.hideImmediately()
        }
    }

    private func detailContent(_ detail: RelevantContentDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.base) {
                if let operationErrorMessage = viewModel.operationErrorMessage {
                    XMInlineStatusBanner(operationErrorMessage, tone: .error)
                } else if viewModel.loadErrorMessage != nil {
                    XMInlineStatusBanner(
                        "相关内容刷新失败",
                        tone: .error,
                        action: XMStateAction(
                            "重试",
                            perform: retryLoad
                        )
                    )
                }

                relevantContent(detail)
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
            .safeAreaPadding(.bottom)
        }
    }

    private var navigationTitle: String {
        guard let detail = viewModel.detail else { return "相关" }
        let title = detail.categoryTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "相关" : title
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if let detail = viewModel.detail {
                Button {
                    navigationCoordinator.present(.relevantEditor(.edit(contentID: detail.contentId)))
                } label: {
                    Image(systemName: "square.and.pencil")
                }

                Button(role: .destructive) {
                    showsDeleteDialog = true
                } label: {
                    Image(systemName: "trash")
                }

                if let url = normalizedURL(detail.url) {
                    Link(destination: url) {
                        Image(systemName: "link")
                    }
                }

                Menu {
                    Button {
                        UIPasteboard.general.string = copyText(from: detail)
                    } label: {
                        XMMenuLabel("复制", systemImage: "doc.on.doc")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(Color.iconSecondary)
                }
                .xmMenuNeutralTint()
            }
        }
    }

    private func relevantContent(_ detail: RelevantContentDetail) -> some View {
        RelevantContentDetailBody(
            detail: detail,
            onAISelection: presentTextLookup
        )
    }

    private func copyText(from detail: RelevantContentDetail) -> String {
        let content = RichTextBridge.htmlToAttributed(detail.contentHTML).string
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return [detail.title, content]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private func presentTextLookup(_ input: AITextLookupInput) {
        aiTextPresentation = AITextResultPresentation(request: .textLookup(input))
    }

    private func retryLoad() {
        Task { await viewModel.load() }
    }

    private func normalizedURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }

        return URL(string: "https://\(trimmed)")
    }

    private func syncReadLoadingVisibility() {
        readLoadingGate.update(intent: viewModel.isLoading ? .read : .none)
    }
}

#Preview {
    NavigationStack {
        RelevantDetailView(contentId: 1)
    }
    .environment(RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty())))
}
