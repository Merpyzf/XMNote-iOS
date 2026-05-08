/**
 * [INPUT]: 依赖 BookshelfLayoutMode、XMBookCover 宽高比、DesignTokens 颜色/间距/圆角令牌与系统 Reduce Motion 设置
 * [OUTPUT]: 对外提供 BookshelfLoadingSkeletonView，渲染书籍主列表首次读取阶段的稳定书架骨架
 * [POS]: Book 模块页面私有加载占位组件，被 BookGridView 的主列表读取态消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书籍主列表首次读取骨架，保持与真实网格/列表接近的结构占位。
struct BookshelfLoadingSkeletonView: View {
    let layoutMode: BookshelfLayoutMode
    let columnCount: Int
    var bottomContentInset: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShimmerActive = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            Group {
                switch layoutMode {
                case .grid:
                    gridSkeleton
                case .list:
                    listSkeleton
                }
            }
            .padding(.bottom, bottomContentInset + Spacing.base)
        }
        .scrollDisabled(true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在整理书架")
        .onAppear {
            updateShimmerState()
        }
        .onChange(of: reduceMotion) { _, _ in
            updateShimmerState()
        }
    }

    private var gridSkeleton: some View {
        LazyVGrid(columns: gridColumns, alignment: .center, spacing: Spacing.section) {
            ForEach(0..<Self.gridItemCount, id: \.self) { index in
                BookshelfLoadingGridItem(
                    shimmerPhase: isShimmerActive,
                    titleWidthRatio: Self.titleWidthRatios[index % Self.titleWidthRatios.count],
                    subtitleWidthRatio: Self.subtitleWidthRatios[index % Self.subtitleWidthRatios.count]
                )
            }
        }
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.top, Spacing.base)
    }

    private var listSkeleton: some View {
        VStack(spacing: Spacing.base) {
            ForEach(0..<Self.listItemCount, id: \.self) { index in
                BookshelfLoadingListRow(
                    shimmerPhase: isShimmerActive,
                    titleWidthRatio: Self.listTitleWidthRatios[index % Self.listTitleWidthRatios.count],
                    subtitleWidthRatio: Self.listSubtitleWidthRatios[index % Self.listSubtitleWidthRatios.count]
                )
            }
        }
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.top, Spacing.base)
    }

    private var gridColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: Spacing.screenEdge, alignment: .top),
            count: max(2, min(columnCount, 4))
        )
    }

    private func updateShimmerState() {
        guard !reduceMotion else {
            isShimmerActive = false
            return
        }
        isShimmerActive = false
        withAnimation(.linear(duration: 1.35).repeatForever(autoreverses: false)) {
            isShimmerActive = true
        }
    }

    private static let gridItemCount = 12
    private static let listItemCount = 8
    private static let titleWidthRatios: [CGFloat] = [0.78, 0.68, 0.86, 0.62]
    private static let subtitleWidthRatios: [CGFloat] = [0.50, 0.44, 0.58, 0.38]
    private static let listTitleWidthRatios: [CGFloat] = [0.64, 0.76, 0.58]
    private static let listSubtitleWidthRatios: [CGFloat] = [0.42, 0.55, 0.36]
}

private struct BookshelfLoadingGridItem: View {
    let shimmerPhase: Bool
    let titleWidthRatio: CGFloat
    let subtitleWidthRatio: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            BookshelfSkeletonBlock(
                cornerRadius: CornerRadius.inlaySmall,
                shimmerPhase: shimmerPhase
            )
            .aspectRatio(XMBookCover.aspectRatio, contentMode: .fit)
            .overlay(alignment: .topTrailing) {
                BookshelfSkeletonBlock(
                    cornerRadius: CornerRadius.inlayMedium,
                    shimmerPhase: shimmerPhase
                )
                .frame(width: 30, height: 16)
                .padding(Spacing.compact)
                .opacity(0.52)
            }

            VStack(alignment: .leading, spacing: Spacing.compact) {
                BookshelfSkeletonLine(widthRatio: titleWidthRatio, shimmerPhase: shimmerPhase)
                    .frame(height: 10)
                BookshelfSkeletonLine(widthRatio: subtitleWidthRatio, shimmerPhase: shimmerPhase)
                    .frame(height: 8)
                    .opacity(0.72)
            }
        }
    }
}

private struct BookshelfLoadingListRow: View {
    let shimmerPhase: Bool
    let titleWidthRatio: CGFloat
    let subtitleWidthRatio: CGFloat

    var body: some View {
        HStack(spacing: Spacing.base) {
            BookshelfSkeletonBlock(
                cornerRadius: CornerRadius.inlaySmall,
                shimmerPhase: shimmerPhase
            )
            .frame(width: 48, height: 68)

            VStack(alignment: .leading, spacing: Spacing.cozy) {
                BookshelfSkeletonLine(widthRatio: titleWidthRatio, shimmerPhase: shimmerPhase)
                    .frame(height: 12)
                BookshelfSkeletonLine(widthRatio: subtitleWidthRatio, shimmerPhase: shimmerPhase)
                    .frame(height: 10)
                    .opacity(0.74)
                BookshelfSkeletonLine(widthRatio: 0.34, shimmerPhase: shimmerPhase)
                    .frame(height: 8)
                    .opacity(0.54)
            }
        }
        .padding(Spacing.base)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
    }
}

private struct BookshelfSkeletonLine: View {
    let widthRatio: CGFloat
    let shimmerPhase: Bool

    var body: some View {
        GeometryReader { proxy in
            BookshelfSkeletonBlock(
                cornerRadius: CornerRadius.inlayTiny,
                shimmerPhase: shimmerPhase
            )
            .frame(width: max(12, proxy.size.width * max(0.1, min(widthRatio, 1))))
        }
    }
}

private struct BookshelfSkeletonBlock: View {
    let cornerRadius: CGFloat
    let shimmerPhase: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.bookCoverPlaceholderBackground.opacity(0.92))
            .overlay {
                GeometryReader { proxy in
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0),
                            Color.white.opacity(0.28),
                            Color.white.opacity(0)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: max(44, proxy.size.width * 0.58))
                    .offset(x: shimmerPhase ? proxy.size.width * 1.18 : -proxy.size.width * 0.76)
                }
                .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
