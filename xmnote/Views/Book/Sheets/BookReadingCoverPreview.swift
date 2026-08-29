/**
 * [INPUT]: 依赖 BookReadingDetailBook、XMBookCover 与 SwiftUI Sheet dismiss
 * [OUTPUT]: 对外提供 BookReadingCoverPreview，展示单书大封面预览
 * [POS]: Views/Book/Sheets 阅读详情业务 Sheet，只读展示且不拥有图片加载实现
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 大封面预览 Sheet；封面加载、占位和失败回退全部复用 XMBookCover。
struct BookReadingCoverPreview: View {
    let book: BookReadingDetailBook
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: Spacing.screenEdge) {
                Spacer()
                XMBookCover.fixedWidth(
                    260,
                    urlString: book.coverURL,
                    border: .init(color: .surfaceBorderDefault, width: StrokeWidth.hairline)
                )
                Text(book.name)
                    .font(AppTypography.headline)
                    .foregroundStyle(Color.textPrimary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .padding(Spacing.screenEdge)
            .background(Color.surfacePage.ignoresSafeArea())
            .navigationTitle("封面预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .tint(Color.textSecondary)
                    .accessibilityLabel("关闭")
                }
            }
        }
    }
}
