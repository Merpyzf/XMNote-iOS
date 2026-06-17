/**
 * [INPUT]: 依赖 BookCollectionListItem、BookCollectionDetail、BookCollectionBookItem 与 XMBookCover 渲染书单列表、详情和书单内书籍关系
 * [OUTPUT]: 对外提供书单模块页面私有视觉组件，统一封面拼贴、海报式封面、指标、详情头、书籍卡片与推荐语区块
 * [POS]: Book 模块书单页面私有展示组件，被 BookCollectionListView、BookCollectionDetailView 与加入书单 Sheet 复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书单封面拼贴，以真实书籍封面建立书单识别，不复刻 Android 重渐变与遮罩。
struct BookCollectionCoverMosaicView: View {
    let covers: [String]
    var size: CGFloat = 82
    var tone: BookCollectionKind = .manual

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                .fill(Color.surfaceCard)
                .overlay {
                    RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                        .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
                }

            if visibleCovers.isEmpty {
                placeholder
            } else {
                mosaic
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var visibleCovers: [String] {
        Array(covers.prefix(4))
    }

    private var coverWidth: CGFloat {
        max(24, size * 0.34)
    }

    private var placeholder: some View {
        VStack(spacing: Spacing.compact) {
            Image(systemName: tone == .annual ? "calendar" : "books.vertical")
                .font(AppTypography.title3)
                .foregroundStyle(Color.textHint)

            RoundedRectangle(cornerRadius: CornerRadius.inlayTiny, style: .continuous)
                .fill(Color.surfaceBorderSubtle)
                .frame(width: size * 0.34, height: Spacing.micro)
        }
    }

    private var mosaic: some View {
        ZStack {
            ForEach(Array(visibleCovers.enumerated()), id: \.offset) { index, cover in
                XMBookCover.fixedWidth(
                    coverWidth,
                    urlString: cover,
                    cornerRadius: CornerRadius.inlaySmall,
                    border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth),
                    placeholderIconSize: .small,
                    surfaceStyle: .spine
                )
                .rotationEffect(.degrees(rotation(for: index)))
                .offset(offset(for: index))
                .zIndex(Double(index))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Spacing.half)
        .clipped()
    }

    private func offset(for index: Int) -> CGSize {
        switch index {
        case 0:
            return CGSize(width: -size * 0.16, height: -size * 0.08)
        case 1:
            return CGSize(width: size * 0.08, height: -size * 0.12)
        case 2:
            return CGSize(width: -size * 0.06, height: size * 0.12)
        default:
            return CGSize(width: size * 0.18, height: size * 0.08)
        }
    }

    private func rotation(for index: Int) -> Double {
        switch index {
        case 0:
            return -5
        case 1:
            return 4
        case 2:
            return -2
        default:
            return 3
        }
    }
}

/// 书单封面横向陈列，用真实封面形成“被整理过的一组书”的集合感。
struct BookCollectionCoverShelfView: View {
    let covers: [String]
    var tone: BookCollectionKind = .manual

    private var visibleCovers: [String] {
        Array(covers.prefix(4))
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: Spacing.tight) {
            if visibleCovers.isEmpty {
                placeholder
            } else {
                ForEach(Array(visibleCovers.enumerated()), id: \.offset) { index, cover in
                    XMBookCover.fixedWidth(
                        index == 0 ? 58 : 50,
                        urlString: cover,
                        cornerRadius: CornerRadius.inlaySmall,
                        border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth),
                        placeholderIconSize: .small,
                        surfaceStyle: .spine
                    )
                    .shadow(
                        color: Color.bookCoverDropShadow.opacity(index == 0 ? 0.70 : 0.42),
                        radius: index == 0 ? 6 : 4,
                        x: Spacing.none,
                        y: index == 0 ? 4 : 2
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        HStack(spacing: Spacing.cozy) {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                    .fill(index == 0 ? Color.surfaceNested : Color.controlFillSecondary.opacity(0.70))
                    .overlay {
                        if index == 0 {
                            Image(systemName: tone == .annual ? "calendar" : "books.vertical")
                                .font(AppTypography.callout)
                                .foregroundStyle(Color.textHint)
                        }
                    }
                    .frame(width: index == 0 ? 58 : 50, height: index == 0 ? 82 : 74)
            }
        }
    }
}

/// 书单海报式封面，将 Android 的多封面集合记忆收敛为 iOS 低饱和视觉区。
struct BookCollectionMutedPosterCoverView: View {
    let covers: [String]
    var tone: BookCollectionKind = .manual
    var seed: String = ""
    var displayMode: DisplayMode = .list

    enum DisplayMode: Equatable {
        case list
        case compactGrid

        var aspectRatio: CGFloat {
            switch self {
            case .list:
                return 2.9
            case .compactGrid:
                return 2.35
            }
        }

        var realCoverLimit: Int {
            switch self {
            case .list:
                return 5
            case .compactGrid:
                return 3
            }
        }
    }

    private var visibleCovers: [String] {
        Array(covers.prefix(displayMode.realCoverLimit))
    }

    private var paletteSeed: String {
        seed.isEmpty ? covers.first ?? "" : "\(seed)-\(covers.first ?? "")"
    }

    private var shapeSeed: String {
        seed.isEmpty ? covers.first ?? "" : seed
    }

    private var palette: BookCollectionMutedPosterPalette {
        BookCollectionMutedPosterPalette.resolve(
            seed: paletteSeed,
            tone: tone
        )
    }

    private var backdropVariant: BookCollectionMutedPosterBackdropVariant {
        BookCollectionMutedPosterBackdropVariant.resolve(seed: shapeSeed)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)

        Color.clear
            .aspectRatio(displayMode.aspectRatio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                GeometryReader { proxy in
                    let size = proxy.size

                    ZStack {
                        BookCollectionMutedPosterBackdrop(
                            palette: palette,
                            size: size,
                            variant: backdropVariant
                        )

                        BookCollectionMutedPosterStack(
                            covers: visibleCovers,
                            palette: palette,
                            size: size,
                            displayMode: displayMode
                        )
                    }
                }
            }
        .compositingGroup()
        .clipShape(shape)
        .overlay {
            shape
                .stroke(Color.surfaceBorderSubtle.opacity(0.72), lineWidth: CardStyle.borderWidth)
        }
        .accessibilityHidden(true)
    }
}

private struct BookCollectionMutedPosterBackdrop: View {
    let palette: BookCollectionMutedPosterPalette
    let size: CGSize
    let variant: BookCollectionMutedPosterBackdropVariant

    var body: some View {
        ZStack {
            palette.base

            ForEach(variant.blobs) { blob in
                Ellipse()
                    .fill(blob.tone.color(in: palette).opacity(blob.opacity))
                    .frame(width: size.width * blob.widthRatio, height: size.height * blob.heightRatio)
                    .rotationEffect(.degrees(blob.rotation))
                    .position(x: size.width * blob.xRatio, y: size.height * blob.yRatio)
            }
        }
    }
}

/// 书单海报背景的稳定随机构图，只使用柔和椭圆曲线避免硬边装饰感。
private struct BookCollectionMutedPosterBackdropVariant {
    let blobs: [BookCollectionMutedPosterBlobSpec]

    static func resolve(seed: String) -> BookCollectionMutedPosterBackdropVariant {
        variants[bookCollectionStableIndex(for: seed, count: variants.count)]
    }

    private static let variants: [BookCollectionMutedPosterBackdropVariant] = [
        BookCollectionMutedPosterBackdropVariant(blobs: [
            .init(id: 0, tone: .highlight, x: 0.24, y: 0.12, width: 0.86, height: 0.74, rotation: 0, opacity: 1.00),
            .init(id: 1, tone: .wash, x: 0.84, y: 0.72, width: 0.62, height: 1.28, rotation: -4, opacity: 1.00),
            .init(id: 2, tone: .accentWash, x: 0.16, y: 0.74, width: 0.48, height: 1.06, rotation: 6, opacity: 1.00)
        ]),
        BookCollectionMutedPosterBackdropVariant(blobs: [
            .init(id: 0, tone: .highlight, x: 0.42, y: 0.18, width: 0.78, height: 0.72, rotation: -8, opacity: 0.96),
            .init(id: 1, tone: .wash, x: 0.72, y: 0.82, width: 0.72, height: 1.18, rotation: 10, opacity: 0.94),
            .init(id: 2, tone: .accentWash, x: 0.12, y: 0.62, width: 0.54, height: 0.94, rotation: -12, opacity: 0.92)
        ]),
        BookCollectionMutedPosterBackdropVariant(blobs: [
            .init(id: 0, tone: .highlight, x: 0.54, y: -0.02, width: 0.74, height: 0.62, rotation: 4, opacity: 0.96),
            .init(id: 1, tone: .accentWash, x: 0.30, y: 0.78, width: 0.66, height: 1.08, rotation: -10, opacity: 0.96),
            .init(id: 2, tone: .wash, x: 0.90, y: 0.58, width: 0.58, height: 1.20, rotation: 8, opacity: 0.90),
            .init(id: 3, tone: .highlight, x: 0.04, y: 0.18, width: 0.38, height: 0.52, rotation: 16, opacity: 0.50)
        ]),
        BookCollectionMutedPosterBackdropVariant(blobs: [
            .init(id: 0, tone: .wash, x: 0.18, y: 0.18, width: 0.78, height: 0.86, rotation: 12, opacity: 0.90),
            .init(id: 1, tone: .highlight, x: 0.70, y: 0.14, width: 0.66, height: 0.58, rotation: -6, opacity: 0.88),
            .init(id: 2, tone: .accentWash, x: 0.76, y: 0.86, width: 0.74, height: 1.08, rotation: -14, opacity: 0.96)
        ]),
        BookCollectionMutedPosterBackdropVariant(blobs: [
            .init(id: 0, tone: .highlight, x: 0.16, y: 0.08, width: 0.58, height: 0.58, rotation: -18, opacity: 0.78),
            .init(id: 1, tone: .accentWash, x: 0.42, y: 0.70, width: 0.80, height: 1.18, rotation: 8, opacity: 0.92),
            .init(id: 2, tone: .wash, x: 0.88, y: 0.36, width: 0.52, height: 0.92, rotation: 14, opacity: 0.94),
            .init(id: 3, tone: .highlight, x: 0.66, y: 0.02, width: 0.42, height: 0.46, rotation: 0, opacity: 0.44)
        ]),
        BookCollectionMutedPosterBackdropVariant(blobs: [
            .init(id: 0, tone: .highlight, x: 0.28, y: 0.28, width: 0.96, height: 0.68, rotation: -6, opacity: 0.88),
            .init(id: 1, tone: .wash, x: 0.58, y: 0.84, width: 0.62, height: 1.16, rotation: 18, opacity: 0.92),
            .init(id: 2, tone: .accentWash, x: 0.98, y: 0.66, width: 0.46, height: 0.98, rotation: -10, opacity: 0.82)
        ]),
        BookCollectionMutedPosterBackdropVariant(blobs: [
            .init(id: 0, tone: .wash, x: 0.04, y: 0.70, width: 0.54, height: 1.02, rotation: 6, opacity: 0.86),
            .init(id: 1, tone: .highlight, x: 0.52, y: 0.10, width: 0.84, height: 0.66, rotation: 10, opacity: 0.96),
            .init(id: 2, tone: .accentWash, x: 0.74, y: 0.78, width: 0.68, height: 1.14, rotation: -8, opacity: 0.92),
            .init(id: 3, tone: .highlight, x: 0.96, y: 0.20, width: 0.34, height: 0.44, rotation: -16, opacity: 0.42)
        ]),
        BookCollectionMutedPosterBackdropVariant(blobs: [
            .init(id: 0, tone: .accentWash, x: 0.24, y: 0.80, width: 0.76, height: 1.08, rotation: -12, opacity: 0.88),
            .init(id: 1, tone: .highlight, x: 0.32, y: 0.02, width: 0.70, height: 0.54, rotation: 8, opacity: 0.88),
            .init(id: 2, tone: .wash, x: 0.86, y: 0.62, width: 0.66, height: 1.26, rotation: 6, opacity: 0.94)
        ])
    ]
}

private struct BookCollectionMutedPosterBlobSpec: Identifiable {
    let id: Int
    let tone: BookCollectionMutedPosterBlobTone
    let xRatio: CGFloat
    let yRatio: CGFloat
    let widthRatio: CGFloat
    let heightRatio: CGFloat
    let rotation: Double
    let opacity: Double

    init(
        id: Int,
        tone: BookCollectionMutedPosterBlobTone,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat,
        rotation: Double,
        opacity: Double
    ) {
        self.id = id
        self.tone = tone
        self.xRatio = x
        self.yRatio = y
        self.widthRatio = width
        self.heightRatio = height
        self.rotation = rotation
        self.opacity = opacity
    }
}

private enum BookCollectionMutedPosterBlobTone {
    case highlight
    case wash
    case accentWash

    func color(in palette: BookCollectionMutedPosterPalette) -> Color {
        switch self {
        case .highlight:
            return palette.highlight
        case .wash:
            return palette.wash
        case .accentWash:
            return palette.accentWash
        }
    }
}

private struct BookCollectionMutedPosterStack: View {
    let covers: [String]
    let palette: BookCollectionMutedPosterPalette
    let size: CGSize
    let displayMode: BookCollectionMutedPosterCoverView.DisplayMode

    var body: some View {
        ZStack {
            ForEach(slots) { slot in
                BookCollectionMutedPosterBook(
                    cover: slot.cover,
                    palette: palette,
                    width: slot.width(in: size, displayMode: displayMode),
                    isPaperLayer: slot.isPaperLayer
                )
                .opacity(slot.opacity)
                .rotationEffect(.degrees(slot.rotation))
                .position(slot.position(in: size))
                .zIndex(slot.zIndex)
            }
        }
    }

    private var slots: [BookCollectionMutedPosterSlot] {
        switch displayMode {
        case .list:
            return listSlots
        case .compactGrid:
            return compactGridSlots
        }
    }

    private var listSlots: [BookCollectionMutedPosterSlot] {
        switch covers.count {
        case 0:
            return [
                paper(id: 0, x: 0.36, y: 0.58, width: 0.150, rotation: -4.0, zIndex: 3, opacity: 0.62),
                paper(id: 1, x: 0.48, y: 0.52, width: 0.140, rotation: 4.0, zIndex: 2, opacity: 0.56),
                paper(id: 2, x: 0.59, y: 0.60, width: 0.132, rotation: -2.0, zIndex: 1, opacity: 0.50)
            ]
        case 1:
            return [
                paper(id: 0, x: 0.34, y: 0.58, width: 0.138, rotation: -5.0, zIndex: 1, opacity: 0.44),
                paper(id: 1, x: 0.55, y: 0.56, width: 0.132, rotation: 5.0, zIndex: 2, opacity: 0.48),
                cover(id: 2, index: 0, x: 0.43, y: 0.55, width: 0.172, rotation: -2.0, zIndex: 3)
            ]
        case 2:
            return [
                paper(id: 0, x: 0.61, y: 0.60, width: 0.128, rotation: -3.0, zIndex: 1, opacity: 0.46),
                cover(id: 1, index: 1, x: 0.50, y: 0.52, width: 0.152, rotation: 4.0, zIndex: 2),
                cover(id: 2, index: 0, x: 0.38, y: 0.57, width: 0.172, rotation: -2.0, zIndex: 3)
            ]
        case 3:
            return [
                cover(id: 0, index: 2, x: 0.60, y: 0.58, width: 0.144, rotation: 5.0, zIndex: 1),
                cover(id: 1, index: 1, x: 0.47, y: 0.51, width: 0.152, rotation: -2.0, zIndex: 2),
                cover(id: 2, index: 0, x: 0.34, y: 0.58, width: 0.168, rotation: 2.0, zIndex: 3)
            ]
        case 4:
            return [
                cover(id: 0, index: 3, x: 0.66, y: 0.57, width: 0.132, rotation: 6.0, zIndex: 1),
                cover(id: 1, index: 2, x: 0.54, y: 0.61, width: 0.140, rotation: -5.0, zIndex: 2),
                cover(id: 2, index: 1, x: 0.42, y: 0.51, width: 0.150, rotation: 3.0, zIndex: 3),
                cover(id: 3, index: 0, x: 0.30, y: 0.58, width: 0.168, rotation: -2.0, zIndex: 4)
            ]
        default:
            return [
                cover(id: 0, index: 4, x: 0.68, y: 0.58, width: 0.128, rotation: -5.0, zIndex: 1),
                cover(id: 1, index: 3, x: 0.58, y: 0.51, width: 0.134, rotation: 6.0, zIndex: 2),
                cover(id: 2, index: 2, x: 0.49, y: 0.61, width: 0.142, rotation: -4.0, zIndex: 3),
                cover(id: 3, index: 1, x: 0.39, y: 0.52, width: 0.150, rotation: 3.0, zIndex: 4),
                cover(id: 4, index: 0, x: 0.29, y: 0.58, width: 0.168, rotation: -2.0, zIndex: 5)
            ]
        }
    }

    private var compactGridSlots: [BookCollectionMutedPosterSlot] {
        switch covers.count {
        case 0:
            return [
                paper(id: 0, x: 0.34, y: 0.58, width: 0.190, rotation: -4.0, zIndex: 3, opacity: 0.60),
                paper(id: 1, x: 0.49, y: 0.52, width: 0.174, rotation: 4.0, zIndex: 2, opacity: 0.54),
                paper(id: 2, x: 0.63, y: 0.59, width: 0.160, rotation: -2.0, zIndex: 1, opacity: 0.48)
            ]
        case 1:
            return [
                paper(id: 0, x: 0.38, y: 0.58, width: 0.168, rotation: -5.0, zIndex: 1, opacity: 0.44),
                paper(id: 1, x: 0.62, y: 0.56, width: 0.158, rotation: 5.0, zIndex: 2, opacity: 0.48),
                cover(id: 2, index: 0, x: 0.50, y: 0.55, width: 0.198, rotation: -2.0, zIndex: 3)
            ]
        case 2:
            return [
                paper(id: 0, x: 0.66, y: 0.60, width: 0.154, rotation: -3.0, zIndex: 1, opacity: 0.46),
                cover(id: 1, index: 1, x: 0.52, y: 0.52, width: 0.180, rotation: 4.0, zIndex: 2),
                cover(id: 2, index: 0, x: 0.38, y: 0.57, width: 0.198, rotation: -2.0, zIndex: 3)
            ]
        default:
            return [
                cover(id: 0, index: 2, x: 0.66, y: 0.58, width: 0.160, rotation: 5.0, zIndex: 1),
                cover(id: 1, index: 1, x: 0.50, y: 0.51, width: 0.180, rotation: -2.0, zIndex: 2),
                cover(id: 2, index: 0, x: 0.34, y: 0.58, width: 0.198, rotation: 2.0, zIndex: 3)
            ]
        }
    }

    private func cover(
        id: Int,
        index: Int,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        rotation: Double,
        zIndex: Double
    ) -> BookCollectionMutedPosterSlot {
        BookCollectionMutedPosterSlot(
            id: id,
            cover: covers[index],
            xRatio: x,
            yRatio: y,
            widthRatio: width,
            rotation: rotation,
            zIndex: zIndex,
            opacity: 1
        )
    }

    private func paper(
        id: Int,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        rotation: Double,
        zIndex: Double,
        opacity: Double
    ) -> BookCollectionMutedPosterSlot {
        BookCollectionMutedPosterSlot(
            id: id,
            cover: nil,
            xRatio: x,
            yRatio: y,
            widthRatio: width,
            rotation: rotation,
            zIndex: zIndex,
            opacity: opacity
        )
    }
}

/// 书单海报封面的内部槽位，用书籍数量决定封面与纸张层的构图关系。
private struct BookCollectionMutedPosterSlot: Identifiable {
    let id: Int
    let cover: String?
    let xRatio: CGFloat
    let yRatio: CGFloat
    let widthRatio: CGFloat
    let rotation: Double
    let zIndex: Double
    let opacity: Double

    var isPaperLayer: Bool {
        cover == nil
    }

    /// 将 Figma 比例坐标映射到当前 poster 尺寸内的位置。
    func position(in size: CGSize) -> CGPoint {
        CGPoint(x: size.width * xRatio, y: size.height * yRatio)
    }

    /// 将比例宽度限制在列表与紧凑网格各自可读的封面尺寸内。
    func width(
        in size: CGSize,
        displayMode: BookCollectionMutedPosterCoverView.DisplayMode
    ) -> CGFloat {
        let rawWidth = size.width * widthRatio
        let minimum: CGFloat = displayMode == .list ? 36 : 28
        let maximum: CGFloat = displayMode == .list ? 58 : 44
        return min(max(rawWidth, minimum), maximum)
    }
}

private struct BookCollectionMutedPosterBook: View {
    let cover: String?
    let palette: BookCollectionMutedPosterPalette
    let width: CGFloat
    let isPaperLayer: Bool

    var body: some View {
        Group {
            if let cover {
                XMBookCover.fixedWidth(
                    width,
                    urlString: cover,
                    cornerRadius: CornerRadius.inlaySmall,
                    border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth),
                    placeholderIconSize: .small,
                    surfaceStyle: .spine
                )
            } else {
                placeholderBook
            }
        }
        .shadow(
            color: Color.bookCoverDropShadow.opacity(isPaperLayer ? 0.08 : 0.26),
            radius: isPaperLayer ? 2 : (width > 50 ? 5 : 4),
            x: Spacing.none,
            y: isPaperLayer ? 1 : (width > 50 ? 3 : 2)
        )
    }

    private var placeholderBook: some View {
        RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
            .fill(palette.paper.opacity(0.92))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color.bookCoverSpineDark.opacity(0.10))
                    .frame(width: max(2, width * 0.08))
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(palette.paperBand.opacity(0.70))
                    .frame(height: max(7, width * 0.18))
            }
            .frame(width: width, height: XMBookCover.height(forWidth: width))
            .overlay {
                RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                    .stroke(Color.surfaceBorderSubtle.opacity(0.34), lineWidth: CardStyle.borderWidth)
            }
    }
}

private struct BookCollectionMutedPosterPalette {
    let base: Color
    let wash: Color
    let accentWash: Color
    let highlight: Color
    let paper: Color
    let paperBand: Color

    static func resolve(seed: String, tone: BookCollectionKind) -> BookCollectionMutedPosterPalette {
        let variants = tone == .annual ? annualVariants : manualVariants
        return variants[bookCollectionStableIndex(for: seed, count: variants.count)]
    }

    private static let manualVariants: [BookCollectionMutedPosterPalette] = [
        BookCollectionMutedPosterPalette(
            base: Color(light: Color(hex: 0xEEF4F1), dark: Color(hex: 0x1F2623)),
            wash: Color(light: Color(hex: 0xC9E3DA).opacity(0.72), dark: Color(hex: 0x355247).opacity(0.62)),
            accentWash: Color(light: Color(hex: 0xE6EEF7).opacity(0.82), dark: Color(hex: 0x344356).opacity(0.58)),
            highlight: Color(light: Color.white.opacity(0.54), dark: Color.white.opacity(0.05)),
            paper: Color(light: Color(hex: 0xF6F2E7), dark: Color(hex: 0x4A4234)),
            paperBand: Color(light: Color(hex: 0xE0D3B6), dark: Color(hex: 0x70634A))
        ),
        BookCollectionMutedPosterPalette(
            base: Color(light: Color(hex: 0xF2F4EC), dark: Color(hex: 0x24261F)),
            wash: Color(light: Color(hex: 0xDCE7D0).opacity(0.74), dark: Color(hex: 0x45533A).opacity(0.58)),
            accentWash: Color(light: Color(hex: 0xE9EEE2).opacity(0.86), dark: Color(hex: 0x394336).opacity(0.64)),
            highlight: Color(light: Color.white.opacity(0.52), dark: Color.white.opacity(0.05)),
            paper: Color(light: Color(hex: 0xF5EDDC), dark: Color(hex: 0x4A3E31)),
            paperBand: Color(light: Color(hex: 0xD8C79F), dark: Color(hex: 0x756241))
        ),
        BookCollectionMutedPosterPalette(
            base: Color(light: Color(hex: 0xF2F1EC), dark: Color(hex: 0x25231F)),
            wash: Color(light: Color(hex: 0xDFD6C4).opacity(0.70), dark: Color(hex: 0x514636).opacity(0.56)),
            accentWash: Color(light: Color(hex: 0xDDE9E0).opacity(0.78), dark: Color(hex: 0x354B3C).opacity(0.58)),
            highlight: Color(light: Color.white.opacity(0.50), dark: Color.white.opacity(0.05)),
            paper: Color(light: Color(hex: 0xF1E7D1), dark: Color(hex: 0x4B3D2E)),
            paperBand: Color(light: Color(hex: 0xD7C095), dark: Color(hex: 0x74603E))
        )
    ]

    private static let annualVariants: [BookCollectionMutedPosterPalette] = [
        BookCollectionMutedPosterPalette(
            base: Color(light: Color(hex: 0xEDF3F8), dark: Color(hex: 0x1F252A)),
            wash: Color(light: Color(hex: 0xD5E4EF).opacity(0.78), dark: Color(hex: 0x394D5E).opacity(0.58)),
            accentWash: Color(light: Color(hex: 0xC9E2DA).opacity(0.72), dark: Color(hex: 0x355048).opacity(0.56)),
            highlight: Color(light: Color.white.opacity(0.54), dark: Color.white.opacity(0.05)),
            paper: Color(light: Color(hex: 0xF7F2E5), dark: Color(hex: 0x4A4233)),
            paperBand: Color(light: Color(hex: 0xDDD0AE), dark: Color(hex: 0x75664B))
        ),
        BookCollectionMutedPosterPalette(
            base: Color(light: Color(hex: 0xF3F1EB), dark: Color(hex: 0x25231F)),
            wash: Color(light: Color(hex: 0xE4DAC8).opacity(0.78), dark: Color(hex: 0x504535).opacity(0.56)),
            accentWash: Color(light: Color(hex: 0xD7E6D1).opacity(0.72), dark: Color(hex: 0x40543A).opacity(0.54)),
            highlight: Color(light: Color.white.opacity(0.54), dark: Color.white.opacity(0.05)),
            paper: Color(light: Color(hex: 0xF6EDD9), dark: Color(hex: 0x4C4030)),
            paperBand: Color(light: Color(hex: 0xDDC89E), dark: Color(hex: 0x74613F))
        )
    ]
}

private func bookCollectionStableIndex(for seed: String, count: Int) -> Int {
    guard count > 0 else { return 0 }
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in seed.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 1_099_511_628_211
    }
    return Int(hash % UInt64(count))
}

/// 书单指标条，用相邻小文本表达统计口径，避免模板化大数字指标卡。
struct BookCollectionMetricStrip: View {
    let bookCount: Int
    let finishedCount: Int
    let targetReadCount: Int?
    var layout: Layout = .inline

    enum Layout {
        case inline
        case compact
    }

    var body: some View {
        HStack(spacing: layout == .inline ? Spacing.base : Spacing.tight) {
            metric(value: "\(bookCount)", label: "本书")
            metric(value: "\(finishedCount)", label: "读完")

            if let targetReadCount, targetReadCount > 0 {
                metric(value: "\(finishedCount)/\(targetReadCount)", label: "目标")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func metric(value: String, label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.micro) {
            Text(value)
                .font(AppTypography.captionSemibold)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)

            Text(label)
                .font(AppTypography.caption2)
                .foregroundStyle(Color.textHint)
                .lineLimit(1)
        }
    }
}

/// 年度目标进度条，用轻量线性反馈表达读完目标，不引入榜单或社区化语义。
struct BookCollectionProgressMeter: View {
    let finishedCount: Int
    let targetReadCount: Int?

    var body: some View {
        if let targetReadCount, targetReadCount > 0 {
            VStack(alignment: .leading, spacing: Spacing.compact) {
                ProgressView(
                    value: min(Double(finishedCount), Double(targetReadCount)),
                    total: Double(targetReadCount)
                )
                .progressViewStyle(.linear)
                .tint(Color.brandDeep.opacity(0.62))

                Text("读完 \(finishedCount)/\(targetReadCount) 本")
                    .font(AppTypography.caption2)
                    .foregroundStyle(Color.textSecondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("年度目标，读完 \(finishedCount) 本，共 \(targetReadCount) 本")
        }
    }
}

/// 书单列表卡片，建立封面、主题和统计之间的稳定层级。
struct BookCollectionListCard: View {
    let item: BookCollectionListItem

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            BookCollectionMutedPosterCoverView(
                covers: item.representativeCovers,
                tone: item.kind,
                seed: posterSeed,
                displayMode: .list
            )

            VStack(alignment: .leading, spacing: Spacing.cozy) {
                Text(title)
                    .font(AppTypography.headlineSemibold)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                BookCollectionProgressMeter(
                    finishedCount: item.finishedCount,
                    targetReadCount: item.targetReadCount
                )

                HStack(alignment: .center, spacing: Spacing.tight) {
                    BookCollectionMetricStrip(
                        bookCount: item.bookCount,
                        finishedCount: item.finishedCount,
                        targetReadCount: item.targetReadCount,
                        layout: .compact
                    )

                    Spacer(minLength: Spacing.tight)

                    Image(systemName: "chevron.right")
                        .font(AppTypography.captionMedium)
                        .foregroundStyle(Color.textHint)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, Spacing.compact)
            .padding(.bottom, Spacing.compact)
        }
        .padding(Spacing.base)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.containerMedium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.containerMedium, style: .continuous)
                .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var title: String {
        if item.kind == .annual, let year = item.year, item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(year) 年阅读"
        }
        return item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名书单" : item.title
    }

    private var subtitle: String {
        let description = item.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty {
            return description
        }
        switch item.kind {
        case .manual:
            return item.bookCount == 0 ? "还没有加入书籍。" : ""
        case .annual:
            return item.bookCount == 0 ? "读完记录会显示在这里。" : ""
        }
    }

    private var accessibilityLabel: String {
        var parts = [title, item.kind == .annual ? "年度书单" : "我的书单", "\(item.bookCount)本书"]
        if item.finishedCount > 0 {
            parts.append("读完\(item.finishedCount)本")
        }
        if let target = item.targetReadCount, target > 0 {
            parts.append("年度目标\(item.finishedCount)/\(target)")
        }
        return parts.joined(separator: "，")
    }

    private var posterSeed: String {
        [
            String(item.id),
            title,
            item.year.map(String.init) ?? ""
        ]
        .joined(separator: "-")
    }
}

/// 书单详情头，将书单主题、统计、只读边界和主动作集中在页面叙事层。
struct BookCollectionDetailHero: View {
    let detail: BookCollectionDetail
    let canPerformAction: Bool
    let onAddBook: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            HStack(alignment: .top, spacing: Spacing.base) {
                BookCollectionCoverMosaicView(
                    covers: detail.books.prefix(4).map(\.book.cover),
                    size: 106,
                    tone: detail.kind
                )

                VStack(alignment: .leading, spacing: Spacing.cozy) {
                    BookCollectionStatusBadge(text: kindLabel, systemImage: kindIcon)

                    Text(title)
                        .font(AppTypography.title3Semibold)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(description)
                        .font(AppTypography.callout)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)

                    BookCollectionMetricStrip(
                        bookCount: detail.bookCount,
                        finishedCount: detail.finishedCount,
                        targetReadCount: detail.targetReadCount
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            BookCollectionProgressMeter(
                finishedCount: detail.finishedCount,
                targetReadCount: detail.targetReadCount
            )

            if detail.kind == .annual {
                BookCollectionReadOnlyNotice()
            } else {
                Button(action: onAddBook) {
                    Label("加入书籍", systemImage: "plus")
                        .font(AppTypography.subheadlineMedium)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canPerformAction)
            }
        }
        .padding(Spacing.section)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.containerMedium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.containerMedium, style: .continuous)
                .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
        }
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        if detail.kind == .annual, let year = detail.year, detail.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(year) 年阅读"
        }
        return detail.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名书单" : detail.title
    }

    private var description: String {
        let text = detail.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            return text
        }
        switch detail.kind {
        case .manual:
            return detail.bookCount == 0 ? "从书架里挑选几本书，给这个主题一个开始。" : "按你的阅读主题整理出的书籍集合。"
        case .annual:
            return "随读完记录自动同步，保留这一年的阅读轨迹。"
        }
    }

    private var kindLabel: String {
        switch detail.kind {
        case .manual:
            return "我的整理"
        case .annual:
            return "年度同步"
        }
    }

    private var kindIcon: String {
        switch detail.kind {
        case .manual:
            return "books.vertical"
        case .annual:
            return "lock"
        }
    }
}

/// 书单内书籍卡片，将书籍信息、阅读元数据和推荐语组织在同一关系单元内。
struct BookCollectionBookCard: View {
    let item: BookCollectionBookItem
    let isEditable: Bool
    let onOpen: () -> Void
    let onEditBook: () -> Void
    let onEditRecommend: () -> Void
    let onRemove: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                HStack(alignment: .top, spacing: Spacing.base) {
                    XMBookCover.fixedWidth(
                        62,
                        urlString: item.book.cover,
                        cornerRadius: CornerRadius.inlaySmall,
                        border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth),
                        placeholderIconSize: .small,
                        surfaceStyle: .spine
                    )

                    VStack(alignment: .leading, spacing: Spacing.cozy) {
                        Text(item.book.title.isEmpty ? "未命名书籍" : item.book.title)
                            .font(AppTypography.subheadlineSemibold)
                            .foregroundStyle(Color.textPrimary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)

                        if !item.book.author.isEmpty {
                            Text(item.book.author)
                                .font(AppTypography.caption)
                                .foregroundStyle(Color.textSecondary)
                                .lineLimit(1)
                        }

                        if !metadataText.isEmpty {
                            Label(metadataText, systemImage: "bookmark")
                                .font(AppTypography.caption2)
                                .foregroundStyle(Color.textHint)
                                .labelStyle(.titleAndIcon)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.right")
                        .font(AppTypography.caption2Semibold)
                        .foregroundStyle(Color.textHint)
                        .padding(.top, Spacing.half)
                }

                if !trimmedRecommend.isEmpty {
                    BookCollectionRecommendQuote(
                        text: trimmedRecommend,
                        isEditable: isEditable,
                        onEdit: onEditRecommend
                    )
                }
            }
            .padding(.horizontal, Spacing.base)
            .padding(.vertical, Spacing.tight)
            .contentShape(RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                .stroke(Color.surfaceBorderSubtle.opacity(0.55), lineWidth: CardStyle.borderWidth)
        }
        .contextMenu {
            Button {
                onOpen()
            } label: {
                XMMenuLabel("查看书籍", systemImage: "book")
            }

            Button {
                onEditBook()
            } label: {
                XMMenuLabel("编辑书籍", systemImage: "pencil")
            }

            Button {
                onEditRecommend()
            } label: {
                XMMenuLabel(item.recommend.isEmpty ? "添加推荐语" : "编辑推荐语", systemImage: "quote.bubble")
            }
            .disabled(!isEditable)

            if isEditable {
                Button(role: .destructive) {
                    onRemove()
                } label: {
                    Label("移出书单", systemImage: "minus.circle")
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if isEditable {
                Button {
                    onEditRecommend()
                } label: {
                    Label("推荐语", systemImage: "quote.bubble")
                }
                .tint(.blue)

                Button(role: .destructive) {
                    onRemove()
                } label: {
                    Label("移出", systemImage: "minus.circle")
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var metadataText: String {
        var parts: [String] = []
        if !item.book.readStatusBadgeTitle.isEmpty {
            parts.append(item.book.readStatusBadgeTitle)
        }
        if item.book.noteCount > 0 {
            parts.append("\(item.book.noteCount) 条书摘")
        }
        if !item.book.readingProgressText.isEmpty {
            parts.append(item.book.readingProgressText)
        }
        return parts.joined(separator: " · ")
    }

    private var trimmedRecommend: String {
        item.recommend.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var accessibilityLabel: String {
        var parts = [item.book.title.isEmpty ? "未命名书籍" : item.book.title]
        if !item.book.author.isEmpty {
            parts.append(item.book.author)
        }
        if !metadataText.isEmpty {
            parts.append(metadataText)
        }
        if !trimmedRecommend.isEmpty {
            parts.append("推荐语，\(trimmedRecommend)")
        } else if isEditable {
            parts.append("可添加推荐语")
        }
        return parts.joined(separator: "，")
    }
}

/// 推荐语区块，让 relation 的主观价值成为书单内容，而不是行内弱说明。
struct BookCollectionRecommendQuote: View {
    let text: String
    let isEditable: Bool
    let onEdit: () -> Void

    var body: some View {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        Button(action: onEdit) {
            HStack(alignment: .top, spacing: Spacing.tight) {
                RoundedRectangle(cornerRadius: CornerRadius.inlayTiny, style: .continuous)
                    .fill(Color.brand.opacity(0.18))
                    .frame(width: 3, height: 34)

                Text(trimmed)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: Spacing.compact)

                if isEditable {
                    Image(systemName: "pencil")
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textHint)
                }
            }
            .padding(.horizontal, Spacing.tight)
            .padding(.vertical, Spacing.cozy)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.surfaceNested.opacity(0.82), in: RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEditable)
        .accessibilityLabel("推荐语，\(trimmed)")
    }
}

/// 书单状态徽标，限定在书单列表与详情头的小型语义说明。
struct BookCollectionStatusBadge: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(AppTypography.caption2Medium)
            .foregroundStyle(Color.textSecondary)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, Spacing.half)
            .padding(.vertical, Spacing.micro)
            .background(Color.surfaceNested, in: Capsule())
            .fixedSize(horizontal: true, vertical: false)
    }
}

/// 年度书单只读说明，放在详情头内，避免页面中部重复占位。
private struct BookCollectionReadOnlyNotice: View {
    var body: some View {
        Label("年度书单只读，随读完记录同步。", systemImage: "lock")
            .font(AppTypography.caption)
            .foregroundStyle(Color.textSecondary)
            .padding(.horizontal, Spacing.tight)
            .padding(.vertical, Spacing.cozy)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.surfaceNested, in: RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous))
    }
}

/// 书单首页读取占位，保持首屏结构稳定，避免列表加载时出现空白内容区。
struct BookCollectionListSkeletonRows: View {
    var body: some View {
        VStack(spacing: Spacing.base) {
            ForEach(0..<3, id: \.self) { _ in
                BookCollectionListSkeletonCard()
            }
        }
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.top, Spacing.half)
        .redacted(reason: .placeholder)
        .allowsHitTesting(false)
    }
}

/// 书单详情读取占位，承接顶部栏下方内容，避免导航转场时露出纯空白页。
struct BookCollectionDetailSkeletonContent: View {
    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.base) {
                BookCollectionDetailSkeletonHero()
                    .padding(.horizontal, Spacing.screenEdge)
                    .padding(.top, Spacing.base)

                ForEach(0..<4, id: \.self) { _ in
                    BookCollectionBookSkeletonCard()
                        .padding(.horizontal, Spacing.screenEdge)
                }
            }
            .padding(.bottom, Spacing.double)
        }
        .scrollIndicators(.hidden)
        .redacted(reason: .placeholder)
        .allowsHitTesting(false)
    }
}

struct BookCollectionListSkeletonCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            BookCollectionPosterSkeletonCover()

            VStack(alignment: .leading, spacing: Spacing.cozy) {
                RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                    .fill(Color.surfaceNested)
                    .frame(width: 168, height: 18)

                RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                    .fill(Color.surfaceNested)
                    .frame(width: 220, height: 14)

                HStack(spacing: Spacing.tight) {
                    RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                        .fill(Color.surfaceNested)
                        .frame(width: 132, height: 14)

                    Spacer(minLength: Spacing.tight)

                    RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                        .fill(Color.surfaceNested)
                        .frame(width: 18, height: 14)
                }
            }
            .padding(.horizontal, Spacing.compact)
            .padding(.bottom, Spacing.compact)
        }
        .padding(Spacing.base)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.containerMedium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.containerMedium, style: .continuous)
                .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
        }
    }
}

/// 书单列表 poster 加载态，用弱纸张层承接完成态的横向书带结构。
private struct BookCollectionPosterSkeletonCover: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)

        Color.clear
            .aspectRatio(2.9, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                GeometryReader { proxy in
                    let size = proxy.size

                    ZStack {
                        Color.surfaceNested.opacity(0.82)

                        Ellipse()
                            .fill(Color.controlFillSecondary.opacity(0.40))
                            .frame(width: size.width * 0.86, height: size.height * 0.74)
                            .position(x: size.width * 0.24, y: size.height * 0.12)

                        Ellipse()
                            .fill(Color.surfaceCard.opacity(0.76))
                            .frame(width: size.width * 0.62, height: size.height * 1.28)
                            .position(x: size.width * 0.84, y: size.height * 0.72)

                        Ellipse()
                            .fill(Color.controlFillSecondary.opacity(0.28))
                            .frame(width: size.width * 0.48, height: size.height * 1.06)
                            .position(x: size.width * 0.16, y: size.height * 0.74)

                        ForEach(0..<3, id: \.self) { index in
                            skeletonPaper(index: index, size: size)
                        }
                    }
                }
            }
            .clipShape(shape)
            .overlay {
                shape
                    .stroke(Color.surfaceBorderSubtle.opacity(0.72), lineWidth: CardStyle.borderWidth)
            }
    }

    private func skeletonPaper(index: Int, size: CGSize) -> some View {
        let specs: [(x: CGFloat, y: CGFloat, width: CGFloat, rotation: Double, opacity: Double)] = [
            (0.36, 0.58, 0.150, -4.0, 0.44),
            (0.48, 0.52, 0.140, 4.0, 0.38),
            (0.59, 0.60, 0.132, -2.0, 0.34)
        ]
        let spec = specs[index]
        let width = min(max(size.width * spec.width, 36), 58)

        return RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
            .fill(Color.surfaceCard.opacity(spec.opacity))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color.surfaceBorderSubtle.opacity(0.32))
                    .frame(width: max(2, width * 0.08))
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.surfaceBorderSubtle.opacity(0.28))
                    .frame(height: max(7, width * 0.18))
            }
            .frame(width: width, height: XMBookCover.height(forWidth: width))
            .overlay {
                RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                    .stroke(Color.surfaceBorderSubtle.opacity(0.28), lineWidth: CardStyle.borderWidth)
            }
            .rotationEffect(.degrees(spec.rotation))
            .position(x: size.width * spec.x, y: size.height * spec.y)
    }
}

private struct BookCollectionDetailSkeletonHero: View {
    var body: some View {
        HStack(alignment: .top, spacing: Spacing.base) {
            RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                .fill(Color.surfaceNested)
                .frame(width: 106, height: 106)

            VStack(alignment: .leading, spacing: Spacing.cozy) {
                RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                    .fill(Color.surfaceNested)
                    .frame(width: 82, height: 22)

                RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                    .fill(Color.surfaceNested)
                    .frame(width: 176, height: 20)

                RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                    .fill(Color.surfaceNested)
                    .frame(width: 210, height: 14)

                RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                    .fill(Color.surfaceNested)
                    .frame(width: 148, height: 14)
            }
        }
        .padding(Spacing.section)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.containerMedium, style: .continuous))
    }
}

private struct BookCollectionBookSkeletonCard: View {
    var body: some View {
        HStack(alignment: .top, spacing: Spacing.base) {
            RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                .fill(Color.surfaceNested)
                .frame(width: 62, height: 88)

            VStack(alignment: .leading, spacing: Spacing.cozy) {
                RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                    .fill(Color.surfaceNested)
                    .frame(width: 190, height: 18)

                RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                    .fill(Color.surfaceNested)
                    .frame(width: 132, height: 14)

                RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                    .fill(Color.surfaceNested)
                    .frame(width: 112, height: 12)
            }
        }
        .padding(.horizontal, Spacing.base)
        .padding(.vertical, Spacing.tight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
    }
}
