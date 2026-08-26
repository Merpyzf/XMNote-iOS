/**
 * [INPUT]: 依赖 SwiftUI/UIKit 导航控制器与系统返回手势，接收是否允许返回及阻断回调
 * [OUTPUT]: 对外提供 View.navigationPopGuard(canPop:onBlockedAttempt:)
 * [POS]: UIComponents/Navigation 的 SwiftUI/UIKit 窄桥接，恢复自定义返回按钮页面的系统手势并拦截脏表单返回
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

extension View {
    /// 为自定义返回按钮页面恢复侧滑返回，并在需要时阻断返回动作。
    func navigationPopGuard(
        canPop: Bool,
        onBlockedAttempt: @escaping () -> Void
    ) -> some View {
        background(
            NavigationPopGuardBridge(
                canPop: canPop,
                onBlockedAttempt: onBlockedAttempt
            )
        )
    }
}

/// 通过 UIKit 导航桥接恢复自定义返回按钮页面的系统返回手势，并统一拦截脏表单返回。
private struct NavigationPopGuardBridge: UIViewControllerRepresentable {
    let canPop: Bool
    let onBlockedAttempt: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onBlockedAttempt: onBlockedAttempt)
    }

    func makeUIViewController(context: Context) -> BridgeViewController {
        let controller = BridgeViewController()
        controller.onNavigationContextUpdated = { [weak controller] in
            guard let controller else { return }
            context.coordinator.attachIfNeeded(to: controller)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: BridgeViewController, context: Context) {
        context.coordinator.canPop = canPop
        context.coordinator.onBlockedAttempt = onBlockedAttempt
        uiViewController.onNavigationContextUpdated = { [weak uiViewController] in
            guard let uiViewController else { return }
            context.coordinator.attachIfNeeded(to: uiViewController)
        }
        context.coordinator.attachIfNeeded(to: uiViewController)
    }

    static func dismantleUIViewController(_ uiViewController: BridgeViewController, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class BridgeViewController: UIViewController {
        var onNavigationContextUpdated: (() -> Void)?

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            onNavigationContextUpdated?()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            onNavigationContextUpdated?()
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var canPop = true
        var onBlockedAttempt: () -> Void

        private var attachmentGeneration: UInt64 = 0
        private weak var navigationController: UINavigationController?
        private weak var edgePopGestureRecognizer: UIGestureRecognizer?
        @available(iOS 26.0, *)
        private weak var contentPopGestureRecognizer: UIGestureRecognizer?

        init(onBlockedAttempt: @escaping () -> Void) {
            self.onBlockedAttempt = onBlockedAttempt
        }

        func attachIfNeeded(to viewController: UIViewController) {
            guard let navigationController = viewController.navigationController else {
                let generation = attachmentGeneration
                DispatchQueue.main.async { [weak self, weak viewController] in
                    guard let self, let viewController else { return }
                    guard self.attachmentGeneration == generation else { return }
                    self.attachIfNeeded(to: viewController)
                }
                return
            }

            if self.navigationController !== navigationController {
                detach()
                self.navigationController = navigationController
                installGestures(on: navigationController)
            } else {
                edgePopGestureRecognizer?.isEnabled = true
                if #available(iOS 26.0, *) {
                    contentPopGestureRecognizer?.isEnabled = true
                }
            }
        }

        func detach() {
            attachmentGeneration &+= 1
            edgePopGestureRecognizer?.delegate = nil
            edgePopGestureRecognizer?.isEnabled = true

            if #available(iOS 26.0, *) {
                contentPopGestureRecognizer?.delegate = nil
                contentPopGestureRecognizer?.isEnabled = true
            }

            navigationController = nil
            edgePopGestureRecognizer = nil
            if #available(iOS 26.0, *) {
                contentPopGestureRecognizer = nil
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            let allowsPop = canPop && (navigationController?.viewControllers.count ?? 0) > 1
            guard !allowsPop else { return true }

            DispatchQueue.main.async { [onBlockedAttempt] in
                onBlockedAttempt()
            }
            return false
        }

        private func installGestures(on navigationController: UINavigationController) {
            edgePopGestureRecognizer = navigationController.interactivePopGestureRecognizer
            edgePopGestureRecognizer?.delegate = self
            edgePopGestureRecognizer?.isEnabled = true

            if #available(iOS 26.0, *) {
                contentPopGestureRecognizer = navigationController.interactiveContentPopGestureRecognizer
                contentPopGestureRecognizer?.delegate = self
                contentPopGestureRecognizer?.isEnabled = true
            }
        }
    }
}
