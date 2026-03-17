/**
 * [INPUT]: 依赖 RepositoryContainer 注入内容仓储，依赖 ReviewDetailViewModel 驱动书评详情状态
 * [OUTPUT]: 对外提供 ReviewDetailView，承接书评单页查看与顶部操作
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

    var body: some View {
        Group {
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
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.surfacePage)
            }
        }
        .task {
            guard viewModel == nil else { return }
            let newViewModel = ReviewDetailViewModel(
                reviewId: reviewId,
                repository: repositories.contentRepository
            )
            viewModel = newViewModel
            await newViewModel.load()
        }
    }
}

private struct ReviewDetailLoadedView: View {
    @Bindable var viewModel: ReviewDetailViewModel
    @Binding var showsDeleteDialog: Bool

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
            Text("iOS 端当前按硬删除实现，主记录和子记录会一起删除。")
        }
        .overlay {
            if viewModel.isLoading || viewModel.isDeleting {
                ProgressView(viewModel.isDeleting ? "正在删除…" : "正在加载…")
            }
        }
        .onAppear {
            Task { await viewModel.load() }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if let detail = viewModel.detail {
                NavigationLink(value: ContentRoute.reviewEditor(reviewId: detail.reviewId)) {
                    Image(systemName: "square.and.pencil")
                }

                Button(role: .destructive) {
                    showsDeleteDialog = true
                } label: {
                    Image(systemName: "trash")
                }

                Menu {
                    Button("复制") {
                        UIPasteboard.general.string = copyText(from: detail)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    private func reviewContent(_ detail: ReviewContentDetail) -> some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            if let dateText = formattedDate(detail.createdDate) {
                Text(dateText)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
            }

            if !trimmed(detail.title).isEmpty {
                Text(detail.title)
                    .font(AppTypography.subheadlineSemibold)
                    .foregroundStyle(Color.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if TimelineMeaningfulPreview.hasMeaningfulHTML(detail.contentHTML) {
                RichText(
                    html: detail.contentHTML,
                    baseFont: AppTypography.uiSemantic(.body),
                    textColor: UIColor.label,
                    lineSpacing: 5
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !detail.imageURLs.isEmpty {
                ContentImageWall(
                    imageURLs: detail.imageURLs,
                    prefix: "review"
                )
                .padding(.top, Spacing.half)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func copyText(from detail: ReviewContentDetail) -> String {
        let content = RichTextBridge.htmlToAttributed(detail.contentHTML).string
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return [detail.title, content]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func formattedDate(_ timestamp: Int64) -> String? {
        guard timestamp > 0 else { return nil }
        return ContentDetailDateFormatter.full.string(
            from: Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)
        )
    }
}

#Preview {
    NavigationStack {
        ReviewDetailView(reviewId: 1)
    }
    .environment(RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty())))
}
