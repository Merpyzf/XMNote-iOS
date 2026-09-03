/**
 * [INPUT]: 依赖 UICollectionViewLayout 可见区域查询、稳定书摘 ID 与当前视口尺寸
 * [OUTPUT]: 对外提供 ImmersiveReviewFlowLayout 与 FlatReviewCanvasLayout 两种可替换虚拟化布局
 * [POS]: Views/Note/Components 的全屏回顾布局层，保证沉浸纵向分页与双向画布都不生成全量布局属性
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

/// 横纵双向漫游画布；任意索引属性均可直接计算，可见查询只枚举当前矩形覆盖的候选行列。
final class FlatReviewCanvasLayout: UICollectionViewLayout {
    private enum Metrics {
        static let baseCardSize = CGSize(width: 176, height: 228)
        static let minimumScale: CGFloat = 0.58
        static let maximumScale: CGFloat = 1.35
        static let horizontalStepFactor: CGFloat = 0.91
        static let verticalStepFactor: CGFloat = 0.86
        static let canvasWidthFactor: CGFloat = 2.5
        static let contentInset: CGFloat = 28
    }

    var noteIDProvider: ((Int) -> Int64?)?
    private(set) var scale: CGFloat = 1
    private var cachedContentSize: CGSize = .zero
    private var cachedColumnCount = 1
    private var cachedViewportSize: CGSize = .zero

    var cardSize: CGSize {
        CGSize(
            width: max(44, Metrics.baseCardSize.width * scale),
            height: max(58, Metrics.baseCardSize.height * scale)
        )
    }

    private var horizontalStep: CGFloat { cardSize.width * Metrics.horizontalStepFactor }
    private var verticalStep: CGFloat { cardSize.height * Metrics.verticalStepFactor }

    override var collectionViewContentSize: CGSize { cachedContentSize }

    /// 更新画布语义缩放；实际重新计算卡片尺寸和内容偏移，不对集合视图做视觉 transform。
    func setScale(_ proposedScale: CGFloat) {
        let next = max(Metrics.minimumScale, min(Metrics.maximumScale, proposedScale))
        guard abs(next - scale) > 0.001 else { return }
        scale = next
        invalidateLayout()
    }

    override func prepare() {
        super.prepare()
        guard let collectionView else {
            cachedContentSize = .zero
            return
        }
        let viewport = collectionView.bounds.size
        let canvasWidth = max(viewport.width + 1, viewport.width * Metrics.canvasWidthFactor)
        if abs(viewport.width - cachedViewportSize.width) > 0.5 || cachedViewportSize == .zero {
            let baseStep = Metrics.baseCardSize.width * Metrics.horizontalStepFactor
            cachedColumnCount = max(
                1,
                Int(
                    floor(
                        (canvasWidth - Metrics.contentInset * 2 - Metrics.baseCardSize.width) / baseStep
                    )
                ) + 1
            )
            cachedViewportSize = viewport
        }
        let count = collectionView.numberOfItems(inSection: 0)
        let rowCount = max(1, Int(ceil(Double(count) / Double(cachedColumnCount))))
        let gridWidth = Metrics.contentInset * 2
            + cardSize.width
            + CGFloat(cachedColumnCount - 1) * horizontalStep
        cachedContentSize = CGSize(
            width: max(canvasWidth, gridWidth),
            height: max(
                viewport.height + 1,
                Metrics.contentInset * 2 + cardSize.height + CGFloat(rowCount - 1) * verticalStep
            )
        )
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard indexPath.section == 0,
              let collectionView,
              indexPath.item < collectionView.numberOfItems(inSection: 0) else {
            return nil
        }
        let row = indexPath.item / cachedColumnCount
        let logicalColumn = indexPath.item % cachedColumnCount
        let column = visualColumn(forLogicalColumn: logicalColumn)
        let noteID = noteIDProvider?(indexPath.item) ?? Int64(indexPath.item)
        let jitter = deterministicJitter(noteID: noteID)
        let origin = CGPoint(
            x: Metrics.contentInset + CGFloat(column) * horizontalStep + jitter.x * scale,
            y: Metrics.contentInset + CGFloat(row) * verticalStep + jitter.y * scale
        )
        let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        attributes.frame = CGRect(origin: origin, size: cardSize)
        attributes.zIndex = Int(abs(noteID % 17))
        return attributes
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard let collectionView else { return [] }
        let count = collectionView.numberOfItems(inSection: 0)
        guard count > 0 else { return [] }

        let expandedRect = rect.insetBy(dx: -cardSize.width * 0.18, dy: -cardSize.height * 0.18)
        let minimumRow = max(0, Int(floor((expandedRect.minY - Metrics.contentInset) / verticalStep)) - 1)
        let maximumRow = max(minimumRow, Int(ceil((expandedRect.maxY - Metrics.contentInset) / verticalStep)) + 1)
        let minimumColumn = max(0, Int(floor((expandedRect.minX - Metrics.contentInset) / horizontalStep)) - 1)
        let maximumColumn = min(
            cachedColumnCount - 1,
            max(minimumColumn, Int(ceil((expandedRect.maxX - Metrics.contentInset) / horizontalStep)) + 1)
        )
        guard minimumColumn <= maximumColumn else { return [] }

        var result: [UICollectionViewLayoutAttributes] = []
        result.reserveCapacity(max(0, maximumRow - minimumRow + 1) * max(0, maximumColumn - minimumColumn + 1))
        for row in minimumRow...maximumRow {
            for column in minimumColumn...maximumColumn {
                let logicalColumn = logicalColumn(forVisualColumn: column)
                let item = row * cachedColumnCount + logicalColumn
                guard item < count,
                      let attributes = layoutAttributesForItem(at: IndexPath(item: item, section: 0)),
                      attributes.frame.intersects(expandedRect) else {
                    continue
                }
                result.append(attributes)
            }
        }
        return result
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        guard let collectionView else { return false }
        return abs(newBounds.width - collectionView.bounds.width) > 0.5
            || abs(newBounds.height - collectionView.bounds.height) > 0.5
    }

    /// 返回指定书摘的画布视觉中心，供模式切换和旋转后恢复上下文。
    func center(forItemAt index: Int) -> CGPoint? {
        layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.center
    }

}

private extension FlatReviewCanvasLayout {
    func visualColumn(forLogicalColumn column: Int) -> Int {
        guard collectionView?.effectiveUserInterfaceLayoutDirection == .rightToLeft else { return column }
        return cachedColumnCount - 1 - column
    }

    func logicalColumn(forVisualColumn column: Int) -> Int {
        guard collectionView?.effectiveUserInterfaceLayoutDirection == .rightToLeft else { return column }
        return cachedColumnCount - 1 - column
    }

    func deterministicJitter(noteID: Int64) -> CGPoint {
        var value = UInt64(bitPattern: noteID) &* 0x9E3779B97F4A7C15
        value ^= value >> 29
        let horizontal = CGFloat(Int(value & 0x0F) - 7) * 0.78
        let vertical = CGFloat(Int((value >> 8) & 0x0F) - 7) * 0.58
        return CGPoint(x: horizontal, y: vertical)
    }
}
