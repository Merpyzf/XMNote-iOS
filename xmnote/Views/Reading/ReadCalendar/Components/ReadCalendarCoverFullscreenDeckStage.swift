/**
 * [INPUT]: 依赖 XMRemoteImage 与 DesignTokens，依赖封面条目、容器尺寸、阶段状态与稳定随机种子
 * [OUTPUT]: 对外提供 ReadCalendarCoverFullscreenDeckStage（封面全屏容器：堆叠态 + 纵向网格态）
 * [POS]: ReadCalendar 页面私有子视图，用于浮层内“情绪化堆叠”向“可浏览列表”过渡的统一渲染
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// ReadCalendarCoverFullscreenDeckStage 负责在浮层中渲染封面堆叠态与纵向网格态。
struct ReadCalendarCoverFullscreenDeckStage: View {
    /// Phase 描述全屏容器当前展示阶段。
    enum Phase: Hashable {
        case stacked
        case grid
    }

    /// MatchedTransitionStyle 描述共享元素匹配项在阶段切换时的节奏策略。
    enum MatchedTransitionStyle: Hashable {
        case staggered
        case synchronous
    }

    /// StackedLayoutAlgorithm 描述堆叠阶段的摆放算法策略。
    enum StackedLayoutAlgorithm: Hashable {
        case templateLegacy
        case panelAwareAdaptive
        case editorialDeskScatter
    }

    /// CoverSizingMode 描述封面尺寸的求解策略。
    enum CoverSizingMode: Hashable {
        case fixed
        case panelAwareBalanced
    }

    /// GridColumnLayoutMode 描述平铺网格的列数策略。
    enum GridColumnLayoutMode: Hashable {
        case adaptive
        case fixed(count: Int, degradeForSmallItemCount: Bool)
    }

    private struct DeckTransform {
        let rotation: Double
        let offsetX: CGFloat
        let offsetY: CGFloat
        let zIndex: Double
        let scale: CGFloat
        let opacity: CGFloat
    }

    private struct DeskTierSpec {
        let distanceFactor: CGFloat
        let overlapMin: CGFloat
        let overlapMax: CGFloat
    }

    private struct DeckAdaptiveMetrics {
        let coverSize: CGSize
        let gridSpacing: CGFloat
        let deskZone: DeskZone
        let baseMinDistance: CGFloat
        let deskDriftX: CGFloat
        let deskDriftY: CGFloat
        let deskTiers: [DeskTierSpec]
    }

    private enum Layout {
        static let hiddenStackAnchorOpacity: CGFloat = 0.001
        static let hiddenExtraGridOpacity: CGFloat = 0
        static let cardAnimationDelayStep: Double = 0.024
        static let cardAnimationDelayCap: Double = 0.2
        static let cardAnimationResponse: CGFloat = 0.42
        static let cardAnimationDamping: CGFloat = 0.86
        static let extraGridFadeDuration: CGFloat = 0.18
        static let borderOpacity: CGFloat = 0.45
        static let borderWidth: CGFloat = 0.45
        static let placeholderOpacity: CGFloat = 0.52
        static let gridSpacing: CGFloat = 10
        static let minGridColumns = 2
        static let maxGridColumns = 4
        static let minGridScale: CGFloat = 0.84
        static let maxGridScale: CGFloat = 1.06
        static let minGridCardWidth: CGFloat = 44
        static let maxCollapsedSupportedCount = 14
        static let defaultCoverAspectRatio: CGFloat = 1.46
        static let minCoverAspectRatio: CGFloat = 1.35
        static let maxCoverAspectRatio: CGFloat = 1.55
        static let adaptiveFillRatioLow: CGFloat = 0.55
        static let adaptiveFillRatioMid: CGFloat = 0.63
        static let adaptiveFillRatioHigh: CGFloat = 0.71
        static let adaptiveFillRatioDense: CGFloat = 0.77
        static let adaptiveEffectiveCoverageUnit: CGFloat = 0.44
        static let adaptiveMinCoverWidth: CGFloat = 62
        static let adaptiveMinCoverWidthRatio: CGFloat = 0.18
        static let adaptiveMaxCoverWidthRatio: CGFloat = 0.43
        static let adaptiveMaxCoverHeightRatio: CGFloat = 0.86
        static let adaptiveGridSpacingRatio: CGFloat = 0.14
        static let adaptiveGridSpacingMin: CGFloat = 8
        static let adaptiveGridSpacingMax: CGFloat = 18
        static let adaptiveDeskZoneHalfXRatio: CGFloat = 0.48
        static let adaptiveDeskZoneHalfYRatio: CGFloat = 0.46
        static let adaptiveDeskSafeHalfXRatio: CGFloat = 0.54
        static let adaptiveDeskSafeHalfYRatio: CGFloat = 0.56
        static let adaptiveDeskDriftXRatio: CGFloat = 0.18
        static let adaptiveDeskDriftYRatio: CGFloat = 0.16
        static let adaptiveDeskMinDistanceRatio: CGFloat = 0.72
        static let minStackedSpreadFactor: CGFloat = 1
        static let maxStackedSpreadFactor: CGFloat = 1.28
        static let adaptiveTangentialJitterUnit: CGFloat = 0.65
        static let adaptiveRadialJitterUnit: CGFloat = 0.22
        static let adaptiveClampInsetXRatio: CGFloat = 0.70
        static let adaptiveClampInsetYRatio: CGFloat = 0.65
        static let adaptiveDirectionRotationWeight: Double = 0.08
        static let adaptiveTemplateRotationWeight: Double = 0.22
        static let deskZoneWidthRatio: CGFloat = 0.82
        static let deskZoneHeightRatio: CGFloat = 0.66
        static let deskSafeInsetXRatio: CGFloat = 0.58
        static let deskSafeInsetYRatio: CGFloat = 0.55
        static let deskAnchorXJitterRatio: CGFloat = 0.08
        static let deskAnchorYJitterRatio: CGFloat = 0.06
        static let deskAnchorRotation: Double = 5
        static let deskRotationMax: Double = 24
        static let deskDirectionRotationWeight: Double = 0.10
        static let deskTemplateRotationWeight: Double = 0.18
        static let deskMaxAttemptsPerTier = 30
        static let deskScaleDecay: CGFloat = 0.03
        static let deskMinScale: CGFloat = 0.84
        static let deskOpacityDecay: CGFloat = 0.02
        static let deskMinOpacity: CGFloat = 0.90
        static let fixedDeskDriftXRatio: CGFloat = 0.12
        static let fixedDeskDriftYRatio: CGFloat = 0.10
    }

    let items: [ReadCalendarCoverFanStack.Item]
    let style: ReadCalendarCoverFanStack.Style
    let coverSize: CGSize
    let containerSize: CGSize
    let phase: Phase
    let phaseToken: Int
    let isAnimated: Bool
    let layoutSeed: ReadCalendarCoverFanStack.LayoutSeed
    let stackedVisibleCount: Int
    let previewLimit: Int
    let shouldClipGrid: Bool
    let matchedTransitionStyle: MatchedTransitionStyle
    let stackedLayoutAlgorithm: StackedLayoutAlgorithm
    let stackedSpreadFactor: CGFloat
    let coverSizingMode: CoverSizingMode
    let sourceCoverAspectRatio: CGFloat
    let gridColumnLayoutMode: GridColumnLayoutMode

    @Namespace private var itemTransitionNamespace

    /// 创建全屏容器阶段视图，统一承载堆叠预览与纵向网格列表。
    init(
        items: [ReadCalendarCoverFanStack.Item],
        style: ReadCalendarCoverFanStack.Style,
        coverSize: CGSize,
        containerSize: CGSize,
        phase: Phase,
        phaseToken: Int,
        isAnimated: Bool,
        layoutSeed: ReadCalendarCoverFanStack.LayoutSeed,
        stackedVisibleCount: Int,
        previewLimit: Int,
        shouldClipGrid: Bool = true,
        matchedTransitionStyle: MatchedTransitionStyle = .staggered,
        stackedLayoutAlgorithm: StackedLayoutAlgorithm = .templateLegacy,
        stackedSpreadFactor: CGFloat = 1,
        coverSizingMode: CoverSizingMode = .fixed,
        sourceCoverAspectRatio: CGFloat = Layout.defaultCoverAspectRatio,
        gridColumnLayoutMode: GridColumnLayoutMode = .adaptive
    ) {
        self.items = items
        self.style = style
        self.coverSize = coverSize
        self.containerSize = containerSize
        self.phase = phase
        self.phaseToken = phaseToken
        self.isAnimated = isAnimated
        self.layoutSeed = layoutSeed
        self.stackedVisibleCount = max(1, stackedVisibleCount)
        self.previewLimit = max(1, previewLimit)
        self.shouldClipGrid = shouldClipGrid
        self.matchedTransitionStyle = matchedTransitionStyle
        self.stackedLayoutAlgorithm = stackedLayoutAlgorithm
        self.stackedSpreadFactor = min(
            Layout.maxStackedSpreadFactor,
            max(Layout.minStackedSpreadFactor, stackedSpreadFactor)
        )
        self.coverSizingMode = coverSizingMode
        self.sourceCoverAspectRatio = Self.normalizedAspectRatio(sourceCoverAspectRatio)
        self.gridColumnLayoutMode = gridColumnLayoutMode
    }

    var body: some View {
        if phase == .grid, shouldClipGrid {
            stageContainer
                .clipped()
        } else {
            stageContainer
        }
    }

    /// 按容器空间与可见堆叠数量反推封面尺寸，提升舞台利用率。
    static func resolveAdaptiveCoverSize(
        containerSize: CGSize,
        visibleCount: Int,
        sourceAspectRatio: CGFloat
    ) -> CGSize {
        let aspect = normalizedAspectRatio(sourceAspectRatio)
        let normalizedCount = max(1, min(visibleCount, Layout.maxCollapsedSupportedCount))
        guard containerSize.width > 0, containerSize.height > 0 else {
            return CGSize(width: Layout.adaptiveMinCoverWidth, height: Layout.adaptiveMinCoverWidth * aspect)
        }

        let fillRatio = adaptiveFillRatio(for: normalizedCount)
        let effectiveCount = 1 + CGFloat(max(0, normalizedCount - 1)) * Layout.adaptiveEffectiveCoverageUnit
        let usableArea = max(1, containerSize.width * containerSize.height)
        let denominator = max(0.001, aspect * effectiveCount)
        let rawWidth = sqrt(usableArea * fillRatio / denominator)
        let lowerBound = max(Layout.adaptiveMinCoverWidth, containerSize.width * Layout.adaptiveMinCoverWidthRatio)
        let upperByWidth = containerSize.width * Layout.adaptiveMaxCoverWidthRatio
        let upperByHeight = containerSize.height * Layout.adaptiveMaxCoverHeightRatio / aspect
        let upperBound = max(lowerBound, min(upperByWidth, upperByHeight))
        let width = clamped(rawWidth, lower: lowerBound, upper: upperBound)
        return CGSize(width: width, height: width * aspect)
    }
}

private extension ReadCalendarCoverFullscreenDeckStage {
    static func adaptiveFillRatio(for visibleCount: Int) -> CGFloat {
        switch visibleCount {
        case ...2:
            return Layout.adaptiveFillRatioLow
        case 3...5:
            return Layout.adaptiveFillRatioMid
        case 6...8:
            return Layout.adaptiveFillRatioHigh
        default:
            return Layout.adaptiveFillRatioDense
        }
    }

    static func normalizedAspectRatio(_ value: CGFloat) -> CGFloat {
        let resolved = value.isFinite && value > 0 ? value : Layout.defaultCoverAspectRatio
        return clamped(resolved, lower: Layout.minCoverAspectRatio, upper: Layout.maxCoverAspectRatio)
    }

    static func clamped(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        min(max(value, lower), upper)
    }

    private var resolvedMetrics: DeckAdaptiveMetrics {
        switch coverSizingMode {
        case .fixed:
            let zone = DeskZone(
                halfX: max(
                    1,
                    min(
                        containerSize.width * Layout.deskZoneWidthRatio * 0.5,
                        max(1, containerSize.width * 0.5 - coverSize.width * Layout.deskSafeInsetXRatio)
                    )
                ),
                halfY: max(
                    1,
                    min(
                        containerSize.height * Layout.deskZoneHeightRatio * 0.5,
                        max(1, containerSize.height * 0.5 - coverSize.height * Layout.deskSafeInsetYRatio)
                    )
                )
            )
            return DeckAdaptiveMetrics(
                coverSize: coverSize,
                gridSpacing: Layout.gridSpacing,
                deskZone: zone,
                baseMinDistance: coverSize.width * 0.58,
                deskDriftX: coverSize.width * Layout.fixedDeskDriftXRatio,
                deskDriftY: coverSize.height * Layout.fixedDeskDriftYRatio,
                deskTiers: [
                    DeskTierSpec(distanceFactor: 1.0, overlapMin: 0.20, overlapMax: 0.35),
                    DeskTierSpec(distanceFactor: 0.85, overlapMin: 0.16, overlapMax: 0.42),
                    DeskTierSpec(distanceFactor: 0.70, overlapMin: 0.12, overlapMax: 0.48)
                ]
            )
        case .panelAwareBalanced:
            let adaptiveCoverSize = Self.resolveAdaptiveCoverSize(
                containerSize: containerSize,
                visibleCount: stackedVisibleLimit,
                sourceAspectRatio: sourceCoverAspectRatio
            )
            let gridSpacing = Self.clamped(
                adaptiveCoverSize.width * Layout.adaptiveGridSpacingRatio,
                lower: Layout.adaptiveGridSpacingMin,
                upper: Layout.adaptiveGridSpacingMax
            )
            let safeHalfX = max(1, (containerSize.width - adaptiveCoverSize.width) * Layout.adaptiveDeskSafeHalfXRatio)
            let safeHalfY = max(1, (containerSize.height - adaptiveCoverSize.height) * Layout.adaptiveDeskSafeHalfYRatio)
            let zone = DeskZone(
                halfX: max(1, min(containerSize.width * Layout.adaptiveDeskZoneHalfXRatio, safeHalfX)),
                halfY: max(1, min(containerSize.height * Layout.adaptiveDeskZoneHalfYRatio, safeHalfY))
            )
            return DeckAdaptiveMetrics(
                coverSize: adaptiveCoverSize,
                gridSpacing: gridSpacing,
                deskZone: zone,
                baseMinDistance: adaptiveCoverSize.width * Layout.adaptiveDeskMinDistanceRatio,
                deskDriftX: adaptiveCoverSize.width * Layout.adaptiveDeskDriftXRatio,
                deskDriftY: adaptiveCoverSize.height * Layout.adaptiveDeskDriftYRatio,
                deskTiers: [
                    DeskTierSpec(distanceFactor: 1.0, overlapMin: 0.16, overlapMax: 0.30),
                    DeskTierSpec(distanceFactor: 0.88, overlapMin: 0.12, overlapMax: 0.36),
                    DeskTierSpec(distanceFactor: 0.76, overlapMin: 0.08, overlapMax: 0.42)
                ]
            )
        }
    }

    var resolvedCoverSize: CGSize {
        resolvedMetrics.coverSize
    }

    var resolvedGridSpacing: CGFloat {
        resolvedMetrics.gridSpacing
    }

    var stageContainer: some View {
        ZStack {
            stackedLayer
                .opacity(phase == .stacked ? 1 : Layout.hiddenStackAnchorOpacity)
                .allowsHitTesting(phase == .stacked)

            gridLayer
                .allowsHitTesting(phase == .grid)
        }
        .frame(width: containerSize.width, height: containerSize.height, alignment: .center)
    }

    var stackedVisibleLimit: Int {
        let cap = min(Layout.maxCollapsedSupportedCount, previewLimit)
        return min(stackedVisibleCount, cap)
    }

    var stackedItems: [ReadCalendarCoverFanStack.Item] {
        Array(items.prefix(stackedVisibleLimit))
    }

    var stackedItemIDSet: Set<String> {
        Set(stackedItems.map(\.id))
    }

    var stackedLayer: some View {
        ZStack {
            ForEach(Array(stackedItems.enumerated()), id: \.element.id) { index, item in
                let transform = collapsedTransform(for: index, total: stackedItems.count)
                coverCard(for: item, size: resolvedCoverSize)
                    .matchedGeometryEffect(
                        id: itemTransitionID(for: item.id),
                        in: itemTransitionNamespace,
                        properties: .frame,
                        anchor: .center,
                        isSource: phase == .stacked
                    )
                    .rotationEffect(.degrees(transform.rotation))
                    .offset(x: transform.offsetX, y: transform.offsetY)
                    .scaleEffect(transform.scale)
                    .zIndex(transform.zIndex)
                    .opacity(transform.opacity)
                    .shadow(
                        color: Color.black.opacity(style.shadowOpacity),
                        radius: style.shadowRadius,
                        x: style.shadowX,
                        y: style.shadowY
                    )
                    .animation(matchedCardAnimation(for: index), value: phaseToken)
            }
        }
        .frame(width: containerSize.width, height: containerSize.height, alignment: .center)
    }

    var gridLayer: some View {
        let cardSize = gridCardSize
        let columns = gridColumns(for: cardSize.width)

        return ScrollView(.vertical, showsIndicators: true) {
            LazyVGrid(columns: columns, spacing: resolvedGridSpacing) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if stackedItemIDSet.contains(item.id) {
                        coverCard(for: item, size: cardSize)
                            .matchedGeometryEffect(
                                id: itemTransitionID(for: item.id),
                                in: itemTransitionNamespace,
                                properties: .frame,
                                anchor: .center,
                                isSource: phase == .grid
                            )
                            .shadow(
                                color: Color.black.opacity(style.shadowOpacity * 0.92),
                                radius: style.shadowRadius,
                                x: style.shadowX,
                                y: style.shadowY
                            )
                            .opacity(phase == .grid ? 1 : Layout.hiddenStackAnchorOpacity)
                            .animation(matchedCardAnimation(for: index), value: phaseToken)
                    } else {
                        coverCard(for: item, size: cardSize)
                            .shadow(
                                color: Color.black.opacity(style.shadowOpacity * 0.92),
                                radius: style.shadowRadius,
                                x: style.shadowX,
                                y: style.shadowY
                            )
                            .opacity(phase == .grid ? 1 : Layout.hiddenExtraGridOpacity)
                            .scaleEffect(phase == .grid ? 1 : 0.96)
                            .animation(.easeOut(duration: Layout.extraGridFadeDuration), value: phaseToken)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, Spacing.base)
        }
    }

    /// 折叠态：与日格封面组件使用同源算法，保证打开首帧摆放一致。
    private func collapsedTransform(for depth: Int, total: Int) -> DeckTransform {
        switch stackedLayoutAlgorithm {
        case .templateLegacy:
            return legacyCollapsedTransform(for: depth)
        case .panelAwareAdaptive:
            return adaptiveCollapsedTransform(for: depth, total: total)
        case .editorialDeskScatter:
            return editorialDeskScatterTransform(for: depth, total: total)
        }
    }

    private func legacyCollapsedTransform(for depth: Int) -> DeckTransform {
        let template = collapsedTemplate(depth: depth)
        let jitterRotation = Double(jitter(depth: depth, channel: 11)) * style.jitterDegree
        let jitterX = jitter(depth: depth, channel: 23) * style.jitterOffsetRatio * resolvedCoverSize.width
        let jitterY = jitter(depth: depth, channel: 31) * style.jitterOffsetRatio * resolvedCoverSize.height

        return DeckTransform(
            rotation: template.rotation + jitterRotation,
            offsetX: (template.offsetX + jitterX) * stackedSpreadFactor,
            offsetY: (template.offsetY + jitterY) * stackedSpreadFactor,
            zIndex: Double(220 - depth),
            scale: max(0.78, template.scale),
            opacity: max(0.78, template.opacity)
        )
    }

    /// 自适应折叠态：根据面板与平铺目标格位反推首屏堆叠，强化“展开为列表”的位移感知。
    private func adaptiveCollapsedTransform(for depth: Int, total: Int) -> DeckTransform {
        let template = collapsedTemplate(depth: depth)
        let jitterRotation = Double(jitter(depth: depth, channel: 151)) * style.jitterDegree
        if depth == 0 || total <= 1 {
            return DeckTransform(
                rotation: jitterRotation * 0.36,
                offsetX: 0,
                offsetY: 0,
                zIndex: Double(220 - depth),
                scale: max(0.78, template.scale),
                opacity: max(0.78, template.opacity)
            )
        }

        let gridTarget = adaptiveGridTargetOffset(for: depth, cardSize: gridCardSize, columns: resolvedGridColumnCount)
        let compression = adaptiveCompressionFactor(for: total)
        let compressed = CGPoint(x: gridTarget.x * compression, y: gridTarget.y * compression)
        let vectorLength = max(0.001, hypot(gridTarget.x, gridTarget.y))
        let direction = CGVector(dx: gridTarget.x / vectorLength, dy: gridTarget.y / vectorLength)
        let tangent = CGVector(dx: -direction.dy, dy: direction.dx)
        let tangentialJitter = jitter(depth: depth, channel: 101)
        let radialJitter = jitter(depth: depth, channel: 131)
        let tangentialAmplitude = min(resolvedCoverSize.width, resolvedCoverSize.height) * Layout.adaptiveTangentialJitterUnit
        let radialAmplitude = resolvedCoverSize.width * Layout.adaptiveRadialJitterUnit
        let perturbed = CGPoint(
            x: compressed.x
                + tangent.dx * tangentialAmplitude * tangentialJitter
                + direction.dx * radialAmplitude * radialJitter,
            y: compressed.y
                + tangent.dy * tangentialAmplitude * tangentialJitter
                + direction.dy * radialAmplitude * radialJitter
        )
        let clamped = adaptiveClamp(offset: perturbed)
        let directionAngle = Double(atan2(gridTarget.y, gridTarget.x) * 180 / .pi)
        let rotation = template.rotation * Layout.adaptiveTemplateRotationWeight
            + directionAngle * Layout.adaptiveDirectionRotationWeight
            + jitterRotation

        return DeckTransform(
            rotation: rotation,
            offsetX: clamped.x,
            offsetY: clamped.y,
            zIndex: Double(220 - depth),
            scale: max(0.78, template.scale),
            opacity: max(0.78, template.opacity)
        )
    }

    /// 折叠态模板：与 ReadCalendarCoverFanStack 保持同构参数。
    private func collapsedTemplate(depth: Int) -> DeckTransform {
        let templates: [(rotation: Double, xRatio: CGFloat, yRatio: CGFloat, scale: CGFloat, opacity: CGFloat)] = [
            (0, 0, 0, 1, 1),
            (style.secondaryRotation, style.secondaryOffsetXRatio, style.secondaryOffsetYRatio, 0.98, 1),
            (style.tertiaryRotation, style.tertiaryOffsetXRatio, style.tertiaryOffsetYRatio, 0.95, 0.99),
            (9, 0.18, -0.16, 0.92, 0.98),
            (-18, -0.62, 0.20, 0.9, 0.97),
            (14, 0.34, -0.24, 0.88, 0.96),
            (-26, -0.78, 0.28, 0.86, 0.95),
            (19, 0.46, -0.32, 0.84, 0.94),
            (-31, -0.9, 0.36, 0.82, 0.93),
            (23, 0.58, -0.36, 0.8, 0.92),
            (-35, -1.02, 0.42, 0.79, 0.91),
            (27, 0.7, -0.4, 0.78, 0.9),
            (-39, -1.1, 0.48, 0.77, 0.89),
            (30, 0.8, -0.44, 0.76, 0.88)
        ]
        let selected = templates[min(depth, templates.count - 1)]
        return DeckTransform(
            rotation: selected.rotation,
            offsetX: resolvedCoverSize.width * selected.xRatio,
            offsetY: resolvedCoverSize.height * selected.yRatio,
            zIndex: Double(220 - depth),
            scale: selected.scale,
            opacity: selected.opacity
        )
    }

    /// 计算纵向网格中的封面尺寸，优先维持封面质感并限制过度放大。
    var gridCardSize: CGSize {
        let columns = resolvedGridColumnCount
        let spacingTotal = resolvedGridSpacing * CGFloat(max(0, columns - 1))
        let availableWidth = max(0, containerSize.width - spacingTotal)
        let naturalWidth = availableWidth / CGFloat(max(1, columns))
        let width: CGFloat
        switch gridColumnLayoutMode {
        case .adaptive:
            let minimum = max(Layout.minGridCardWidth, resolvedCoverSize.width * Layout.minGridScale)
            let adaptiveMaximum = max(minimum, resolvedCoverSize.width * Layout.maxGridScale)
            width = min(adaptiveMaximum, max(minimum, naturalWidth))
        case .fixed:
            let fixedMaximum = max(1, resolvedCoverSize.width * Layout.maxGridScale)
            width = max(1, min(fixedMaximum, naturalWidth))
        }
        let ratio = max(1.2, resolvedCoverSize.height / max(1, resolvedCoverSize.width))
        return CGSize(width: width, height: width * ratio)
    }

    /// 根据容器宽度与目标卡片宽度生成纵向网格列配置。
    func gridColumns(for cardWidth: CGFloat) -> [GridItem] {
        let count = resolvedGridColumnCount
        let item = GridItem(.fixed(cardWidth), spacing: resolvedGridSpacing, alignment: .top)
        return Array(repeating: item, count: count)
    }

    /// 计算可用列数：支持自适应模式与固定列模式。
    var resolvedGridColumnCount: Int {
        switch gridColumnLayoutMode {
        case .adaptive:
            guard items.count > 1 else { return 1 }
            let preferredWidth = max(Layout.minGridCardWidth, resolvedCoverSize.width * Layout.minGridScale)
            let rough = Int((containerSize.width + resolvedGridSpacing) / (preferredWidth + resolvedGridSpacing))
            return min(Layout.maxGridColumns, max(Layout.minGridColumns, rough))
        case let .fixed(count, degradeForSmallItemCount):
            let sanitized = max(1, count)
            if degradeForSmallItemCount {
                return max(1, min(sanitized, items.count))
            }
            return sanitized
        }
    }

    /// 计算自适应堆叠中的目标格位中心（相对容器中心）。
    func adaptiveGridTargetOffset(for index: Int, cardSize: CGSize, columns: Int) -> CGPoint {
        let clampedColumns = max(1, columns)
        let column = index % clampedColumns
        let row = index / clampedColumns
        let gridWidth = CGFloat(clampedColumns) * cardSize.width
            + CGFloat(max(0, clampedColumns - 1)) * resolvedGridSpacing
        let startX = (containerSize.width - gridWidth) / 2
        let x = startX + cardSize.width / 2 + CGFloat(column) * (cardSize.width + resolvedGridSpacing)
        let topInset = Spacing.base
        let y = topInset + cardSize.height / 2 + CGFloat(row) * (cardSize.height + resolvedGridSpacing)
        return CGPoint(
            x: x - containerSize.width / 2,
            y: y - containerSize.height / 2
        )
    }

    func adaptiveCompressionFactor(for total: Int) -> CGFloat {
        switch total {
        case ...1:
            return 0
        case 2:
            return 0.24
        case 3...5:
            return 0.20
        case 6...8:
            return 0.17
        default:
            return 0.14
        }
    }

    func adaptiveClamp(offset: CGPoint) -> CGPoint {
        let maxX = max(0, containerSize.width * 0.5 - resolvedCoverSize.width * Layout.adaptiveClampInsetXRatio)
        let maxY = max(0, containerSize.height * 0.5 - resolvedCoverSize.height * Layout.adaptiveClampInsetYRatio)
        return CGPoint(
            x: min(max(offset.x, -maxX), maxX),
            y: min(max(offset.y, -maxY), maxY)
        )
    }

    private struct DeskZone {
        let halfX: CGFloat
        let halfY: CGFloat
    }

    private struct DeskPlacement {
        let offset: CGPoint
        let rotation: Double
    }

    private struct DeskCandidate {
        let offset: CGPoint
        let score: CGFloat
        let isQualified: Bool
    }

    /// 桌面散落态：先独立求解“随手摆放”位置，再通过共享元素过渡到列表。
    private func editorialDeskScatterTransform(for depth: Int, total: Int) -> DeckTransform {
        let placements = editorialDeskPlacements(total: total)
        let safeIndex = min(max(0, depth), max(0, placements.count - 1))
        let placement = placements[safeIndex]
        return DeckTransform(
            rotation: placement.rotation,
            offsetX: placement.offset.x,
            offsetY: placement.offset.y,
            zIndex: Double(220 - depth),
            scale: editorialScale(for: depth),
            opacity: editorialOpacity(for: depth)
        )
    }

    private func editorialDeskPlacements(total: Int) -> [DeskPlacement] {
        guard total > 0 else { return [] }
        let metrics = resolvedMetrics
        let zone = metrics.deskZone
        var placements: [DeskPlacement] = []
        placements.reserveCapacity(total)

        let anchorOffset = clampToDeskZone(
            CGPoint(
                x: deskSymmetricRandom(depth: 0, attempt: 0, tier: 0, channel: 11)
                    * resolvedCoverSize.width * Layout.deskAnchorXJitterRatio,
                y: deskSymmetricRandom(depth: 0, attempt: 0, tier: 0, channel: 17)
                    * resolvedCoverSize.height * Layout.deskAnchorYJitterRatio
            ),
            zone: zone
        )
        let anchorRotation = Double(deskSymmetricRandom(depth: 0, attempt: 0, tier: 0, channel: 23))
            * Layout.deskAnchorRotation
        placements.append(DeskPlacement(offset: anchorOffset, rotation: anchorRotation))

        guard total > 1 else { return placements }

        for depth in 1..<total {
            placements.append(bestDeskPlacement(for: depth, placed: placements, metrics: metrics))
        }
        return placements
    }

    private func bestDeskPlacement(
        for depth: Int,
        placed: [DeskPlacement],
        metrics: DeckAdaptiveMetrics
    ) -> DeskPlacement {
        let zone = metrics.deskZone
        var bestOverall: DeskCandidate?

        for (tierIndex, tier) in metrics.deskTiers.enumerated() {
            let minimumDistance = metrics.baseMinDistance * tier.distanceFactor
            var bestInTier: DeskCandidate?

            for attempt in 0..<Layout.deskMaxAttemptsPerTier {
                let candidateOffset = deskCandidateOffset(
                    for: depth,
                    attempt: attempt,
                    tier: tierIndex,
                    zone: zone,
                    metrics: metrics
                )
                let evaluated = evaluateDeskCandidate(
                    candidateOffset,
                    placed: placed,
                    zone: zone,
                    minDistance: minimumDistance,
                    overlapMin: tier.overlapMin,
                    overlapMax: tier.overlapMax
                )
                let candidate = DeskCandidate(
                    offset: candidateOffset,
                    score: evaluated.score,
                    isQualified: evaluated.isQualified
                )
                if let current = bestInTier {
                    if candidate.score > current.score {
                        bestInTier = candidate
                    }
                } else {
                    bestInTier = candidate
                }
                if let currentOverall = bestOverall {
                    if candidate.score > currentOverall.score {
                        bestOverall = candidate
                    }
                } else {
                    bestOverall = candidate
                }
            }

            if let bestInTier, bestInTier.isQualified {
                return DeskPlacement(
                    offset: bestInTier.offset,
                    rotation: editorialRotation(for: bestInTier.offset, depth: depth, tier: tierIndex)
                )
            }
        }

        let fallbackOffset = bestOverall?.offset ?? clampToDeskZone(
            CGPoint(
                x: deskSymmetricRandom(depth: depth, attempt: 0, tier: 99, channel: 31) * zone.halfX,
                y: deskSymmetricRandom(depth: depth, attempt: 0, tier: 99, channel: 37) * zone.halfY
            ),
            zone: zone
        )
        return DeskPlacement(
            offset: fallbackOffset,
            rotation: editorialRotation(for: fallbackOffset, depth: depth, tier: 99)
        )
    }

    private func clampToDeskZone(_ offset: CGPoint, zone: DeskZone) -> CGPoint {
        CGPoint(
            x: min(max(offset.x, -zone.halfX), zone.halfX),
            y: min(max(offset.y, -zone.halfY), zone.halfY)
        )
    }

    private func deskCandidateOffset(
        for depth: Int,
        attempt: Int,
        tier: Int,
        zone: DeskZone,
        metrics: DeckAdaptiveMetrics
    ) -> CGPoint {
        let angle = Double(deskUnitRandom(depth: depth, attempt: attempt, tier: tier, channel: 41)) * .pi * 2
        let radius = sqrt(deskUnitRandom(depth: depth, attempt: attempt, tier: tier, channel: 53))
        let radiusX = zone.halfX * radius
        let radiusY = zone.halfY * radius
        let driftX = deskSymmetricRandom(depth: depth, attempt: attempt, tier: tier, channel: 67)
            * metrics.deskDriftX
        let driftY = deskSymmetricRandom(depth: depth, attempt: attempt, tier: tier, channel: 71)
            * metrics.deskDriftY
        let offset = CGPoint(
            x: CGFloat(cos(angle)) * radiusX + driftX,
            y: CGFloat(sin(angle)) * radiusY + driftY
        )
        return clampToDeskZone(offset, zone: zone)
    }

    private func evaluateDeskCandidate(
        _ offset: CGPoint,
        placed: [DeskPlacement],
        zone: DeskZone,
        minDistance: CGFloat,
        overlapMin: CGFloat,
        overlapMax: CGFloat
    ) -> (score: CGFloat, isQualified: Bool) {
        guard !placed.isEmpty else { return (1, true) }
        var minDistanceToOthers = CGFloat.greatestFiniteMagnitude
        var overlapSum: CGFloat = 0
        var maxOverlap: CGFloat = 0

        for item in placed {
            let dx = offset.x - item.offset.x
            let dy = offset.y - item.offset.y
            let distance = hypot(dx, dy)
            minDistanceToOthers = min(minDistanceToOthers, distance)
            let overlap = overlapRatio(lhs: offset, rhs: item.offset)
            overlapSum += overlap
            maxOverlap = max(maxOverlap, overlap)
        }

        let avgOverlap = overlapSum / CGFloat(max(1, placed.count))
        let hasCollision = minDistanceToOthers < minDistance
        let overlapInRange = avgOverlap >= overlapMin && avgOverlap <= overlapMax
        let overlapScore = overlapFitness(avgOverlap, minOverlap: overlapMin, maxOverlap: overlapMax)
        let spacingScore = min(1, max(0, (minDistanceToOthers - minDistance) / (resolvedCoverSize.width * 0.9)))
        let quadrantScore = quadrantBalanceScore(offset: offset, placed: placed)
        let edgePenalty = edgeProximityPenalty(offset: offset, zone: zone)
        let crowdPenalty = max(0, maxOverlap - 0.62) * 1.5
        let collisionPenalty: CGFloat = hasCollision ? 3.5 : 0
        let score = overlapScore * 2
            + spacingScore * 1.1
            + quadrantScore * 0.65
            - edgePenalty
            - crowdPenalty
            - collisionPenalty
        let qualified = !hasCollision && overlapInRange && maxOverlap <= 0.62
        return (score, qualified)
    }

    private func overlapFitness(_ overlap: CGFloat, minOverlap: CGFloat, maxOverlap: CGFloat) -> CGFloat {
        if overlap < minOverlap {
            let penalty = (minOverlap - overlap) / max(0.0001, minOverlap)
            return max(-1, 1 - penalty * 1.8)
        }
        if overlap > maxOverlap {
            let penalty = (overlap - maxOverlap) / max(0.0001, 1 - maxOverlap)
            return max(-1, 1 - penalty * 1.8)
        }
        return 1
    }

    private func overlapRatio(lhs: CGPoint, rhs: CGPoint) -> CGFloat {
        let overlapWidth = max(0, resolvedCoverSize.width - abs(lhs.x - rhs.x))
        let overlapHeight = max(0, resolvedCoverSize.height - abs(lhs.y - rhs.y))
        let area = overlapWidth * overlapHeight
        let fullArea = max(1, resolvedCoverSize.width * resolvedCoverSize.height)
        return area / fullArea
    }

    private func quadrantBalanceScore(offset: CGPoint, placed: [DeskPlacement]) -> CGFloat {
        var counts = [0, 0, 0, 0]
        for item in placed {
            counts[quadrantIndex(for: item.offset)] += 1
        }
        let candidateIndex = quadrantIndex(for: offset)
        let maxCount = counts.max() ?? 0
        let candidateCount = counts[candidateIndex]
        let normalized = CGFloat(maxCount - candidateCount) / CGFloat(max(1, maxCount + 1))
        return max(0, normalized)
    }

    private func quadrantIndex(for offset: CGPoint) -> Int {
        switch (offset.x >= 0, offset.y >= 0) {
        case (true, false):
            return 0
        case (false, false):
            return 1
        case (false, true):
            return 2
        case (true, true):
            return 3
        }
    }

    private func edgeProximityPenalty(offset: CGPoint, zone: DeskZone) -> CGFloat {
        let normalizedX = abs(offset.x) / max(1, zone.halfX)
        let normalizedY = abs(offset.y) / max(1, zone.halfY)
        let nearEdge = max(normalizedX, normalizedY)
        guard nearEdge > 0.78 else { return 0 }
        return min(1, (nearEdge - 0.78) / 0.22) * 0.75
    }

    private func editorialRotation(for offset: CGPoint, depth: Int, tier: Int) -> Double {
        let randomRotation = Double(deskSymmetricRandom(depth: depth, attempt: 0, tier: tier, channel: 89))
            * Layout.deskRotationMax
        let directionRotation = Double(atan2(offset.y, offset.x) * 180 / .pi)
            * Layout.deskDirectionRotationWeight
        let templateRotation = collapsedTemplate(depth: depth).rotation
            * Layout.deskTemplateRotationWeight
        let value = randomRotation + directionRotation + templateRotation
        return min(Layout.deskRotationMax + 4, max(-(Layout.deskRotationMax + 4), value))
    }

    private func editorialScale(for depth: Int) -> CGFloat {
        max(Layout.deskMinScale, 1 - CGFloat(depth) * Layout.deskScaleDecay)
    }

    private func editorialOpacity(for depth: Int) -> CGFloat {
        max(Layout.deskMinOpacity, 1 - CGFloat(depth) * Layout.deskOpacityDecay)
    }

    private func deskUnitRandom(depth: Int, attempt: Int, tier: Int, channel: UInt64) -> CGFloat {
        let depthValue = UInt64(max(0, depth) + 1)
        let attemptValue = UInt64(max(0, attempt) + 1)
        let tierValue = UInt64(max(0, tier) + 1)
        var state = layoutSeed.rawValue
            ^ depthValue &* 0x9E37_79B9_7F4A_7C15
            ^ attemptValue &* 0xBF58_476D_1CE4_E5B9
            ^ tierValue &* 0x94D0_49BB_1331_11EB
            ^ channel &* 0xD6E8_FEB8_6659_FD93
        state = splitMix64(state)
        return CGFloat(Double(state) / Double(UInt64.max))
    }

    private func deskSymmetricRandom(depth: Int, attempt: Int, tier: Int, channel: UInt64) -> CGFloat {
        deskUnitRandom(depth: depth, attempt: attempt, tier: tier, channel: channel) * 2 - 1
    }

    /// 生成单张卡片的过渡动画，阶段切换时形成轻微错峰感。
    func matchedCardAnimation(for index: Int) -> Animation? {
        guard isAnimated else { return nil }
        let baseAnimation = Animation.spring(
            response: Layout.cardAnimationResponse,
            dampingFraction: Layout.cardAnimationDamping
        )
        switch matchedTransitionStyle {
        case .staggered:
            return baseAnimation.delay(min(Layout.cardAnimationDelayCap, Double(index) * Layout.cardAnimationDelayStep))
        case .synchronous:
            return baseAnimation
        }
    }

    /// 生成稳定抖动值（-1...1），保证同日同数据布局可复现。
    func jitter(depth: Int, channel: UInt64) -> CGFloat {
        let depthValue = UInt64(max(0, depth) + 1)
        var state = layoutSeed.rawValue
            &+ depthValue &* 0x9E37_79B9_7F4A_7C15
            ^ channel &* 0xBF58_476D_1CE4_E5B9
        state = splitMix64(state)
        let unit = Double(state) / Double(UInt64.max)
        return CGFloat(unit * 2 - 1)
    }

    /// 执行 splitMix64 变换，提升抖动序列分布均匀性。
    func splitMix64(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    func itemTransitionID(for itemID: String) -> String {
        "cover-deck-item-\(itemID)"
    }

    /// 为全屏阶段渲染单张封面卡片，委托 XMBookCover 统一裁切与占位。
    func coverCard(for item: ReadCalendarCoverFanStack.Item, size: CGSize) -> some View {
        XMBookCover.fixedSize(
            width: size.width,
            height: size.height,
            urlString: item.coverURL ?? "",
            border: .init(color: .white.opacity(Layout.borderOpacity), width: Layout.borderWidth),
            placeholderBackground: Color.readCalendarSelectionFill.opacity(Layout.placeholderOpacity),
            placeholderIconFont: nil,
            priority: .low
        )
    }

    /// 归一化封面宽高比到安全范围，避免极端值导致布局异常。
}
