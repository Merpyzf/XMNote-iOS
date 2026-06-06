/**
 * [INPUT]: 依赖 UIKit 键盘 frame 通知、承载视图坐标系与 UIScrollView adjusted/content inset，计算集合视图需要额外避让的软件键盘高度
 * [OUTPUT]: 对外提供 BookshelfCollectionKeyboardAvoidanceCoordinator，供 Book 模块页面私有 UICollectionView host 统一处理键盘避让、动画参数与自定义 bottom inset 写入
 * [POS]: Book 模块页面私有键盘避让协调器，被默认书架、聚合维度与二级书籍列表集合承载层复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import UIKit

/// 统一把软件键盘与集合视图的重叠高度转换成 UIScrollView 自定义 bottom inset。
final class BookshelfCollectionKeyboardAvoidanceCoordinator {
    struct AnimationContext {
        let duration: TimeInterval
        let options: UIView.AnimationOptions

        static let immediate = AnimationContext(
            duration: 0,
            options: [.beginFromCurrentState, .allowUserInteraction]
        )

        var isAnimated: Bool {
            duration > 0.01
        }
    }

    private weak var hostView: UIView?
    private weak var scrollView: UIScrollView?
    private let onInsetChange: (CGFloat, AnimationContext) -> Void
    private var observers: [NSObjectProtocol] = []
    private var keyboardFrameInScreen: CGRect?
    private var currentInset: CGFloat = 0

    /// 绑定承载视图与滚动视图；回调只报告需要写入 contentInset 的自定义键盘避让部分。
    init(
        hostView: UIView,
        scrollView: UIScrollView,
        onInsetChange: @escaping (CGFloat, AnimationContext) -> Void
    ) {
        self.hostView = hostView
        self.scrollView = scrollView
        self.onInsetChange = onInsetChange
    }

    deinit {
        invalidate()
    }

    /// 开始监听键盘 frame 变化。重复调用是安全的，适合在 UIKit host 初始化后立即接入。
    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(
                forName: UIResponder.keyboardWillChangeFrameNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleKeyboardFrameNotification(notification)
            }
        )
        observers.append(
            center.addObserver(
                forName: UIResponder.keyboardWillHideNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleKeyboardFrameNotification(notification)
            }
        )
    }

    /// 停止监听，避免集合 host 被销毁后继续响应系统通知。
    func invalidate() {
        let center = NotificationCenter.default
        for observer in observers {
            center.removeObserver(observer)
        }
        observers.removeAll()
    }

    /// 承载视图 bounds、window 或系统 safe area 变化后重新计算避让高度。
    func recalculate(animated: Bool) {
        applyResolvedInset(
            animation: animated ? defaultAnimationContext : .immediate,
            force: false
        )
    }

    /// 清空当前键盘避让状态，用于 host 复用或离开窗口时回到稳定基线。
    func reset() {
        keyboardFrameInScreen = nil
        setInset(0, animation: .immediate, force: true)
    }

    private var defaultAnimationContext: AnimationContext {
        AnimationContext(
            duration: 0.25,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut]
        )
    }

    private func handleKeyboardFrameNotification(_ notification: Notification) {
        let userInfo = notification.userInfo ?? [:]
        keyboardFrameInScreen = (userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        applyResolvedInset(
            animation: animationContext(from: userInfo),
            force: false
        )
    }

    private func animationContext(from userInfo: [AnyHashable: Any]) -> AnimationContext {
        let duration = (userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        let curveRawValue = (userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue
            ?? UInt(UIView.AnimationCurve.easeInOut.rawValue)
        let curveOptions = UIView.AnimationOptions(rawValue: curveRawValue << 16)
        return AnimationContext(
            duration: duration,
            options: [
                .beginFromCurrentState,
                .allowUserInteraction,
                curveOptions
            ]
        )
    }

    private func applyResolvedInset(animation: AnimationContext, force: Bool) {
        setInset(resolvedCustomKeyboardInset(), animation: animation, force: force)
    }

    private func setInset(_ inset: CGFloat, animation: AnimationContext, force: Bool) {
        let roundedInset = max(0, ceil(inset))
        guard force || abs(roundedInset - currentInset) > 0.5 else { return }
        currentInset = roundedInset
        onInsetChange(roundedInset, animation)
    }

    private func resolvedCustomKeyboardInset() -> CGFloat {
        guard let hostView,
              let scrollView,
              let window = hostView.window,
              let keyboardFrameInScreen,
              !keyboardFrameInScreen.isNull,
              !keyboardFrameInScreen.isEmpty,
              hostView.bounds.height > 0 else {
            return 0
        }

        let keyboardFrameInWindow = window.convert(keyboardFrameInScreen, from: window.screen.coordinateSpace)
        let keyboardFrameInHost = hostView.convert(keyboardFrameInWindow, from: window)
        let overlapHeight = hostView.bounds.intersection(keyboardFrameInHost).height
        guard overlapHeight > 0.5 else { return 0 }

        let systemAdjustedBottomInset = max(
            0,
            scrollView.adjustedContentInset.bottom - scrollView.contentInset.bottom
        )
        return max(0, overlapHeight - systemAdjustedBottomInset)
    }
}
