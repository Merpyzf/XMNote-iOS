/**
 * [INPUT]: 依赖 XMBookCover、BookshelfBookPayload 与封面角标语义 token 渲染书籍/分组网格封面
 * [OUTPUT]: 对外提供 BookshelfGridBookCoverView、BookshelfGridGroupCoverView 与轻量毛玻璃角标基础视图
 * [POS]: Book 模块页面私有封面展示基础组件，被默认书架与聚合入口网格复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 书籍网格中的单本书封面，集中承接阅读状态、置顶与书摘数量角标。
struct BookshelfGridBookCoverView: View {
    let book: BookshelfBookPayload
    var showsNoteCount = true
    var isPinned = false

    private let coverCornerRadius = CornerRadius.inlaySmall

    var body: some View {
        XMBookCover.responsive(
            urlString: book.cover,
            cornerRadius: coverCornerRadius,
            border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth),
            surfaceStyle: .spine
        )
        .overlay {
            BookshelfCoverBadgeLayer(
                isPinned: isPinned,
                topTrailingBadge: readingStatusBadge,
                bottomTrailingBadge: noteCountBadge,
                cornerRadius: coverCornerRadius
            )
        }
    }

    private var readingStatusBadge: BookshelfCoverBadgeContent? {
        guard let status = BookshelfCoverReadingStatus(from: book) else {
            return nil
        }
        return BookshelfCoverBadgeContent(
            text: status.title,
            tone: .status(status.color),
            accessibilityLabel: status.title
        )
    }

    private var noteCountBadge: BookshelfCoverBadgeContent? {
        guard showsNoteCount, book.noteCount > 0 else {
            return nil
        }
        return BookshelfCoverBadgeContent(
            text: "\(book.noteCount)",
            tone: .dark,
            accessibilityLabel: "\(book.noteCount)条书摘"
        )
    }
}

/// 书架分组网格封面，以 1 大、2 竖、3 小的拼贴表达组内内容。
struct BookshelfGridGroupCoverView: View {
    let covers: [String]
    let count: Int
    var isPinned = false

    private let coverCornerRadius = CornerRadius.inlaySmall

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                .fill(Color.surfaceCard)
                .overlay {
                    RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                        .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
                }

            BookshelfCoverMosaicView(covers: covers)
                .padding(Spacing.half)
        }
        .aspectRatio(XMBookCover.aspectRatio, contentMode: .fit)
        .overlay {
            BookshelfCoverBadgeLayer(
                isPinned: isPinned,
                topTrailingBadge: nil,
                bottomTrailingBadge: groupCountBadge,
                cornerRadius: CornerRadius.blockLarge
            )
        }
    }

    private var groupCountBadge: BookshelfCoverBadgeContent? {
        guard count > 0 else {
            return nil
        }
        return BookshelfCoverBadgeContent(
            text: "\(count)本",
            tone: .dark,
            accessibilityLabel: "\(count)本书籍"
        )
    }
}

/// 书籍封面文字角标，使用紧凑玻璃色块承载阅读状态与数量。
struct BookshelfCoverTextBadge: View {
    let text: String
    let placement: BookshelfCoverBadgePlacement
    let tone: BookshelfCoverBadgeTone
    let cornerRadius: CGFloat
    var accessibilityLabel: String? = nil

    var body: some View {
        Text(text)
            .font(AppTypography.caption2Medium)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .foregroundStyle(.white)
            .padding(.horizontal, Spacing.half)
            .padding(.vertical, Spacing.micro)
            .background {
                BookshelfCoverGlassBadgeBackground(
                    placement: placement,
                    tone: tone,
                    cornerRadius: cornerRadius
                )
            }
            .shadow(
                color: .bookCoverBadgeContentShadow,
                radius: BookshelfCoverBadgeMetrics.contentShadowRadius,
                x: 0,
                y: BookshelfCoverBadgeMetrics.contentShadowY
            )
            .fixedSize(horizontal: true, vertical: true)
            .accessibilityLabel(Text(verbatim: accessibilityLabel ?? text))
    }
}

/// 书籍封面置顶角标，保持与 Android 端 pin badge 相同的左上信息位置。
struct BookshelfCoverPinBadge: View {
    let cornerRadius: CGFloat

    var body: some View {
        Image(systemName: "pin.fill")
            .font(AppTypography.caption2Semibold)
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background {
                BookshelfCoverGlassBadgeBackground(
                    placement: .topLeading,
                    tone: .dark,
                    cornerRadius: cornerRadius
                )
            }
            .shadow(
                color: .bookCoverBadgeContentShadow,
                radius: BookshelfCoverBadgeMetrics.contentShadowRadius,
                x: 0,
                y: BookshelfCoverBadgeMetrics.contentShadowY
            )
            .accessibilityLabel("已置顶")
    }
}

/// 封面角标贴边位置，负责提供与截图一致的内侧圆角。
enum BookshelfCoverBadgePlacement {
    case topLeading
    case topTrailing
    case bottomTrailing

    func cornerRadii(outerRadius: CGFloat, innerRadius: CGFloat) -> RectangleCornerRadii {
        switch self {
        case .topLeading:
            return RectangleCornerRadii(
                topLeading: outerRadius,
                bottomLeading: CornerRadius.none,
                bottomTrailing: innerRadius,
                topTrailing: CornerRadius.none
            )
        case .topTrailing:
            return RectangleCornerRadii(
                topLeading: CornerRadius.none,
                bottomLeading: innerRadius,
                bottomTrailing: CornerRadius.none,
                topTrailing: outerRadius
            )
        case .bottomTrailing:
            return RectangleCornerRadii(
                topLeading: innerRadius,
                bottomLeading: CornerRadius.none,
                bottomTrailing: outerRadius,
                topTrailing: CornerRadius.none
            )
        }
    }
}

private struct BookshelfCoverBadgeContent {
    let text: String
    let tone: BookshelfCoverBadgeTone
    let accessibilityLabel: String
}

private struct BookshelfCoverBadgeLayer: View {
    let isPinned: Bool
    let topTrailingBadge: BookshelfCoverBadgeContent?
    let bottomTrailingBadge: BookshelfCoverBadgeContent?
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            if isPinned {
                BookshelfCoverPinBadge(cornerRadius: cornerRadius)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            if let topTrailingBadge {
                BookshelfCoverTextBadge(
                    text: topTrailingBadge.text,
                    placement: .topTrailing,
                    tone: topTrailingBadge.tone,
                    cornerRadius: cornerRadius,
                    accessibilityLabel: topTrailingBadge.accessibilityLabel
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }

            if let bottomTrailingBadge {
                BookshelfCoverTextBadge(
                    text: bottomTrailingBadge.text,
                    placement: .bottomTrailing,
                    tone: bottomTrailingBadge.tone,
                    cornerRadius: cornerRadius,
                    accessibilityLabel: bottomTrailingBadge.accessibilityLabel
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

enum BookshelfCoverBadgeTone {
    case dark
    case status(Color)

    var blurStyle: UIBlurEffect.Style {
        switch self {
        case .dark, .status:
            return .systemUltraThinMaterialDark
        }
    }

    var overlayFill: Color {
        switch self {
        case .dark:
            return .bookCoverBadgeDarkOverlay
        case .status(let color):
            return color.opacity(0.42)
        }
    }
}

private struct BookshelfCoverGlassBadgeBackground: View {
    let placement: BookshelfCoverBadgePlacement
    let tone: BookshelfCoverBadgeTone
    let cornerRadius: CGFloat

    var body: some View {
        let shape = BookshelfCoverBadgeShape(
            radii: placement.cornerRadii(
                outerRadius: cornerRadius,
                innerRadius: CornerRadius.inlaySmall
            )
        )

        BookshelfCoverBadgeBlurView(style: tone.blurStyle)
            .overlay {
                shape.fill(Color.bookCoverBadgeBlurWash)
            }
            .overlay {
                shape.fill(tone.overlayFill)
            }
            .overlay {
                shape.stroke(Color.bookCoverBadgeInnerStroke, lineWidth: CardStyle.borderWidth)
            }
            .compositingGroup()
            .clipShape(shape)
    }
}

private enum BookshelfCoverBadgeMetrics {
    static let contentShadowRadius: CGFloat = 0.6
    static let contentShadowY: CGFloat = 0.4
}

private struct BookshelfCoverBadgeBlurView: UIViewRepresentable {
    let style: UIBlurEffect.Style

    func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: UIBlurEffect(style: style))
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIVisualEffectView, context: Context) {
        view.effect = UIBlurEffect(style: style)
    }
}

private struct BookshelfCoverBadgeShape: Shape {
    let radii: RectangleCornerRadii

    func path(in rect: CGRect) -> Path {
        UnevenRoundedRectangle(cornerRadii: radii, style: .continuous)
            .path(in: rect)
    }
}

private struct BookshelfCoverMosaicView: View {
    let covers: [String]

    var body: some View {
        GeometryReader { proxy in
            let metrics = BookshelfCoverMosaicMetrics(size: proxy.size)

            ZStack(alignment: .topLeading) {
                mosaicCell(at: 0, metrics: metrics)
                    .frame(width: metrics.largeWidth, height: metrics.topHeight)
                    .offset(x: metrics.origin, y: metrics.origin)

                mosaicCell(at: 1, metrics: metrics)
                    .frame(width: metrics.sideWidth, height: metrics.sideHeight)
                    .offset(x: metrics.sideX, y: metrics.origin)

                mosaicCell(at: 2, metrics: metrics)
                    .frame(width: metrics.sideWidth, height: metrics.sideHeight)
                    .offset(x: metrics.sideX, y: metrics.origin + metrics.sideHeight + metrics.spacing)

                ForEach(0..<3, id: \.self) { index in
                    mosaicCell(at: index + 3, metrics: metrics)
                        .frame(width: metrics.bottomWidth, height: metrics.bottomHeight)
                        .offset(
                            x: metrics.origin + CGFloat(index) * (metrics.bottomWidth + metrics.spacing),
                            y: metrics.bottomY
                        )
                }
            }
        }
    }

    private func mosaicCell(at index: Int, metrics: BookshelfCoverMosaicMetrics) -> some View {
        let cover = cover(at: index)
        return XMBookCover.fixedSize(
            width: metrics.cellWidth(for: index),
            height: metrics.cellHeight(for: index),
            urlString: cover,
            cornerRadius: index == 0 ? CornerRadius.inlaySmall : CornerRadius.inlayTiny,
            border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth),
            placeholderIconSize: cover.isEmpty ? .hidden : .small,
            surfaceStyle: index == 0 ? .spine : .plain
        )
    }

    private func cover(at index: Int) -> String {
        guard covers.indices.contains(index) else { return "" }
        return covers[index]
    }
}

private struct BookshelfCoverMosaicMetrics {
    let origin: CGFloat
    let spacing: CGFloat
    let largeWidth: CGFloat
    let topHeight: CGFloat
    let sideWidth: CGFloat
    let sideHeight: CGFloat
    let bottomWidth: CGFloat
    let bottomHeight: CGFloat
    let sideX: CGFloat
    let bottomY: CGFloat

    init(size: CGSize) {
        origin = Spacing.tiny
        spacing = Spacing.compact

        let availableWidth = max(1, size.width - origin * 2)
        let availableHeight = max(1, size.height - origin * 2)
        bottomHeight = max(1, availableHeight * 0.29)
        topHeight = max(1, availableHeight - spacing - bottomHeight)
        sideWidth = max(1, (availableWidth - spacing) * 0.34)
        largeWidth = max(1, availableWidth - spacing - sideWidth)
        sideHeight = max(1, (topHeight - spacing) / 2)
        bottomWidth = max(1, (availableWidth - spacing * 2) / 3)
        sideX = origin + largeWidth + spacing
        bottomY = origin + topHeight + spacing
    }

    func cellWidth(for index: Int) -> CGFloat {
        switch index {
        case 0:
            return largeWidth
        case 1, 2:
            return sideWidth
        default:
            return bottomWidth
        }
    }

    func cellHeight(for index: Int) -> CGFloat {
        switch index {
        case 0:
            return topHeight
        case 1, 2:
            return sideHeight
        default:
            return bottomHeight
        }
    }
}

private struct BookshelfCoverReadingStatus {
    let title: String
    let color: Color

    init?(from book: BookshelfBookPayload) {
        guard let status = BookEntryReadingStatus(rawValue: book.readStatusId) else {
            return nil
        }
        let title = book.readStatusName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = title.isEmpty ? status.title : title
        self.color = status.coverBadgeColor
    }
}

private extension BookEntryReadingStatus {
    var coverBadgeColor: Color {
        switch self {
        case .wantRead:
            return .statusWish
        case .reading:
            return .statusReading
        case .finished:
            return .statusDone
        case .abandoned:
            return .statusAbandoned
        case .onHold:
            return .statusOnHold
        }
    }
}
