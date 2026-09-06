/**
 * [INPUT]: 接收有界真实纸张预览及激活/取消回调
 * [OUTPUT]: 提供可取消纸面点按的原生惯性横滑、RTL 与有序辅助功能；不提交业务当前项
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

/// 原生滚动只浏览堆叠，不分页吸附、不启动整组正文准备。
@MainActor
final class CanvasStackBrowserView: UIView, UIScrollViewDelegate {
    let scrollView = CanvasStackScrollView()
    let material = UIVisualEffectView(effect: nil)
    let backdrop = UIImageView()
    private let titleLabel = UILabel()
    private let hintLabel = UILabel()
    let returnButton = UIButton(type: .system)
    private(set) var previews: [CanvasStackPreview] = []
    private var piles: [NoteReviewCanvasStackID: CanvasStackPileView] = [:]
    private var applying = false
    private var lastFocusedID: NoteReviewCanvasStackID?
    private var focusCompletion: (() -> Void)?
    var onFocus: ((NoteReviewCanvasStackID) -> Void)?
    var onActivate: ((NoteReviewCanvasStackID) -> Void)?
    var onReturn: (() -> Void)?
    var onStable: (() -> Void)?
    var onInteraction: (() -> Void)?
    var contentInsets: UIEdgeInsets = .zero
    let reduced: Bool
    var step: CGFloat { cardWidth + Spacing.double * 2 }
    var cardWidth: CGFloat { min(320, bounds.width * 0.72) }
    var isMoving: Bool { scrollView.isDragging || scrollView.isDecelerating || focusCompletion != nil }
    var focusedID: NoteReviewCanvasStackID? {
        guard !previews.isEmpty else { return nil }
        let index = min(previews.count - 1, max(0, Int((scrollView.contentOffset.x / max(1, step)).rounded())))
        return previews[physicalIndex(index)].group.id
    }

    /// 仅镜像空间方向，目录和 VoiceOver 的业务顺序不反转。
    private func physicalIndex(_ index: Int) -> Int {
        effectiveUserInterfaceLayoutDirection == .rightToLeft ? previews.count - 1 - index : index
    }

    /// 控件覆盖内容区域而不改变桌面尺寸，模糊材质由收拢时间轴接入。
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
        scrollView.alwaysBounceHorizontal = true
        scrollView.isPagingEnabled = false
        scrollView.decelerationRate = .normal
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.scrollsToTop = false
        addSubview(scrollView)
        titleLabel.text = "浏览卡片堆"
        titleLabel.font = ReadingContentTypography.uiAnnotationSemibold
        titleLabel.textColor = NoteReviewCanvasAppearance.primary
        titleLabel.textAlignment = .center
        addSubview(titleLabel)
        hintLabel.text = "左右滑动浏览 · 点按卡片堆展开"
        hintLabel.font = ReadingContentTypography.uiMetadata
        hintLabel.textColor = NoteReviewCanvasAppearance.secondary
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 0
        addSubview(hintLabel)
        var config = UIButton.Configuration.plain()
        config.title = "返回当前桌面"
        config.baseForegroundColor = NoteReviewCanvasAppearance.primary
        returnButton.configuration = config
        returnButton.addAction(UIAction { [weak self] _ in self?.onReturn?() }, for: .touchUpInside)
        addSubview(returnButton)
    }
    /// 该表面依赖就绪端点，只通过代码创建。
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 只摆放覆盖控件和小窗口纸堆，不向桌面提交几何。
    override func layoutSubviews() {
        super.layoutSubviews()
        titleLabel.frame = CGRect(x: Spacing.screenEdge, y: contentInsets.top + Spacing.base,
            width: bounds.width - Spacing.screenEdge * 2, height: 32)
        let bottom = bounds.height - contentInsets.bottom
        returnButton.frame = CGRect(x: Spacing.screenEdge, y: bottom - 56, width: bounds.width - Spacing.screenEdge * 2, height: 48)
        hintLabel.frame = CGRect(x: Spacing.screenEdge, y: bottom - 90, width: bounds.width - Spacing.screenEdge * 2, height: 32)
        layoutPiles()
    }

    /// 仅在静止时重置小窗口原点，等量补偿当前堆的屏幕 X，惯性期间不改滚动状态。
    func apply(_ values: [CanvasStackPreview], preserving id: NoteReviewCanvasStackID?) {
        guard !isMoving else { return }
        applying = true
        let anchor = id ?? focusedID
        let oldIndex = anchor.flatMap { value in previews.firstIndex { $0.group.id == value } }
        let anchorX = oldIndex.map { CGFloat(physicalIndex($0)) * step - scrollView.contentOffset.x } ?? 0
        for (key, pile) in piles where !values.contains(where: { $0.group.id == key }) {
            pile.removeFromSuperview(); piles.removeValue(forKey: key)
        }
        previews = values
        var entering: [CanvasStackPileView] = []
        for preview in values where piles[preview.group.id] == nil {
            let pile = CanvasStackPileView(preview: preview, reduced: reduced)
            pile.onActivate = { [weak self] in
                guard let self, !isMoving else { return }
                onActivate?(preview.group.id)
            }
            scrollView.addSubview(pile)
            piles[preview.group.id] = pile
            if window != nil { pile.alpha = 0; entering.append(pile) }
        }
        layoutPiles()
        scrollView.accessibilityElements = values.compactMap { piles[$0.group.id] }
        if let anchor, let index = values.firstIndex(where: { $0.group.id == anchor }) {
            scrollView.setContentOffset(CGPoint(x: CGFloat(physicalIndex(index)) * step - anchorX, y: 0), animated: false)
        }
        applying = false
        lastFocusedID = focusedID
        for (index, pile) in entering.enumerated() {
            UIView.animate(withDuration: reduced ? 0.12 : 0.16, delay: reduced ? 0 : min(0.03, Double(index) * 0.01),
                options: [.beginFromCurrentState, .allowUserInteraction], animations: { pile.alpha = 1 })
        }
    }

    /// 几何只与视口和至多五个真实堆有关，不依赖全量目录或正文。
    private func layoutPiles() {
        scrollView.contentSize = CGSize(width: bounds.width + CGFloat(max(0, previews.count - 1)) * step, height: bounds.height)
        let top = contentInsets.top + 70
        let bottom = bounds.height - contentInsets.bottom - 100
        let centerY = top + max(100, bottom - top) * 0.57
        for (index, preview) in previews.enumerated() {
            guard let pile = piles[preview.group.id] else { continue }
            pile.frame = CGRect(x: CGFloat(physicalIndex(index)) * step, y: 0, width: bounds.width, height: bounds.height)
            pile.arrange(center: CGPoint(x: bounds.midX, y: centerY), width: cardWidth)
        }
    }

    /// 将纸堆端点转换到唯一转场容器，身份不依赖滚动索引。
    func poses(for id: NoteReviewCanvasStackID, in container: UIView) -> [Int64: CanvasOverviewPaperPose] {
        guard let pile = piles[id] else { return [:] }
        return pile.poses(in: container)
    }

    /// 代理持有显示权期间隐藏同一堆，避免两份纸面叠加。
    func setPileHidden(_ id: NoteReviewCanvasStackID, hidden: Bool) { piles[id]?.alpha = hidden ? 0 : 1 }

    /// 返回按钮可连续横移到原堆；只改变预览位置，不提交阅读身份。
    func focus(_ id: NoteReviewCanvasStackID, completion: @escaping () -> Void) {
        guard let index = previews.firstIndex(where: { $0.group.id == id }) else { return }
        let target = CGPoint(x: CGFloat(physicalIndex(index)) * step, y: 0)
        if reduced || abs(target.x - scrollView.contentOffset.x) < 1 {
            applying = true
            scrollView.setContentOffset(target, animated: false)
            applying = false
            lastFocusedID = id
            completion()
        } else {
            focusCompletion = completion
            scrollView.setContentOffset(target, animated: true)
        }
    }

    /// 控件在同一时间轴渐显，不与独立纸面争夺显示权。
    func setChromeVisible(_ visible: Bool) {
        titleLabel.alpha = visible ? 1 : 0; hintLabel.alpha = visible ? 1 : 0; returnButton.alpha = visible ? 1 : 0
    }

    /// 新手势取消程序性返回和待展开请求，但不改变阅读身份。
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { focusCompletion = nil; onInteraction?() }
    /// 浏览焦点只用于预览需求，不回写当前书摘。
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !applying, focusCompletion == nil, let id = focusedID, id != lastFocusedID else { return }
        lastFocusedID = id
        onFocus?(id)
    }
    /// 惯性结束后才允许等量补偿有界预览窗口。
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { onStable?() }
    /// 无惯性的短拖动也需补齐邻堆。
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { onStable?() } }

    /// 原生横移结束后再展开目标，避免一边移动一边更换正文。
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        let completion = focusCompletion
        focusCompletion = nil
        lastFocusedID = focusedID
        completion?()
        if completion == nil { onStable?() }
    }

    /// 辅助功能沿目录顺序浏览，空间方向随 RTL 镜像。
    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        guard let id = focusedID, let index = previews.firstIndex(where: { $0.group.id == id }) else { return false }
        let delta = direction == .left ? 1 : direction == .right ? -1 : 0
        let next = index + (effectiveUserInterfaceLayoutDirection == .rightToLeft ? -delta : delta)
        guard next != index, previews.indices.contains(next) else { return false }
        focus(previews[next].group.id) { [weak self] in
            self?.onStable?()
            UIAccessibility.post(notification: .pageScrolled, argument: "\(self?.previews[next].group.members.count ?? 0) 条书摘")
        }
        return true
    }

    /// 辅助功能退出和可见返回按钮使用同一个恢复路径。
    override func accessibilityPerformEscape() -> Bool { onReturn?(); return true }
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
