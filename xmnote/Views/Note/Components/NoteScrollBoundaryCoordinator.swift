/**
 * [INPUT]: 依赖 UIKit UIScrollView/panGestureRecognizer/CADisplayLink 与 SwiftUI UIViewRepresentable，接收搜索揭示轨道高度、固定态、启用态和 Reduce Motion
 * [OUTPUT]: 对 NoteCollapsibleSearchPage 提供页面私有滚动位置协调器，以单一 contentOffset 驱动直操揭示、初始布局校准、原生边界反馈与可中断 Snap
 * [POS]: Note 模块首页页面私有 UIKit 桥接，只观察并吸附所属 SwiftUI ScrollView，不接管 delegate 或改写 contentInset
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// SwiftUI 页面持有的稳定控制句柄，把程序化展开请求转发给当前页面自己的 UIKit 协调器。
@MainActor
final class NoteScrollBoundaryController {
    private struct PendingExpansion {
        let isExpanded: Bool
        let animated: Bool
        let completion: ((Bool) -> Void)?
    }

    private weak var coordinator: NoteScrollBoundaryCoordinator?
    private var pendingExpansion: PendingExpansion?

    /// 绑定当前页面实际安装的协调器，并在滚动层级就绪时提交最后一个待执行请求。
    func bind(_ coordinator: NoteScrollBoundaryCoordinator) {
        self.coordinator = coordinator
        guard let pendingExpansion else { return }
        self.pendingExpansion = nil
        coordinator.setExpanded(
            pendingExpansion.isExpanded,
            animated: pendingExpansion.animated,
            completion: pendingExpansion.completion
        )
    }

    /// 将搜索抽屉移动到完整展开或收起端点；完成值表示请求是否由真实 UIScrollView 执行。
    func setExpanded(
        _ isExpanded: Bool,
        animated: Bool,
        completion: @escaping (Bool) -> Void
    ) {
        guard let coordinator else {
            pendingExpansion = PendingExpansion(
                isExpanded: isExpanded,
                animated: animated,
                completion: completion
            )
            return
        }
        pendingExpansion = nil
        coordinator.setExpanded(
            isExpanded,
            animated: animated,
            completion: completion
        )
    }

    /// 在 UIScrollView 尚未装配时暂存端点请求，绑定后同步执行且可被后续用户动作覆盖。
    func setExpandedWhenAvailable(_ isExpanded: Bool, animated: Bool) {
        guard let coordinator else {
            pendingExpansion = PendingExpansion(
                isExpanded: isExpanded,
                animated: animated,
                completion: nil
            )
            return
        }
        pendingExpansion = nil
        coordinator.setExpanded(
            isExpanded,
            animated: animated,
            completion: nil
        )
    }

    /// 页面切换时停止尚未完成的端点移动，避免隐藏页面继续改写可见状态。
    func cancelProgrammaticMovement() {
        let completion = pendingExpansion?.completion
        pendingExpansion = nil
        completion?(false)
        coordinator?.cancelProgrammaticMovement()
    }
}

/// 零尺寸 SwiftUI 探针，用公开 UIView 层级定位所属 UIScrollView，不接管系统或 SwiftUI 的 delegate。
struct NoteScrollBoundaryBridge: UIViewRepresentable {
    let controller: NoteScrollBoundaryController
    let maximumRevealHeight: CGFloat
    let isEnabled: Bool
    let isPinned: Bool
    let reduceMotion: Bool
    let onRevealHeightChange: (CGFloat) -> Void

    /// 创建页面独立协调器，确保 KeepAlive 的各个分类互不共享手势会话。
    func makeCoordinator() -> NoteScrollBoundaryCoordinator {
        NoteScrollBoundaryCoordinator(controller: controller)
    }

    /// 创建不参与布局和命中的探针视图，并在进入层级后绑定最近的 UIScrollView。
    func makeUIView(context: Context) -> NoteScrollBoundaryProbeView {
        let probe = NoteScrollBoundaryProbeView()
        probe.coordinator = context.coordinator
        context.coordinator.configure(
            maximumRevealHeight: maximumRevealHeight,
            isEnabled: isEnabled,
            isPinned: isPinned,
            reduceMotion: reduceMotion,
            onRevealHeightChange: onRevealHeightChange
        )
        return probe
    }

    /// 同步抽屉约束与页面状态；视图层级变化时重新确认所属 ScrollView。
    func updateUIView(_ uiView: NoteScrollBoundaryProbeView, context: Context) {
        context.coordinator.configure(
            maximumRevealHeight: maximumRevealHeight,
            isEnabled: isEnabled,
            isPinned: isPinned,
            reduceMotion: reduceMotion,
            onRevealHeightChange: onRevealHeightChange
        )
        context.coordinator.resolveScrollView(from: uiView)
    }

    /// 探针拆除时同步移除手势 target 并释放帧回调，不改变滚动容器的系统 inset。
    static func dismantleUIView(
        _ uiView: NoteScrollBoundaryProbeView,
        coordinator: NoteScrollBoundaryCoordinator
    ) {
        uiView.coordinator = nil
        coordinator.detach()
    }
}

/// 通过进入 window 和布局时机重试绑定，并在系统安全区变化后重新发布真实揭示高度。
final class NoteScrollBoundaryProbeView: UIView {
    weak var coordinator: NoteScrollBoundaryCoordinator?

    /// 探针进入真实窗口后解析所属滚动容器。
    override func didMoveToWindow() {
        super.didMoveToWindow()
        coordinator?.resolveScrollView(from: self)
    }

    /// SwiftUI 调整页面层级或安全区时再次校准滚动容器与抽屉可见高度。
    override func layoutSubviews() {
        super.layoutSubviews()
        coordinator?.resolveScrollView(from: self)
        coordinator?.synchronizeBaseInsetsIfNeeded()
    }

    /// 探针不承载交互，所有触摸继续交给原始 SwiftUI ScrollView。
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        false
    }
}

/// 以 UIScrollView 的规范化纵向位置为唯一几何真相，观察透明轨道并吸附到展开或收起端点。
@MainActor
final class NoteScrollBoundaryCoordinator: NSObject {
    private struct DeferredExpansion {
        let isExpanded: Bool
        let animated: Bool
        let completion: ((Bool) -> Void)?
    }

    private weak var scrollView: UIScrollView?
    private var maximumRevealHeight: CGFloat = 0
    private var revealHeight: CGFloat = 0
    private var isEnabled = false
    private var isPinned = false
    private var reduceMotion = false
    private var onRevealHeightChange: ((CGFloat) -> Void)?
    private var isApplyingOffset = false

    private var displayLink: CADisplayLink?
    private var programmaticAnimator: UIViewPropertyAnimator?
    private var programmaticCompletion: ((Bool) -> Void)?
    private var deferredExpansion: DeferredExpansion?

    /// 注入稳定控制句柄，让 SwiftUI 状态机无需持有 UIKit 视图引用。
    init(controller: NoteScrollBoundaryController) {
        super.init()
        controller.bind(self)
    }

    deinit {
        displayLink?.invalidate()
    }

    /// 更新抽屉约束；固定搜索始终完整显示，恢复普通浏览时重新读取当前滚动位置。
    func configure(
        maximumRevealHeight: CGFloat,
        isEnabled: Bool,
        isPinned: Bool,
        reduceMotion: Bool,
        onRevealHeightChange: @escaping (CGFloat) -> Void
    ) {
        let previousMaximum = self.maximumRevealHeight
        let wasPinned = self.isPinned
        self.maximumRevealHeight = max(0, maximumRevealHeight)
        self.isEnabled = isEnabled
        self.isPinned = isPinned
        self.reduceMotion = reduceMotion
        self.onRevealHeightChange = onRevealHeightChange

        if previousMaximum != self.maximumRevealHeight {
            revealHeight = clampedRevealHeight(revealHeight)
        }
        if isPinned, !wasPinned {
            setExpanded(true, animated: false, completion: nil)
        } else if !isPinned, wasPinned, let scrollView {
            publishRevealHeight(from: scrollView)
        } else if isPinned {
            publishRevealHeight(maximumRevealHeight)
        }
    }

    /// 优先沿父视图链定位 UIScrollView；稳定容器探针则查找最近共同容器内的滚动子视图。
    func resolveScrollView(from probe: UIView) {
        var ancestor = probe.superview
        while let view = ancestor {
            if let candidate = view as? UIScrollView {
                attach(to: candidate)
                return
            }
            if let candidate = firstDescendantScrollView(in: view, excluding: probe) {
                attach(to: candidate)
                return
            }
            ancestor = view.superview
        }
    }

    /// 系统安全区或 SwiftUI 容器调整后只重算规范化位置，不改写任何 contentInset。
    func synchronizeBaseInsetsIfNeeded() {
        guard let scrollView,
              !isApplyingOffset,
              programmaticAnimator == nil else {
            return
        }
        if isPinned {
            publishRevealHeight(maximumRevealHeight)
        } else {
            publishRevealHeight(from: scrollView)
        }
    }

    /// 把当前搜索抽屉移动到完整展开或收起端点，并统一处理 Snap 与程序化显示。
    func setExpanded(
        _ isExpanded: Bool,
        animated: Bool,
        completion: ((Bool) -> Void)?
    ) {
        guard scrollView != nil else {
            deferredExpansion = DeferredExpansion(
                isExpanded: isExpanded,
                animated: animated,
                completion: completion
            )
            return
        }
        deferredExpansion = nil
        startMovement(
            toNormalizedOffset: isExpanded ? 0 : maximumRevealHeight,
            animated: animated,
            initialPanVelocityY: nil,
            completion: completion
        )
    }

    /// 停止当前程序化移动并向调用方报告未完成，供页面切换或新手势接管。
    func cancelProgrammaticMovement() {
        let deferredCompletion = deferredExpansion?.completion
        deferredExpansion = nil
        deferredCompletion?(false)
        cancelProgrammaticMovement(notify: true)
    }

    /// 绑定新的滚动视图前移除旧 target，防止 KeepAlive 重排后一次手势被重复处理。
    private func attach(to scrollView: UIScrollView) {
        guard self.scrollView !== scrollView else { return }
        detach()
        self.scrollView = scrollView
        scrollView.panGestureRecognizer.addTarget(self, action: #selector(handlePan(_:)))
        establishInitialPosition(in: scrollView)
        reconcileInitialPositionAfterLayout(in: scrollView)

        if let deferredExpansion {
            self.deferredExpansion = nil
            setExpanded(
                deferredExpansion.isExpanded,
                animated: deferredExpansion.animated,
                completion: deferredExpansion.completion
            )
        }
    }

    /// 新滚动容器从透明轨道的正确端点起步；已有非顶部现场则保持其真实位置。
    private func establishInitialPosition(in scrollView: UIScrollView) {
        let currentOffset = normalizedOffsetY(in: scrollView)
        guard abs(currentOffset) <= NoteScrollBoundaryMetrics.offsetEpsilon else {
            publishRevealHeight(from: scrollView)
            return
        }

        let shouldOpen = isPinned
            || revealHeight >= maximumRevealHeight / 2
        applyNormalizedOffset(
            shouldOpen ? 0 : maximumRevealHeight,
            notify: true,
            in: scrollView
        )
    }

    /// SwiftUI 可能在探针绑定后的同一轮布局重置 contentOffset；下一主队列周期只修复“抽屉已隐藏但轨道仍展开”的矛盾状态。
    private func reconcileInitialPositionAfterLayout(in scrollView: UIScrollView) {
        DispatchQueue.main.async { [weak self, weak scrollView] in
            guard let self,
                  let scrollView,
                  self.scrollView === scrollView,
                  self.programmaticAnimator == nil,
                  !self.isApplyingOffset else {
                return
            }

            if self.isPinned {
                self.applyNormalizedOffset(
                    0,
                    notify: true,
                    in: scrollView
                )
                return
            }

            let currentOffset = self.normalizedOffsetY(in: scrollView)
            let hasHiddenDrawerAtExpandedTrack = abs(currentOffset)
                    <= NoteScrollBoundaryMetrics.offsetEpsilon
                && self.revealHeight
                    <= NoteScrollBoundaryMetrics.geometryEpsilon
            guard hasHiddenDrawerAtExpandedTrack else {
                self.publishRevealHeight(from: scrollView)
                return
            }

            self.applyNormalizedOffset(
                self.maximumRevealHeight,
                notify: true,
                in: scrollView
            )
        }
    }

    /// 解除原生观察关系并停止自动移动；透明轨道随 SwiftUI 页面生命周期自行销毁。
    func detach() {
        deferredExpansion = nil
        cancelProgrammaticMovement(notify: false)
        if let scrollView {
            scrollView.panGestureRecognizer.removeTarget(self, action: #selector(handlePan(_:)))
        }
        scrollView = nil
    }

    /// 逐层优先选择最近容器的滚动子视图，避免 LazyVStack 子视图更新时丢失所属滚动容器。
    private func firstDescendantScrollView(
        in root: UIView,
        excluding probe: UIView
    ) -> UIScrollView? {
        for subview in root.subviews where subview !== probe {
            if let scrollView = subview as? UIScrollView {
                return scrollView
            }
        }
        for subview in root.subviews where subview !== probe {
            if let scrollView = firstDescendantScrollView(in: subview, excluding: probe) {
                return scrollView
            }
        }
        return nil
    }

    /// 原生 pan 全程拥有滚动几何；协调器只发布轨道进度，并在松手后处理部分展开区间的 Snap。
    @objc
    private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let scrollView, recognizer === scrollView.panGestureRecognizer else { return }

        switch recognizer.state {
        case .began:
            if programmaticAnimator != nil {
                cancelProgrammaticMovement(notify: true)
            }
            guard isEnabled, !isPinned, maximumRevealHeight > 0 else { return }
            publishRevealHeight(from: scrollView)
        case .changed:
            guard isEnabled, !isPinned, maximumRevealHeight > 0 else { return }
            publishRevealHeight(from: scrollView)
        case .ended:
            guard isEnabled, !isPinned, maximumRevealHeight > 0 else { return }
            settleDrawerIfNeeded(
                panVelocityY: recognizer.velocity(in: recognizer.view).y,
                in: scrollView
            )
        case .cancelled:
            guard isEnabled, !isPinned, maximumRevealHeight > 0 else { return }
            settleDrawerIfNeeded(panVelocityY: 0, in: scrollView)
        case .failed:
            if isEnabled, !isPinned {
                publishRevealHeight(from: scrollView)
            }
        case .possible:
            break
        @unknown default:
            if isEnabled, !isPinned {
                publishRevealHeight(from: scrollView)
            }
        }
    }

    /// 松手时用短时速度投影和中点共同选择端点；真实内容区内的普通滚动不被搜索 Snap 截断。
    private func settleDrawerIfNeeded(
        panVelocityY: CGFloat,
        in scrollView: UIScrollView
    ) {
        let currentOffset = normalizedOffsetY(in: scrollView)
        publishRevealHeight(from: scrollView)

        guard currentOffset <= maximumRevealHeight
                + NoteScrollBoundaryMetrics.boundaryEpsilon else {
            return
        }

        let projectedOffset = clampedNormalizedOffset(
            currentOffset - panVelocityY * NoteScrollBoundaryMetrics.projectionHorizon
        )
        let targetOffset = projectedOffset < maximumRevealHeight / 2
            ? CGFloat.zero
            : maximumRevealHeight

        DispatchQueue.main.async { [weak self] in
            self?.startMovement(
                toNormalizedOffset: targetOffset,
                animated: !(self?.reduceMotion ?? true),
                initialPanVelocityY: panVelocityY,
                completion: nil
            )
        }
    }

    /// 统一创建 Snap 与程序化端点动画，保证任一时刻只有 contentOffset 一个几何写入者。
    private func startMovement(
        toNormalizedOffset requestedOffset: CGFloat,
        animated: Bool,
        initialPanVelocityY: CGFloat?,
        completion: ((Bool) -> Void)?
    ) {
        guard let scrollView else {
            completion?(false)
            return
        }

        cancelProgrammaticMovement(notify: false)
        let targetOffset = clampedNormalizedOffset(requestedOffset)

        if initialPanVelocityY != nil {
            scrollView.setContentOffset(scrollView.contentOffset, animated: false)
        }

        let currentOffset = normalizedOffsetY(in: scrollView)
        guard abs(currentOffset - targetOffset)
                > NoteScrollBoundaryMetrics.offsetEpsilon else {
            applyNormalizedOffset(targetOffset, notify: true, in: scrollView)
            completion?(true)
            return
        }

        guard animated, !reduceMotion else {
            applyNormalizedOffset(targetOffset, notify: true, in: scrollView)
            completion?(true)
            return
        }

        programmaticCompletion = completion
        let targetContentOffsetY = contentOffsetY(
            forNormalizedOffset: targetOffset,
            in: scrollView
        )
        let remainingDistance = targetContentOffsetY - scrollView.contentOffset.y
        let duration = movementDuration(distance: abs(currentOffset - targetOffset))
        let timing = UISpringTimingParameters(
            dampingRatio: NoteScrollBoundaryMetrics.settleDampingRatio,
            initialVelocity: CGVector(
                dx: 0,
                dy: normalizedInitialVelocity(
                    panVelocityY: initialPanVelocityY,
                    remainingContentOffsetDistance: remainingDistance
                )
            )
        )
        let animator = UIViewPropertyAnimator(duration: duration, timingParameters: timing)
        animator.addAnimations { [weak self, weak scrollView] in
            guard let self, let scrollView else { return }
            self.isApplyingOffset = true
            scrollView.contentOffset = CGPoint(
                x: scrollView.contentOffset.x,
                y: targetContentOffsetY
            )
            scrollView.layoutIfNeeded()
            self.isApplyingOffset = false
        }
        animator.addCompletion { [weak self] position in
            guard let self else { return }
            self.finishProgrammaticMovement(
                atNormalizedOffset: targetOffset,
                didExecute: position == .end
            )
        }
        programmaticAnimator = animator
        animator.startAnimation()
        startDisplayLink()
    }

    /// 在指定滚动容器内提交精确端点；仅写 contentOffset，不制造第二套 inset 几何。
    private func applyNormalizedOffset(
        _ requestedOffset: CGFloat,
        notify: Bool,
        in scrollView: UIScrollView
    ) {
        let targetOffset = clampedNormalizedOffset(requestedOffset)
        isApplyingOffset = true
        UIView.performWithoutAnimation {
            scrollView.contentOffset = CGPoint(
                x: scrollView.contentOffset.x,
                y: contentOffsetY(forNormalizedOffset: targetOffset, in: scrollView)
            )
            scrollView.layoutIfNeeded()
        }
        isApplyingOffset = false

        if notify {
            publishRevealHeight(revealHeight(forNormalizedOffset: targetOffset))
        }
    }

    /// 读取滚动层显示态，让 SwiftUI 硬裁剪与 UIKit Snap 在同一刷新帧保持一致。
    @objc
    private func displayLinkDidFire() {
        guard programmaticAnimator != nil,
              let scrollView,
              let presentationOffsetY = scrollView.layer.presentation()?.bounds.origin.y else {
            return
        }
        let normalizedOffset = normalizedOffsetY(
            contentOffsetY: presentationOffsetY,
            in: scrollView
        )
        publishRevealHeight(revealHeight(forNormalizedOffset: normalizedOffset))
    }

    /// 启动与屏幕刷新同步的高度观察，只在自动 Snap 期间驱动 SwiftUI 裁剪。
    private func startDisplayLink() {
        stopDisplayLink()
        let displayLink = CADisplayLink(target: self, selector: #selector(displayLinkDidFire))
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
    }

    /// 释放自动 Snap 的帧回调，避免页面稳定后继续触发 SwiftUI 更新。
    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// 中断自动移动时冻结显示层当前 offset，让下一次手势从真实视觉位置继续。
    private func cancelProgrammaticMovement(notify: Bool) {
        guard let animator = programmaticAnimator else {
            if notify {
                let completion = programmaticCompletion
                programmaticCompletion = nil
                completion?(false)
            }
            return
        }

        let presentationOffsetY = currentPresentedContentOffsetY()
        animator.stopAnimation(true)
        programmaticAnimator = nil
        stopDisplayLink()

        if let scrollView {
            isApplyingOffset = true
            UIView.performWithoutAnimation {
                scrollView.contentOffset = CGPoint(
                    x: scrollView.contentOffset.x,
                    y: presentationOffsetY
                )
                scrollView.layoutIfNeeded()
            }
            isApplyingOffset = false
            publishRevealHeight(from: scrollView)
        }

        let completion = programmaticCompletion
        programmaticCompletion = nil
        if notify {
            completion?(false)
        }
    }

    /// 在动画端点提交精确滚动位置并只调用一次完成回调。
    private func finishProgrammaticMovement(
        atNormalizedOffset targetOffset: CGFloat,
        didExecute: Bool
    ) {
        programmaticAnimator = nil
        stopDisplayLink()
        if let scrollView {
            applyNormalizedOffset(targetOffset, notify: true, in: scrollView)
        }
        let completion = programmaticCompletion
        programmaticCompletion = nil
        completion?(didExecute)
    }

    /// 返回滚动层当前显示态 offset；无活动显示层时回退到模型层位置。
    private func currentPresentedContentOffsetY() -> CGFloat {
        guard let scrollView else { return 0 }
        return scrollView.layer.presentation()?.bounds.origin.y
            ?? scrollView.contentOffset.y
    }

    /// 将 UIKit 原始 offset 转换为与 SwiftUI ScrollGeometry 一致的顶部规范化坐标。
    private func normalizedOffsetY(in scrollView: UIScrollView) -> CGFloat {
        normalizedOffsetY(contentOffsetY: scrollView.contentOffset.y, in: scrollView)
    }

    /// 使用指定显示层 offset 计算规范化坐标，供 Snap 的逐帧读取复用。
    private func normalizedOffsetY(
        contentOffsetY: CGFloat,
        in scrollView: UIScrollView
    ) -> CGFloat {
        contentOffsetY + scrollView.adjustedContentInset.top
    }

    /// 把规范化轨道位置转换回 UIScrollView 模型层 contentOffset。
    private func contentOffsetY(
        forNormalizedOffset offset: CGFloat,
        in scrollView: UIScrollView
    ) -> CGFloat {
        offset - scrollView.adjustedContentInset.top
    }

    /// 轨道从 52pt 滚向 0pt 时按相同距离揭示搜索框，超出两端继续交给系统边界反馈。
    private func revealHeight(forNormalizedOffset offset: CGFloat) -> CGFloat {
        clampedRevealHeight(maximumRevealHeight - offset)
    }

    /// 发布当前滚动模型对应的真实高度；相同高度不重复写入 SwiftUI 状态。
    private func publishRevealHeight(from scrollView: UIScrollView) {
        publishRevealHeight(
            isPinned
                ? maximumRevealHeight
                : revealHeight(forNormalizedOffset: normalizedOffsetY(in: scrollView))
        )
    }

    /// 仅在高度确实变化时通知 SwiftUI，减少拖动与显示链路中的无效重绘。
    private func publishRevealHeight(_ height: CGFloat) {
        let nextHeight = clampedRevealHeight(height)
        guard abs(revealHeight - nextHeight)
                >= NoteScrollBoundaryMetrics.geometryEpsilon else {
            return
        }
        revealHeight = nextHeight
        onRevealHeightChange?(nextHeight)
    }

    /// 把任意高度约束到搜索抽屉允许的可见区间。
    private func clampedRevealHeight(_ height: CGFloat) -> CGFloat {
        min(max(height, 0), maximumRevealHeight)
    }

    /// 把投影位置约束到透明轨道的两个 Snap 端点之间。
    private func clampedNormalizedOffset(_ offset: CGFloat) -> CGFloat {
        min(max(offset, 0), maximumRevealHeight)
    }

    /// 剩余距离决定短 Snap 时长，避免小距离收口仍拖出完整长尾。
    private func movementDuration(distance: CGFloat) -> TimeInterval {
        let progress = maximumRevealHeight > 0
            ? min(distance / maximumRevealHeight, 1)
            : 0
        return NoteScrollBoundaryMetrics.minimumDuration
            + (NoteScrollBoundaryMetrics.maximumDuration - NoteScrollBoundaryMetrics.minimumDuration)
                * progress
    }

    /// 只继承朝向目标的松手速度，反向速度由临界阻尼自然收口，避免先逆行再回弹。
    private func normalizedInitialVelocity(
        panVelocityY: CGFloat?,
        remainingContentOffsetDistance: CGFloat
    ) -> CGFloat {
        guard let panVelocityY,
              abs(remainingContentOffsetDistance) > NoteScrollBoundaryMetrics.offsetEpsilon else {
            return 0
        }

        let contentOffsetVelocity = -panVelocityY
        guard contentOffsetVelocity * remainingContentOffsetDistance > 0 else {
            return 0
        }
        return min(
            abs(contentOffsetVelocity / remainingContentOffsetDistance),
            NoteScrollBoundaryMetrics.maximumNormalizedInitialVelocity
        )
    }
}

/// 页面私有滚动容差与 Snap 参数；不修改任何公共动效或设计令牌。
private enum NoteScrollBoundaryMetrics {
    static let boundaryEpsilon: CGFloat = 0.5
    static let offsetEpsilon: CGFloat = 0.5
    static let geometryEpsilon: CGFloat = 0.25
    static let projectionHorizon: CGFloat = 0.12
    static let minimumDuration: TimeInterval = 0.18
    static let maximumDuration: TimeInterval = 0.22
    static let settleDampingRatio: CGFloat = 1
    static let maximumNormalizedInitialVelocity: CGFloat = 1.5
}
