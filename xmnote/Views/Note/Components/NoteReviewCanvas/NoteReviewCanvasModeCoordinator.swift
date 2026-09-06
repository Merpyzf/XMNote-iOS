/**
 * [INPUT]: 接收稳定 noteID 对应的真实阅读与总览端点、请求模式及显示权回调
 * [OUTPUT]: 提供页面唯一模式状态与可反向的阅读纸张交接
 * [POS]: NoteReviewCanvas 页面转场协调器，不保存偏好或访问数据
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import UIKit
import SwiftUI

/// 转场纸面使用真实端点的材质，透明正文不再携带第二张完整纸卡。
struct NoteReviewCanvasReadingSurface {
    let color: UIColor
    let cornerRadius: CGFloat
    let skin: UIImage?
    let backgroundImage: UIImage?
    let backgroundOverlay: UIColor?

    /// 所有外观已在主 actor 解析，动画只消费颜色和准备好的图片，不读取资源。
    init(color: UIColor, cornerRadius: CGFloat = 0, skin: UIImage? = nil,
         backgroundImage: UIImage? = nil, backgroundOverlay: UIColor? = nil) {
        self.color = color
        self.cornerRadius = cornerRadius
        self.skin = skin
        self.backgroundImage = backgroundImage
        self.backgroundOverlay = backgroundOverlay
    }
}

/// 原始排版尺寸与屏幕纸面分离；动画投影现成像素，不按屏幕宽度重新排版。
struct NoteReviewCanvasReadingEndpoint {
    /// 业务身份与准备代次绑定；两种排版分别保存自己的内容和外观版本。
    struct Identity: Equatable {
        let noteID: Int64
        let requestGeneration: Int
        let contentVersion: Int
        let appearanceVersion: Int

        /// 两种排版的版本可不同，但必须属于同一业务身份和同一次请求。
        func belongsToSameRequest(as other: Self) -> Bool {
            noteID == other.noteID && requestGeneration == other.requestGeneration
        }
    }
    let identity: Identity?
    let image: UIImage
    let frame: CGRect
    let rotation: CGFloat
    let logicalSize: CGSize
    let surface: NoteReviewCanvasReadingSurface
    let backdropColor: UIColor
    let imageIncludesSurface: Bool
    let viewportImage: UIImage?
    let viewportFrame: CGRect?

    /// 普通端点传入透明正文；中断捕获明确标记整纸像素，避免再次叠加纸皮。
    init(image: UIImage, frame: CGRect, rotation: CGFloat, logicalSize: CGSize? = nil,
         surface: NoteReviewCanvasReadingSurface = .init(color: .clear),
         backdropColor: UIColor = .clear, imageIncludesSurface: Bool = false,
         viewportImage: UIImage? = nil, viewportFrame: CGRect? = nil, identity: Identity? = nil) {
        self.identity = identity
        self.image = image
        self.frame = frame
        self.rotation = rotation
        self.logicalSize = logicalSize ?? image.size
        self.surface = surface
        self.backdropColor = backdropColor
        self.imageIncludesSurface = imageIncludesSurface
        self.viewportImage = viewportImage
        self.viewportFrame = viewportFrame
    }

    /// 端点阴影、圆角与文字共享同一投影倍率，不把原始卡宽误认为屏幕宽度。
    var scale: CGFloat { frame.width / max(1, logicalSize.width) }

    /// 从正在显示的代理获取当前纸面；只用于用户中断，不在逐帧路径截屏。
    @MainActor static func capture(_ paper: UIView, in container: UIView,
        backdropColor: UIColor = .clear, surfaceColor: UIColor = .clear, cornerRadius: CGFloat = 0) -> Self {
        let center = paper.superview?.convert(paper.center, to: container) ?? paper.center
        let scale = hypot(paper.transform.a, paper.transform.b)
        let size = CGSize(width: paper.bounds.width * scale, height: paper.bounds.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = container.traitCollection.displayScale
        let image = UIGraphicsImageRenderer(size: paper.bounds.size, format: format).image { paper.layer.render(in: $0.cgContext) }
        return Self(image: image, frame: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
            width: size.width, height: size.height), rotation: atan2(paper.transform.b, paper.transform.a),
            logicalSize: paper.bounds.size, surface: .init(color: surfaceColor, cornerRadius: cornerRadius),
            backdropColor: backdropColor, imageIncludesSurface: true)
    }
}

/// 主 actor 串行管理模式请求与显示权；准备任务由宿主取消，迟到结果需匹配 requestedMode。
@MainActor
final class NoteReviewCanvasModeCoordinator {
    enum State { case idle, preparing, animating, settling }
    private(set) var state: State = .idle
    private(set) var settledMode: NoteReviewPresentationMode = .immersive
    private(set) var requestedMode: NoteReviewPresentationMode?
    var isOverviewTransition = false
    var reverseOverview: ((NoteReviewPresentationMode) -> Bool)?
    var onSurfaceChanged: (() -> Void)?
    var onReadingProgress: ((NoteReviewPresentationMode, NoteReviewPresentationMode, CGFloat) -> Void)?
    var presentationScrollView: UIScrollView? { scene }
    private var sourceMode: NoteReviewPresentationMode?
    private var targetMode: NoteReviewPresentationMode?
    private var animator: UIViewPropertyAnimator?
    private var dissolve: NoteReviewCanvasSurfaceDissolve?
    private var scene: NoteReviewCanvasReadingScene?
    private var clock: CADisplayLink?
    private var generation = 0

    /// 记录最新请求，不把尚未完成的目标写成已落稳模式。
    func request(_ target: NoteReviewPresentationMode) {
        NoteReviewCanvasHandoffDiagnostics.event("request generation=\(generation) target=\(target.rawValue)")
        requestedMode = target
        state = .preparing
    }

    /// 原方向或反向共享同一时间轴，不重建端点或回到初始位置。
    func reverseIfPossible(to target: NoteReviewPresentationMode) -> Bool {
        if isOverviewTransition {
            let previous = requestedMode
            requestedMode = target
            guard reverseOverview?(target) == true else { requestedMode = previous; return false }
            return true
        }
        if let dissolve, target == sourceMode || target == targetMode {
            requestedMode = target
            dissolve.reverse(target == sourceMode)
            return true
        }
        guard let animator, target == sourceMode || target == targetMode else { return false }
        requestedMode = target
        animator.isReversed = target == sourceMode
        return true
    }

    /// 只标记视觉准备，不改变当前业务身份。
    func markPreparing() { state = .preparing }
    /// 总览复合重排交由共享场景绘制，仍由本协调器提交业务模式。
    func markAnimating() { state = .animating }

    /// 第三个目标接管实际显示端点；宿主先保留整幅源画面，旧动画完成回调失效。
    func interrupt(in container: UIView) -> NoteReviewCanvasReadingEndpoint? {
        // The host already froze the displayed scene. Do not advance one more frame here.
        let endpoint = scene.map { NoteReviewCanvasReadingEndpoint.capture($0.paper, in: container,
            backdropColor: $0.backgroundColor ?? .clear, surfaceColor: $0.paperColor ?? .clear,
            cornerRadius: $0.paperCornerRadius) }
        generation += 1
        dissolve?.cancel(); dissolve = nil
        animator?.stopAnimation(true); animator = nil
        clock?.invalidate(); clock = nil
        scene?.removeFromSuperview(); scene = nil
        isOverviewTransition = false
        return endpoint
    }

    /// 后台冻结同一动画时间轴，恢复时继续，不触发过期完成回调。
    func setPaused(_ paused: Bool) {
        clock?.isPaused = paused
        if paused { dissolve?.animator.pauseAnimation() }
        else if dissolve?.animator.state == .active { dissolve?.animator.startAnimation() }
        if paused { animator?.pauseAnimation() }
        else if animator?.state == .active { animator?.startAnimation() }
    }
    /// 一次交还显示权后提交结果。
    func settle(_ mode: NoteReviewPresentationMode, handoff: () -> Void = {}) {
        generation += 1
        state = .settling
        NoteReviewCanvasHandoffDiagnostics.event("handoff generation=\(generation) owner=live mode=\(mode.rawValue)")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dissolve?.cancel(); dissolve = nil
        settledMode = mode
        requestedMode = nil
        isOverviewTransition = false
        // Reveal the prepared live owner before disposing the proxy in this same commit.
        handoff()
        scene?.removeFromSuperview()
        scene = nil
        animator = nil
        clock?.invalidate()
        clock = nil
        onSurfaceChanged?()
        CATransaction.commit()
        state = .idle
    }

    /// 内容已就绪但共享端点不可用时仍完成用户选择，不让可选动画资源阻断阅读。
    func animateDissolve(from: NoteReviewPresentationMode, to: NoteReviewPresentationMode,
        source: UIView, target: UIView, frozenSource: UIView?, container: UIView, below chrome: UIView,
        completion: @escaping (NoteReviewPresentationMode) -> Void) {
        generation += 1
        let token = generation
        sourceMode = from
        targetMode = to
        state = .animating
        let transition = NoteReviewCanvasSurfaceDissolve(source: source, target: target,
            frozenSource: frozenSource, container: container, below: chrome) { [weak self] reachedTarget in
                guard let self, generation == token else { return }
                completion(reachedTarget ? to : from)
            }
        dissolve = transition
        onSurfaceChanged?()
        transition.animator.startAnimation()
    }

    /// 两端均已准备后接管真实表面，运动期间只更新代理属性。
    func animateReading(from: NoteReviewPresentationMode, to: NoteReviewPresentationMode,
        source: NoteReviewCanvasReadingEndpoint, destination: NoteReviewCanvasReadingEndpoint,
        sourceBackground: UIView?, targetBackground: UIView?, clip: CGRect, container: UIView,
        below chrome: UIView, takeOwnership: () -> Void,
        completion: @escaping (NoteReviewPresentationMode) -> Void) {
        generation += 1
        let token = generation
        animator?.stopAnimation(true)
        clock?.invalidate()
        scene?.removeFromSuperview()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let surface = NoteReviewCanvasReadingScene(source: source, target: destination, clip: clip,
            sourceBackground: sourceBackground, targetBackground: targetBackground)
        scene = surface
        sourceMode = from
        targetMode = to
        state = .animating
        container.insertSubview(surface, belowSubview: chrome)
        surface.layoutIfNeeded()
        surface.render(0)
        onReadingProgress?(from, to, 0)
        takeOwnership()
        onSurfaceChanged?()
        CATransaction.commit()
        let reduced = UIAccessibility.isReduceMotionEnabled || UIAccessibility.prefersCrossFadeTransitions
        NoteReviewCanvasHandoffDiagnostics.record("proxy-first", view: surface)
        surface.reducedMotion = reduced
        let animation = reduced
            ? UIViewPropertyAnimator(duration: 0.12, curve: .easeInOut)
            : UIViewPropertyAnimator(duration: 0.30, dampingRatio: 0.96)
        animation.addAnimations { surface.clock.center = CGPoint(x: 1, y: 0) }
        animation.addCompletion { [weak self] position in
            guard let self, generation == token else { return }
            surface.render(position == .start ? 0 : 1)
            onReadingProgress?(from, to, position == .start ? 0 : 1)
            NoteReviewCanvasHandoffDiagnostics.record("proxy-last", view: surface, progress: position == .start ? 0 : 1)
            completion(position == .start ? from : to)
        }
        animator = animation
        if let progress = NoteReviewCanvasHandoffDiagnostics.fixedProgress {
            animation.startAnimation()
            animation.pauseAnimation()
            animation.fractionComplete = progress
            surface.render(progress)
            onReadingProgress?(from, to, progress)
            NoteReviewCanvasHandoffDiagnostics.record("proxy-fixed", view: surface, progress: progress)
            return
        }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        clock = link
        animation.startAnimation()
    }

    /// 使用实际展示位置驱动文字互补交叉淡变，最后八十毫秒不再改变端点排版。
    @objc private func tick() {
        guard let scene, let animator else { return }
        let progress = scene.clock.layer.presentation()?.position.x ?? animator.fractionComplete
        scene.render(progress)
        if let sourceMode, let targetMode { onReadingProgress?(sourceMode, targetMode, progress) }
    }

    /// 永久关闭中止时钟与动画；完成回调不再有提交资格。
    func dispose() {
        generation += 1
        dissolve?.cancel(); dissolve = nil
        animator?.stopAnimation(true)
        animator = nil
        clock?.invalidate()
        clock = nil
        scene?.removeFromSuperview()
        scene = nil
        requestedMode = nil
        reverseOverview = nil
        onSurfaceChanged = nil
        onReadingProgress = nil
        state = .idle
    }
}

/// 转场场景是临时唯一显示者，背景快照排除共享纸张，代理内部最多两份固定排版。
@MainActor
final class NoteReviewCanvasReadingScene: NoteReviewCanvasTransitionSurface {
    let clock = UIView(frame: .zero)
    var reducedMotion = false { didSet { render(lastProgress) } }
    private let source: NoteReviewCanvasReadingEndpoint
    private let target: NoteReviewCanvasReadingEndpoint
    private let sourceInk: UIImageView
    private let targetInk: UIImageView
    let paper = UIView()
    private let paperFill = UIView()
    private let contentClip = UIView()
    private let sourceSkin: UIImageView
    private let targetSkin: UIImageView
    private let sourceImage: UIImageView
    private let targetImage: UIImageView
    private let sourceTint = UIView()
    private let targetTint = UIView()
    private let sourceBackdrop: UIView?
    private let targetBackdrop: UIView?
    private let clip: CGRect
    private var sourceMask: CAShapeLayer?
    private var targetMask: CAShapeLayer?
    private var lastProgress: CGFloat = 0

    /// 同一生产采样供限定测试核对等比投影和互补透明度，不建立第二份动效算法。
    var contentProjection: (source: CGRect, target: CGRect) { (sourceInk.frame, targetInk.frame) }
    var contentOpacity: (source: CGFloat, target: CGFloat) { (sourceInk.alpha, targetInk.alpha) }
    var paperCornerRadius: CGFloat { contentClip.layer.cornerRadius }
    var paperColor: UIColor? { paperFill.backgroundColor }

    /// 快照与纸面均在同一裁剪坐标系，固定页面按钮不进入运动层。
    init(source: NoteReviewCanvasReadingEndpoint, target: NoteReviewCanvasReadingEndpoint, clip: CGRect,
         sourceBackground: UIView?, targetBackground: UIView?) {
        self.source = source
        self.target = target
        self.clip = clip
        sourceInk = UIImageView(image: source.image)
        targetInk = UIImageView(image: target.image)
        sourceSkin = UIImageView(image: source.imageIncludesSurface ? nil : source.surface.skin)
        targetSkin = UIImageView(image: target.imageIncludesSurface ? nil : target.surface.skin)
        sourceImage = UIImageView(image: source.imageIncludesSurface ? nil : source.surface.backgroundImage)
        targetImage = UIImageView(image: target.imageIncludesSurface ? nil : target.surface.backgroundImage)
        sourceBackdrop = sourceBackground
        targetBackdrop = targetBackground
        super.init(frame: clip)
        clipsToBounds = true
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        backgroundColor = source.backdropColor
        for (index, entry) in [(sourceBackground, source), (targetBackground, target)].enumerated() {
            let (background, endpoint) = entry
            guard let background else { continue }
            background.frame = background.frame.offsetBy(dx: -clip.minX, dy: -clip.minY)
            renderingContent.addSubview(background)
            let mask = CAShapeLayer()
            let path = UIBezierPath(rect: background.bounds)
            let shadow = endpoint.surface.skin == nil ? 0 : CanvasOverviewPaperRenderer.shadowPadding * endpoint.scale
            let hole = endpoint.frame.offsetBy(dx: -background.frame.minX - clip.minX,
                                                dy: -background.frame.minY - clip.minY).insetBy(dx: -shadow, dy: -shadow)
            let paperPath = UIBezierPath(roundedRect: hole,
                cornerRadius: endpoint.surface.cornerRadius * endpoint.scale + shadow)
            paperPath.apply(CGAffineTransform(translationX: hole.midX, y: hole.midY)
                .rotated(by: endpoint.rotation).translatedBy(x: -hole.midX, y: -hole.midY))
            path.append(paperPath)
            mask.path = path.cgPath
            mask.fillRule = .evenOdd
            background.layer.mask = mask
            if index == 0 { sourceMask = mask } else { targetMask = mask }
        }
        paper.backgroundColor = .clear
        paper.clipsToBounds = false
        renderingContent.addSubview(paper)
        paper.addSubview(paperFill)
        paper.addSubview(sourceSkin)
        paper.addSubview(targetSkin)
        contentClip.clipsToBounds = true
        paper.addSubview(contentClip)
        sourceTint.backgroundColor = source.surface.backgroundOverlay
        targetTint.backgroundColor = target.surface.backgroundOverlay
        sourceTint.isHidden = sourceImage.image == nil
        targetTint.isHidden = targetImage.image == nil
        for image in [sourceImage, targetImage] { image.contentMode = .scaleAspectFill; image.clipsToBounds = true }
        for content in [sourceImage, sourceTint, targetImage, targetTint, sourceInk, targetInk] { contentClip.addSubview(content) }
        sourceInk.contentMode = .scaleToFill
        targetInk.contentMode = .scaleToFill
        clock.isHidden = true
        addSubview(clock)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 复用同一端点和同一 render 入口，在未挂载的场景中恢复本帧；不复制系统边缘滤镜。
    override func preparedContentImage() -> UIImage? {
        func copyBackdrop(_ view: UIView?) -> UIView? {
            guard let view else { return nil }
            // Normal backgrounds are prepared UIImageViews; a frozen handoff wraps one such image.
            guard let image = (view as? UIImageView)?.image ?? (view.subviews.first as? UIImageView)?.image else { return nil }
            let copy = UIImageView(image: image)
            copy.frame = view.frame.offsetBy(dx: clip.minX, dy: clip.minY)
            copy.backgroundColor = view.backgroundColor
            return copy
        }
        let copiedSource = copyBackdrop(sourceBackdrop), copiedTarget = copyBackdrop(targetBackdrop)
        guard sourceBackdrop == nil || copiedSource != nil, targetBackdrop == nil || copiedTarget != nil else { return nil }
        let copy = NoteReviewCanvasReadingScene(source: source, target: target, clip: clip,
            sourceBackground: copiedSource, targetBackground: copiedTarget)
        copy.reducedMotion = reducedMotion
        copy.render(lastProgress)
        return rasterizePreparedScene(copy)
    }

    /// 每帧仅改变几何与透明度，文字图像保持等比与各自真实端点换行。
    func render(_ value: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let p = min(1, max(0, value))
        lastProgress = p
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * p }
        let rect = CGRect(
            x: mix(source.frame.minX, target.frame.minX), y: mix(source.frame.minY, target.frame.minY),
            width: mix(source.frame.width, target.frame.width), height: mix(source.frame.height, target.frame.height))
        let logicalWidth = max(1, mix(source.logicalSize.width, target.logicalSize.width))
        let scale = max(0.001, rect.width / logicalWidth)
        paper.bounds = CGRect(x: 0, y: 0, width: logicalWidth, height: rect.height / scale)
        paper.center = CGPoint(x: rect.midX - clip.minX, y: rect.midY - clip.minY)
        paper.transform = CGAffineTransform(rotationAngle: mix(source.rotation, target.rotation)).scaledBy(x: scale, y: scale)
        let radius = mix(source.surface.cornerRadius, target.surface.cornerRadius)
        paperFill.frame = paper.bounds
        paperFill.layer.cornerRadius = radius
        paperFill.backgroundColor = NoteReviewCanvasAppearance.interpolatePaper(
            from: source.surface.color.cgColor, to: target.surface.color.cgColor, progress: p)
        contentClip.frame = paper.bounds
        contentClip.layer.cornerRadius = radius
        sourceSkin.frame = paper.bounds.insetBy(dx: -CanvasOverviewPaperRenderer.shadowPadding, dy: -CanvasOverviewPaperRenderer.shadowPadding)
        targetSkin.frame = sourceSkin.frame
        sourceSkin.alpha = 1 - p
        targetSkin.alpha = p
        sourceImage.frame = paper.bounds
        targetImage.frame = paper.bounds
        sourceTint.frame = paper.bounds
        targetTint.frame = paper.bounds
        sourceImage.alpha = 1 - p
        sourceTint.alpha = 1 - p
        targetImage.alpha = p
        targetTint.alpha = p
        // A complete prepared text image is one logical block. Both axes use the same
        // factor, anchored at the reading origin; only the paper's lower edge clips it.
        func inkFrame(_ endpoint: NoteReviewCanvasReadingEndpoint) -> CGRect {
            let factor = logicalWidth / max(1, endpoint.logicalSize.width)
            return CGRect(x: 0, y: 0, width: endpoint.logicalSize.width * factor,
                          height: endpoint.logicalSize.height * factor)
        }
        sourceInk.frame = inkFrame(source)
        targetInk.frame = inkFrame(target)
        let text = reducedMotion ? p : min(1, max(0, (p - 0.32) / 0.30))
        sourceInk.alpha = 1 - text
        targetInk.alpha = text
        let backgroundPhase = min(1, max(0, (p - 0.12) / 0.70))
        let backgroundMix = reducedMotion ? p : backgroundPhase * backgroundPhase * (3 - 2 * backgroundPhase)
        sourceBackdrop?.alpha = 1 - backgroundMix
        targetBackdrop?.alpha = backgroundMix
        backgroundColor = NoteReviewCanvasAppearance.interpolatePaper(
            from: source.backdropColor.cgColor, to: target.backdropColor.cgColor, progress: backgroundMix)
        // Crossfade preference preserves each real endpoint at its own location rather
        // than teleporting the shared paper to the target before the first fade frame.
        let usesBackgroundDissolve = reducedMotion && sourceBackdrop != nil && targetBackdrop != nil
        let resolvedSourceMask = usesBackgroundDissolve ? nil : sourceMask
        let resolvedTargetMask = usesBackgroundDissolve ? nil : targetMask
        if sourceBackdrop?.layer.mask !== resolvedSourceMask { sourceBackdrop?.layer.mask = resolvedSourceMask }
        if targetBackdrop?.layer.mask !== resolvedTargetMask { targetBackdrop?.layer.mask = resolvedTargetMask }
        paper.isHidden = usesBackgroundDissolve
    }
}

/// 页面状态由生产宿主更新，LoadingGate 只负责提示显隐时间。
@MainActor @Observable
final class NoteReviewCanvasPageFeedback {
    let gate = LoadingGate()
    private(set) var isWaiting = false
    var error: String?
    var isEmpty = false
    var retry: (() -> Void)?
    var needsReadingRecovery = false

    /// 同一请求不重复重置显示延迟；取消、失败和就绪立即解除按钮反馈。
    func setWaiting(_ waiting: Bool) {
        guard waiting != isWaiting else { return }
        isWaiting = waiting
        if waiting { gate.update(intent: .read) }
        else { gate.hideImmediately() }
    }

    /// 目标内容不可取得时结束 spinner，恢复资格交给宿主的下一次菜单，不占据阅读表面。
    func showReadingRecovery() {
        needsReadingRecovery = true
        setWaiting(false)
    }
}

/// 复用项目状态组件，不另造画布专用加载或错误皮肤。
struct NoteReviewCanvasPageFeedbackView: View {
    let state: NoteReviewCanvasPageFeedback
    var body: some View {
        VStack(spacing: Spacing.base) {
            if let error = state.error {
                XMInlineStatusBanner(error, tone: .error, action: XMStateAction("重试") { state.retry?() })
            } else if state.isEmpty {
                XMContentStateView(role: .noResults, title: "当前筛选下没有书摘")
            }
        }
    }
}
