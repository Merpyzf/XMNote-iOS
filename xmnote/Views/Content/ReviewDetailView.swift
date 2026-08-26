/**
 * [INPUT]: 依赖 RepositoryContainer 注入内容/AI 仓储，依赖 ReviewDetailViewModel 驱动书评详情状态
 * [OUTPUT]: 对外提供 ReviewDetailView，承接书评单页查看、选区 AI 释义与顶部操作
 * [POS]: Content 模块书评查看壳层，被时间线点击链路推入
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 书评单页详情页，对齐 Android 的 toolbar + 单页滚动结构。
struct ReviewDetailView: View {
    let reviewId: Int64

    @Environment(RepositoryContainer.self) private var repositories
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: ReviewDetailViewModel?
    @State private var showsDeleteDialog = false
    @State private var bootstrapLoadingGate = LoadingGate()

    var body: some View {
        ZStack {
            if let viewModel {
                ReviewDetailLoadedView(
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
                    LoadingStateView("正在加载书评…", style: .card)
                }
            }
        }
        .task {
            guard viewModel == nil else { return }
            bootstrapLoadingGate.update(intent: .read)
            let newViewModel = ReviewDetailViewModel(
                reviewId: reviewId,
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

private struct ReviewDetailLoadedView: View {
    @Bindable var viewModel: ReviewDetailViewModel
    @Binding var showsDeleteDialog: Bool
    @Environment(RepositoryContainer.self) private var repositories
    @Environment(AppNavigationCoordinator.self) private var navigationCoordinator
    @State private var readLoadingGate = LoadingGate()
    @State private var aiTextPresentation: AITextResultPresentation?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.base) {
                if let detail = viewModel.detail {
                    reviewContent(detail)
                } else if let errorMessage = viewModel.errorMessage {
                    viewerMessageCard(text: errorMessage)
                }
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
            .safeAreaPadding(.bottom)
        }
        .background(Color.surfacePage)
        .navigationTitle("书评")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .confirmationDialog("删除当前书评？", isPresented: $showsDeleteDialog) {
            Button("删除", role: .destructive) {
                Task { await viewModel.deleteCurrentReview() }
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

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if let detail = viewModel.detail {
                Button {
                    navigationCoordinator.present(.reviewEditor(.edit(reviewID: detail.reviewId)))
                } label: {
                    Image(systemName: "square.and.pencil")
                }

                Button(role: .destructive) {
                    showsDeleteDialog = true
                } label: {
                    Image(systemName: "trash")
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

    private func reviewContent(_ detail: ReviewContentDetail) -> some View {
        ReviewContentDetailBody(
            detail: detail,
            onAISelection: presentTextLookup
        )
    }

    private func copyText(from detail: ReviewContentDetail) -> String {
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

    private func syncReadLoadingVisibility() {
        readLoadingGate.update(intent: viewModel.isLoading ? .read : .none)
    }
}

#Preview {
    NavigationStack {
        ReviewDetailView(reviewId: 1)
    }
    .environment(RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty())))
}
