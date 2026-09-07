/**
 * [INPUT]: 依赖 UIKit UIScrollView/UIViewController 的系统滚动边缘观察 API 与 UIScrollEdgeEffect
 * [OUTPUT]: 对外提供 XMSystemScrollEdgeRegistration，统一维护 UIKit 主滚动视图的系统栏观察、soft 边缘样式与安全释放
 * [POS]: UIComponents/Navigation/ScrollEdge 的 UIKit 窄桥接；不绘制视觉层，不持有业务状态或页面布局策略
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import UIKit

/// 维护 UIKit 主滚动视图与最近页面控制器之间的系统栏观察关系。
@MainActor
final class XMSystemScrollEdgeRegistration {
    typealias UpdateTransaction = (_ systemUpdate: () -> Void) -> Void

    private let edges: UIRectEdge
    private weak var registeredScrollView: UIScrollView?
    private weak var registeredViewController: UIViewController?

    /// 创建只处理顶部、底部或双边缘的注册器；系统边缘样式固定为 soft。
    init(edges: UIRectEdge) {
        let supportedEdges = edges.intersection([.top, .bottom])
        precondition(!supportedEdges.isEmpty, "XMSystemScrollEdgeRegistration requires top or bottom edge")
        self.edges = supportedEdges
    }

    /// 幂等登记真实滚动主体；默认保持逻辑纵向位置，复杂列表可注入自己的稳定锚点事务。
    func update(
        scrollView: UIScrollView,
        transaction: UpdateTransaction? = nil
    ) {
        configureSystemEdgeEffects(on: scrollView)

        guard scrollView.window != nil,
              let viewController = nearestOwningViewController(from: scrollView) else {
            invalidate(transaction: transaction)
            return
        }

        let previousScrollView = registeredScrollView
        let previousViewController = registeredViewController
        let isChangingOwner = previousScrollView !== scrollView
            || previousViewController !== viewController
        let needsTopRegistration = edges.contains(.top)
            && viewController.contentScrollView(for: .top) !== scrollView
        let needsBottomRegistration = edges.contains(.bottom)
            && viewController.contentScrollView(for: .bottom) !== scrollView

        let needsPreviousCleanup = isChangingOwner
            && hasObservedEdge(
                scrollView: previousScrollView,
                viewController: previousViewController
            )
        let needsSystemUpdate = needsPreviousCleanup
            || needsTopRegistration
            || needsBottomRegistration

        guard needsSystemUpdate else {
            registeredScrollView = scrollView
            registeredViewController = viewController
            return
        }

        performSystemUpdate(on: scrollView, transaction: transaction) {
            if isChangingOwner {
                self.clearObservation(
                    scrollView: previousScrollView,
                    viewController: previousViewController
                )
            }
            if needsTopRegistration {
                viewController.setContentScrollView(scrollView, for: .top)
            }
            if needsBottomRegistration {
                viewController.setContentScrollView(scrollView, for: .bottom)
            }
        }
        registeredScrollView = scrollView
        registeredViewController = viewController
    }

    /// 仅解除仍由当前注册器持有的观察关系，避免误清理后续页面接管的滚动主体。
    func invalidate(transaction: UpdateTransaction? = nil) {
        let scrollView = registeredScrollView
        let viewController = registeredViewController
        registeredScrollView = nil
        registeredViewController = nil

        guard let scrollView,
              hasObservedEdge(scrollView: scrollView, viewController: viewController) else {
            return
        }

        performSystemUpdate(on: scrollView, transaction: transaction) {
            self.clearObservation(
                scrollView: scrollView,
                viewController: viewController
            )
        }
    }

    /// 为所选系统边缘设置统一 soft 过渡；未选边缘保持页面原有策略。
    private func configureSystemEdgeEffects(on scrollView: UIScrollView) {
        if edges.contains(.top) {
            scrollView.topEdgeEffect.isHidden = false
            scrollView.topEdgeEffect.style = .soft
        }
        if edges.contains(.bottom) {
            scrollView.bottomEdgeEffect.isHidden = false
            scrollView.bottomEdgeEffect.style = .soft
        }
    }

    /// 默认在系统重算安全区前后保持逻辑纵向位置，避免首次登记时内容发生跳动。
    private func performSystemUpdate(
        on scrollView: UIScrollView,
        transaction: UpdateTransaction?,
        update: () -> Void
    ) {
        if let transaction {
            transaction(update)
            return
        }

        let adjustedInsetBeforeUpdate = scrollView.adjustedContentInset
        let logicalOffsetY = scrollView.contentOffset.y + adjustedInsetBeforeUpdate.top
        update()
        scrollView.superview?.layoutIfNeeded()
        scrollView.layoutIfNeeded()

        guard scrollView.adjustedContentInset != adjustedInsetBeforeUpdate else { return }
        let minimumOffsetY = -scrollView.adjustedContentInset.top
        let maximumOffsetY = max(
            minimumOffsetY,
            scrollView.contentSize.height
                - scrollView.bounds.height
                + scrollView.adjustedContentInset.bottom
        )
        let restoredOffsetY = min(
            max(
                logicalOffsetY - scrollView.adjustedContentInset.top,
                minimumOffsetY
            ),
            maximumOffsetY
        )
        scrollView.setContentOffset(
            CGPoint(x: scrollView.contentOffset.x, y: restoredOffsetY),
            animated: false
        )
    }

    /// 判断指定控制器是否仍在任一目标边缘观察该滚动视图。
    private func hasObservedEdge(
        scrollView: UIScrollView?,
        viewController: UIViewController?
    ) -> Bool {
        guard let scrollView, let viewController else { return false }
        return (edges.contains(.top) && viewController.contentScrollView(for: .top) === scrollView)
            || (edges.contains(.bottom) && viewController.contentScrollView(for: .bottom) === scrollView)
    }

    /// 按对象身份清理选中边缘，保证控制器已移交给新页面时不发生误释放。
    private func clearObservation(
        scrollView: UIScrollView?,
        viewController: UIViewController?
    ) {
        guard let scrollView, let viewController else { return }
        if edges.contains(.top),
           viewController.contentScrollView(for: .top) === scrollView {
            viewController.setContentScrollView(nil, for: .top)
        }
        if edges.contains(.bottom),
           viewController.contentScrollView(for: .bottom) === scrollView {
            viewController.setContentScrollView(nil, for: .bottom)
        }
    }

    /// 沿响应链定位 SwiftUI hosting 或 UIKit 页面中最近的真实控制器 owner。
    private func nearestOwningViewController(from responder: UIResponder) -> UIViewController? {
        var currentResponder: UIResponder? = responder
        while let current = currentResponder {
            if let viewController = current as? UIViewController {
                return viewController
            }
            currentResponder = current.next
        }
        return nil
    }
}
