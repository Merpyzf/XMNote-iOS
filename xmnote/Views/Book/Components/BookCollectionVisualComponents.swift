/**
 * [INPUT]: 依赖 BookCollectionListItem、BookCollectionDisplaySetting、BookCollectionDetail、BookCollectionBookItem、XMBookCover、XMBookCoverAppearance、InteractionMetrics 与 ReadingStatusPresentation 渲染书单列表、详情和书单内书籍关系
 * [OUTPUT]: 对外提供书单模块页面私有视觉组件，统一堆叠/规整封面、海报式封面、指标、详情头、书籍卡片、中性上下文操作、书籍元信息入口与 relation 文本语义区块
 * [POS]: Book 模块书单页面私有展示组件，被 BookCollectionListView、BookCollectionDetailView 与加入书单 Sheet 复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书单页面对进度、总结和补充入口的统一强调色，避免把组件细节提升为全局色阶。
private enum BookCollectionVisualAppearance {
    static let emphasisAccent = Color.xmHex(0x2DA44F)
}

/// 书单内 relation 文本的页面展示语义，将同一 `recommend` 字段映射为普通书单收藏理由或年度书单年度点评。
nonisolated struct BookCollectionRelationNotePresentation: Hashable, Sendable {
    let title: String
    let addTitle: String
    let editTitle: String
    let placeholder: String
    let clearHint: String
    let emptyAccessibilityHint: String
    let savingMessage: String
    let savedMessage: String

    /// 根据书单类型生成 relation 文本在当前页面中的业务文案。
    static func make(kind: BookCollectionKind) -> BookCollectionRelationNotePresentation {
        switch kind {
        case .manual:
            return BookCollectionRelationNotePresentation(
                title: "收藏理由",
                addTitle: "添加收藏理由",
                editTitle: "编辑收藏理由",
                placeholder: "写下收藏理由",
                clearHint: "留空保存会清除收藏理由，但不会移出书单",
                emptyAccessibilityHint: "可添加收藏理由",
                savingMessage: "正在保存收藏理由…",
                savedMessage: "收藏理由已保存"
            )
        case .annual:
            return BookCollectionRelationNotePresentation(
                title: "年度点评",
                addTitle: "添加年度点评",
                editTitle: "编辑年度点评",
                placeholder: "写下年度点评",
                clearHint: "留空保存会清除年度点评，但不会改变年度书单成员",
                emptyAccessibilityHint: "可添加年度点评",
                savingMessage: "正在保存年度点评…",
                savedMessage: "年度点评已保存"
            )
        }
    }

    /// 根据 relation 文本是否已有内容，输出用户当前会执行的编辑动作。
    func editActionTitle(hasText: Bool) -> String {
        hasText ? editTitle : addTitle
    }
}

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
                        .stroke(Color.surfaceBorderSubtle, lineWidth: StrokeWidth.hairline)
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
                    border: .init(color: .surfaceBorderSubtle, width: StrokeWidth.hairline),
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
                        border: .init(color: .surfaceBorderSubtle, width: StrokeWidth.hairline),
                        placeholderIconSize: .small,
                        surfaceStyle: .spine
                    )
                    .shadow(
                        color: XMBookCoverAppearance.dropShadow.opacity(index == 0 ? 0.70 : 0.42),
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
        case detailHero

        var aspectRatio: CGFloat {
            switch self {
            case .list:
                return 2.9
            case .compactGrid:
                return 2.35
            case .detailHero:
                return 1.88
            }
        }

        var realCoverLimit: Int {
            switch self {
            case .list, .detailHero:
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
                .stroke(Color.surfaceBorderSubtle.opacity(0.72), lineWidth: StrokeWidth.hairline)
        }
        .accessibilityHidden(true)
    }
}

/// 书单规整海报封面，用等距封面陈列表达更稳定的信息浏览模式。
struct BookCollectionRegularPosterCoverView: View {
    let covers: [String]
    var tone: BookCollectionKind = .manual
    var seed: String = ""
    var displayMode: BookCollectionMutedPosterCoverView.DisplayMode = .list

    private var visibleCovers: [String] {
        Array(covers.prefix(displayMode.realCoverLimit))
    }

    private var paletteSeed: String {
        seed.isEmpty ? covers.first ?? "" : "\(seed)-\(covers.first ?? "")"
    }

    private var palette: BookCollectionMutedPosterPalette {
        BookCollectionMutedPosterPalette.resolve(
            seed: paletteSeed,
            tone: tone
        )
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
                        palette.base

                        HStack(alignment: .center, spacing: coverSpacing(in: size)) {
                            if visibleCovers.isEmpty {
                                placeholderRow(width: coverWidth(in: size))
                            } else {
                                ForEach(Array(visibleCovers.enumerated()), id: \.offset) { _, cover in
                                    XMBookCover.fixedWidth(
                                        coverWidth(in: size),
                                        urlString: cover,
                                        cornerRadius: CornerRadius.inlaySmall,
                                        border: .init(color: .surfaceBorderSubtle, width: StrokeWidth.hairline),
                                        placeholderIconSize: .small,
                                        surfaceStyle: .spine
                                    )
                                    .shadow(
                                        color: XMBookCoverAppearance.dropShadow.opacity(0.20),
                                        radius: 4,
                                        x: Spacing.none,
                                        y: 2
                                    )
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal, Spacing.base)
                    }
                }
            }
            .compositingGroup()
            .clipShape(shape)
            .overlay {
                shape
                    .stroke(Color.surfaceBorderSubtle.opacity(0.72), lineWidth: StrokeWidth.hairline)
            }
            .accessibilityHidden(true)
    }

    private func coverWidth(in size: CGSize) -> CGFloat {
        let rawWidth: CGFloat
        let minimum: CGFloat
        let maximum: CGFloat
        switch displayMode {
        case .list:
            rawWidth = size.width * 0.15
            minimum = 36
            maximum = 58
        case .compactGrid:
            rawWidth = size.width * 0.20
            minimum = 28
            maximum = 44
        case .detailHero:
            rawWidth = size.width * 0.20
            minimum = 56
            maximum = 82
        }
        return min(max(rawWidth, minimum), maximum)
    }

    private func coverSpacing(in size: CGSize) -> CGFloat {
        switch displayMode {
        case .list:
            return min(Spacing.base, size.width * 0.035)
        case .compactGrid:
            return min(Spacing.cozy, size.width * 0.030)
        case .detailHero:
            return min(Spacing.base, size.width * 0.036)
        }
    }

    private func placeholderRow(width: CGFloat) -> some View {
        HStack(alignment: .bottom, spacing: Spacing.cozy) {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                    .fill(index == 0 ? palette.paper.opacity(0.94) : palette.paperBand.opacity(0.58))
                    .overlay {
                        if index == 0 {
                            Image(systemName: tone == .annual ? "calendar" : "books.vertical")
                                .font(AppTypography.callout)
                                .foregroundStyle(Color.textHint)
                        }
                    }
                    .frame(width: width, height: XMBookCover.height(forWidth: width))
            }
        }
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
        case .detailHero:
            return detailHeroSlots
        }
    }

    private var detailHeroSlots: [BookCollectionMutedPosterSlot] {
        switch covers.count {
        case 0:
            return [
                paper(id: 0, x: 0.39, y: 0.58, width: 0.206, rotation: -3.0, zIndex: 2, opacity: 0.60),
                paper(id: 1, x: 0.50, y: 0.50, width: 0.222, rotation: 2.0, zIndex: 3, opacity: 0.68),
                paper(id: 2, x: 0.62, y: 0.58, width: 0.190, rotation: 3.0, zIndex: 1, opacity: 0.52)
            ]
        case 1:
            return [
                paper(id: 0, x: 0.39, y: 0.58, width: 0.186, rotation: -3.0, zIndex: 1, opacity: 0.42),
                paper(id: 1, x: 0.61, y: 0.56, width: 0.178, rotation: 3.0, zIndex: 2, opacity: 0.46),
                cover(id: 2, index: 0, x: 0.50, y: 0.53, width: 0.238, rotation: 0.0, zIndex: 3)
            ]
        case 2:
            return [
                paper(id: 0, x: 0.62, y: 0.57, width: 0.176, rotation: 2.0, zIndex: 1, opacity: 0.42),
                cover(id: 1, index: 1, x: 0.54, y: 0.51, width: 0.208, rotation: 3.0, zIndex: 2),
                cover(id: 2, index: 0, x: 0.42, y: 0.56, width: 0.232, rotation: -2.0, zIndex: 3)
            ]
        case 3:
            return [
                cover(id: 0, index: 2, x: 0.62, y: 0.56, width: 0.196, rotation: 3.0, zIndex: 1),
                cover(id: 1, index: 1, x: 0.50, y: 0.49, width: 0.224, rotation: -1.5, zIndex: 3),
                cover(id: 2, index: 0, x: 0.38, y: 0.57, width: 0.204, rotation: -3.0, zIndex: 2)
            ]
        case 4:
            return [
                cover(id: 0, index: 3, x: 0.67, y: 0.55, width: 0.174, rotation: 3.0, zIndex: 1),
                cover(id: 1, index: 2, x: 0.56, y: 0.49, width: 0.206, rotation: 2.0, zIndex: 3),
                cover(id: 2, index: 1, x: 0.45, y: 0.52, width: 0.218, rotation: -1.0, zIndex: 4),
                cover(id: 3, index: 0, x: 0.34, y: 0.58, width: 0.190, rotation: -3.0, zIndex: 2)
            ]
        default:
            return [
                cover(id: 0, index: 4, x: 0.70, y: 0.57, width: 0.160, rotation: 3.0, zIndex: 1),
                cover(id: 1, index: 3, x: 0.60, y: 0.49, width: 0.180, rotation: 2.0, zIndex: 3),
                cover(id: 2, index: 2, x: 0.50, y: 0.54, width: 0.222, rotation: -0.5, zIndex: 5),
                cover(id: 3, index: 1, x: 0.40, y: 0.50, width: 0.196, rotation: -2.0, zIndex: 4),
                cover(id: 4, index: 0, x: 0.30, y: 0.58, width: 0.168, rotation: -3.0, zIndex: 2)
            ]
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
        let minimum: CGFloat
        let maximum: CGFloat
        switch displayMode {
        case .list:
            minimum = 36
            maximum = 58
        case .compactGrid:
            minimum = 28
            maximum = 44
        case .detailHero:
            minimum = 54
            maximum = 88
        }
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
                    border: .init(color: .surfaceBorderSubtle, width: StrokeWidth.hairline),
                    placeholderIconSize: .small,
                    surfaceStyle: .spine
                )
            } else {
                placeholderBook
            }
        }
        .shadow(
            color: XMBookCoverAppearance.dropShadow.opacity(isPaperLayer ? 0.08 : 0.26),
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
                    .fill(XMBookCoverAppearance.spineDark.opacity(0.10))
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
                    .stroke(Color.surfaceBorderSubtle.opacity(0.34), lineWidth: StrokeWidth.hairline)
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
            base: Color.xmAdaptive(light: Color.xmHex(0xEEF4F1), dark: Color.xmHex(0x1F2623)),
            wash: Color.xmAdaptive(light: Color.xmHex(0xC9E3DA).opacity(0.72), dark: Color.xmHex(0x355247).opacity(0.62)),
            accentWash: Color.xmAdaptive(light: Color.xmHex(0xE6EEF7).opacity(0.82), dark: Color.xmHex(0x344356).opacity(0.58)),
            highlight: Color.xmAdaptive(light: Color.white.opacity(0.54), dark: Color.white.opacity(0.05)),
            paper: Color.xmAdaptive(light: Color.xmHex(0xF6F2E7), dark: Color.xmHex(0x4A4234)),
            paperBand: Color.xmAdaptive(light: Color.xmHex(0xE0D3B6), dark: Color.xmHex(0x70634A))
        ),
        BookCollectionMutedPosterPalette(
            base: Color.xmAdaptive(light: Color.xmHex(0xF2F4EC), dark: Color.xmHex(0x24261F)),
            wash: Color.xmAdaptive(light: Color.xmHex(0xDCE7D0).opacity(0.74), dark: Color.xmHex(0x45533A).opacity(0.58)),
            accentWash: Color.xmAdaptive(light: Color.xmHex(0xE9EEE2).opacity(0.86), dark: Color.xmHex(0x394336).opacity(0.64)),
            highlight: Color.xmAdaptive(light: Color.white.opacity(0.52), dark: Color.white.opacity(0.05)),
            paper: Color.xmAdaptive(light: Color.xmHex(0xF5EDDC), dark: Color.xmHex(0x4A3E31)),
            paperBand: Color.xmAdaptive(light: Color.xmHex(0xD8C79F), dark: Color.xmHex(0x756241))
        ),
        BookCollectionMutedPosterPalette(
            base: Color.xmAdaptive(light: Color.xmHex(0xF2F1EC), dark: Color.xmHex(0x25231F)),
            wash: Color.xmAdaptive(light: Color.xmHex(0xDFD6C4).opacity(0.70), dark: Color.xmHex(0x514636).opacity(0.56)),
            accentWash: Color.xmAdaptive(light: Color.xmHex(0xDDE9E0).opacity(0.78), dark: Color.xmHex(0x354B3C).opacity(0.58)),
            highlight: Color.xmAdaptive(light: Color.white.opacity(0.50), dark: Color.white.opacity(0.05)),
            paper: Color.xmAdaptive(light: Color.xmHex(0xF1E7D1), dark: Color.xmHex(0x4B3D2E)),
            paperBand: Color.xmAdaptive(light: Color.xmHex(0xD7C095), dark: Color.xmHex(0x74603E))
        )
    ]

    private static let annualVariants: [BookCollectionMutedPosterPalette] = [
        BookCollectionMutedPosterPalette(
            base: Color.xmAdaptive(light: Color.xmHex(0xEDF3F8), dark: Color.xmHex(0x1F252A)),
            wash: Color.xmAdaptive(light: Color.xmHex(0xD5E4EF).opacity(0.78), dark: Color.xmHex(0x394D5E).opacity(0.58)),
            accentWash: Color.xmAdaptive(light: Color.xmHex(0xC9E2DA).opacity(0.72), dark: Color.xmHex(0x355048).opacity(0.56)),
            highlight: Color.xmAdaptive(light: Color.white.opacity(0.54), dark: Color.white.opacity(0.05)),
            paper: Color.xmAdaptive(light: Color.xmHex(0xF7F2E5), dark: Color.xmHex(0x4A4233)),
            paperBand: Color.xmAdaptive(light: Color.xmHex(0xDDD0AE), dark: Color.xmHex(0x75664B))
        ),
        BookCollectionMutedPosterPalette(
            base: Color.xmAdaptive(light: Color.xmHex(0xF3F1EB), dark: Color.xmHex(0x25231F)),
            wash: Color.xmAdaptive(light: Color.xmHex(0xE4DAC8).opacity(0.78), dark: Color.xmHex(0x504535).opacity(0.56)),
            accentWash: Color.xmAdaptive(light: Color.xmHex(0xD7E6D1).opacity(0.72), dark: Color.xmHex(0x40543A).opacity(0.54)),
            highlight: Color.xmAdaptive(light: Color.white.opacity(0.54), dark: Color.white.opacity(0.05)),
            paper: Color.xmAdaptive(light: Color.xmHex(0xF6EDD9), dark: Color.xmHex(0x4C4030)),
            paperBand: Color.xmAdaptive(light: Color.xmHex(0xDDC89E), dark: Color.xmHex(0x74613F))
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
                .tint(BookCollectionVisualAppearance.emphasisAccent.opacity(0.62))

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
    var displayMode: BookCollectionDisplayMode = .list
    var coverArrangement: BookCollectionCoverArrangement = .stacked
    var showsStatistics: Bool = true
    @ScaledMetric(relativeTo: .subheadline) private var gridTextSlotHeight: CGFloat = 64
    @ScaledMetric(relativeTo: .caption) private var gridMetricSlotHeight: CGFloat = 20

    var body: some View {
        switch displayMode {
        case .list:
            listCard
        case .grid:
            gridCard
        }
    }

    private var listCard: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            posterCover(displayMode: .list)

            VStack(alignment: .leading, spacing: Spacing.cozy) {
                Text(title)
                    .font(AppTypography.headlineSemibold)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(subtitle)
                    .font(AppTypography.caption)
                    .foregroundStyle(subtitleColor)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if showsStatistics {
                    BookCollectionProgressMeter(
                        finishedCount: item.finishedCount,
                        targetReadCount: item.targetReadCount
                    )
                }

                HStack(alignment: .center, spacing: Spacing.tight) {
                    if showsStatistics {
                        BookCollectionMetricStrip(
                            bookCount: item.bookCount,
                            finishedCount: item.finishedCount,
                            targetReadCount: item.targetReadCount,
                            layout: .compact
                        )
                    }

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
                .stroke(Color.surfaceBorderSubtle, lineWidth: StrokeWidth.hairline)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var gridCard: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            posterCover(displayMode: .compactGrid)

            VStack(alignment: .leading, spacing: Spacing.half) {
                VStack(alignment: .leading, spacing: Spacing.compact) {
                    Text(title)
                        .font(AppTypography.subheadlineSemibold)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .topLeading)

                    Text(subtitle)
                        .font(AppTypography.caption2)
                        .foregroundStyle(subtitleColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: gridTextSlotHeight, alignment: .topLeading)

                if showsStatistics {
                    BookCollectionMetricStrip(
                        bookCount: item.bookCount,
                        finishedCount: item.finishedCount,
                        targetReadCount: item.targetReadCount,
                        layout: .compact
                    )
                    .padding(.top, Spacing.micro)
                    .frame(height: gridMetricSlotHeight, alignment: .leading)
                }
            }
            .padding(.horizontal, Spacing.compact)
            .padding(.bottom, Spacing.compact)
        }
        .padding(Spacing.cozy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.containerMedium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.containerMedium, style: .continuous)
                .stroke(Color.surfaceBorderSubtle, lineWidth: StrokeWidth.hairline)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private func posterCover(displayMode: BookCollectionMutedPosterCoverView.DisplayMode) -> some View {
        switch coverArrangement {
        case .stacked:
            BookCollectionMutedPosterCoverView(
                covers: item.representativeCovers,
                tone: item.kind,
                seed: posterSeed,
                displayMode: displayMode
            )
        case .regular:
            BookCollectionRegularPosterCoverView(
                covers: item.representativeCovers,
                tone: item.kind,
                seed: posterSeed,
                displayMode: displayMode
            )
        }
    }

    private var title: String {
        if item.kind == .annual, let year = item.year, item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(year) 年阅读"
        }
        return item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名书单" : item.title
    }

    private var subtitle: String {
        let description = item.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return description.isEmpty ? "还没有写简介" : description
    }

    private var subtitleColor: Color {
        hasWrittenDescription ? Color.textSecondary : Color.textHint
    }

    private var hasWrittenDescription: Bool {
        !item.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

/// 书单详情 Header 视觉实验方案，仅影响封面识别区的表达方式。
enum BookCollectionHeaderVisualStyle: String, CaseIterable, Identifiable {
    case editorialDesk
    case gallery
    case shelf
    case quietPoster

    var id: String { rawValue }

    var menuTitle: String {
        switch self {
        case .editorialDesk:
            return "D 阅读桌面"
        case .gallery:
            return "A 无背景画廊"
        case .shelf:
            return "B 书脊陈列台"
        case .quietPoster:
            return "C 消隐海报"
        }
    }
}

/// 书单详情阅读桌面封面组，用真实封面在信息区右侧建立书单对象感。
private struct BookCollectionEditorialCoverCluster: View {
    let covers: [String]
    let tone: BookCollectionKind

    private var visibleCovers: [String] {
        Array(covers.prefix(5))
    }

    var body: some View {
        ZStack {
            Capsule()
                .fill(XMBookCoverAppearance.dropShadow.opacity(0.06))
                .blur(radius: 7)
                .frame(width: 86, height: 9)
                .offset(y: 47)

            if visibleCovers.isEmpty {
                placeholderStack
            } else {
                coverStack
            }
        }
        .frame(width: 116, height: 108)
        .accessibilityHidden(true)
    }

    private var coverStack: some View {
        ZStack {
            ForEach(Array(visibleCovers.enumerated()), id: \.offset) { index, cover in
                XMBookCover.fixedWidth(
                    coverWidth(for: index),
                    urlString: cover,
                    cornerRadius: CornerRadius.inlaySmall,
                    border: .init(color: .surfaceBorderSubtle, width: StrokeWidth.hairline),
                    placeholderIconSize: .small,
                    surfaceStyle: .spine
                )
                .rotationEffect(.degrees(rotation(for: index)))
                .offset(offset(for: index))
                .zIndex(zIndex(for: index))
                .shadow(
                    color: XMBookCoverAppearance.dropShadow.opacity(index == 0 ? 0.22 : 0.14),
                    radius: index == 0 ? 8 : 5,
                    x: Spacing.none,
                    y: index == 0 ? 6 : 3
                )
            }
        }
    }

    private var placeholderStack: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                    .fill(index == 0 ? Color.surfaceCard : Color.surfaceNested)
                    .overlay {
                        RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                            .stroke(Color.surfaceBorderSubtle.opacity(index == 0 ? 0.76 : 0.52), lineWidth: StrokeWidth.hairline)
                    }
                    .overlay(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: CornerRadius.inlayHairline, style: .continuous)
                            .fill(Color.surfacePage.opacity(0.62))
                            .frame(width: 22, height: 3)
                            .padding(.top, Spacing.cozy)
                            .padding(.leading, Spacing.cozy)
                    }
                    .overlay {
                        if index == 0 {
                            Image(systemName: tone == .annual ? "calendar" : "books.vertical")
                                .font(AppTypography.caption)
                                .foregroundStyle(Color.textHint)
                        }
                    }
                    .frame(width: placeholderWidth(for: index), height: placeholderHeight(for: index))
                    .rotationEffect(.degrees(placeholderRotation(for: index)))
                    .offset(placeholderOffset(for: index))
                    .zIndex(Double(3 - index))
            }
        }
    }

    private func coverWidth(for index: Int) -> CGFloat {
        switch index {
        case 0:
            return 60
        case 1, 2:
            return 41
        default:
            return 32
        }
    }

    private func offset(for index: Int) -> CGSize {
        switch index {
        case 0:
            return CGSize(width: 0, height: 1)
        case 1:
            return CGSize(width: -29, height: 11)
        case 2:
            return CGSize(width: 29, height: 12)
        case 3:
            return CGSize(width: -43, height: 19)
        default:
            return CGSize(width: 43, height: 20)
        }
    }

    private func rotation(for index: Int) -> Double {
        switch index {
        case 1:
            return -2
        case 2:
            return 2
        case 3:
            return -1.5
        case 4:
            return 1.5
        default:
            return 0
        }
    }

    private func zIndex(for index: Int) -> Double {
        switch index {
        case 0:
            return 5
        case 1, 2:
            return 3
        default:
            return 1
        }
    }

    private func placeholderWidth(for index: Int) -> CGFloat {
        index == 0 ? 54 : 42
    }

    private func placeholderHeight(for index: Int) -> CGFloat {
        XMBookCover.height(forWidth: placeholderWidth(for: index))
    }

    private func placeholderOffset(for index: Int) -> CGSize {
        switch index {
        case 0:
            return CGSize(width: 0, height: 4)
        case 1:
            return CGSize(width: -29, height: 14)
        default:
            return CGSize(width: 29, height: 15)
        }
    }

    private func placeholderRotation(for index: Int) -> Double {
        switch index {
        case 1:
            return -1.5
        case 2:
            return 1.5
        default:
            return 0
        }
    }
}

/// 书单详情封面舞台，在相同封面槽位下提供可对比的 Header 视觉方案。
private struct BookCollectionHeaderCoverStage: View {
    let covers: [String]
    let tone: BookCollectionKind
    let seed: String
    let visualStyle: BookCollectionHeaderVisualStyle

    private var visibleCovers: [String] {
        Array(covers.prefix(BookCollectionMutedPosterCoverView.DisplayMode.detailHero.realCoverLimit))
    }

    private var paletteSeed: String {
        seed.isEmpty ? covers.first ?? "" : "\(seed)-\(covers.first ?? "")"
    }

    private var palette: BookCollectionMutedPosterPalette {
        BookCollectionMutedPosterPalette.resolve(seed: paletteSeed, tone: tone)
    }

    var body: some View {
        Color.clear
            .aspectRatio(BookCollectionMutedPosterCoverView.DisplayMode.detailHero.aspectRatio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                GeometryReader { proxy in
                    let size = proxy.size

                    ZStack {
                        backgroundLayer(in: size)

                        BookCollectionMutedPosterStack(
                            covers: visibleCovers,
                            palette: palette,
                            size: size,
                            displayMode: .detailHero
                        )
                    }
                    .frame(width: size.width, height: size.height)
                }
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func backgroundLayer(in size: CGSize) -> some View {
        switch visualStyle {
        case .editorialDesk:
            EmptyView()
        case .gallery:
            Capsule()
                .fill(XMBookCoverAppearance.dropShadow.opacity(0.07))
                .blur(radius: 8)
                .frame(width: size.width * 0.46, height: max(8, size.height * 0.05))
                .position(x: size.width * 0.50, y: size.height * 0.77)
        case .shelf:
            RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                .fill(Color.surfaceCard.opacity(0.96))
                .frame(width: size.width * 0.70, height: max(18, size.height * 0.10))
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.surfaceBorderSubtle.opacity(0.74))
                        .frame(height: StrokeWidth.hairline)
                        .padding(.horizontal, Spacing.tight)
                }
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color.surfaceNested.opacity(0.42))
                        .frame(height: max(4, size.height * 0.025))
                }
                .shadow(
                    color: XMBookCoverAppearance.dropShadow.opacity(0.10),
                    radius: 8,
                    x: Spacing.none,
                    y: 3
                )
                .position(x: size.width * 0.50, y: size.height * 0.82)
        case .quietPoster:
            quietPosterBackground(in: size)
        }
    }

    private func quietPosterBackground(in size: CGSize) -> some View {
        let shape = RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)

        return ZStack(alignment: .bottom) {
            shape
                .fill(Color.surfaceCard)

            Rectangle()
                .fill(Color.surfaceNested.opacity(0.24))
                .frame(height: size.height * 0.36)

            LinearGradient(
                colors: [
                    Color.white.opacity(0.18),
                    Color.white.opacity(0.02),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .overlay {
            shape
                .stroke(Color.surfaceBorderSubtle.opacity(0.52), lineWidth: StrokeWidth.hairline)
        }
        .shadow(
            color: XMBookCoverAppearance.dropShadow.opacity(0.04),
            radius: 10,
            x: Spacing.none,
            y: 4
        )
    }
}

/// 书单详情头，将书单主题、统计、同步边界和主动作集中在页面叙事层。
struct BookCollectionDetailHero: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false
    let detail: BookCollectionDetail
    var visualStyle: BookCollectionHeaderVisualStyle = .editorialDesk
    var onShowFullSummary: () -> Void = {}

    var body: some View {
        Group {
            switch visualStyle {
            case .editorialDesk:
                editorialDeskHero
            case .gallery, .shelf, .quietPoster:
                legacyHero
            }
        }
        .onAppear {
            guard !hasAppeared else { return }
            if reduceMotion {
                hasAppeared = true
            } else {
                withAnimation(.smooth(duration: 0.26)) {
                    hasAppeared = true
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var editorialDeskHero: some View {
        HStack(alignment: .top, spacing: Spacing.section) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text(title)
                    .font(AppTypography.title3Semibold)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                Text(description)
                    .font(AppTypography.footnote)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if shouldOfferFullSummary {
                    Button(action: onShowFullSummary) {
                        Text("查看完整简介")
                            .font(AppTypography.captionMedium)
                            .foregroundStyle(BookCollectionVisualAppearance.emphasisAccent)
                            .frame(minHeight: 28, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("查看完整书单简介")
                }

                BookCollectionProgressSummary(
                    kind: detail.kind,
                    bookCount: detail.bookCount,
                    finishedCount: detail.finishedCount,
                    targetReadCount: detail.targetReadCount,
                    displayStyle: .compact
                )
                .padding(.top, Spacing.base)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared || reduceMotion ? 0 : 6)

            BookCollectionEditorialCoverCluster(
                covers: posterCovers,
                tone: detail.kind
            )
            .padding(.top, Spacing.cozy)
            .opacity(hasAppeared ? 1 : 0)
            .scaleEffect(hasAppeared || reduceMotion ? 1 : 0.975)
        }
    }

    private var legacyHero: some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                BookCollectionHeaderCoverStage(
                    covers: posterCovers,
                    tone: detail.kind,
                    seed: posterSeed,
                    visualStyle: visualStyle
                )
                .id(visualStyle)
                .opacity(hasAppeared ? 1 : 0)
                .scaleEffect(hasAppeared || reduceMotion ? 1 : 0.985)
                .transition(.opacity.combined(with: .scale(scale: 0.985)))

                VStack(alignment: .leading, spacing: Spacing.cozy) {
                    Text(title)
                        .font(AppTypography.title3Semibold)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(description)
                        .font(AppTypography.callout)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared || reduceMotion ? 0 : 6)
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: visualStyle)

            BookCollectionProgressSummary(
                kind: detail.kind,
                bookCount: detail.bookCount,
                finishedCount: detail.finishedCount,
                targetReadCount: detail.targetReadCount
            )
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared || reduceMotion ? 0 : 6)
        }
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
            return detail.bookCount == 0 ? "从书架里挑选几本书，给这个主题一个开始" : "按你的阅读主题整理出的书籍集合"
        case .annual:
            return "随读完记录自动同步，保留这一年的阅读轨迹"
        }
    }

    private var shouldOfferFullSummary: Bool {
        let rawDescription = detail.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.count > 18 || rawDescription.count > 24 || rawDescription.contains(where: \.isNewline)
    }

    private var posterCovers: [String] {
        Array(detail.books.prefix(5).map(\.book.cover))
    }

    private var posterSeed: String {
        [
            String(detail.id),
            title,
            detail.year.map(String.init) ?? ""
        ]
        .joined(separator: "-")
    }
}

/// 书单详情摘要，根据书单类型区分目标进度与普通书单概览。
struct BookCollectionProgressSummary: View {
    /// 控制进度区在详情头和完整简介 Sheet 中的可见信息密度。
    enum DisplayStyle {
        case standard
        case compact
    }

    let kind: BookCollectionKind
    let bookCount: Int
    let finishedCount: Int
    let targetReadCount: Int?
    var displayStyle: DisplayStyle = .standard

    var body: some View {
        Group {
            switch kind {
            case .manual:
                manualSummary
            case .annual:
                annualSummary
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var manualSummary: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            if displayStyle == .standard {
                Text("书单概览")
                    .font(AppTypography.captionMedium)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
            }

            BookCollectionManualSummaryLine(
                bookCount: bookCount,
                finishedCount: finishedCount
            )
        }
    }

    @ViewBuilder
    private var annualSummary: some View {
        if hasTarget {
            annualTargetSummary
        } else {
            annualRecordSummary
        }
    }

    private var annualTargetSummary: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            switch displayStyle {
            case .standard:
                standardHeader
                progressTrack
            case .compact:
                compactProgressRow
            }

            Text(detailText)
                .font(AppTypography.caption)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var annualRecordSummary: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            if displayStyle == .standard {
                Text("年度记录")
                    .font(AppTypography.captionMedium)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
            }

            BookCollectionSummaryMetricPill(
                title: "今年读完",
                value: "\(completedCount) 本",
                tint: BookCollectionVisualAppearance.emphasisAccent,
                isEmphasized: true
            )
        }
    }

    private var standardHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(progressTitle)
                .font(AppTypography.captionSemibold)
                .foregroundStyle(Color.textPrimary)

            Spacer(minLength: Spacing.tight)

            Text("\(completionPercent)%")
                .font(AppTypography.captionSemibold)
                .foregroundStyle(Color.textPrimary)
                .contentTransition(.numericText())
        }
    }

    private var compactProgressRow: some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.cozy) {
                Text(progressTitle)
                    .font(AppTypography.captionSemibold)
                    .foregroundStyle(Color.textPrimary)

                Spacer(minLength: Spacing.tight)

                Text("\(completionPercent)%")
                    .font(AppTypography.captionMedium)
                    .foregroundStyle(Color.textSecondary)
                    .contentTransition(.numericText())
            }

            progressTrack
        }
    }

    private var progressTrack: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.surfaceBorderSubtle.opacity(0.46))

                Capsule()
                    .fill(BookCollectionVisualAppearance.emphasisAccent.opacity(0.62))
                    .frame(width: proxy.size.width * progressFraction)
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }

    private var denominator: Int {
        if let targetReadCount, targetReadCount > 0 {
            return targetReadCount
        }
        return bookCount
    }

    private var progressFraction: CGFloat {
        guard denominator > 0 else { return 0 }
        return min(CGFloat(completedCount) / CGFloat(denominator), 1)
    }

    private var completionPercent: Int {
        guard denominator > 0 else { return 0 }
        return Int((Double(completedCount) / Double(denominator) * 100).rounded())
    }

    private var progressTitle: String {
        guard denominator > 0 else {
            return "已读 0 本"
        }
        return "年度目标 \(completedCount)/\(denominator)"
    }

    private var detailText: String {
        if let targetReadCount, targetReadCount > 0 {
            return "今年读完 \(completedCount) 本 · 目标 \(targetReadCount) 本"
        }
        return "今年读完 \(completedCount) 本"
    }

    private var hasTarget: Bool {
        (targetReadCount ?? 0) > 0
    }

    private var completedCount: Int {
        kind == .annual ? bookCount : finishedCount
    }

    private var accessibilityLabel: String {
        switch kind {
        case .manual:
            return "书单概览，收录 \(bookCount) 本，已读 \(finishedCount) 本"
        case .annual:
            if hasTarget {
                return "年度目标，完成 \(completionPercent)%，\(detailText)"
            }
            return "年度记录，\(detailText)"
        }
    }
}

/// 普通书单的中性概览文本，避免用多个标签制造按钮感和进度感。
private struct BookCollectionManualSummaryLine: View {
    let bookCount: Int
    let finishedCount: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.half) {
            Text("收录")
            metricValue("\(bookCount) 本")
            separator
            Text("已读")
            metricValue("\(finishedCount) 本")
        }
        .font(AppTypography.captionMedium)
        .foregroundStyle(Color.textSecondary)
        .lineLimit(1)
        .minimumScaleFactor(0.88)
        .contentTransition(.numericText())
    }

    private func metricValue(_ value: String) -> some View {
        Text(value)
            .foregroundStyle(Color.textPrimary.opacity(0.78))
    }

    private var separator: some View {
        Text("·")
            .foregroundStyle(Color.textHint.opacity(0.72))
    }
}

/// 书单摘要中的轻量数值标签，避免普通书单被误读成任务进度或强按钮。
private struct BookCollectionSummaryMetricPill: View {
    let title: String
    let value: String
    let tint: Color
    let isEmphasized: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.half) {
            Text(title)
                .font(AppTypography.caption2)
                .foregroundStyle(Color.textSecondary)

            Text(value)
                .font(AppTypography.captionMedium)
                .foregroundStyle(isEmphasized ? tint.opacity(0.92) : Color.textPrimary)
                .contentTransition(.numericText())
        }
        .frame(minHeight: 24)
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// 书单内容区头部，只承载分区标题与同步状态，添加入口交给底部悬浮操作层。
struct BookCollectionContentHeader: View {
    enum Status {
        case autoSynced

        var title: String {
            switch self {
            case .autoSynced:
                return "自动同步"
            }
        }

        var systemImage: String {
            switch self {
            case .autoSynced:
                return "arrow.triangle.2.circlepath"
            }
        }

        var accessibilityLabel: String {
            switch self {
            case .autoSynced:
                return "年度书单内容自动同步"
            }
        }
    }

    let title: String
    let status: Status?

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.base) {
            Text(title)
                .font(AppTypography.subheadlineMedium)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.86)

            Spacer(minLength: Spacing.tight)

            if let status {
                Label(status.title, systemImage: status.systemImage)
                    .font(AppTypography.captionMedium)
                    .foregroundStyle(Color.textSecondary)
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, Spacing.cozy)
                    .frame(minHeight: 32)
                    .background(Color.surfaceNested, in: Capsule())
                    .accessibilityLabel(status.accessibilityLabel)
            }
        }
        .padding(.horizontal, Spacing.contentEdge)
        .padding(.top, Spacing.contentEdge)
        .padding(.bottom, Spacing.tight)
    }
}

/// 空书单在内容容器内部的轻量说明，保持和非空书单一致的页面重心。
struct BookCollectionEmptyBooksRow: View {
    var body: some View {
        XMCompactStateView(
            role: .empty,
            title: "暂无书籍"
        )
    }
}

/// 书单内书籍档案卡，将封面、简介、阅读状态和 relation 文本组织成一个完整策展单元。
struct BookCollectionBookCard: View {
    @ScaledMetric(relativeTo: .subheadline) private var scaledCoverWidth: CGFloat = 72
    let item: BookCollectionBookItem
    let canEditStructure: Bool
    let canEditRelationNote: Bool
    let canEditMetadata: Bool
    var relationNotePresentation: BookCollectionRelationNotePresentation = .make(kind: .manual)
    var showsSeparator: Bool = false
    let onOpen: () -> Void
    let onEditBook: () -> Void
    let onEditMetadata: () -> Void
    let onRestorePlaceholder: () -> Void
    let onEditRecommend: () -> Void
    let onRemove: () -> Void

    var body: some View {
        cardContent
            .padding(Spacing.base)
            .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                    .stroke(Color.surfaceBorderSubtle.opacity(0.58), lineWidth: StrokeWidth.hairline)
            }
            .shadow(
                color: XMBookCoverAppearance.dropShadow.opacity(0.055),
                radius: 10,
                x: Spacing.none,
                y: 4
            )
            .padding(.bottom, showsSeparator ? Spacing.base : Spacing.contentEdge)
        .contextMenu {
            Button {
                item.isPlaceholder ? onRestorePlaceholder() : onOpen()
            } label: {
                XMMenuLabel(item.isPlaceholder ? "加入书架" : "查看书籍", systemImage: item.isPlaceholder ? "plus.circle" : "book")
            }

            if !item.isPlaceholder {
                Button {
                    onEditBook()
                } label: {
                    XMMenuLabel("编辑书籍", systemImage: "pencil")
                }
            } else {
                Button {
                    onEditMetadata()
                } label: {
                    XMMenuLabel("编辑书籍信息", systemImage: "square.and.pencil")
                }
                .disabled(!canEditMetadata)
            }

            Button {
                onEditRecommend()
            } label: {
                XMMenuLabel(relationNoteActionTitle, systemImage: "quote.bubble")
            }
            .disabled(!canEditRelationNote)

            if canEditStructure {
                Button(role: .destructive) {
                    onRemove()
                } label: {
                    Label("移出书单", systemImage: "minus.circle")
                }
            }
        }
        .xmMenuNeutralTint()
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if canEditRelationNote {
                Button {
                    onEditRecommend()
                } label: {
                    Label(relationNotePresentation.title, systemImage: "quote.bubble")
                }
                .tint(Color.editActionFill)
            }

            if canEditStructure {
                Button(role: .destructive) {
                    onRemove()
                } label: {
                    Label("移出", systemImage: "minus.circle")
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAction(named: item.isPlaceholder ? "加入书架" : "查看书籍", item.isPlaceholder ? onRestorePlaceholder : onOpen)
        .modifier(BookCollectionEditBookAccessibilityAction(
            title: item.isPlaceholder ? "编辑书籍信息" : "编辑书籍",
            isEnabled: item.isPlaceholder ? canEditMetadata : true,
            action: item.isPlaceholder ? onEditMetadata : onEditBook
        ))
        .modifier(BookCollectionEditableBookActions(
            canEditStructure: canEditStructure,
            canEditRelationNote: canEditRelationNote,
            noteActionTitle: relationNoteActionTitle,
            onEditRecommend: onEditRecommend,
            onRemove: onRemove
        ))
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: Spacing.base) {
                    XMBookCover.fixedWidth(
                        coverWidth,
                        urlString: item.book.cover,
                        cornerRadius: CornerRadius.inlaySmall,
                        border: .init(color: .surfaceBorderSubtle, width: StrokeWidth.hairline),
                        placeholderIconSize: .small,
                        surfaceStyle: .spine
                    )
                    .shadow(
                        color: XMBookCoverAppearance.dropShadow.opacity(0.14),
                        radius: 7,
                        x: Spacing.none,
                        y: 4
                    )

                    VStack(alignment: .leading, spacing: Spacing.cozy) {
                        titleCluster

                        if hasSummary {
                            BookCollectionBookSummaryText(text: trimmedSummary)
                        }

                        if item.isPlaceholder {
                            BookCollectionPlaceholderRestorePrompt()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            reasonContent
        }
    }

    private var titleCluster: some View {
        HStack(alignment: .top, spacing: Spacing.cozy) {
            VStack(alignment: .leading, spacing: Spacing.compact) {
                Text(displayTitle)
                    .font(AppTypography.subheadlineSemibold)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if !item.book.author.isEmpty {
                    Text(item.book.author)
                        .font(AppTypography.footnote)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            if !statusTitle.isEmpty {
                BookCollectionReadStatusChip(
                    text: statusTitle,
                    readStatusID: item.book.readStatusId
                )
            }
        }
    }

    @ViewBuilder
    private var reasonContent: some View {
        if !trimmedRecommend.isEmpty {
            BookCollectionRecommendQuote(
                text: trimmedRecommend,
                isEditable: canEditRelationNote,
                presentation: relationNotePresentation,
                onEdit: onEditRecommend
            )
        } else if canEditRelationNote {
            BookCollectionAddReasonPrompt(
                presentation: relationNotePresentation,
                action: onEditRecommend
            )
        }
    }

    private var coverWidth: CGFloat {
        min(scaledCoverWidth, 84)
    }

    private var displayTitle: String {
        item.book.title.isEmpty ? "未命名书籍" : item.book.title
    }

    private var statusTitle: String {
        if item.isPlaceholder {
            return "未加入书架"
        }
        return item.book.readStatusBadgeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasSummary: Bool {
        !trimmedSummary.isEmpty
    }

    private var trimmedSummary: String {
        item.summaryPlainText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedRecommend: String {
        item.recommend.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var relationNoteActionTitle: String {
        relationNotePresentation.editActionTitle(hasText: !trimmedRecommend.isEmpty)
    }

    private var accessibilityLabel: String {
        var parts = [displayTitle]
        if !item.book.author.isEmpty {
            parts.append(item.book.author)
        }
        if !statusTitle.isEmpty {
            parts.append(item.isPlaceholder ? statusTitle : "阅读状态，\(statusTitle)")
        }
        if hasSummary {
            parts.append("简介，\(trimmedSummary)")
        }
        if !trimmedRecommend.isEmpty {
            parts.append("\(relationNotePresentation.title)，\(trimmedRecommend)")
        } else if canEditRelationNote {
            parts.append(relationNotePresentation.emptyAccessibilityHint)
        }
        return parts.joined(separator: "，")
    }
}

private struct BookCollectionEditBookAccessibilityAction: ViewModifier {
    let title: String
    let isEnabled: Bool
    let action: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.accessibilityAction(named: title, action)
        } else {
            content
        }
    }
}

/// 书单书籍卡片中的阅读状态标签，用低饱和色表达状态，不抢标题和简介。
private struct BookCollectionReadStatusChip: View {
    let text: String
    let readStatusID: Int64

    var body: some View {
        Text(text)
            .font(AppTypography.caption2Medium)
            .foregroundStyle(tint)
            .padding(.horizontal, Spacing.half)
            .frame(minHeight: 24)
            .background(tint.opacity(0.07), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(tint.opacity(0.10), lineWidth: StrokeWidth.hairline)
            }
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("阅读状态 \(text)")
    }

    private var tint: Color {
        if text == "未加入书架" {
            return Color.textSecondary.opacity(0.64)
        }
        return BookEntryReadingStatus(rawValue: readStatusID)?.collectionBookCardTint ?? Color.textSecondary
    }
}

/// 占位书恢复提示，实际操作由整张卡片、上下文菜单与无障碍 action 承接。
private struct BookCollectionPlaceholderRestorePrompt: View {
    var body: some View {
        HStack(spacing: Spacing.half) {
            Image(systemName: "plus.circle")
                .font(AppTypography.captionMedium)

            Text("点击卡片加入书架")
                .font(AppTypography.captionMedium)
        }
        .foregroundStyle(Color.textSecondary)
        .frame(minHeight: 32, alignment: .leading)
    }
}

/// 书籍简介预览，只在存在真实简介时展示，避免空文案降低列表质感。
private struct BookCollectionBookSummaryText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(AppTypography.footnote)
            .foregroundStyle(Color.textSecondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 可编辑 relation 文本的占位入口，保持卡片可操作但不制造主按钮压力。
private struct BookCollectionAddReasonPrompt: View {
    let presentation: BookCollectionRelationNotePresentation
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: Spacing.half) {
                Image(systemName: "plus")
                    .font(AppTypography.captionMedium)

                Text(presentation.addTitle)
                    .font(AppTypography.captionMedium)
            }
            .foregroundStyle(Color.textSecondary)
            .frame(
                maxWidth: .infinity,
                minHeight: InteractionMetrics.minimumTouchTarget,
                alignment: .leading
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(presentation.addTitle)
    }
}

private extension BookEntryReadingStatus {
    var collectionBookCardTint: Color {
        switch self {
        case .wantRead:
            return ReadingStatusPresentation.wantRead.opacity(0.68)
        case .reading:
            return ReadingStatusPresentation.reading.opacity(0.68)
        case .finished:
            return ReadingStatusPresentation.readDone.opacity(0.70)
        case .abandoned:
            return ReadingStatusPresentation.abandoned.opacity(0.66)
        case .onHold:
            return ReadingStatusPresentation.onHold.opacity(0.66)
        }
    }
}

private struct BookCollectionEditableBookActions: ViewModifier {
    let canEditStructure: Bool
    let canEditRelationNote: Bool
    let noteActionTitle: String
    let onEditRecommend: () -> Void
    let onRemove: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        content
            .modifier(BookCollectionRelationNoteAccessibilityAction(
                isEnabled: canEditRelationNote,
                title: noteActionTitle,
                action: onEditRecommend
            ))
            .modifier(BookCollectionRemoveAccessibilityAction(
                isEnabled: canEditStructure,
                action: onRemove
            ))
    }
}

private struct BookCollectionRelationNoteAccessibilityAction: ViewModifier {
    let isEnabled: Bool
    let title: String
    let action: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.accessibilityAction(named: title, action)
        } else {
            content
        }
    }
}

private struct BookCollectionRemoveAccessibilityAction: ViewModifier {
    let isEnabled: Bool
    let action: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.accessibilityAction(named: "移出书单", action)
        } else {
            content
        }
    }
}

/// Relation 文本区块，让收藏理由或年度点评成为书籍行内附属信息，而不是漂浮卡片。
struct BookCollectionRecommendQuote: View {
    let text: String
    let isEditable: Bool
    let presentation: BookCollectionRelationNotePresentation
    let onEdit: () -> Void

    var body: some View {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        Button(action: onEdit) {
            VStack(alignment: .leading, spacing: Spacing.compact) {
                HStack(alignment: .center, spacing: Spacing.compact) {
                    Text(presentation.title)
                        .font(AppTypography.caption2Medium)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)

                    Spacer(minLength: Spacing.compact)

                    if isEditable {
                        Image(systemName: "pencil")
                            .font(AppTypography.caption2)
                            .foregroundStyle(Color.textHint.opacity(0.58))
                    }
                }

                Text(trimmed)
                    .font(AppTypography.footnote)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Spacing.tight)
            .padding(.vertical, Spacing.cozy)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.surfaceNested.opacity(0.54), in: RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous)
                    .stroke(Color.surfaceBorderSubtle.opacity(0.22), lineWidth: StrokeWidth.hairline)
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEditable)
        .accessibilityLabel("\(presentation.title)，\(trimmed)")
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

/// 年度书单自动同步说明，放在详情头内，避免页面中部重复占位。
private struct BookCollectionReadOnlyNotice: View {
    var body: some View {
        Label("年度书单随读完记录自动同步，年度点评可编辑", systemImage: "arrow.triangle.2.circlepath")
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
                .stroke(Color.surfaceBorderSubtle, lineWidth: StrokeWidth.hairline)
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
                    .stroke(Color.surfaceBorderSubtle.opacity(0.72), lineWidth: StrokeWidth.hairline)
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
                    .stroke(Color.surfaceBorderSubtle.opacity(0.28), lineWidth: StrokeWidth.hairline)
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
