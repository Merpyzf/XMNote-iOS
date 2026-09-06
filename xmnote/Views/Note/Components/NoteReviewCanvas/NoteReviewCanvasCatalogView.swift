/**
 * [INPUT]: 接收最多二十四个真实目录集合、当前位置及既有纸面外观
 * [OUTPUT]: 绘制无需读取正文的有序叠纸集合，提供命中与虚拟无障碍元素
 * [POS]: 单画布的远景表示；只改变信息层级，不生成虚构正文或永久卡片视图
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import UIKit

/// 集合层只在主 actor 配置／绘制有界标签；原生滚动缩放不触发排版或读取。
final class NoteReviewCanvasCatalogView: UIView {
    private struct Paper {
        let group: NoteReviewDirectoryGroup
        let frame: CGRect
        let count: NSAttributedString
        let range: NSAttributedString
        let marker: NSAttributedString?
    }
    private var papers: [Paper] = []
    private var style: CanvasOverviewPaperStyle?
    var onActivate: ((NoteReviewDirectoryGroup) -> Void)?
    private(set) var preferredSize = CGSize.zero
    private(set) var fitScale: CGFloat = 1

    /// 文字用真实数量与全局范围；屏幕密度决定集合数，不伪造内容摘要。
    func configure(_ catalog: NoteReviewCanvasDirectoryCatalog, style: CanvasOverviewPaperStyle, viewport: CGSize) {
        self.style = style
        isOpaque = true
        layer.backgroundColor = style.canvasBaseColor
        isAccessibilityElement = false
        let count = max(1, catalog.groups.count)
        let columns = min(count, max(1, Int(viewport.width / 160)))
        let rows = Int(ceil(CGFloat(count) / CGFloat(columns)))
        let width: CGFloat = 220
        let height: CGFloat = 172
        let gap: CGFloat = 24
        preferredSize = CGSize(width: CGFloat(columns) * (width + gap) + 72,
            height: CGFloat(rows) * (height + gap) + 72)
        fitScale = min(viewport.width / preferredSize.width, viewport.height / preferredSize.height) * 0.86
        let alignment = NSMutableParagraphStyle()
        alignment.alignment = .center
        let labels: [NSAttributedString.Key: Any] = [.font: style.bodyFont.withSize(18 / fitScale),
            .foregroundColor: style.primaryTextColor, .paragraphStyle: alignment]
        let metadata: [NSAttributedString.Key: Any] = [.font: style.metadataFont.withSize(11 / fitScale),
            .foregroundColor: style.secondaryTextColor, .paragraphStyle: alignment]
        let current = Set(catalog.currentPath.map(\.id))
        papers = catalog.groups.enumerated().map { index, group in
            let column = style.traits.layoutDirection == .rightToLeft ? columns - 1 - index % columns : index % columns
            return Paper(group: group, frame: CGRect(x: 48 + CGFloat(column) * (width + gap),
                y: 48 + CGFloat(index / columns) * (height + gap), width: width, height: height),
                count: .init(string: "\(group.count.formatted()) 条", attributes: labels),
                range: .init(string: "\(group.firstOrdinal + 1)–\(group.lastOrdinal + 1)", attributes: metadata),
                marker: current.contains(group.id) ? .init(string: "当前所在", attributes: metadata) : nil)
        }
        accessibilityElements = papers.map { paper in
            let element = CanvasOverviewAccessibilityElement(accessibilityContainer: self)
            element.accessibilityIdentifier = "review-group-\(paper.group.id.level)-\(paper.group.id.bucket)"
            element.accessibilityLabel = "\(paper.group.count) 条书摘，第 \(paper.group.firstOrdinal + 1) 到 \(paper.group.lastOrdinal + 1) 条"
                + (paper.marker == nil ? "" : "，当前所在")
            element.accessibilityHint = "放大查看这个集合"
            element.accessibilityTraits = .button
            element.accessibilityFrameInContainerSpace = paper.frame
            element.activate = { [weak self] in self?.onActivate?(paper.group); return self != nil }
            return element
        }
        setNeedsDisplay()
    }

    /// 命中只接受纸面，空白与阴影不触发集合导航。
    func group(at point: CGPoint) -> NoteReviewDirectoryGroup? { papers.first { $0.frame.contains(point) }?.group }

    /// 缩放焦点落在留白时选择最近集合，仅查询最多二十四个已显示元素。
    func nearestGroup(to point: CGPoint) -> NoteReviewDirectoryGroup? {
        papers.min {
            hypot($0.frame.midX - point.x, $0.frame.midY - point.y) < hypot($1.frame.midX - point.x, $1.frame.midY - point.y)
        }?.group
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), let style else { return }
        CanvasOverviewCanvasRasterizer.fillCanvas(rect, style: style, in: context)
        for paper in papers where paper.frame.insetBy(dx: -24, dy: -24).intersects(rect) {
            for depth in stride(from: 2, through: 0, by: -1) {
                let frame = paper.frame.offsetBy(dx: CGFloat(depth) * 3, dy: CGFloat(depth) * 5)
                let path = CGPath(roundedRect: frame, cornerWidth: style.cornerRadius, cornerHeight: style.cornerRadius, transform: nil)
                context.saveGState()
                if depth == 0 { context.setShadow(offset: CGSize(width: 0, height: 4), blur: 12, color: UIColor.black.withAlphaComponent(0.11).cgColor) }
                context.addPath(path); context.setFillColor(style.paperColor); context.fillPath()
                context.setShadow(offset: .zero, blur: 0, color: nil)
                context.addPath(path); context.setStrokeColor(style.borderColor); context.setLineWidth(StrokeWidth.hairline); context.strokePath()
                context.restoreGState()
            }
            let inset: CGFloat = 18
            paper.count.draw(in: CGRect(x: paper.frame.minX + inset, y: paper.frame.midY - 36 / fitScale,
                width: paper.frame.width - inset * 2, height: 26 / fitScale))
            paper.range.draw(in: CGRect(x: paper.frame.minX + inset, y: paper.frame.midY - 4 / fitScale,
                width: paper.frame.width - inset * 2, height: 18 / fitScale))
            paper.marker?.draw(in: CGRect(x: paper.frame.minX + inset, y: paper.frame.midY + 18 / fitScale,
                width: paper.frame.width - inset * 2, height: 18 / fitScale))
        }
    }
}
