/**
 * [INPUT]: 接收有界真实纸张预览及激活/取消回调
 * [OUTPUT]: 提供两列纵向纸堆网格、滚动期稳定坐标与速度预取需求、RTL 与有序辅助功能；不提交业务当前项
 * [POS]: NoteReviewCanvas 页面私有覆盖表面，卡片内容与空间交互解耦
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import UIKit

/// 堆叠仅决定相对位置，纸面高度由内容层提供；背纸前两行始终可见。
nonisolated enum CanvasStackLayout {
    /// 以真实卡高生成露出正文起点的纸堆端点，静态展示与运动代理复用同一结果。
    static func poses(sizes: [CGSize], center: CGPoint, cardWidth: CGFloat, reduced: Bool) -> [CanvasOverviewPaperPose] {
        sizes.enumerated().map { index, size in
            let scale = cardWidth / max(1, size.width)
            let depth = CGFloat(index)
            return .init(center: CGPoint(x: center.x + depth * (reduced ? 0 : 5),
                y: center.y - depth * 54 + (size.height - (sizes.first?.height ?? size.height)) * scale / 2),
                size: CGSize(width: cardWidth, height: size.height * scale),
                rotation: reduced || index == 0 ? 0 : (index.isMultiple(of: 2) ? 0.018 : -0.018))
        }
    }
}

/// 页面内的网格锚点只保存稳定身份与相对可见位置，不改写阅读进度。
struct CanvasStackGridViewport {
    let id: NoteReviewCanvasStackID
    let relativeY: CGFloat
}

/// 重新打开目录只保留轻量组身份，纸面按当前尺寸和外观重新准备。
struct CanvasStackGridBookmark {
    let rows: [[NoteReviewCanvasStackGroup]]
    let viewport: CanvasStackGridViewport
    let visibleIDs: Set<NoteReviewCanvasStackID>
}

/// 两列真实纸堆随原生纵向滚动浏览；整行更新保持可见身份与列位置。
@MainActor
final class CanvasStackBrowserView: UIView, UIScrollViewDelegate {
    let scrollView = CanvasStackScrollView()
    let material = UIVisualEffectView(effect: nil)
    let backdrop = UIImageView()
    private(set) var rows: [[CanvasStackPreview]] = []
    var previews: [CanvasStackPreview] { rows.flatMap { $0 } }
    private var piles: [NoteReviewCanvasStackID: CanvasStackPileView] = [:]
    private var rowFrames: [CGRect] = []
    private var applying = false
    private var lastFocusedID: NoteReviewCanvasStackID?
    private var focusCompletion: (() -> Void)?
    private var chromeVisible = true
    private var lastLayoutSize: CGSize = .zero
    private var lastOffsetY: CGFloat = 0
    private var layoutOriginY: CGFloat = 0
    private var lastScrollTime: CFTimeInterval = 0
    private var scrollSpeed: CGFloat = 0
    private var pendingViewport: CanvasStackGridViewport?
    private(set) var preferredDirection = 1
    var onFocus: ((NoteReviewCanvasStackID) -> Void)?
    var onActivate: ((NoteReviewCanvasStackID) -> Void)?
    var onReturn: (() -> Void)?
    var onStable: (() -> Void)?
    var onInteraction: (() -> Void)?
    var onDemand: (() -> Void)?
    var contentInsets: UIEdgeInsets = .zero
    let reduced: Bool

    /// 预留背纸错位和旋转的横向范围，真实纸张在各列内继续按原比例展示。
    static func paperWidth(in width: CGFloat) -> CGFloat {
        max(1, min(320, (width - Spacing.screenEdge * 2 - Spacing.double) / 2 - 24))
    }

    var cardWidth: CGFloat { Self.paperWidth(in: bounds.width) }
    var isMoving: Bool { scrollView.isDragging || scrollView.isDecelerating || focusCompletion != nil }
    var isPositioning: Bool { focusCompletion != nil }
    private var visibleRect: CGRect {
        CGRect(x: 0, y: scrollView.contentOffset.y + contentInsets.top,
               width: bounds.width, height: max(1, bounds.height - contentInsets.top - contentInsets.bottom))
    }
    var visibleIDs: Set<NoteReviewCanvasStackID> {
        Set(rows.enumerated().filter { rowFrames.indices.contains($0.offset) && rowFrames[$0.offset].intersects(visibleRect) }
            .flatMap { $0.element.map { $0.group.id } })
    }
    var focusedID: NoteReviewCanvasStackID? {
        rows.enumerated().first { rowFrames.indices.contains($0.offset) && rowFrames[$0.offset].intersects(visibleRect) }?
            .element.first?.group.id ?? previews.first?.group.id
    }
    var viewport: CanvasStackGridViewport? {
        guard let id = focusedID, let frame = frame(for: id) else { return nil }
        return .init(id: id, relativeY: frame.minY - visibleRect.minY)
    }

    /// 覆盖层沿用已有背景和玻璃交接，只有纸堆内容改为纵向网格。
    init(frame: CGRect, reduced: Bool) {
        self.reduced = reduced
        super.init(frame: frame)
        backgroundColor = NoteReviewCanvasAppearance.backgroundColor
        clipsToBounds = true
        backdrop.frame = bounds; backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(backdrop)
        material.frame = bounds; material.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(material)
        scrollView.frame = bounds; scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.delegate = self
        scrollView.alwaysBounceVertical = true
        scrollView.isPagingEnabled = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.scrollsToTop = false
        addSubview(scrollView)
    }

    /// 该表面依赖就绪端点，只通过代码创建。
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 旋转或容器变化时以同一纸堆的可见位置重建行高。
    override func layoutSubviews() {
        super.layoutSubviews()
        guard lastLayoutSize != bounds.size else { return }
        let anchor = pendingViewport ?? viewport
        applying = true
        layoutOriginY = 0
        layoutPiles()
        if let anchor { restore(anchor) }
        applying = false
        lastLayoutSize = bounds.size
    }

    /// 滚动中立即接入整行；复用幸存行的内容坐标，追加与回收不重设滚动偏移或惯性。
    func apply(_ values: [[CanvasStackPreview]], preserving anchor: CanvasStackGridViewport? = nil) {
        let saved = anchor ?? pendingViewport ?? viewport
        let survivingID = rows.first { row in values.contains { $0.first?.group.id == row.first?.group.id } }?.first?.group.id
        let oldY = survivingID.flatMap { frame(for: $0)?.minY }
        let oldOffset = scrollView.contentOffset
        let preservesCoordinates = anchor == nil && pendingViewport == nil && oldY != nil && lastLayoutSize == bounds.size
        applying = true
        let ids = Set(values.flatMap { $0.map { $0.group.id } })
        for key in Array(piles.keys) where !ids.contains(key) {
            piles.removeValue(forKey: key)?.removeFromSuperview()
        }
        rows = values.filter { !$0.isEmpty }
        for preview in previews where piles[preview.group.id] == nil {
            let pile = CanvasStackPileView(preview: preview, reduced: reduced)
            pile.onActivate = { [weak self] in
                guard let self, !isMoving else { return }
                onActivate?(preview.group.id)
            }
            pile.countLabel.alpha = chromeVisible ? 1 : 0
            scrollView.addSubview(pile)
            piles[preview.group.id] = pile
        }
        layoutOriginY = 0
        layoutPiles(updatesContentSize: false)
        var offsetAdjustment: CGFloat = 0
        if preservesCoordinates, let survivingID, let oldY, let newY = frame(for: survivingID)?.minY {
            layoutOriginY = oldY - newY
            if layoutOriginY < 0 {
                offsetAdjustment = -layoutOriginY
                layoutOriginY = 0
            }
        }
        layoutPiles()
        scrollView.accessibilityElements = previews.compactMap { piles[$0.group.id] }
        if preservesCoordinates {
            if offsetAdjustment > 0.5 {
                scrollView.contentOffset = CGPoint(x: oldOffset.x, y: oldOffset.y + offsetAdjustment)
            }
        } else if let saved { restore(saved) }
        applying = false
        lastFocusedID = focusedID
        lastOffsetY = scrollView.contentOffset.y
        lastLayoutSize = bounds.size
    }

    /// 同行取真实叠纸与数量的较大高度；纸堆本身不拉伸、不截断。
    private func layoutPiles(updatesContentSize: Bool = true) {
        let cellWidth = cardWidth + 24
        let gridWidth = cellWidth * 2 + Spacing.double
        let left = (bounds.width - gridWidth) / 2
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        var y = layoutOriginY + contentInsets.top + Spacing.double
        rowFrames = []
        for row in rows {
            let heights = row.map { piles[$0.group.id]?.gridHeight(width: cardWidth) ?? 0 }
            let height = heights.max() ?? 0
            rowFrames.append(CGRect(x: left, y: y, width: gridWidth, height: height))
            for (column, preview) in row.enumerated() {
                guard let pile = piles[preview.group.id] else { continue }
                let physicalColumn = rtl ? 1 - column : column
                pile.frame = CGRect(x: left + CGFloat(physicalColumn) * (cellWidth + Spacing.double),
                    y: y, width: cellWidth, height: heights[column])
                pile.arrangeTopAligned(width: cardWidth)
            }
            y += height + Spacing.double
        }
        let bottom = rows.isEmpty ? y : y - Spacing.double
        if updatesContentSize {
            scrollView.contentSize = CGSize(width: bounds.width,
                height: max(bounds.height, bottom + Spacing.double + contentInsets.bottom))
        }
    }

    /// 常态提前三屏，快速滑动按实际速度提前最多五屏；反向始终保留一屏半缓冲。
    func demandDirection(reachedStart: Bool, reachedEnd: Bool) -> Int? {
        guard let first = rowFrames.first, let last = rowFrames.last else { return nil }
        let forward = max(visibleRect.height * 3, min(visibleRect.height * 5, scrollSpeed * 1.5))
        let backward = visibleRect.height * 1.5
        let needsPrevious = !reachedStart && first.minY > visibleRect.minY - (preferredDirection < 0 ? forward : backward)
        let needsNext = !reachedEnd && last.maxY < visibleRect.maxY + (preferredDirection > 0 ? forward : backward)
        if preferredDirection > 0, needsNext { return 1 }
        if needsPrevious { return -1 }
        return needsNext ? 1 : nil
    }

    /// 回收仅限远离可见区域的完整边缘行，保留同方向预取空间。
    func canEvictRow(at index: Int) -> Bool {
        guard rowFrames.indices.contains(index) else { return false }
        let rect = rowFrames[index]
        return !rect.intersects(visibleRect.insetBy(dx: 0, dy: -visibleRect.height))
    }

    /// 纸堆位置用实际视图坐标导出，供现有独立纸张动画使用。
    func poses(for id: NoteReviewCanvasStackID, in container: UIView) -> [Int64: CanvasOverviewPaperPose] {
        piles[id]?.poses(in: container) ?? [:]
    }

    /// 代理持有显示权期间只隐藏对应纸堆。
    func setPileHidden(_ id: NoteReviewCanvasStackID, hidden: Bool) { piles[id]?.alpha = hidden ? 0 : 1 }

    /// 还原锚点时补偿纵向原点，避免前插预览导致跳位。
    func restore(_ viewport: CanvasStackGridViewport) {
        guard let rect = frame(for: viewport.id) else { return }
        let target = max(0, rect.minY - contentInsets.top - viewport.relativeY)
        if target > clampedOffset(target) + 0.5 {
            // A taller viewport may need the next row before its old anchor can fit naturally.
            pendingViewport = viewport
            scrollView.contentSize.height = target + scrollView.bounds.height
        } else { pendingViewport = nil }
        scrollView.setContentOffset(CGPoint(x: 0, y: target), animated: false)
    }

    /// 确认真实目录末端后移除准备期间的临时空间，短目录仍以自然底部收尾。
    func settleRestorationAtEnd() {
        guard pendingViewport != nil, !isMoving else { return }
        pendingViewport = nil
        applying = true
        layoutPiles()
        scrollView.setContentOffset(CGPoint(x: 0, y: clampedOffset(scrollView.contentOffset.y)), animated: false)
        applying = false
    }

    /// 仅返回原桌面或辅助功能定位时滚动；普通点按从原位展开。
    func focus(_ id: NoteReviewCanvasStackID, completion: @escaping () -> Void) {
        guard let rect = frame(for: id) else { return }
        let target = CGPoint(x: 0, y: clampedOffset(rect.minY - contentInsets.top - Spacing.double))
        if visibleIDs.contains(id) || reduced || abs(target.y - scrollView.contentOffset.y) < 1 {
            if !visibleIDs.contains(id) { scrollView.setContentOffset(target, animated: false) }
            completion()
        } else {
            focusCompletion = completion
            scrollView.setContentOffset(target, animated: true)
        }
    }

    /// 数量控件和纸面共用既有转场时间轴。
    func setChromeVisible(_ visible: Bool) {
        chromeVisible = visible
        piles.values.forEach { $0.countLabel.alpha = visible ? 1 : 0 }
    }

    /// 新拖动取消待展开请求，正文预览仍可继续准备。
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        focusCompletion = nil
        pendingViewport = nil
        scrollSpeed = 0
        lastScrollTime = CACurrentMediaTime()
        onInteraction?()
        onDemand?()
    }

    /// 滚动只更新预览需求，不提交阅读身份或吸附位置。
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !applying else { return }
        let delta = scrollView.contentOffset.y - lastOffsetY
        let now = CACurrentMediaTime()
        let elapsed = now - lastScrollTime
        if elapsed > 0.001, elapsed < 0.25 {
            scrollSpeed = scrollSpeed * 0.7 + abs(delta) / elapsed * 0.3
        }
        lastScrollTime = now
        if abs(delta) > 1 { preferredDirection = delta > 0 ? 1 : -1 }
        lastOffsetY = scrollView.contentOffset.y
        if let id = focusedID, id != lastFocusedID {
            lastFocusedID = id
            onFocus?(id)
        }
        onDemand?()
    }

    /// 惯性结束只校准预取需求，内容接入无需等待此事件。
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { scrollSpeed = 0; onStable?() }

    /// 无惯性的短拖动也会触发边缘补齐与失败重试。
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { onStable?() }
    }

    /// 程序定位结束后执行原桌面恢复，不能在滚动中替换动画端点。
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        let completion = focusCompletion
        focusCompletion = nil
        lastFocusedID = focusedID
        completion?()
        if completion == nil { onStable?() }
    }

    /// 辅助功能沿纵向翻阅可见区域，网格朗读顺序保持逐行。
    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        guard direction == .up || direction == .down else { return false }
        let target = clampedOffset(scrollView.contentOffset.y + (direction == .up ? -1 : 1) * visibleRect.height * 0.8)
        guard abs(target - scrollView.contentOffset.y) > 1 else { onStable?(); return false }
        scrollView.setContentOffset(CGPoint(x: 0, y: target), animated: false)
        onStable?()
        UIAccessibility.post(notification: .pageScrolled, argument: nil)
        return true
    }

    /// 辅助功能退出沿用返回原桌面的恢复路径。
    override func accessibilityPerformEscape() -> Bool { onReturn?(); return true }

    /// 行内两个纸堆共用纵向定位边界。
    private func frame(for id: NoteReviewCanvasStackID) -> CGRect? {
        guard let index = rows.firstIndex(where: { $0.contains { $0.group.id == id } }),
              rowFrames.indices.contains(index) else { return nil }
        return rowFrames[index]
    }

    /// 内容较少时不制造额外可滚动的空白页。
    private func clampedOffset(_ y: CGFloat) -> CGFloat {
        min(max(0, y), max(0, scrollView.contentSize.height - scrollView.bounds.height))
    }
}

/// 纸堆是 UIControl；触摸交给纸堆后继续移动，仍须允许原生滚动取消点击。
@MainActor
final class CanvasStackScrollView: UIScrollView {
    /// 覆盖 UIControl 默认不取消的行为，让按住后拖动与快速反向保持滚动语义。
    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is CanvasStackPileView || super.touchesShouldCancel(in: view)
    }
}

/// 一堆内有多张独立真实纸面，按钮与 VoiceOver 都落到这堆而不是隐式当前项。
@MainActor
private final class CanvasStackPileView: UIControl {
    let preview: CanvasStackPreview
    let reduced: Bool
    var papers: [CanvasStackPaperView] = []
    let countLabel = UILabel()
    var onActivate: (() -> Void)?

    /// 多张真实纸面只合并无障碍入口，不合并绘制或伪造背纸内容。
    init(preview: CanvasStackPreview, reduced: Bool) {
        self.preview = preview; self.reduced = reduced
        super.init(frame: .zero)
        for content in preview.papers.reversed() {
            let paper = CanvasStackPaperView(content: content)
            addSubview(paper); papers.insert(paper, at: 0)
        }
        countLabel.text = "\(preview.group.members.count) 条书摘"
        countLabel.textAlignment = .center
        countLabel.font = ReadingContentTypography.uiAnnotation
        countLabel.textColor = NoteReviewCanvasAppearance.secondary
        countLabel.numberOfLines = 0
        countLabel.adjustsFontForContentSizeCategory = true
        addSubview(countLabel)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = preview.papers.prefix(3).map(\.accessibilityLabel).joined(separator: "；")
        accessibilityValue = countLabel.text
        accessibilityHint = "点按展开这一组书摘"
        accessibilityIdentifier = "review-stack-\(preview.group.id.bucket)"
        addAction(UIAction { [weak self] _ in self?.onActivate?() }, for: .touchUpInside)
    }
    /// 纸堆必须持有明确内容身份，不支持归档创建。
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 字号与布局结果不变，仅投影到堆叠骨架给出的尺寸。
    func arrange(center: CGPoint, width: CGFloat) {
        let poses = CanvasStackLayout.poses(sizes: papers.map { $0.content.logicalSize }, center: center, cardWidth: width, reduced: reduced)
        for (paper, pose) in zip(papers, poses) { paper.apply(pose) }
        let bottom = poses.first?.boundingFrame.maxY ?? center.y
        countLabel.frame = CGRect(x: center.x - width / 2, y: bottom + Spacing.double, width: width, height: 28)
    }

    /// 行高包含全部真实背纸及动态数量文字，不以最前纸张的高度代替整堆。
    func gridHeight(width: CGFloat) -> CGFloat {
        let paperBounds = gridPaperBounds(width: width)
        return ceil(paperBounds.height + Spacing.double + countLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    }

    /// 整堆边界顶对齐，数量保持自身语义字号，不参与纸面缩放。
    func arrangeTopAligned(width: CGFloat) {
        let paperBounds = gridPaperBounds(width: width)
        arrange(center: CGPoint(x: bounds.midX - paperBounds.midX, y: -paperBounds.minY), width: width)
        let labelHeight = ceil(countLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        countLabel.frame = CGRect(x: (bounds.width - width) / 2, y: paperBounds.height + Spacing.double,
                                 width: width, height: labelHeight)
    }

    /// 绘制与测量复用同一组纸张端点，包含背纸旋转后的边界。
    private func gridPaperBounds(width: CGFloat) -> CGRect {
        CanvasStackLayout.poses(sizes: papers.map { $0.content.logicalSize }, center: .zero, cardWidth: width, reduced: reduced)
            .reduce(CGRect.null) { $0.union($1.boundingFrame) }
    }

    /// 捕获端点的等比变换，供收拢或展开时直接连续接管。
    func poses(in container: UIView) -> [Int64: CanvasOverviewPaperPose] {
        Dictionary(uniqueKeysWithValues: papers.map { paper in
            let scale = hypot(paper.transform.a, paper.transform.b)
            return (paper.content.noteID, .init(center: convert(paper.center, to: container),
                size: CGSize(width: paper.bounds.width * scale, height: paper.bounds.height * scale),
                rotation: atan2(paper.transform.b, paper.transform.a)))
        })
    }

    /// 阴影和纸堆外留白不触发展开。
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        papers.contains { $0.convert($0.bounds, to: self).contains(point) }
    }
    /// VoiceOver 使用相同的固定组身份执行展开。
    override func accessibilityActivate() -> Bool { onActivate?(); return true }
    override var accessibilityFrame: CGRect {
        get {
            let local = papers.reduce(CGRect.null) { $0.union($1.convert($1.bounds, to: self)) }
            return UIAccessibility.convertToScreenCoordinates(local, in: self)
        }
        set { }
    }
}
