/**
 * [INPUT]: 依赖 UICollectionViewLayout 可见区域查询、稳定书摘 ID、页面 chrome 避让与设计系统间距
 * [OUTPUT]: 对外提供沉浸分页、顺序自适应行带桌面与纵向瀑布流三种可替换虚拟化布局
 * [POS]: Views/Note/Components 的全屏回顾布局层，以不可变桌面几何和可见行二分避免滚动热路径全量扫描
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import UIKit

/// 单条全屏纵向分页布局；每个 Cell 严格占据一个集合视图视口，由系统滚动视图负责分页物理。
final class ImmersiveReviewFlowLayout: UICollectionViewFlowLayout {
    override init() {
        super.init()
        scrollDirection = .vertical
        minimumLineSpacing = 0
        minimumInteritemSpacing = 0
        estimatedItemSize = .zero
        sectionInset = .zero
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        itemSize = CGSize(
            width: max(1, collectionView.bounds.width - sectionInset.left - sectionInset.right),
            height: max(1, collectionView.bounds.height - sectionInset.top - sectionInset.bottom)
        )
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        guard let collectionView else { return false }
        return abs(newBounds.width - collectionView.bounds.width) > 0.5
            || abs(newBounds.height - collectionView.bounds.height) > 0.5
    }
}

/// 书摘总览页面私有几何；数字只服务桌面和瀑布流，不晋升为全局设计令牌。
enum NoteReviewOverviewMetrics {
    static let estimatedCardHeight: CGFloat = 280
    static let minimumCardHeight: CGFloat = 168
    static let maximumCardHeight: CGFloat = 420
    static let maximumDesktopCardHeight: CGFloat = 336
    static let cardWidthRatio: CGFloat = 0.78
    static let minimumDesktopCardWidth: CGFloat = 300
    static let maximumDesktopCardWidth: CGFloat = 420
    static let minimumVisualSpacing: CGFloat = Spacing.double
    static let canvasOuterMargin: CGFloat = 48
    static let desktopRowPhases: [CGFloat] = [0, Spacing.base, 0, -Spacing.base]
    static let rotationDegrees: [CGFloat] = [0, 0, 0, -0.35, 0.35, -0.6, 0.6]
    static let fullDesktopViewportOccupancy: CGFloat = 0.82
    static let readableCardWidthRatio: CGFloat = 0.56
    static let maximumCardWidthRatio: CGFloat = 0.88
    static let overviewProjectedCardWidth: CGFloat = 132
    static let maximumLiveCellCount = 48
    static let waterfallSpacing: CGFloat = Spacing.screenEdge
    static let waterfallEdgeInset: CGFloat = Spacing.screenEdge
    static let waterfallMinimumRegularColumnWidth: CGFloat = 220
}

/// 单张桌面纸张的轻量几何快照；远景分块可直接消费它而无需创建 Cell。
struct NoteReviewDesktopPlacement {
    let index: Int
    let logicalFrame: CGRect
    let logicalVisualFrame: CGRect
    let contentCenter: CGPoint
    let contentVisualFrame: CGRect
    let rotationAngle: CGFloat
    let scale: CGFloat

    /// 返回 Cell 外框的统一物理缩放；纸张旋转由 Cell 内部 paperView 单独承担，避免重复旋转。
    var contentTransform: CGAffineTransform {
        CGAffineTransform(scaleX: scale, y: scale)
    }
}

/// 后台分块与前台 Layout 共享的单张纸纯几何；所有坐标均位于未缩放桌面坐标系。
nonisolated struct NoteReviewDesktopPaperGeometry: Sendable {
    let index: Int
    let noteID: Int64
    let logicalFrame: CGRect
    let logicalVisualFrame: CGRect
    let rotationAngle: CGFloat

    var logicalFrameCenter: CGPoint {
        CGPoint(x: logicalFrame.midX, y: logicalFrame.midY)
    }
}

/// 可安全交给后台任务的桌面几何快照；只保存值类型配置、稳定槽位和已提交纸高。
nonisolated struct DesktopGeometrySnapshot: Sendable {
    let generation: UInt64
    let slotIDs: [Int64?]
    let itemCount: Int
    let columnCount: Int
    let rowCount: Int
    let cardWidth: CGFloat
    let maximumCardHeight: CGFloat
    let slotSize: CGSize
    let stepSize: CGSize
    let canvasSize: CGSize
    let usesAccessibilityLayout: Bool
    let isRightToLeft: Bool
    let measuredHeights: [Int: CGFloat]
    let estimatedCardHeight: CGFloat
    let minimumCardHeight: CGFloat
    let canvasOuterMargin: CGFloat
    let desktopRowPhases: [CGFloat]
    let rotationDegrees: [CGFloat]
    let paperGeometriesByIndex: [NoteReviewDesktopPaperGeometry?]
    let rowVisualFrames: [CGRect]
    let rowItemIndexes: [[Int]]

    /// 返回指定稳定槽位的纸张纯几何；删除后保留的空槽不产生纸张。
    func paperGeometry(at index: Int) -> NoteReviewDesktopPaperGeometry? {
        guard paperGeometriesByIndex.indices.contains(index) else { return nil }
        return paperGeometriesByIndex[index]
    }

    /// 通过可见行二分枚举逻辑分块及 bleed 周边的候选，并以纸张中心的半开区间归属避免跨块重复。
    func paperGeometries(
        in tileRect: CGRect,
        bleed: CGFloat
    ) throws -> [NoteReviewDesktopPaperGeometry] {
        guard itemCount > 0,
              tileRect.width > 0,
              tileRect.height > 0 else { return [] }
        let normalizedBleed = bleed.isFinite ? max(0, bleed) : 0
        let queryRect = tileRect.insetBy(dx: -normalizedBleed, dy: -normalizedBleed)
        var result: [NoteReviewDesktopPaperGeometry] = []
        result.reserveCapacity(32)
        var examinedCount = 0
        var row = firstRowWhoseVisualFrameEnds(after: queryRect.minY)
        while row < rowItemIndexes.count {
            if rowVisualFrames[row].minY > queryRect.maxY { break }
            for index in rowItemIndexes[row] {
                if examinedCount.isMultiple(of: 64) {
                    try Task.checkCancellation()
                }
                examinedCount += 1
                guard let geometry = paperGeometry(at: index) else { continue }
                guard geometry.logicalVisualFrame.intersects(queryRect),
                      containsHalfOpen(tileRect, point: geometry.logicalFrameCenter) else { continue }
                result.append(geometry)
            }
            row += 1
        }
        return result
    }

    /// 在互不重叠的顺序行带中二分定位首个底边进入查询范围的行。
    private func firstRowWhoseVisualFrameEnds(after minimumY: CGFloat) -> Int {
        var lowerBound = 0
        var upperBound = rowVisualFrames.count
        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            if rowVisualFrames[middle].maxY < minimumY {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        return lowerBound
    }

    /// 使用半开矩形判定中心归属，避免相邻分块共同拥有边界纸张。
    private func containsHalfOpen(_ rect: CGRect, point: CGPoint) -> Bool {
        point.x >= rect.minX
            && point.x < rect.maxX
            && point.y >= rect.minY
            && point.y < rect.maxY
    }
}

/// 当前桌面 generation 的测量约束；控制器必须用该卡宽生成完整高度表。
nonisolated struct NoteReviewDesktopGeometryPreparationContext: Sendable {
    let generation: UInt64
    let cardWidth: CGFloat
    let maximumCardHeight: CGFloat
}

/// 后台纯数据构建器的不可变输入；只有完整高度表才能从 Layout 公开入口创建该请求。
nonisolated struct NoteReviewDesktopGeometryBuildRequest: Sendable {
    let generation: UInt64
    let slotIDs: [Int64?]
    let itemHeights: [CGFloat]
    let viewportSize: CGSize
    let chromeInsets: UIEdgeInsets
    let usesAccessibilityLayout: Bool
    let isRightToLeft: Bool
    let isCompleteHeightTable: Bool
}

/// 一代桌面排版的不可变结果；构建期间不接触 UIKit 视图，主线程只做 generation 校验和原子安装。
nonisolated struct NoteReviewDesktopCommittedGeometry: Sendable {
    let generation: UInt64
    let slotIDs: [Int64?]
    let itemCount: Int
    let columnCount: Int
    let rowCount: Int
    let cardWidth: CGFloat
    let maximumCardHeight: CGFloat
    let slotSize: CGSize
    let stepSize: CGSize
    let canvasSize: CGSize
    let viewportSize: CGSize
    let chromeInsets: UIEdgeInsets
    let usesAccessibilityLayout: Bool
    let isRightToLeft: Bool
    let itemHeights: [CGFloat]
    let slotLogicalFrames: [CGRect]
    let slotVisualFrames: [CGRect]
    let slotRotationAngles: [CGFloat]
    let rowVisualFrames: [CGRect]
    let rowItemIndexes: [[Int]]
    let isCompleteHeightTable: Bool
}

/// 构建顺序自适应行带；调用者可在 detached Task 中执行，取消会在长清单中定期生效。
nonisolated enum NoteReviewDesktopGeometryBuilder {
    /// 解析与正式 builder 完全相同的卡宽和高度上限，供调用方在构建前完成整批文本测量。
    static func preparationContext(
        generation: UInt64,
        viewportSize: CGSize,
        chromeInsets: UIEdgeInsets
    ) -> NoteReviewDesktopGeometryPreparationContext {
        let normalizedInsets = normalizedInsets(chromeInsets)
        let availableSize = CGSize(
            width: max(1, viewportSize.width - normalizedInsets.left - normalizedInsets.right),
            height: max(1, viewportSize.height - normalizedInsets.top - normalizedInsets.bottom)
        )
        return NoteReviewDesktopGeometryPreparationContext(
            generation: generation,
            cardWidth: max(
                NoteReviewOverviewMetrics.minimumDesktopCardWidth,
                min(
                    NoteReviewOverviewMetrics.maximumDesktopCardWidth,
                    min(availableSize.width, availableSize.height)
                        * NoteReviewOverviewMetrics.cardWidthRatio
                )
            ),
            maximumCardHeight: NoteReviewOverviewMetrics.maximumDesktopCardHeight
        )
    }

    static func build(
        _ request: NoteReviewDesktopGeometryBuildRequest
    ) throws -> NoteReviewDesktopCommittedGeometry {
        let normalizedInsets = UIEdgeInsets(
            top: max(0, request.chromeInsets.top),
            left: max(0, request.chromeInsets.left),
            bottom: max(0, request.chromeInsets.bottom),
            right: max(0, request.chromeInsets.right)
        )
        let availableSize = CGSize(
            width: max(1, request.viewportSize.width - normalizedInsets.left - normalizedInsets.right),
            height: max(1, request.viewportSize.height - normalizedInsets.top - normalizedInsets.bottom)
        )
        let itemCount = request.slotIDs.count
        let preparationContext = preparationContext(
            generation: request.generation,
            viewportSize: request.viewportSize,
            chromeInsets: normalizedInsets
        )
        let cardWidth = preparationContext.cardWidth
        let maximumHeight = preparationContext.maximumCardHeight
        let maximumAngle = CGFloat(0.6) * .pi / 180
        let maximumVisualSize = rotatedBoundingSize(
            CGSize(width: cardWidth, height: maximumHeight),
            angle: maximumAngle
        )
        let slotSize = maximumVisualSize
        let stepSize = CGSize(
            width: slotSize.width + NoteReviewOverviewMetrics.minimumVisualSpacing,
            height: NoteReviewOverviewMetrics.estimatedCardHeight
                + NoteReviewOverviewMetrics.minimumVisualSpacing
        )
        let columnCount = resolvedDesktopColumnCount(
            itemCount: itemCount,
            availableSize: availableSize,
            stepSize: stepSize
        )
        let rowCount = columnCount == 0
            ? 0
            : Int(ceil(Double(itemCount) / Double(columnCount)))
        let heights = request.slotIDs.indices.map { index in
            let proposed = request.itemHeights.indices.contains(index)
                ? request.itemHeights[index]
                : NoteReviewOverviewMetrics.estimatedCardHeight
            return max(
                NoteReviewOverviewMetrics.minimumCardHeight,
                min(maximumHeight, proposed.isFinite ? proposed : NoteReviewOverviewMetrics.estimatedCardHeight)
            )
        }
        var logicalFrames = Array(repeating: CGRect.zero, count: itemCount)
        var visualFrames = Array(repeating: CGRect.zero, count: itemCount)
        var rotationAngles = Array(repeating: CGFloat.zero, count: itemCount)
        var rowVisualFrames: [CGRect] = []
        var rowItemIndexes: [[Int]] = []
        rowVisualFrames.reserveCapacity(rowCount)
        rowItemIndexes.reserveCapacity(rowCount)

        let phases = request.usesAccessibilityLayout
            ? [CGFloat.zero]
            : NoteReviewOverviewMetrics.desktopRowPhases
        let minimumPhase = phases.min() ?? 0
        var nextRowVisualTop = NoteReviewOverviewMetrics.canvasOuterMargin
        var maximumVisualRight = NoteReviewOverviewMetrics.canvasOuterMargin

        for row in 0..<rowCount {
            if row.isMultiple(of: 32) { try Task.checkCancellation() }
            let lowerBound = row * columnCount
            let upperBound = min(itemCount, lowerBound + columnCount)
            let indexes = Array(lowerBound..<upperBound)
            rowItemIndexes.append(indexes)
            let styles = indexes.map { index in
                makeDesktopPaperStyle(
                    noteID: request.slotIDs[index] ?? Int64(index),
                    measuredHeight: heights[index],
                    cardWidth: cardWidth,
                    maximumCardHeight: maximumHeight,
                    usesAccessibilityLayout: request.usesAccessibilityLayout,
                    isRightToLeft: request.isRightToLeft
                )
            }
            let maximumTopBleed = styles.map { max(0, ($0.visualSize.height - $0.height) / 2) }.max() ?? 0
            let logicalTop = nextRowVisualTop + maximumTopBleed
            let phase = phases.isEmpty ? 0 : phases[row % phases.count]
            let rowOriginX = NoteReviewOverviewMetrics.canvasOuterMargin - minimumPhase + phase
            var rowVisualFrame = CGRect.null

            for (column, index) in indexes.enumerated() {
                let style = styles[column]
                let centerX = rowOriginX + slotSize.width / 2 + CGFloat(column) * stepSize.width
                let logicalFrame = CGRect(
                    x: centerX - cardWidth / 2,
                    y: logicalTop,
                    width: cardWidth,
                    height: style.height
                )
                let visualFrame = rotatedBoundingFrame(for: logicalFrame, angle: style.rotationAngle)
                logicalFrames[index] = logicalFrame
                visualFrames[index] = visualFrame
                rotationAngles[index] = style.rotationAngle
                rowVisualFrame = rowVisualFrame.union(visualFrame)
            }
            if rowVisualFrame.isNull {
                rowVisualFrame = CGRect(
                    x: NoteReviewOverviewMetrics.canvasOuterMargin,
                    y: nextRowVisualTop,
                    width: 0,
                    height: 0
                )
            }
            rowVisualFrames.append(rowVisualFrame)
            maximumVisualRight = max(maximumVisualRight, rowVisualFrame.maxX)
            nextRowVisualTop = rowVisualFrame.maxY + NoteReviewOverviewMetrics.minimumVisualSpacing
        }

        let contentBottom = rowVisualFrames.last?.maxY ?? 0
        let canvasSize = itemCount == 0
            ? availableSize
            : CGSize(
                width: max(1, maximumVisualRight + NoteReviewOverviewMetrics.canvasOuterMargin),
                height: max(1, contentBottom + NoteReviewOverviewMetrics.canvasOuterMargin)
            )
        return NoteReviewDesktopCommittedGeometry(
            generation: request.generation,
            slotIDs: request.slotIDs,
            itemCount: itemCount,
            columnCount: columnCount,
            rowCount: rowCount,
            cardWidth: cardWidth,
            maximumCardHeight: maximumHeight,
            slotSize: slotSize,
            stepSize: stepSize,
            canvasSize: canvasSize,
            viewportSize: request.viewportSize,
            chromeInsets: normalizedInsets,
            usesAccessibilityLayout: request.usesAccessibilityLayout,
            isRightToLeft: request.isRightToLeft,
            itemHeights: heights,
            slotLogicalFrames: logicalFrames,
            slotVisualFrames: visualFrames,
            slotRotationAngles: rotationAngles,
            rowVisualFrames: rowVisualFrames,
            rowItemIndexes: rowItemIndexes,
            isCompleteHeightTable: request.isCompleteHeightTable
        )
    }

    /// 0/1/2 条采用显式列数，其余清单只按 N 与安全视口比例选择一次。
    private static func resolvedDesktopColumnCount(
        itemCount: Int,
        availableSize: CGSize,
        stepSize: CGSize
    ) -> Int {
        switch itemCount {
        case 0: return 0
        case 1: return 1
        case 2: return 2
        default:
            let aspectRatio = availableSize.width / max(1, availableSize.height)
            let estimate = Int(
                round(
                    sqrt(
                        CGFloat(itemCount)
                            * aspectRatio
                            * stepSize.height
                            / max(1, stepSize.width)
                    )
                )
            )
            return max(2, min(itemCount, estimate))
        }
    }
}

/// 构建行带时单张纸所需的稳定样式；高度与旋转均不依赖滚动状态。
nonisolated private struct DesktopPaperStyle: Sendable {
    let height: CGFloat
    let rotationAngle: CGFloat
    let visualSize: CGSize
}

/// 将 ID、自然高度和无障碍环境解析为确定性纸张样式。
private func makeDesktopPaperStyle(
    noteID: Int64,
    measuredHeight: CGFloat?,
    cardWidth: CGFloat,
    maximumCardHeight: CGFloat,
    usesAccessibilityLayout: Bool,
    isRightToLeft: Bool
) -> DesktopPaperStyle {
    let seed = deterministicSeed(noteID: noteID)
    let rawHeight = measuredHeight ?? NoteReviewOverviewMetrics.estimatedCardHeight
    let height = max(
        NoteReviewOverviewMetrics.minimumCardHeight,
        min(maximumCardHeight, rawHeight)
    )
    let rotations = NoteReviewOverviewMetrics.rotationDegrees
    let rawDegrees = rotations.isEmpty
        ? 0
        : rotations[
            Int((seed >> 32) % UInt64(rotations.count))
        ]
    let degrees: CGFloat
    if usesAccessibilityLayout {
        degrees = 0
    } else {
        degrees = isRightToLeft ? -rawDegrees : rawDegrees
    }
    let rotationAngle = degrees * .pi / 180
    return DesktopPaperStyle(
        height: height,
        rotationAngle: rotationAngle,
        visualSize: rotatedBoundingSize(
            CGSize(width: cardWidth, height: height),
            angle: rotationAngle
        )
    )
}

/// 二维有限桌面布局；全部书摘拥有稳定公式化槽位，但只为查询矩形生成布局属性。
final class NoteReviewDesktopCanvasLayout: UICollectionViewLayout {
    var noteIDProvider: ((Int) -> Int64?)? {
        didSet {
            requestedGeometryGeneration &+= 1
            needsGeometryRebuild = true
            invalidateLayout()
        }
    }

    private(set) var scale: CGFloat = 1
    private(set) var fitScale: CGFloat = 1
    private(set) var readableScale: CGFloat = 1
    private(set) var maximumScale: CGFloat = 1
    private(set) var resolvedCardWidth: CGFloat = 1
    private(set) var resolvedMaximumCardHeight = NoteReviewOverviewMetrics.maximumDesktopCardHeight
    private(set) var logicalCanvasSize: CGSize = .zero
    private(set) var canvasContentOrigin: CGPoint = .zero
    private(set) var contentCanvasFrame: CGRect = .zero

    var projectedCardWidth: CGFloat { resolvedCardWidth * scale }
    var isOverviewRendering: Bool {
        projectedCardWidth < NoteReviewOverviewMetrics.overviewProjectedCardWidth
    }

    fileprivate struct GeometrySnapshot {
        let itemCount: Int
        let columnCount: Int
        let rowCount: Int
        let cardWidth: CGFloat
        let maximumCardHeight: CGFloat
        let slotSize: CGSize
        let stepSize: CGSize
        let canvasSize: CGSize
        let viewportSize: CGSize
        let layoutDirection: UIUserInterfaceLayoutDirection
        let slotIDs: [Int64?]
        let slotLogicalFrames: [CGRect]
        let slotVisualFrames: [CGRect]
        let slotRotationAngles: [CGFloat]
        let rowVisualFrames: [CGRect]
        let rowItemIndexes: [[Int]]
        let isCompleteHeightTable: Bool
    }

    private var chromeInsets: UIEdgeInsets = .zero
    private var usesAccessibilityLayout = false
    private var measuredHeights: [Int: CGFloat] = [:]
    private var geometry: GeometrySnapshot?
    private var cachedContentSize: CGSize = .zero
    private var needsGeometryRebuild = true
    private var hasInitializedScale = false
    private var returnsItemAttributes = true
    private var requestedGeometryGeneration: UInt64 = 0
    private var appliedGeometryGeneration: UInt64?
    private var generationViewportSize: CGSize = .zero
    private var generationLayoutDirection: UIUserInterfaceLayoutDirection?
    private(set) var geometrySnapshotGeneration: UInt64 = 0
    private var cachedExportedGeometrySnapshot: DesktopGeometrySnapshot?

    override var collectionViewContentSize: CGSize { cachedContentSize }

    /// 注入浮动 chrome 避让和辅助功能布局状态；后者会移除纯装饰旋转与错位。
    func updateEnvironment(chromeInsets: UIEdgeInsets, usesAccessibilityLayout: Bool) {
        let normalizedInsets = normalizedInsets(chromeInsets)
        guard !approximatelyEqual(self.chromeInsets, normalizedInsets)
                || self.usesAccessibilityLayout != usesAccessibilityLayout else {
            return
        }
        self.chromeInsets = normalizedInsets
        self.usesAccessibilityLayout = usesAccessibilityLayout
        measuredHeights.removeAll()
        beginNewGeometryGeneration()
    }

    /// 开启新的桌面排版代次；筛选、排序、字体或视口语义变化均使旧后台结果失效。
    func beginNewGeometryGeneration() {
        requestedGeometryGeneration &+= 1
        needsGeometryRebuild = true
        invalidateLayout()
    }

    /// 切换近景逐项 Cell 与远景分块渲染；关闭后布局仍保留完整几何查询能力。
    func setItemAttributesEnabled(_ isEnabled: Bool) {
        guard returnsItemAttributes != isEnabled else { return }
        returnsItemAttributes = isEnabled
        invalidateLayout()
    }

    /// 设置真实几何缩放并返回约束后的值；文字和内容不重排，只随 Cell transform 等比缩放。
    @discardableResult
    func setScale(_ proposedScale: CGFloat) -> CGFloat {
        guard proposedScale.isFinite, proposedScale > 0 else { return scale }
        let lowerBound = min(fitScale, maximumScale)
        let nextScale = max(lowerBound, min(maximumScale, proposedScale))
        guard abs(nextScale - scale) > 0.0001 else { return scale }
        scale = nextScale
        hasInitializedScale = true
        updateContentGeometry()
        invalidateLayout()
        return scale
    }

    /// 缓存单张纸在逻辑卡宽下的自然高度，并只失效该索引的表现属性。
    @discardableResult
    func updateMeasuredHeight(_ height: CGFloat, forItemAt index: Int) -> Bool {
        updateMeasuredHeights([index: height])
    }

    /// 兼容旧控制器的估高入口；完整 generation 提交后禁止逐项高度原地重排。
    @discardableResult
    func updateMeasuredHeights(_ updates: [Int: CGFloat]) -> Bool {
        var didChange = false
        for (index, height) in updates where index >= 0 && height.isFinite && height > 0 {
            let normalized = max(
                NoteReviewOverviewMetrics.minimumCardHeight,
                min(NoteReviewOverviewMetrics.maximumDesktopCardHeight, height)
            )
            if abs((measuredHeights[index] ?? NoteReviewOverviewMetrics.estimatedCardHeight) - normalized) > 0.5 {
                didChange = true
            }
            measuredHeights[index] = normalized
        }
        guard didChange, geometry?.isCompleteHeightTable != true else { return false }
        needsGeometryRebuild = true
        invalidateLayout()
        return true
    }

    /// 清除依赖字体和卡宽的测高缓存，并使仍在后台构建的旧代次失效。
    func resetMeasuredHeights() {
        measuredHeights.removeAll(keepingCapacity: true)
        beginNewGeometryGeneration()
    }

    /// 返回当前 generation 的统一测量约束；卡宽由正式 builder 解析，调用方无需复制布局公式。
    func makeGeometryPreparationContext() -> NoteReviewDesktopGeometryPreparationContext? {
        guard let collectionView else { return nil }
        return makeGeometryPreparationContext(
            viewportSize: collectionView.bounds.size,
            layoutDirection: collectionView.effectiveUserInterfaceLayoutDirection
        )
    }

    /// 使用调用方当前视口准备桌面 generation，使尚未挂载的布局也能在源模式后台完成测量。
    func makeGeometryPreparationContext(
        viewportSize: CGSize,
        layoutDirection: UIUserInterfaceLayoutDirection
    ) -> NoteReviewDesktopGeometryPreparationContext? {
        guard viewportSize.width.isFinite,
              viewportSize.height.isFinite,
              viewportSize.width > 0,
              viewportSize.height > 0 else { return nil }
        synchronizeGeometryEnvironment(
            viewportSize: viewportSize,
            layoutDirection: layoutDirection
        )
        return NoteReviewDesktopGeometryBuilder.preparationContext(
            generation: requestedGeometryGeneration,
            viewportSize: viewportSize,
            chromeInsets: chromeInsets
        )
    }

    /// 从完整 noteID 高度表创建后台构建请求；任何占用槽缺高都会拒绝产生半成品。
    func makeCommittedGeometryBuildRequest(
        slotIDs: [Int64?],
        heightsByNoteID: [Int64: CGFloat]
    ) -> NoteReviewDesktopGeometryBuildRequest? {
        guard let preparationContext = makeGeometryPreparationContext() else { return nil }
        return makeCommittedGeometryBuildRequest(
            slotIDs: slotIDs,
            heightsByNoteID: heightsByNoteID,
            preparationContext: preparationContext
        )
    }

    /// 用产生高度表的同代测量约束创建请求；generation 或卡宽变化时拒绝陈旧结果。
    func makeCommittedGeometryBuildRequest(
        slotIDs: [Int64?],
        heightsByNoteID: [Int64: CGFloat],
        preparationContext: NoteReviewDesktopGeometryPreparationContext
    ) -> NoteReviewDesktopGeometryBuildRequest? {
        guard let collectionView,
              let request = makeCommittedGeometryBuildRequest(
                slotIDs: slotIDs,
                heightsByNoteID: heightsByNoteID,
                preparationContext: preparationContext,
                viewportSize: collectionView.bounds.size,
                layoutDirection: collectionView.effectiveUserInterfaceLayoutDirection
              ) else {
            return nil
        }
        return request
    }

    /// 使用显式视口构建完整请求；generation 不一致时拒绝旧测量，且不要求布局已挂载。
    func makeCommittedGeometryBuildRequest(
        slotIDs: [Int64?],
        heightsByNoteID: [Int64: CGFloat],
        preparationContext: NoteReviewDesktopGeometryPreparationContext,
        viewportSize: CGSize,
        layoutDirection: UIUserInterfaceLayoutDirection
    ) -> NoteReviewDesktopGeometryBuildRequest? {
        guard let currentContext = makeGeometryPreparationContext(
                viewportSize: viewportSize,
                layoutDirection: layoutDirection
              ),
              preparationContext.generation == currentContext.generation,
              abs(preparationContext.cardWidth - currentContext.cardWidth) <= 0.5,
              abs(preparationContext.maximumCardHeight - currentContext.maximumCardHeight) <= 0.5 else {
            return nil
        }
        var heights: [CGFloat] = []
        heights.reserveCapacity(slotIDs.count)
        for (index, noteID) in slotIDs.enumerated() {
            if let noteID {
                guard let height = heightsByNoteID[noteID], height.isFinite, height > 0 else { return nil }
                heights.append(height)
            } else if let geometry,
                      geometry.slotLogicalFrames.indices.contains(index) {
                heights.append(geometry.slotLogicalFrames[index].height)
            } else {
                heights.append(NoteReviewOverviewMetrics.estimatedCardHeight)
            }
        }
        return NoteReviewDesktopGeometryBuildRequest(
            generation: preparationContext.generation,
            slotIDs: slotIDs,
            itemHeights: heights,
            viewportSize: viewportSize,
            chromeInsets: chromeInsets,
            usesAccessibilityLayout: usesAccessibilityLayout,
            isRightToLeft: layoutDirection == .rightToLeft,
            isCompleteHeightTable: true
        )
    }

    /// 校验 generation 与当前环境后一次安装全部 frame；过期后台结果不会触碰已显示几何。
    @discardableResult
    func installCommittedGeometry(_ result: NoteReviewDesktopCommittedGeometry) -> Bool {
        guard let collectionView else { return false }
        return installCommittedGeometry(
            result,
            expectedItemCount: collectionView.numberOfItems(inSection: 0),
            viewportSize: collectionView.bounds.size,
            layoutDirection: collectionView.effectiveUserInterfaceLayoutDirection
        )
    }

    /// 按显式视口原子安装完整结果；未挂载时先保存可信几何，真正挂载后由 `prepare()` 补齐内容坐标。
    @discardableResult
    func installCommittedGeometry(
        _ result: NoteReviewDesktopCommittedGeometry,
        expectedItemCount: Int,
        viewportSize: CGSize,
        layoutDirection: UIUserInterfaceLayoutDirection
    ) -> Bool {
        synchronizeGeometryEnvironment(
            viewportSize: viewportSize,
            layoutDirection: layoutDirection
        )
        guard result.isCompleteHeightTable,
              result.generation == requestedGeometryGeneration,
              result.itemCount == expectedItemCount,
              result.slotIDs.indices.allSatisfy({
                  result.slotIDs[$0] == noteIDProvider?($0)
              }),
              result.viewportSize == viewportSize,
              approximatelyEqual(result.chromeInsets, chromeInsets),
              result.usesAccessibilityLayout == usesAccessibilityLayout,
              result.isRightToLeft == (layoutDirection == .rightToLeft) else { return false }
        measuredHeights = Dictionary(
            uniqueKeysWithValues: result.slotIDs.indices.compactMap { index in
                guard result.slotIDs[index] != nil else { return nil }
                return (index, result.itemHeights[index])
            }
        )
        applyGeometryResult(result)
        invalidateLayout()
        return true
    }

    /// 导出与当前已应用 Layout 完全一致的纯值快照；pending 期间只允许继续导出身份相同的旧 committed 几何。
    func makeGeometrySnapshot(slotIDs: [Int64?]) -> DesktopGeometrySnapshot? {
        guard let geometry,
              slotIDs == geometry.slotIDs,
              geometry.isCompleteHeightTable
                || (!needsGeometryRebuild && appliedGeometryGeneration == requestedGeometryGeneration) else {
            return nil
        }
        if let cachedExportedGeometrySnapshot,
           cachedExportedGeometrySnapshot.generation == geometrySnapshotGeneration,
           cachedExportedGeometrySnapshot.slotIDs == slotIDs {
            return cachedExportedGeometrySnapshot
        }
        let snapshot = DesktopGeometrySnapshot(
            generation: geometrySnapshotGeneration,
            slotIDs: slotIDs,
            itemCount: geometry.itemCount,
            columnCount: geometry.columnCount,
            rowCount: geometry.rowCount,
            cardWidth: geometry.cardWidth,
            maximumCardHeight: geometry.maximumCardHeight,
            slotSize: geometry.slotSize,
            stepSize: geometry.stepSize,
            canvasSize: geometry.canvasSize,
            usesAccessibilityLayout: usesAccessibilityLayout,
            isRightToLeft: geometry.layoutDirection == .rightToLeft,
            measuredHeights: Dictionary(
                uniqueKeysWithValues: geometry.slotIDs.indices.compactMap { index in
                    guard geometry.slotIDs[index] != nil else { return nil }
                    return (index, geometry.slotLogicalFrames[index].height)
                }
            ),
            estimatedCardHeight: NoteReviewOverviewMetrics.estimatedCardHeight,
            minimumCardHeight: NoteReviewOverviewMetrics.minimumCardHeight,
            canvasOuterMargin: NoteReviewOverviewMetrics.canvasOuterMargin,
            desktopRowPhases: NoteReviewOverviewMetrics.desktopRowPhases,
            rotationDegrees: NoteReviewOverviewMetrics.rotationDegrees,
            paperGeometriesByIndex: geometry.slotIDs.indices.map { index in
                guard let noteID = geometry.slotIDs[index] else { return nil }
                return NoteReviewDesktopPaperGeometry(
                    index: index,
                    noteID: noteID,
                    logicalFrame: geometry.slotLogicalFrames[index],
                    logicalVisualFrame: geometry.slotVisualFrames[index],
                    rotationAngle: geometry.slotRotationAngles[index]
                )
            },
            rowVisualFrames: geometry.rowVisualFrames,
            rowItemIndexes: geometry.rowItemIndexes
        )
        cachedExportedGeometrySnapshot = snapshot
        return snapshot
    }

    override func prepare() {
        super.prepare()
        guard let collectionView else {
            cachedContentSize = .zero
            return
        }
        let viewportSize = collectionView.bounds.size
        let itemCount = collectionView.numberOfItems(inSection: 0)
        let layoutDirection = collectionView.effectiveUserInterfaceLayoutDirection
        synchronizeGeometryEnvironment(
            viewportSize: viewportSize,
            layoutDirection: layoutDirection
        )
        let previousGeometry = geometry
        if previousGeometry?.itemCount != itemCount
            || previousGeometry?.viewportSize != viewportSize
            || previousGeometry?.layoutDirection != layoutDirection
            || appliedGeometryGeneration != requestedGeometryGeneration {
            needsGeometryRebuild = true
        }
        guard needsGeometryRebuild else {
            updateContentGeometry()
            return
        }
        if previousGeometry?.isCompleteHeightTable == true,
           appliedGeometryGeneration != requestedGeometryGeneration {
            updateContentGeometry()
            return
        }
        rebuildGeometry(
            itemCount: itemCount,
            viewportSize: viewportSize,
            layoutDirection: layoutDirection
        )
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard returnsItemAttributes,
              indexPath.section == 0,
              let placement = placement(forItemAt: indexPath.item) else {
            return nil
        }
        return makeAttributes(for: placement)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard returnsItemAttributes else { return [] }
        return placements(
            in: rect,
            overscan: max(rect.width, rect.height) * 0.35,
            maximumCount: NoteReviewOverviewMetrics.maximumLiveCellCount
        ).map(makeAttributes(for:))
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        guard let collectionView else { return false }
        return abs(newBounds.width - collectionView.bounds.width) > 0.5
            || abs(newBounds.height - collectionView.bounds.height) > 0.5
    }

    /// 返回指定索引的逻辑纸面、旋转视觉框和当前缩放后内容坐标。
    func placement(forItemAt index: Int) -> NoteReviewDesktopPlacement? {
        guard let geometry,
              geometry.slotLogicalFrames.indices.contains(index),
              geometry.slotVisualFrames.indices.contains(index),
              geometry.slotRotationAngles.indices.contains(index) else { return nil }
        let logicalFrame = geometry.slotLogicalFrames[index]
        let logicalVisualFrame = geometry.slotVisualFrames[index]
        let contentCenter = contentPoint(forLogicalPoint: logicalFrame.center)
        let contentVisualSize = CGSize(
            width: logicalVisualFrame.width * scale,
            height: logicalVisualFrame.height * scale
        )
        return NoteReviewDesktopPlacement(
            index: index,
            logicalFrame: logicalFrame,
            logicalVisualFrame: logicalVisualFrame,
            contentCenter: contentCenter,
            contentVisualFrame: CGRect(center: contentCenter, size: contentVisualSize),
            rotationAngle: geometry.slotRotationAngles[index],
            scale: scale
        )
    }

    /// 通过行列反算只返回与内容矩形相交的卡片，供远景分块和二维预取复用。
    func placements(
        in contentRect: CGRect,
        overscan: CGFloat = 0,
        maximumCount: Int? = nil
    ) -> [NoteReviewDesktopPlacement] {
        if let maximumCount, maximumCount <= 0 { return [] }
        guard let geometry, geometry.itemCount > 0, scale > 0 else { return [] }
        let expandedContentRect = contentRect.insetBy(dx: -max(0, overscan), dy: -max(0, overscan))
        let logicalRect = logicalRect(forContentRect: expandedContentRect)
        let candidateIndexes = candidateIndexes(
            inLogicalRect: logicalRect,
            geometry: geometry,
            maximumCount: maximumCount
        )
        let currentItemCount = collectionView?.numberOfItems(inSection: 0) ?? geometry.itemCount
        var result = candidateIndexes
            .filter { $0 < currentItemCount }
            .compactMap(placement(forItemAt:))
            .filter { $0.contentVisualFrame.intersects(expandedContentRect) }
        if let maximumCount, result.count > maximumCount {
            let target = CGPoint(x: expandedContentRect.midX, y: expandedContentRect.midY)
            result.sort { squaredDistance($0.contentCenter, target) < squaredDistance($1.contentCenter, target) }
            result.removeSubrange(maximumCount...)
        }
        return result
    }

    /// 把 Collection View 内容坐标转换为未缩放桌面坐标，供捏合前记录焦点。
    func logicalPoint(forContentPoint point: CGPoint) -> CGPoint {
        guard scale > 0 else { return .zero }
        return CGPoint(
            x: (point.x - canvasContentOrigin.x) / scale,
            y: (point.y - canvasContentOrigin.y) / scale
        )
    }

    /// 把未缩放桌面坐标投影回 Collection View 内容坐标，供缩放后补偿焦点偏移。
    func contentPoint(forLogicalPoint point: CGPoint) -> CGPoint {
        CGPoint(
            x: canvasContentOrigin.x + point.x * scale,
            y: canvasContentOrigin.y + point.y * scale
        )
    }

    /// 返回指定书摘当前缩放后的桌面中心。
    func center(forItemAt index: Int) -> CGPoint? {
        placement(forItemAt: index)?.contentCenter
    }

    /// 返回指定书摘的稳定纸张旋转，供转场快照在展开前回正。
    func rotationAngle(forItemAt index: Int) -> CGFloat {
        placement(forItemAt: index)?.rotationAngle ?? 0
    }

    /// 返回让指定书摘位于 chrome 安全视口中央的合法二维偏移。
    func contentOffset(centeredOnItemAt index: Int) -> CGPoint? {
        guard let center = center(forItemAt: index) else { return nil }
        return contentOffset(centeredOnContentPoint: center)
    }

    /// 返回让指定逻辑桌面点位于安全视口中央的合法二维偏移。
    func contentOffset(centeredOnLogicalPoint point: CGPoint) -> CGPoint {
        contentOffset(centeredOnContentPoint: contentPoint(forLogicalPoint: point))
    }

    /// 返回当前偏移对应的桌面逻辑中心，适合作为同会话视口恢复值。
    func logicalCenter(forContentOffset contentOffset: CGPoint) -> CGPoint {
        logicalPoint(
            forContentPoint: CGPoint(
                x: contentOffset.x + viewportFocusPoint.x,
                y: contentOffset.y + viewportFocusPoint.y
            )
        )
    }

    /// 返回离给定偏移的安全视口中心最近的书摘索引，查询范围固定为邻近槽位。
    func indexNearestViewportCenter(forContentOffset contentOffset: CGPoint) -> Int? {
        let contentPoint = CGPoint(
            x: contentOffset.x + viewportFocusPoint.x,
            y: contentOffset.y + viewportFocusPoint.y
        )
        return indexNearest(toContentPoint: contentPoint)
    }

    /// 返回内容矩形覆盖的可见索引；行列反算避免按书摘总数扫描。
    func visibleItemIndexes(
        in contentRect: CGRect,
        overscan: CGFloat = 0,
        maximumCount: Int? = nil
    ) -> [Int] {
        placements(in: contentRect, overscan: overscan, maximumCount: maximumCount).map(\.index)
    }

    /// 按当前速度外推未来视口，并返回距离未来中心最近的一批二维预取索引。
    func predictedItemIndexes(
        forContentOffset contentOffset: CGPoint,
        velocity: CGPoint,
        lookAhead: CGFloat = 0.28,
        overscan: CGFloat = 0,
        maximumCount: Int = 20
    ) -> [Int] {
        guard let collectionView, maximumCount > 0 else { return [] }
        let maximumTravel = CGSize(
            width: collectionView.bounds.width * 1.5,
            height: collectionView.bounds.height * 1.5
        )
        let predictedOffset = CGPoint(
            x: contentOffset.x + max(-maximumTravel.width, min(maximumTravel.width, velocity.x * lookAhead)),
            y: contentOffset.y + max(-maximumTravel.height, min(maximumTravel.height, velocity.y * lookAhead))
        )
        let predictedRect = CGRect(origin: predictedOffset, size: collectionView.bounds.size)
        return placements(in: predictedRect, overscan: overscan, maximumCount: maximumCount).map(\.index)
    }
}

private extension NoteReviewDesktopCanvasLayout {
    var viewportFocusPoint: CGPoint {
        guard let collectionView else { return .zero }
        return CGPoint(
            x: (collectionView.bounds.width + chromeInsets.left - chromeInsets.right) / 2,
            y: (collectionView.bounds.height + chromeInsets.top - chromeInsets.bottom) / 2
        )
    }

    /// 将视口与布局方向纳入 generation；横竖屏变化后，旧测量和后台几何都不能提交。
    func synchronizeGeometryEnvironment(
        viewportSize: CGSize,
        layoutDirection: UIUserInterfaceLayoutDirection
    ) {
        guard generationViewportSize != viewportSize
                || generationLayoutDirection != layoutDirection else { return }
        generationViewportSize = viewportSize
        generationLayoutDirection = layoutDirection
        requestedGeometryGeneration &+= 1
        needsGeometryRebuild = true
        cachedExportedGeometrySnapshot = nil
    }

    /// 旧控制器尚未提供完整高度表时同步构建临时行带；完整结果必须走后台 builder 与原子安装。
    func rebuildGeometry(
        itemCount: Int,
        viewportSize: CGSize,
        layoutDirection: UIUserInterfaceLayoutDirection
    ) {
        let slotIDs = (0..<itemCount).map { noteIDProvider?($0) }
        let heights = slotIDs.indices.map { index in
            measuredHeights[index]
                ?? geometry?.slotLogicalFrames[safe: index]?.height
                ?? NoteReviewOverviewMetrics.estimatedCardHeight
        }
        let request = NoteReviewDesktopGeometryBuildRequest(
            generation: requestedGeometryGeneration,
            slotIDs: slotIDs,
            itemHeights: heights,
            viewportSize: viewportSize,
            chromeInsets: chromeInsets,
            usesAccessibilityLayout: usesAccessibilityLayout,
            isRightToLeft: layoutDirection == .rightToLeft,
            isCompleteHeightTable: false
        )
        guard let result = try? NoteReviewDesktopGeometryBuilder.build(request) else { return }
        applyGeometryResult(result)
    }

    /// 将纯数据 builder 结果映射为 Layout 内部快照，并在单一主线程提交点更新缩放边界。
    func applyGeometryResult(_ result: NoteReviewDesktopCommittedGeometry) {
        geometry = GeometrySnapshot(
            itemCount: result.itemCount,
            columnCount: result.columnCount,
            rowCount: result.rowCount,
            cardWidth: result.cardWidth,
            maximumCardHeight: result.maximumCardHeight,
            slotSize: result.slotSize,
            stepSize: result.stepSize,
            canvasSize: result.canvasSize,
            viewportSize: result.viewportSize,
            layoutDirection: result.isRightToLeft ? .rightToLeft : .leftToRight,
            slotIDs: result.slotIDs,
            slotLogicalFrames: result.slotLogicalFrames,
            slotVisualFrames: result.slotVisualFrames,
            slotRotationAngles: result.slotRotationAngles,
            rowVisualFrames: result.rowVisualFrames,
            rowItemIndexes: result.rowItemIndexes,
            isCompleteHeightTable: result.isCompleteHeightTable
        )
        let availableSize = CGSize(
            width: max(1, result.viewportSize.width - chromeInsets.left - chromeInsets.right),
            height: max(1, result.viewportSize.height - chromeInsets.top - chromeInsets.bottom)
        )
        let oldFitScale = fitScale
        resolvedCardWidth = result.cardWidth
        resolvedMaximumCardHeight = result.maximumCardHeight
        logicalCanvasSize = result.canvasSize
        let rawFitScale = min(
            availableSize.width / max(1, result.canvasSize.width),
            availableSize.height / max(1, result.canvasSize.height)
        )
        fitScale = max(
            0.001,
            min(1, rawFitScale * NoteReviewOverviewMetrics.fullDesktopViewportOccupancy)
        )
        let proposedReadableScale = availableSize.width
            * NoteReviewOverviewMetrics.readableCardWidthRatio / max(1, result.cardWidth)
        let proposedMaximumScale = availableSize.width
            * NoteReviewOverviewMetrics.maximumCardWidthRatio / max(1, result.slotSize.width)
        maximumScale = max(fitScale, max(proposedReadableScale, proposedMaximumScale))
        readableScale = max(fitScale, min(maximumScale, proposedReadableScale))
        if !hasInitializedScale || abs(scale - oldFitScale) <= max(0.0001, oldFitScale * 0.01) {
            scale = fitScale
        } else {
            scale = max(fitScale, min(maximumScale, scale))
        }
        geometrySnapshotGeneration &+= 1
        appliedGeometryGeneration = result.generation
        needsGeometryRebuild = false
        cachedExportedGeometrySnapshot = nil
        updateContentGeometry()
    }

    /// 根据当前物理缩放更新画布在内容坐标中的居中原点和滚动尺寸。
    func updateContentGeometry() {
        guard let collectionView, let geometry else { return }
        let scaledCanvasSize = CGSize(
            width: geometry.canvasSize.width * scale,
            height: geometry.canvasSize.height * scale
        )
        let availableSize = CGSize(
            width: max(1, collectionView.bounds.width - chromeInsets.left - chromeInsets.right),
            height: max(1, collectionView.bounds.height - chromeInsets.top - chromeInsets.bottom)
        )
        canvasContentOrigin = CGPoint(
            x: chromeInsets.left + max(0, (availableSize.width - scaledCanvasSize.width) / 2),
            y: chromeInsets.top + max(0, (availableSize.height - scaledCanvasSize.height) / 2)
        )
        contentCanvasFrame = CGRect(origin: canvasContentOrigin, size: scaledCanvasSize)
        cachedContentSize = CGSize(
            width: max(
                collectionView.bounds.width + 1,
                scaledCanvasSize.width + chromeInsets.left + chromeInsets.right
            ),
            height: max(
                collectionView.bounds.height + 1,
                scaledCanvasSize.height + chromeInsets.top + chromeInsets.bottom
            )
        )
    }

    /// 创建使用未缩放 bounds 的 Cell 属性，使文字与纸张只接受统一几何 transform。
    func makeAttributes(for placement: NoteReviewDesktopPlacement) -> UICollectionViewLayoutAttributes {
        let attributes = UICollectionViewLayoutAttributes(
            forCellWith: IndexPath(item: placement.index, section: 0)
        )
        attributes.center = placement.contentCenter
        attributes.size = placement.logicalFrame.size
        attributes.transform = placement.contentTransform
        attributes.zIndex = 1
        return attributes
    }

    /// 将内容矩形反投影为逻辑桌面矩形，不触发任何 Cell 创建。
    func logicalRect(forContentRect rect: CGRect) -> CGRect {
        guard scale > 0 else { return .zero }
        return CGRect(
            x: (rect.minX - canvasContentOrigin.x) / scale,
            y: (rect.minY - canvasContentOrigin.y) / scale,
            width: rect.width / scale,
            height: rect.height / scale
        )
    }

    /// 先二分可见行，再按固定水平步长反算列；全景 Cell 候选也保持有界。
    func candidateIndexes(
        inLogicalRect rect: CGRect,
        geometry: GeometrySnapshot,
        maximumCount: Int?
    ) -> [Int] {
        guard geometry.itemCount > 0, geometry.rowCount > 0 else { return [] }
        let firstRow = firstRowWhoseVisualFrameEnds(after: rect.minY, geometry: geometry)
        let rowUpperBound = firstRowWhoseVisualFrameStarts(after: rect.maxY, geometry: geometry)
        guard firstRow < rowUpperBound else { return [] }
        var rows = firstRow..<rowUpperBound
        if let maximumCount {
            let visibleColumnEstimate = max(
                1,
                min(
                    geometry.columnCount,
                    Int(ceil(rect.width / max(1, geometry.stepSize.width))) + 2
                )
            )
            let rowBudget = max(
                1,
                Int(ceil(CGFloat(maximumCount * 3) / CGFloat(visibleColumnEstimate)))
            )
            if rows.count > rowBudget {
                rows = centeredRange(
                    around: nearestRow(to: rect.midY, geometry: geometry),
                    count: rowBudget,
                    within: rows
                )
            }
        }
        var result: [Int] = []
        result.reserveCapacity(maximumCount.map { $0 * 3 } ?? 32)
        for row in rows {
            let originX = rowOriginX(row: row, geometry: geometry)
            let step = max(1, geometry.stepSize.width)
            let columnRange = clampedIntegerRange(
                minimum: Int(floor((rect.minX - originX) / step)) - 1,
                maximum: Int(ceil((rect.maxX - originX) / step)) + 1,
                validUpperBound: geometry.columnCount - 1
            )
            for column in columnRange {
                let index = row * geometry.columnCount + column
                guard index < geometry.itemCount,
                      geometry.slotVisualFrames[index].intersects(rect) else { continue }
                result.append(index)
            }
        }
        result.sort()
        return result
    }

    /// 最近项只检查最近行及相邻两行的横向邻位，复杂度不随总数增长。
    func indexNearest(toContentPoint point: CGPoint) -> Int? {
        guard let geometry, geometry.itemCount > 0 else { return nil }
        let logicalPoint = logicalPoint(forContentPoint: point)
        let targetRow = nearestRow(to: logicalPoint.y, geometry: geometry)
        var indexes: [Int] = []
        let rowRange = max(0, targetRow - 1)...min(geometry.rowCount - 1, targetRow + 1)
        for row in rowRange {
            let originX = rowOriginX(row: row, geometry: geometry)
            let proposedColumn = Int(
                round(
                    (logicalPoint.x - originX - geometry.slotSize.width / 2)
                        / max(1, geometry.stepSize.width)
                )
            )
            let column = max(0, min(geometry.columnCount - 1, proposedColumn))
            let columnRange = max(0, column - 1)...min(geometry.columnCount - 1, column + 1)
            for candidateColumn in columnRange {
                let index = row * geometry.columnCount + candidateColumn
                if index < geometry.itemCount, geometry.slotIDs[index] != nil {
                    indexes.append(index)
                }
            }
        }
        return indexes.min { lhs, rhs in
            squaredDistance(geometry.slotLogicalFrames[lhs].center, logicalPoint)
                < squaredDistance(geometry.slotLogicalFrames[rhs].center, logicalPoint)
        }
    }

    func rowOriginX(row: Int, geometry: GeometrySnapshot) -> CGFloat {
        let phases = usesAccessibilityLayout
            ? [CGFloat.zero]
            : NoteReviewOverviewMetrics.desktopRowPhases
        let minimumPhase = phases.min() ?? 0
        let phase = phases.isEmpty ? 0 : phases[row % phases.count]
        return NoteReviewOverviewMetrics.canvasOuterMargin - minimumPhase + phase
    }

    func firstRowWhoseVisualFrameEnds(after minimumY: CGFloat, geometry: GeometrySnapshot) -> Int {
        var lowerBound = 0
        var upperBound = geometry.rowVisualFrames.count
        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            if geometry.rowVisualFrames[middle].maxY < minimumY {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        return lowerBound
    }

    func firstRowWhoseVisualFrameStarts(after maximumY: CGFloat, geometry: GeometrySnapshot) -> Int {
        var lowerBound = 0
        var upperBound = geometry.rowVisualFrames.count
        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            if geometry.rowVisualFrames[middle].minY <= maximumY {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        return lowerBound
    }

    func nearestRow(to targetY: CGFloat, geometry: GeometrySnapshot) -> Int {
        guard !geometry.rowVisualFrames.isEmpty else { return 0 }
        var lowerBound = 0
        var upperBound = geometry.rowVisualFrames.count
        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            if geometry.rowVisualFrames[middle].midY < targetY {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        if lowerBound == 0 { return 0 }
        if lowerBound == geometry.rowVisualFrames.count { return lowerBound - 1 }
        let previous = lowerBound - 1
        return abs(geometry.rowVisualFrames[previous].midY - targetY)
            <= abs(geometry.rowVisualFrames[lowerBound].midY - targetY)
            ? previous
            : lowerBound
    }

    /// 返回将内容点放在安全视口中心后的合法滚动偏移。
    func contentOffset(centeredOnContentPoint point: CGPoint) -> CGPoint {
        guard let collectionView else { return .zero }
        let proposed = CGPoint(
            x: point.x - viewportFocusPoint.x,
            y: point.y - viewportFocusPoint.y
        )
        let minimum = CGPoint(
            x: -collectionView.adjustedContentInset.left,
            y: -collectionView.adjustedContentInset.top
        )
        let maximum = CGPoint(
            x: max(
                minimum.x,
                cachedContentSize.width - collectionView.bounds.width
                    + collectionView.adjustedContentInset.right
            ),
            y: max(
                minimum.y,
                cachedContentSize.height - collectionView.bounds.height
                    + collectionView.adjustedContentInset.bottom
            )
        )
        return CGPoint(
            x: max(minimum.x, min(maximum.x, proposed.x)),
            y: max(minimum.y, min(maximum.y, proposed.y))
        )
    }

}

/// 纵向瀑布流布局；按固定索引分列缓存轻量 frame，高度变化只重算对应列后缀。
final class NoteReviewWaterfallLayout: UICollectionViewLayout {
    private(set) var resolvedCardWidth: CGFloat = 1
    private(set) var resolvedMaximumCardHeight = NoteReviewOverviewMetrics.maximumCardHeight
    private(set) var columnCount = 1

    private var chromeInsets: UIEdgeInsets = .zero
    private var usesAccessibilityLayout = false
    private var measuredHeights: [Int: CGFloat] = [:]
    private var cachedFrames: [CGRect] = []
    private var columnItemIndexes: [[Int]] = []
    private var dirtyColumnOrdinals: [Int: Int] = [:]
    private var cachedContentSize: CGSize = .zero
    private var cachedViewportSize: CGSize = .zero
    private var cachedItemCount = 0
    private var needsFullRebuild = true

    override var collectionViewContentSize: CGSize { cachedContentSize }

    /// 注入 chrome 避让和辅助功能状态；宽度语义改变时清除旧测高并重建分列。
    func updateEnvironment(chromeInsets: UIEdgeInsets, usesAccessibilityLayout: Bool) {
        let normalizedInsets = normalizedInsets(chromeInsets)
        guard !approximatelyEqual(self.chromeInsets, normalizedInsets)
                || self.usesAccessibilityLayout != usesAccessibilityLayout else {
            return
        }
        self.chromeInsets = normalizedInsets
        self.usesAccessibilityLayout = usesAccessibilityLayout
        measuredHeights.removeAll()
        needsFullRebuild = true
        invalidateLayout()
    }

    /// 缓存指定卡片自然高度，并把重排范围限定为该列的后缀。
    @discardableResult
    func updateMeasuredHeight(_ height: CGFloat, forItemAt index: Int) -> Bool {
        updateMeasuredHeights([index: height])
    }

    /// 批量更新测高；每列只记录最早变化的 ordinal，避免重复重算前缀。
    @discardableResult
    func updateMeasuredHeights(_ updates: [Int: CGFloat]) -> Bool {
        var didChange = false
        for (index, height) in updates where index >= 0 && height.isFinite && height > 0 {
            let oldHeight = resolvedHeight(forItemAt: index)
            measuredHeights[index] = height
            guard abs(oldHeight - resolvedHeight(forItemAt: index)) > 0.5 else { continue }
            let column = index % max(1, columnCount)
            let ordinal = index / max(1, columnCount)
            dirtyColumnOrdinals[column] = min(dirtyColumnOrdinals[column] ?? ordinal, ordinal)
            didChange = true
        }
        guard didChange else { return false }
        invalidateLayout()
        return true
    }

    /// 清除依赖卡宽和字体的高度缓存，并让所有列回到稳定估高。
    func resetMeasuredHeights() {
        guard !measuredHeights.isEmpty else { return }
        measuredHeights.removeAll(keepingCapacity: true)
        needsFullRebuild = true
        invalidateLayout()
    }

    override func prepare() {
        super.prepare()
        guard let collectionView else {
            cachedContentSize = .zero
            return
        }
        let viewportSize = collectionView.bounds.size
        let itemCount = collectionView.numberOfItems(inSection: 0)
        let nextColumnCount = resolvedColumnCount(for: viewportSize)
        let nextCardWidth = cardWidth(for: viewportSize, columnCount: nextColumnCount)
        if viewportSize != cachedViewportSize
            || itemCount != cachedItemCount
            || nextColumnCount != columnCount
            || abs(nextCardWidth - resolvedCardWidth) > 0.5 {
            if cachedViewportSize != .zero, abs(nextCardWidth - resolvedCardWidth) > 0.5 {
                measuredHeights.removeAll()
            }
            cachedViewportSize = viewportSize
            cachedItemCount = itemCount
            columnCount = nextColumnCount
            resolvedCardWidth = nextCardWidth
            needsFullRebuild = true
        }
        measuredHeights = measuredHeights.filter { $0.key < itemCount }
        if needsFullRebuild {
            rebuildAllFrames(itemCount: itemCount, viewportSize: viewportSize)
        } else if !dirtyColumnOrdinals.isEmpty {
            rebuildDirtyColumnSuffixes(viewportSize: viewportSize)
        } else {
            updateContentSize(viewportSize: viewportSize)
        }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard indexPath.section == 0, cachedFrames.indices.contains(indexPath.item) else { return nil }
        let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        attributes.frame = cachedFrames[indexPath.item]
        attributes.zIndex = 1
        return attributes
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        visibleItemIndexes(in: rect, overscan: NoteReviewOverviewMetrics.waterfallSpacing).compactMap {
            layoutAttributesForItem(at: IndexPath(item: $0, section: 0))
        }
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        guard let collectionView else { return false }
        return abs(newBounds.width - collectionView.bounds.width) > 0.5
            || abs(newBounds.height - collectionView.bounds.height) > 0.5
    }

    /// 返回指定瀑布流卡片的内容坐标 frame。
    func frame(forItemAt index: Int) -> CGRect? {
        guard cachedFrames.indices.contains(index) else { return nil }
        return cachedFrames[index]
    }

    /// 返回指定瀑布流卡片的视觉中心。
    func center(forItemAt index: Int) -> CGPoint? {
        frame(forItemAt: index)?.center
    }

    /// 返回让指定卡片位于安全视口中央的合法纵向偏移。
    func contentOffset(centeredOnItemAt index: Int) -> CGPoint? {
        guard let collectionView, let center = center(forItemAt: index) else { return nil }
        let focusY = (collectionView.bounds.height + chromeInsets.top - chromeInsets.bottom) / 2
        let minimumY = -collectionView.adjustedContentInset.top
        let maximumY = max(
            minimumY,
            cachedContentSize.height - collectionView.bounds.height
                + collectionView.adjustedContentInset.bottom
        )
        return CGPoint(
            x: -collectionView.adjustedContentInset.left,
            y: max(minimumY, min(maximumY, center.y - focusY))
        )
    }

    /// 返回距安全视口中心最近的可见卡片索引。
    func indexNearestViewportCenter(forContentOffset contentOffset: CGPoint) -> Int? {
        guard let collectionView, cachedItemCount > 0 else { return nil }
        let target = CGPoint(
            x: contentOffset.x + collectionView.bounds.width / 2,
            y: contentOffset.y
                + (collectionView.bounds.height + chromeInsets.top - chromeInsets.bottom) / 2
        )
        let queryRect = CGRect(
            x: contentOffset.x,
            y: contentOffset.y,
            width: collectionView.bounds.width,
            height: collectionView.bounds.height
        )
        let candidates = visibleItemIndexes(
            in: queryRect,
            overscan: NoteReviewOverviewMetrics.maximumCardHeight
        )
        return candidates.min {
            squaredDistance(cachedFrames[$0].center, target)
                < squaredDistance(cachedFrames[$1].center, target)
        }
    }

    /// 逐列二分定位首个相交 frame，仅返回可见范围索引。
    func visibleItemIndexes(
        in contentRect: CGRect,
        overscan: CGFloat = 0,
        maximumCount: Int? = nil
    ) -> [Int] {
        if let maximumCount, maximumCount <= 0 { return [] }
        let queryRect = contentRect.insetBy(dx: -max(0, overscan), dy: -max(0, overscan))
        var result: [Int] = []
        for items in columnItemIndexes where !items.isEmpty {
            var ordinal = firstOrdinalWhoseFrameEnds(after: queryRect.minY, in: items)
            while ordinal < items.count {
                let index = items[ordinal]
                let frame = cachedFrames[index]
                if frame.minY > queryRect.maxY { break }
                if frame.intersects(queryRect) { result.append(index) }
                ordinal += 1
            }
        }
        result.sort()
        if let maximumCount, result.count > maximumCount {
            let center = CGPoint(x: queryRect.midX, y: queryRect.midY)
            result.sort {
                squaredDistance(cachedFrames[$0].center, center)
                    < squaredDistance(cachedFrames[$1].center, center)
            }
            result.removeSubrange(maximumCount...)
        }
        return result
    }

    /// 外推未来纵向视口并返回距离未来中心最近的一批预取索引。
    func predictedItemIndexes(
        forContentOffset contentOffset: CGPoint,
        velocity: CGPoint,
        lookAhead: CGFloat = 0.28,
        overscan: CGFloat = 0,
        maximumCount: Int = 20
    ) -> [Int] {
        guard let collectionView, maximumCount > 0 else { return [] }
        let travel = max(
            -collectionView.bounds.height * 1.5,
            min(collectionView.bounds.height * 1.5, velocity.y * lookAhead)
        )
        let predictedRect = CGRect(
            x: contentOffset.x,
            y: contentOffset.y + travel,
            width: collectionView.bounds.width,
            height: collectionView.bounds.height
        )
        return visibleItemIndexes(
            in: predictedRect,
            overscan: overscan,
            maximumCount: maximumCount
        )
    }
}

private extension NoteReviewWaterfallLayout {
    /// 按视口、方向和 Dynamic Type 确定稳定列数。
    func resolvedColumnCount(for viewportSize: CGSize) -> Int {
        let availableWidth = max(1, viewportSize.width - chromeInsets.left - chromeInsets.right)
        guard !usesAccessibilityLayout, availableWidth >= 360 else { return 1 }
        if collectionView?.traitCollection.horizontalSizeClass == .regular {
            let usableWidth = max(
                1,
                availableWidth - NoteReviewOverviewMetrics.waterfallEdgeInset * 2
            )
            let proposed = Int(
                floor(
                    (usableWidth + NoteReviewOverviewMetrics.waterfallSpacing)
                        / (NoteReviewOverviewMetrics.waterfallMinimumRegularColumnWidth
                            + NoteReviewOverviewMetrics.waterfallSpacing)
                )
            )
            return max(2, min(4, proposed))
        }
        return viewportSize.width > viewportSize.height ? 3 : 2
    }

    /// 根据列数计算瀑布流卡宽，边缘和列间距均为 16pt。
    func cardWidth(for viewportSize: CGSize, columnCount: Int) -> CGFloat {
        let availableWidth = max(
            1,
            viewportSize.width
                - chromeInsets.left
                - chromeInsets.right
                - NoteReviewOverviewMetrics.waterfallEdgeInset * 2
                - CGFloat(max(0, columnCount - 1)) * NoteReviewOverviewMetrics.waterfallSpacing
        )
        return max(1, availableWidth / CGFloat(max(1, columnCount)))
    }

    /// 按固定 index modulo column 规则构建所有轻量 frame。
    func rebuildAllFrames(itemCount: Int, viewportSize: CGSize) {
        cachedFrames = Array(repeating: .zero, count: itemCount)
        columnItemIndexes = Array(repeating: [], count: columnCount)
        for index in 0..<itemCount {
            columnItemIndexes[index % columnCount].append(index)
        }
        for column in 0..<columnCount {
            rebuildColumn(column, fromOrdinal: 0)
        }
        dirtyColumnOrdinals.removeAll(keepingCapacity: true)
        needsFullRebuild = false
        updateContentSize(viewportSize: viewportSize)
    }

    /// 只重算发生高度变化的各列后缀。
    func rebuildDirtyColumnSuffixes(viewportSize: CGSize) {
        let dirtyColumns = dirtyColumnOrdinals
        dirtyColumnOrdinals.removeAll(keepingCapacity: true)
        for (column, ordinal) in dirtyColumns {
            rebuildColumn(column, fromOrdinal: ordinal)
        }
        updateContentSize(viewportSize: viewportSize)
    }

    /// 从指定 ordinal 向下重排单列，不触碰其他列和本列前缀。
    func rebuildColumn(_ column: Int, fromOrdinal requestedOrdinal: Int) {
        guard columnItemIndexes.indices.contains(column) else { return }
        let items = columnItemIndexes[column]
        guard !items.isEmpty else { return }
        let startOrdinal = max(0, min(requestedOrdinal, items.count - 1))
        let originX = chromeInsets.left
            + NoteReviewOverviewMetrics.waterfallEdgeInset
            + CGFloat(column)
                * (resolvedCardWidth + NoteReviewOverviewMetrics.waterfallSpacing)
        var nextY: CGFloat
        if startOrdinal == 0 {
            nextY = chromeInsets.top + NoteReviewOverviewMetrics.waterfallEdgeInset
        } else {
            nextY = cachedFrames[items[startOrdinal - 1]].maxY
                + NoteReviewOverviewMetrics.waterfallSpacing
        }
        for ordinal in startOrdinal..<items.count {
            let index = items[ordinal]
            let height = resolvedHeight(forItemAt: index)
            cachedFrames[index] = CGRect(
                x: originX,
                y: nextY,
                width: resolvedCardWidth,
                height: height
            )
            nextY += height + NoteReviewOverviewMetrics.waterfallSpacing
        }
    }

    /// 以各列末项的最大 Y 计算纵向滚动尺寸。
    func updateContentSize(viewportSize: CGSize) {
        let maximumY = columnItemIndexes.compactMap { items in
            items.last.map { cachedFrames[$0].maxY }
        }.max() ?? 0
        cachedContentSize = CGSize(
            width: max(1, viewportSize.width),
            height: max(
                viewportSize.height + 1,
                maximumY + chromeInsets.bottom + NoteReviewOverviewMetrics.waterfallEdgeInset
            )
        )
    }

    /// 返回约束后的自然卡高；未加载正文使用稳定 280pt 估高。
    func resolvedHeight(forItemAt index: Int) -> CGFloat {
        let height = measuredHeights[index] ?? NoteReviewOverviewMetrics.estimatedCardHeight
        return max(
            NoteReviewOverviewMetrics.minimumCardHeight,
            min(NoteReviewOverviewMetrics.maximumCardHeight, height)
        )
    }

    /// 在单列有序 frame 中二分定位第一个底边进入查询范围的 ordinal。
    func firstOrdinalWhoseFrameEnds(after minimumY: CGFloat, in items: [Int]) -> Int {
        var lowerBound = 0
        var upperBound = items.count
        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            if cachedFrames[items[middle]].maxY < minimumY {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        return lowerBound
    }
}

/// 将边距归一为非负值，避免外部 chrome 状态产生反向内容区。
private func normalizedInsets(_ insets: UIEdgeInsets) -> UIEdgeInsets {
    UIEdgeInsets(
        top: max(0, insets.top),
        left: max(0, insets.left),
        bottom: max(0, insets.bottom),
        right: max(0, insets.right)
    )
}

/// 以半点容差比较两组边距，屏蔽布局浮点噪声。
private func approximatelyEqual(_ lhs: UIEdgeInsets, _ rhs: UIEdgeInsets) -> Bool {
    abs(lhs.top - rhs.top) <= 0.5
        && abs(lhs.left - rhs.left) <= 0.5
        && abs(lhs.bottom - rhs.bottom) <= 0.5
        && abs(lhs.right - rhs.right) <= 0.5
}

/// 生成指定上限内的闭区间；完全落在有效范围外时返回空区间。
private func clampedIntegerRange(
    minimum: Int,
    maximum: Int,
    validUpperBound: Int
) -> Range<Int> {
    guard validUpperBound >= 0, maximum >= 0, minimum <= validUpperBound else { return 0..<0 }
    let lowerBound = max(0, minimum)
    let upperBound = min(validUpperBound, maximum)
    guard lowerBound <= upperBound else { return 0..<0 }
    return lowerBound..<(upperBound + 1)
}

/// 围绕目标值裁剪已有半开区间，并尽量保持请求数量。
private func centeredRange(
    around center: Int,
    count: Int,
    within range: Range<Int>
) -> Range<Int> {
    guard !range.isEmpty, count > 0, count < range.count else { return range }
    var lower = max(range.lowerBound, center - count / 2)
    var upper = lower + count
    if upper > range.upperBound {
        upper = range.upperBound
        lower = max(range.lowerBound, upper - count)
    }
    return lower..<upper
}

/// 返回两个点的平方距离，避免热路径中不必要的平方根。
private func squaredDistance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
    let dx = lhs.x - rhs.x
    let dy = lhs.y - rhs.y
    return dx * dx + dy * dy
}

/// 返回旋转后轴对齐视觉外框的尺寸。
private func rotatedBoundingSize(_ size: CGSize, angle: CGFloat) -> CGSize {
    let cosine = abs(cos(angle))
    let sine = abs(sin(angle))
    return CGSize(
        width: size.width * cosine + size.height * sine,
        height: size.width * sine + size.height * cosine
    )
}

/// 返回旋转后围绕原中心的轴对齐视觉外框。
private func rotatedBoundingFrame(for frame: CGRect, angle: CGFloat) -> CGRect {
    CGRect(center: frame.center, size: rotatedBoundingSize(frame.size, angle: angle))
}

/// 使用稳定 64 位混合生成只依赖 note ID 的布局种子。
nonisolated private func deterministicSeed(noteID: Int64) -> UInt64 {
    var value = UInt64(bitPattern: noteID) &* 0x9E3779B97F4A7C15
    value ^= value >> 30
    value &*= 0xBF58476D1CE4E5B9
    value ^= value >> 27
    value &*= 0x94D049BB133111EB
    value ^= value >> 31
    return value
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }

    /// 以中心和尺寸构建矩形，统一桌面与瀑布流的坐标表达。
    init(center: CGPoint, size: CGSize) {
        self.init(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}

private extension Array {
    /// 安全读取构建前一代的槽位数据，避免清单长度变化时访问越界。
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
