/**
 * [INPUT]: 接收已准备的真实源、目标表面与可选可信源快照
 * [OUTPUT]: 提供不依赖共享纸张端点的短淡变和可反向显示权交接
 * [POS]: NoteReviewCanvas 页面私有降级动效；不承担数据读取或业务模式提交
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import UIKit

/// 动画资源不足时保留导航结果；主 actor 管理一次淡变，取消不会调用旧完成闭包。
@MainActor
final class NoteReviewCanvasSurfaceDissolve {
    let animator: UIViewPropertyAnimator
    private let source: UIView
    private let target: UIView
    private let cover: UIView?
    private let sourceBackground: UIColor?
    private var isCancelled = false

    /// 目标内容必须事先就绪；快照不可用时直接淡变真实源，不再把快照作为切换前置条件。
    init(source: UIView, target: UIView, frozenSource: UIView?, container: UIView, below chrome: UIView,
         completion: @escaping (Bool) -> Void) {
        self.source = source
        self.target = target
        sourceBackground = source.backgroundColor
        let snapshot = frozenSource ?? source.snapshotView(afterScreenUpdates: false)
        cover = snapshot
        let reduced = UIAccessibility.isReduceMotionEnabled || UIAccessibility.prefersCrossFadeTransitions
        animator = UIViewPropertyAnimator(duration: reduced ? 0.12 : 0.18, curve: .easeInOut)
        if let snapshot {
            if frozenSource == nil { snapshot.frame = source.convert(source.bounds, to: container) }
            snapshot.backgroundColor = container.backgroundColor ?? source.backgroundColor
            snapshot.isUserInteractionEnabled = false
            snapshot.accessibilityElementsHidden = true
            container.insertSubview(snapshot, belowSubview: chrome)
            source.alpha = 0
        } else {
            container.insertSubview(source, belowSubview: chrome)
            source.backgroundColor = container.backgroundColor ?? source.backgroundColor
            source.alpha = 1
        }
        source.isUserInteractionEnabled = false
        target.isUserInteractionEnabled = false
        source.accessibilityElementsHidden = true
        target.accessibilityElementsHidden = true
        target.alpha = 1
        animator.addAnimations { (snapshot ?? source).alpha = 0 }
        animator.addCompletion { [weak self] position in
            guard let self, !isCancelled else { return }
            let reachedTarget = position == .end
            // Restore the settled live surface before removing its last trusted pixels.
            source.alpha = reachedTarget ? 0 : 1
            target.alpha = reachedTarget ? 1 : 0
            source.backgroundColor = self.sourceBackground
            completion(reachedTarget)
            snapshot?.removeFromSuperview()
        }
    }

    /// 反向沿正在显示的透明度继续，不重新生成画面或回到旧端点。
    func reverse(_ reversed: Bool) { animator.isReversed = reversed }

    /// 永久关闭或第三目标接管时取消回调；调用方负责保留当前混合画面并提交新的显示权。
    func cancel() {
        isCancelled = true
        if animator.state == .active { animator.stopAnimation(true) }
        cover?.removeFromSuperview()
        source.backgroundColor = sourceBackground
    }
}
