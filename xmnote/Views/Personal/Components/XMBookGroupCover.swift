/**
 * [INPUT]: 依赖 XMBookCover 渲染书籍封面，依赖 XMBookCoverAppearance 与 DesignTokens 提供封面外观、圆角及描边语义
 * [OUTPUT]: 对外提供 XMBookGroupCover，用紧凑书籍叠放、书盒、规整裁片或轻托盘样式表达书籍分组封面
 * [POS]: Views/Personal/Components 的页面私有分组封面组件，仅服务书籍分组管理入口
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书籍分组封面，用叠放的书籍封面表达“多本书组成一个分组”的内容语义。
struct XMBookGroupCover: View {
    enum Style {
        case compactList
        case collectionCaseCompact
        case orderedGridCompact
        case adaptiveManagementCompact
    }

    let covers: [String]
    var style: Style = .compactList

    @ViewBuilder
    var body: some View {
        switch style {
        case .compactList:
            compactListCover
        case .collectionCaseCompact:
            collectionCaseCompactCover
        case .orderedGridCompact:
            orderedGridCompactCover
        case .adaptiveManagementCompact:
            adaptiveManagementCompactCover
        }
    }

    private var compactListCover: some View {
        let metrics = XMBookGroupCoverMetrics(style: style)
        let coverShape = RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)

        return ZStack {
            coverShape.fill(Color.surfaceNested)

            ForEach(metrics.slots) { slot in
                groupCoverSlot(slot)
            }
        }
        .frame(width: metrics.containerSize.width, height: metrics.containerSize.height)
        .clipShape(coverShape)
        .overlay {
            coverShape.stroke(Color.surfaceBorderSubtle.opacity(0.68), lineWidth: StrokeWidth.hairline)
        }
        .accessibilityHidden(true)
    }

    private var collectionCaseCompactCover: some View {
        let metrics = XMBookGroupCollectionCaseMetrics.compact
        let outerShape = RoundedRectangle(cornerRadius: metrics.outerCornerRadius, style: .continuous)
        let trayShape = RoundedRectangle(cornerRadius: metrics.trayCornerRadius, style: .continuous)

        return ZStack(alignment: .topLeading) {
            outerShape.fill(Color.surfaceNested)

            trayShape
                .fill(Color.surfaceCard.opacity(0.76))
                .frame(width: metrics.traySize.width, height: metrics.traySize.height)
                .offset(x: metrics.trayOrigin.x, y: metrics.trayOrigin.y)

            trayShape
                .stroke(Color.surfaceBorderSubtle.opacity(0.34), lineWidth: StrokeWidth.hairline)
                .frame(width: metrics.traySize.width, height: metrics.traySize.height)
                .offset(x: metrics.trayOrigin.x, y: metrics.trayOrigin.y)

            ForEach(metrics.spineSlots) { slot in
                collectionCaseSlot(slot)
            }

            collectionCaseSlot(metrics.primarySlot)
        }
        .frame(width: metrics.containerSize.width, height: metrics.containerSize.height)
        .clipShape(outerShape)
        .overlay {
            outerShape.stroke(Color.surfaceBorderSubtle.opacity(0.54), lineWidth: StrokeWidth.hairline)
        }
        .accessibilityHidden(true)
    }

    private var orderedGridCompactCover: some View {
        let metrics = XMBookGroupOrderedGridMetrics.compact
        let outerShape = RoundedRectangle(cornerRadius: metrics.outerCornerRadius, style: .continuous)
        let gridShape = RoundedRectangle(cornerRadius: metrics.gridCornerRadius, style: .continuous)

        return ZStack(alignment: .topLeading) {
            outerShape.fill(Color.surfaceNested)

            ZStack(alignment: .topLeading) {
                Color.surfaceBorderSubtle.opacity(0.18)

                ForEach(metrics.slots) { slot in
                    orderedGridSlot(slot)
                }
            }
            .frame(width: metrics.gridSize.width, height: metrics.gridSize.height)
            .clipShape(gridShape)
            .overlay {
                gridShape.stroke(Color.surfaceBorderSubtle.opacity(0.38), lineWidth: StrokeWidth.hairline)
            }
            .offset(x: metrics.gridOrigin.x, y: metrics.gridOrigin.y)
        }
        .frame(width: metrics.containerSize.width, height: metrics.containerSize.height)
        .clipShape(outerShape)
        .overlay {
            outerShape.stroke(Color.surfaceBorderSubtle.opacity(0.50), lineWidth: StrokeWidth.hairline)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var adaptiveManagementCompactCover: some View {
        switch covers.count {
        case 0:
            adaptiveEmptyCover
        case 1:
            adaptiveSingleCover
        case 2:
            adaptiveDoubleCover
        case 3:
            adaptiveTripletCover
        default:
            adaptiveGridCover
        }
    }

    private var adaptiveEmptyCover: some View {
        let metrics = XMBookGroupAdaptiveManagementMetrics.compact

        return ZStack(alignment: .topLeading) {
            adaptiveTray(
                size: metrics.emptyTraySize,
                origin: metrics.emptyTrayOrigin,
                cornerRadius: metrics.trayCornerRadius
            )

            Image(systemName: "folder")
                .font(AppTypography.caption)
                .foregroundStyle(Color.textHint)
                .frame(width: metrics.emptyGlyphSize.width, height: metrics.emptyGlyphSize.height)
                .position(
                    x: metrics.emptyTrayOrigin.x + metrics.emptyTraySize.width / 2,
                    y: metrics.emptyTrayOrigin.y + metrics.emptyTraySize.height / 2
                )
        }
        .frame(width: metrics.containerSize.width, height: metrics.containerSize.height)
        .accessibilityHidden(true)
    }

    private var adaptiveSingleCover: some View {
        let metrics = XMBookGroupAdaptiveManagementMetrics.compact

        return ZStack(alignment: .topLeading) {
            adaptiveTray(
                size: metrics.singleTraySize,
                origin: metrics.singleTrayOrigin,
                cornerRadius: metrics.trayCornerRadius
            )

            adaptiveBookCoverCell(
                urlString: cover(at: 0),
                size: metrics.singleCoverSize,
                origin: metrics.singleCoverOrigin,
                cornerRadius: metrics.primaryCoverCornerRadius,
                surfaceStyle: .spine,
                shadowOpacity: 0.18,
                shadowRadius: 2.2,
                shadowY: 1.4
            )
        }
        .frame(width: metrics.containerSize.width, height: metrics.containerSize.height)
        .accessibilityHidden(true)
    }

    private var adaptiveDoubleCover: some View {
        let metrics = XMBookGroupAdaptiveManagementMetrics.compact

        return ZStack(alignment: .topLeading) {
            adaptiveTray(
                size: metrics.doubleTraySize,
                origin: metrics.doubleTrayOrigin,
                cornerRadius: metrics.trayCornerRadius
            )

            adaptiveBookCoverCell(
                urlString: cover(at: 1),
                size: metrics.doubleBackCoverSize,
                origin: metrics.doubleBackCoverOrigin,
                cornerRadius: metrics.secondaryCoverCornerRadius,
                rotationDegrees: 2.4,
                shadowOpacity: 0.10,
                shadowRadius: 1.8,
                shadowY: 1
            )

            adaptiveBookCoverCell(
                urlString: cover(at: 0),
                size: metrics.doubleFrontCoverSize,
                origin: metrics.doubleFrontCoverOrigin,
                cornerRadius: metrics.primaryCoverCornerRadius,
                surfaceStyle: .spine,
                rotationDegrees: -2,
                shadowOpacity: 0.18,
                shadowRadius: 2.2,
                shadowY: 1.4
            )
        }
        .frame(width: metrics.containerSize.width, height: metrics.containerSize.height)
        .accessibilityHidden(true)
    }

    private var adaptiveTripletCover: some View {
        let metrics = XMBookGroupAdaptiveManagementMetrics.compact
        let gridShape = RoundedRectangle(cornerRadius: metrics.gridCornerRadius, style: .continuous)

        return ZStack(alignment: .topLeading) {
            adaptiveTray(
                size: metrics.tripletTraySize,
                origin: metrics.tripletTrayOrigin,
                cornerRadius: metrics.gridCornerRadius
            )

            ZStack(alignment: .topLeading) {
                adaptiveBookCoverCell(
                    urlString: cover(at: 0),
                    size: metrics.tripletPrimarySize,
                    origin: metrics.tripletPrimaryOrigin,
                    cornerRadius: 0,
                    surfaceStyle: .plain,
                    border: nil,
                    shadowOpacity: 0,
                    shadowRadius: 0,
                    shadowY: 0
                )

                adaptiveBookCoverCell(
                    urlString: cover(at: 1),
                    size: metrics.tripletSecondarySize,
                    origin: metrics.tripletTopOrigin,
                    cornerRadius: 0,
                    surfaceStyle: .plain,
                    border: nil,
                    shadowOpacity: 0,
                    shadowRadius: 0,
                    shadowY: 0
                )

                adaptiveBookCoverCell(
                    urlString: cover(at: 2),
                    size: metrics.tripletSecondarySize,
                    origin: metrics.tripletBottomOrigin,
                    cornerRadius: 0,
                    surfaceStyle: .plain,
                    border: nil,
                    shadowOpacity: 0,
                    shadowRadius: 0,
                    shadowY: 0
                )
            }
            .frame(width: metrics.tripletTraySize.width, height: metrics.tripletTraySize.height)
            .compositingGroup()
            .clipShape(gridShape)
            .offset(x: metrics.tripletTrayOrigin.x, y: metrics.tripletTrayOrigin.y)
        }
        .frame(width: metrics.containerSize.width, height: metrics.containerSize.height)
        .accessibilityHidden(true)
    }

    private var adaptiveGridCover: some View {
        let metrics = XMBookGroupAdaptiveManagementMetrics.compact
        let gridShape = RoundedRectangle(cornerRadius: metrics.gridCornerRadius, style: .continuous)

        return ZStack(alignment: .topLeading) {
            adaptiveTray(
                size: metrics.gridTraySize,
                origin: metrics.gridTrayOrigin,
                cornerRadius: metrics.gridCornerRadius
            )

            ZStack(alignment: .topLeading) {
                ForEach(metrics.gridSlots) { slot in
                    adaptiveBookCoverCell(
                        urlString: cover(at: slot.coverIndex),
                        size: slot.size,
                        origin: slot.origin,
                        cornerRadius: 0,
                        surfaceStyle: .plain,
                        border: nil,
                        shadowOpacity: 0,
                        shadowRadius: 0,
                        shadowY: 0
                    )
                }
            }
            .frame(width: metrics.gridTraySize.width, height: metrics.gridTraySize.height)
            .compositingGroup()
            .clipShape(gridShape)
            .offset(x: metrics.gridTrayOrigin.x, y: metrics.gridTrayOrigin.y)
        }
        .frame(width: metrics.containerSize.width, height: metrics.containerSize.height)
        .accessibilityHidden(true)
    }

    private func adaptiveTray(size: CGSize, origin: CGPoint, cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        return shape
            .fill(Color.surfaceNested.opacity(0.52))
            .frame(width: size.width, height: size.height)
            .overlay {
                shape.stroke(Color.surfaceBorderSubtle.opacity(0.22), lineWidth: StrokeWidth.hairline)
            }
            .position(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
    }

    private func groupCoverSlot(_ slot: XMBookGroupCoverSlot) -> some View {
        let urlString = cover(at: slot.coverIndex)
        return XMBookCover.fixedSize(
            width: slot.size.width,
            height: slot.size.height,
            urlString: urlString,
            cornerRadius: slot.cornerRadius,
            border: .init(color: slot.borderColor.opacity(slot.borderOpacity), width: StrokeWidth.hairline),
            placeholderBackground: slot.placeholderBackground,
            placeholderIconSize: urlString.isEmpty ? .hidden : .small,
            priority: .low,
            surfaceStyle: slot.coverIndex == 0 ? .spine : .plain
        )
        .opacity(urlString.isEmpty ? slot.emptyOpacity : 1)
        .rotationEffect(.degrees(slot.rotationDegrees))
        .shadow(color: XMBookCoverAppearance.dropShadow.opacity(slot.shadowOpacity), radius: slot.shadowRadius, x: 0, y: slot.shadowY)
        .offset(x: slot.offset.width, y: slot.offset.height)
        .zIndex(slot.zIndex)
    }

    private func collectionCaseSlot(_ slot: XMBookGroupCollectionCaseSlot) -> some View {
        let urlString = cover(at: slot.coverIndex)
        return XMBookCover.fixedSize(
            width: slot.size.width,
            height: slot.size.height,
            urlString: urlString,
            cornerRadius: slot.cornerRadius,
            border: .init(color: slot.borderColor.opacity(slot.borderOpacity), width: StrokeWidth.hairline),
            placeholderBackground: slot.placeholderBackground,
            placeholderIconSize: .hidden,
            priority: .low,
            surfaceStyle: slot.surfaceStyle
        )
        .opacity(urlString.isEmpty ? slot.emptyOpacity : 1)
        .overlay {
            if let decoration = slot.spineDecoration {
                collectionCaseSpineDecoration(slot: slot, decoration: decoration)
            }
        }
        .shadow(color: XMBookCoverAppearance.dropShadow.opacity(slot.shadowOpacity), radius: slot.shadowRadius, x: slot.shadowX, y: slot.shadowY)
        .position(
            x: slot.origin.x + slot.size.width / 2,
            y: slot.origin.y + slot.size.height / 2
        )
        .zIndex(slot.zIndex)
    }

    private func orderedGridSlot(_ slot: XMBookGroupOrderedGridSlot) -> some View {
        let urlString = cover(at: slot.coverIndex)
        return XMBookCover.fixedSize(
            width: slot.size.width,
            height: slot.size.height,
            urlString: urlString,
            cornerRadius: slot.cornerRadius,
            border: nil,
            placeholderBackground: slot.placeholderBackground,
            placeholderIconSize: .hidden,
            priority: .low,
            surfaceStyle: .plain
        )
        .opacity(urlString.isEmpty ? slot.emptyOpacity : 1)
        .position(
            x: slot.origin.x + slot.size.width / 2,
            y: slot.origin.y + slot.size.height / 2
        )
        .zIndex(slot.zIndex)
    }

    private func adaptiveBookCoverCell(
        urlString: String,
        size: CGSize,
        origin: CGPoint,
        cornerRadius: CGFloat,
        surfaceStyle: XMBookCover.SurfaceStyle = .plain,
        rotationDegrees: Double = 0,
        border: XMBookCover.Border? = .init(color: Color.surfaceBorderSubtle.opacity(0.50), width: StrokeWidth.hairline),
        shadowOpacity: Double,
        shadowRadius: CGFloat,
        shadowY: CGFloat
    ) -> some View {
        XMBookCover.fixedSize(
            width: size.width,
            height: size.height,
            urlString: urlString,
            cornerRadius: cornerRadius,
            border: border,
            placeholderBackground: XMBookCoverAppearance.placeholderBackground,
            placeholderIconSize: .small,
            priority: .low,
            surfaceStyle: surfaceStyle
        )
        .rotationEffect(.degrees(rotationDegrees))
        .shadow(color: XMBookCoverAppearance.dropShadow.opacity(shadowOpacity), radius: shadowRadius, x: 0, y: shadowY)
        .position(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
    }

    private func collectionCaseSpineDecoration(
        slot: XMBookGroupCollectionCaseSlot,
        decoration: XMBookGroupSpineDecoration
    ) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: slot.cornerRadius, style: .continuous)
                .fill(decoration.surfaceWash)

            HStack(spacing: Spacing.none) {
                Rectangle()
                    .fill(decoration.leadingEdge)
                    .frame(width: decoration.leadingEdgeWidth)

                Spacer(minLength: 0)

                Rectangle()
                    .fill(decoration.trailingHighlight)
                    .frame(width: decoration.trailingHighlightWidth)
            }

            VStack(spacing: Spacing.none) {
                Rectangle()
                    .fill(decoration.capLine)
                    .frame(height: decoration.capLineWidth)

                Spacer(minLength: 0)

                Rectangle()
                    .fill(decoration.separatorLine)
                    .frame(height: decoration.separatorLineWidth)
                    .padding(.horizontal, decoration.separatorInset)

                Spacer(minLength: 0)

                Rectangle()
                    .fill(decoration.capLine)
                    .frame(height: decoration.capLineWidth)
            }
            .padding(.horizontal, Spacing.hairline)
        }
        .allowsHitTesting(false)
    }

    private func cover(at index: Int) -> String {
        guard covers.indices.contains(index) else { return "" }
        return covers[index]
    }
}

private struct XMBookGroupCoverSlot: Identifiable {
    let id: Int
    let coverIndex: Int
    let size: CGSize
    let offset: CGSize
    let zIndex: Double
    let cornerRadius: CGFloat
    let placeholderBackground: Color
    let borderColor: Color
    let borderOpacity: Double
    let emptyOpacity: Double
    let shadowOpacity: Double
    let shadowRadius: CGFloat
    let shadowY: CGFloat
    let rotationDegrees: Double
}

private struct XMBookGroupCollectionCaseSlot: Identifiable {
    let id: Int
    let coverIndex: Int
    let size: CGSize
    let origin: CGPoint
    let zIndex: Double
    let cornerRadius: CGFloat
    let placeholderBackground: Color
    let borderColor: Color
    let borderOpacity: Double
    let emptyOpacity: Double
    let shadowOpacity: Double
    let shadowRadius: CGFloat
    let shadowX: CGFloat
    let shadowY: CGFloat
    let surfaceStyle: XMBookCover.SurfaceStyle
    let spineDecoration: XMBookGroupSpineDecoration?
}

private struct XMBookGroupSpineDecoration {
    let surfaceWash: Color
    let leadingEdge: Color
    let leadingEdgeWidth: CGFloat
    let trailingHighlight: Color
    let trailingHighlightWidth: CGFloat
    let capLine: Color
    let capLineWidth: CGFloat
    let separatorLine: Color
    let separatorLineWidth: CGFloat
    let separatorInset: CGFloat
}

private struct XMBookGroupOrderedGridSlot: Identifiable {
    let id: Int
    let coverIndex: Int
    let size: CGSize
    let origin: CGPoint
    let zIndex: Double
    let cornerRadius: CGFloat
    let placeholderBackground: Color
    let emptyOpacity: Double
}

private struct XMBookGroupAdaptiveGridSlot: Identifiable {
    let id: Int
    let coverIndex: Int
    let size: CGSize
    let origin: CGPoint
}

private struct XMBookGroupAdaptiveManagementMetrics {
    let containerSize: CGSize
    let trayCornerRadius: CGFloat
    let emptyTraySize: CGSize
    let emptyTrayOrigin: CGPoint
    let emptyGlyphSize: CGSize
    let singleTraySize: CGSize
    let singleTrayOrigin: CGPoint
    let singleCoverSize: CGSize
    let singleCoverOrigin: CGPoint
    let doubleTraySize: CGSize
    let doubleTrayOrigin: CGPoint
    let doubleFrontCoverSize: CGSize
    let doubleFrontCoverOrigin: CGPoint
    let doubleBackCoverSize: CGSize
    let doubleBackCoverOrigin: CGPoint
    let primaryCoverCornerRadius: CGFloat
    let secondaryCoverCornerRadius: CGFloat
    let gridCornerRadius: CGFloat
    let tripletTraySize: CGSize
    let tripletTrayOrigin: CGPoint
    let tripletPrimarySize: CGSize
    let tripletPrimaryOrigin: CGPoint
    let tripletSecondarySize: CGSize
    let tripletTopOrigin: CGPoint
    let tripletBottomOrigin: CGPoint
    let gridTraySize: CGSize
    let gridTrayOrigin: CGPoint
    let gridSlots: [XMBookGroupAdaptiveGridSlot]

    static let compact = XMBookGroupAdaptiveManagementMetrics(
        containerSize: CGSize(width: 48, height: 56),
        trayCornerRadius: 6,
        emptyTraySize: CGSize(width: 32, height: 32),
        emptyTrayOrigin: CGPoint(x: 8, y: 12),
        emptyGlyphSize: CGSize(width: 16, height: 16),
        singleTraySize: CGSize(width: 40, height: 52),
        singleTrayOrigin: CGPoint(x: 2, y: 2),
        singleCoverSize: CGSize(width: 33, height: 49),
        singleCoverOrigin: CGPoint(x: 5.5, y: 3.5),
        doubleTraySize: CGSize(width: 46, height: 50),
        doubleTrayOrigin: CGPoint(x: 1, y: 3),
        doubleFrontCoverSize: CGSize(width: 32, height: 47),
        doubleFrontCoverOrigin: CGPoint(x: 4.5, y: 5),
        doubleBackCoverSize: CGSize(width: 30, height: 45),
        doubleBackCoverOrigin: CGPoint(x: 18, y: 6),
        primaryCoverCornerRadius: CornerRadius.inlaySmall,
        secondaryCoverCornerRadius: CornerRadius.inlayTiny,
        gridCornerRadius: 5,
        tripletTraySize: CGSize(width: 47, height: 50),
        tripletTrayOrigin: CGPoint(x: 0.5, y: 3),
        tripletPrimarySize: CGSize(width: 30.5, height: 50),
        tripletPrimaryOrigin: CGPoint(x: 0, y: 0),
        tripletSecondarySize: CGSize(width: 15.5, height: 24.5),
        tripletTopOrigin: CGPoint(x: 31.5, y: 0),
        tripletBottomOrigin: CGPoint(x: 31.5, y: 25.5),
        gridTraySize: CGSize(width: XMBookGroupAdaptiveGridConstants.gridWidth, height: XMBookGroupAdaptiveGridConstants.gridHeight),
        gridTrayOrigin: CGPoint(x: XMBookGroupAdaptiveGridConstants.gridOriginX, y: 3),
        gridSlots: [
            XMBookGroupAdaptiveGridSlot(
                id: 0,
                coverIndex: 0,
                size: XMBookGroupAdaptiveGridConstants.cellSize,
                origin: CGPoint(x: XMBookGroupAdaptiveGridConstants.horizontalInset, y: 0)
            ),
            XMBookGroupAdaptiveGridSlot(
                id: 1,
                coverIndex: 1,
                size: XMBookGroupAdaptiveGridConstants.cellSize,
                origin: CGPoint(x: XMBookGroupAdaptiveGridConstants.trailingColumnX, y: 0)
            ),
            XMBookGroupAdaptiveGridSlot(
                id: 2,
                coverIndex: 2,
                size: XMBookGroupAdaptiveGridConstants.cellSize,
                origin: CGPoint(x: XMBookGroupAdaptiveGridConstants.horizontalInset, y: XMBookGroupAdaptiveGridConstants.bottomRowY)
            ),
            XMBookGroupAdaptiveGridSlot(
                id: 3,
                coverIndex: 3,
                size: XMBookGroupAdaptiveGridConstants.cellSize,
                origin: CGPoint(
                    x: XMBookGroupAdaptiveGridConstants.trailingColumnX,
                    y: XMBookGroupAdaptiveGridConstants.bottomRowY
                )
            )
        ]
    )
}

private enum XMBookGroupAdaptiveGridConstants {
    static let gridWidth: CGFloat = 42
    static let gridHeight: CGFloat = 50
    static let coverGap: CGFloat = 1
    static let cellHeight: CGFloat = (gridHeight - coverGap) / 2
    static let cellSize = CGSize(width: cellHeight * XMBookCover.aspectRatio, height: cellHeight)
    static let horizontalInset: CGFloat = (gridWidth - cellSize.width * 2 - coverGap) / 2
    static let trailingColumnX: CGFloat = horizontalInset + cellSize.width + coverGap
    static let bottomRowY: CGFloat = cellHeight + coverGap
    static let gridOriginX: CGFloat = (48 - gridWidth) / 2
}

private struct XMBookGroupCollectionCaseMetrics {
    let containerSize: CGSize
    let outerCornerRadius: CGFloat
    let traySize: CGSize
    let trayOrigin: CGPoint
    let trayCornerRadius: CGFloat
    let primarySlot: XMBookGroupCollectionCaseSlot
    let spineSlots: [XMBookGroupCollectionCaseSlot]

    static let compact = XMBookGroupCollectionCaseMetrics(
        containerSize: CGSize(width: 58, height: 56),
        outerCornerRadius: XMBookGroupCollectionCaseConstants.outerCornerRadius,
        traySize: CGSize(width: 50, height: 48),
        trayOrigin: CGPoint(x: 4, y: 4),
        trayCornerRadius: XMBookGroupCollectionCaseConstants.trayCornerRadius,
        primarySlot: XMBookGroupCollectionCaseSlot(
            id: 0,
            coverIndex: 0,
            size: CGSize(width: 29, height: 44),
            origin: CGPoint(x: 7, y: 6),
            zIndex: 3,
            cornerRadius: XMBookGroupCollectionCaseConstants.primaryCornerRadius,
            placeholderBackground: XMBookCoverAppearance.placeholderBackground,
            borderColor: Color.surfaceBorderSubtle,
            borderOpacity: 0.50,
            emptyOpacity: 1,
            shadowOpacity: 0.10,
            shadowRadius: 0.9,
            shadowX: 0.8,
            shadowY: 0.4,
            surfaceStyle: .spine,
            spineDecoration: nil
        ),
        spineSlots: [
            XMBookGroupCollectionCaseSlot(
                id: 1,
                coverIndex: 1,
                size: CGSize(width: 11, height: 44),
                origin: CGPoint(x: 36, y: 6),
                zIndex: 2,
                cornerRadius: XMBookGroupCollectionCaseConstants.spineCornerRadius,
                placeholderBackground: Color.controlFillSecondary,
                borderColor: Color.textHint,
                borderOpacity: 0.40,
                emptyOpacity: 1,
                shadowOpacity: 0,
                shadowRadius: 0,
                shadowX: 0,
                shadowY: 0,
                surfaceStyle: .plain,
                spineDecoration: .primary
            ),
            XMBookGroupCollectionCaseSlot(
                id: 2,
                coverIndex: 2,
                size: CGSize(width: 8, height: 42),
                origin: CGPoint(x: 46, y: 7),
                zIndex: 1,
                cornerRadius: XMBookGroupCollectionCaseConstants.spineCornerRadius,
                placeholderBackground: Color.controlFillSecondary.opacity(0.82),
                borderColor: Color.textHint,
                borderOpacity: 0.34,
                emptyOpacity: 1,
                shadowOpacity: 0,
                shadowRadius: 0,
                shadowX: 0,
                shadowY: 0,
                surfaceStyle: .plain,
                spineDecoration: .secondary
            )
        ]
    )
}

private enum XMBookGroupCollectionCaseConstants {
    static let outerCornerRadius: CGFloat = 5
    static let trayCornerRadius: CGFloat = 4
    static let primaryCornerRadius: CGFloat = 3
    static let spineCornerRadius: CGFloat = 2
}

private struct XMBookGroupOrderedGridMetrics {
    let containerSize: CGSize
    let outerCornerRadius: CGFloat
    let gridSize: CGSize
    let gridOrigin: CGPoint
    let gridCornerRadius: CGFloat
    let slots: [XMBookGroupOrderedGridSlot]

    static let compact = XMBookGroupOrderedGridMetrics(
        containerSize: CGSize(width: 58, height: 56),
        outerCornerRadius: XMBookGroupOrderedGridConstants.outerCornerRadius,
        gridSize: CGSize(width: XMBookGroupOrderedGridConstants.gridWidth, height: XMBookGroupOrderedGridConstants.gridHeight),
        gridOrigin: CGPoint(x: 4, y: 4),
        gridCornerRadius: XMBookGroupOrderedGridConstants.gridCornerRadius,
        slots: [
            XMBookGroupOrderedGridSlot(
                id: 0,
                coverIndex: 0,
                size: XMBookGroupOrderedGridConstants.cellSize,
                origin: CGPoint(x: XMBookGroupOrderedGridConstants.horizontalInset, y: 0),
                zIndex: 1,
                cornerRadius: 0,
                placeholderBackground: XMBookCoverAppearance.placeholderBackground,
                emptyOpacity: 1
            ),
            XMBookGroupOrderedGridSlot(
                id: 1,
                coverIndex: 1,
                size: XMBookGroupOrderedGridConstants.cellSize,
                origin: CGPoint(x: XMBookGroupOrderedGridConstants.trailingColumnX, y: 0),
                zIndex: 1,
                cornerRadius: 0,
                placeholderBackground: Color.controlFillSecondary.opacity(0.94),
                emptyOpacity: 1
            ),
            XMBookGroupOrderedGridSlot(
                id: 2,
                coverIndex: 2,
                size: XMBookGroupOrderedGridConstants.cellSize,
                origin: CGPoint(x: XMBookGroupOrderedGridConstants.horizontalInset, y: XMBookGroupOrderedGridConstants.bottomRowY),
                zIndex: 1,
                cornerRadius: 0,
                placeholderBackground: Color.controlFillSecondary.opacity(0.88),
                emptyOpacity: 1
            ),
            XMBookGroupOrderedGridSlot(
                id: 3,
                coverIndex: 3,
                size: XMBookGroupOrderedGridConstants.cellSize,
                origin: CGPoint(
                    x: XMBookGroupOrderedGridConstants.trailingColumnX,
                    y: XMBookGroupOrderedGridConstants.bottomRowY
                ),
                zIndex: 1,
                cornerRadius: 0,
                placeholderBackground: Color.controlFillSecondary.opacity(0.82),
                emptyOpacity: 1
            )
        ]
    )
}

private enum XMBookGroupOrderedGridConstants {
    static let outerCornerRadius: CGFloat = 5
    static let gridCornerRadius: CGFloat = 4
    static let gridWidth: CGFloat = 50
    static let gridHeight: CGFloat = 48
    static let coverGap: CGFloat = 1
    static let cellHeight: CGFloat = (gridHeight - coverGap) / 2
    static let cellSize = CGSize(width: cellHeight * XMBookCover.aspectRatio, height: cellHeight)
    static let horizontalInset: CGFloat = (gridWidth - cellSize.width * 2 - coverGap) / 2
    static let trailingColumnX: CGFloat = horizontalInset + cellSize.width + coverGap
    static let bottomRowY: CGFloat = cellHeight + coverGap
}

private extension XMBookGroupSpineDecoration {
    static let primary = XMBookGroupSpineDecoration(
        surfaceWash: Color.surfaceCard.opacity(0.09),
        leadingEdge: Color.black.opacity(0.10),
        leadingEdgeWidth: 1,
        trailingHighlight: Color.white.opacity(0.12),
        trailingHighlightWidth: 0.5,
        capLine: Color.surfaceBorderSubtle.opacity(0.26),
        capLineWidth: 0.45,
        separatorLine: Color.surfaceBorderSubtle.opacity(0.20),
        separatorLineWidth: 0.45,
        separatorInset: 3.8
    )

    static let secondary = XMBookGroupSpineDecoration(
        surfaceWash: Color.surfaceNested.opacity(0.08),
        leadingEdge: Color.black.opacity(0.08),
        leadingEdgeWidth: 0.8,
        trailingHighlight: Color.white.opacity(0.10),
        trailingHighlightWidth: 0.4,
        capLine: Color.surfaceBorderSubtle.opacity(0.22),
        capLineWidth: 0.45,
        separatorLine: Color.surfaceBorderSubtle.opacity(0.17),
        separatorLineWidth: 0.4,
        separatorInset: 3
    )
}

private struct XMBookGroupCoverMetrics {
    let containerSize: CGSize
    let cornerRadius: CGFloat
    let slots: [XMBookGroupCoverSlot]

    init(style: XMBookGroupCover.Style) {
        switch style {
        case .compactList, .collectionCaseCompact, .orderedGridCompact, .adaptiveManagementCompact:
            containerSize = CGSize(width: 58, height: 56)
            cornerRadius = CornerRadius.inlaySmall
            slots = [
                XMBookGroupCoverSlot(
                    id: 2,
                    coverIndex: 2,
                    size: CGSize(width: 25, height: 38),
                    offset: CGSize(width: 17, height: -6),
                    zIndex: 0,
                    cornerRadius: CornerRadius.inlayTiny,
                    placeholderBackground: Color.controlFillSecondary,
                    borderColor: Color.textHint,
                    borderOpacity: 0.42,
                    emptyOpacity: 1,
                    shadowOpacity: 0.14,
                    shadowRadius: 2,
                    shadowY: 1,
                    rotationDegrees: 4
                ),
                XMBookGroupCoverSlot(
                    id: 1,
                    coverIndex: 1,
                    size: CGSize(width: 28, height: 42),
                    offset: CGSize(width: 7, height: 2),
                    zIndex: 1,
                    cornerRadius: CornerRadius.inlayTiny,
                    placeholderBackground: XMBookCoverAppearance.placeholderBackground,
                    borderColor: Color.textHint,
                    borderOpacity: 0.48,
                    emptyOpacity: 1,
                    shadowOpacity: 0.16,
                    shadowRadius: 2,
                    shadowY: 1,
                    rotationDegrees: 2
                ),
                XMBookGroupCoverSlot(
                    id: 0,
                    coverIndex: 0,
                    size: CGSize(width: 31, height: 45),
                    offset: CGSize(width: -10, height: 1),
                    zIndex: 2,
                    cornerRadius: CornerRadius.inlaySmall,
                    placeholderBackground: XMBookCoverAppearance.placeholderBackground,
                    borderColor: Color.surfaceBorderSubtle,
                    borderOpacity: 0.58,
                    emptyOpacity: 1.0,
                    shadowOpacity: 0.16,
                    shadowRadius: 3,
                    shadowY: 2,
                    rotationDegrees: 0
                )
            ]
        }
    }
}
