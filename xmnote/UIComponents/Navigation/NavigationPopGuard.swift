/**
 * [INPUT]: 依赖 SwiftUI/UIKit 导航控制器与系统返回手势，接收返回权限、手势开始、页面显示及阻断回调
 * [OUTPUT]: 对外提供兼容旧调用的 View.navigationPopGuard，并透出允许返回开始与 viewDidAppear 生命周期
 * [POS]: UIComponents/Navigation 的 SwiftUI/UIKit 窄桥接，恢复自定义返回按钮页面的系统手势并拦截脏表单返回
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

extension View {
    /// 为自定义返回按钮页面恢复系统返回手势，并协调退出准备与取消后的页面恢复。
    func navigationPopGuard(
        canPop: Bool,
        onAllowedPopStart: @escaping () -> Void = {},
        onDidAppear: @escaping () -> Void = {},
        onBlockedAttempt: @escaping () -> Void
    ) -> some View {
        background(
            NavigationPopGuardBridge(
                canPop: canPop,
                onAllowedPopStart: onAllowedPopStart,
                onDidAppear: onDidAppear,
                onBlockedAttempt: onBlockedAttempt
            )
        )
    }
}

/// 通过 UIKit 导航桥接恢复自定义返回按钮页面的系统返回手势，并统一拦截脏表单返回。
private struct NavigationPopGuardBridge: UIViewControllerRepresentable {
    let canPop: Bool
    let onAllowedPopStart: () -> Void
    let onDidAppear: () -> Void
    let onBlockedAttempt: () -> Void

    /// 创建持有最新生命周期与手势回调的导航协调器。
    func makeCoordinator() -> Coordinator {
        Coordinator(
            onAllowedPopStart: onAllowedPopStart,
            onDidAppear: onDidAppear,
            onBlockedAttempt: onBlockedAttempt
        )
    }

    /// 创建不参与布局的 UIKit 生命周期桥接控制器。
    func makeUIViewController(context: Context) -> BridgeViewController {
        let controller = BridgeViewController()
        controller.onNavigationContextUpdated = { [weak controller] in
            guard let controller else { return }
            context.coordinator.attachIfNeeded(to: controller)
        }
        controller.onDidAppear = {
            context.coordinator.notifyDidAppear()
        }
        return controller
    }

    /// 同步最新权限与回调，避免手势或页面重现时执行过期闭包。
    func updateUIViewController(_ uiViewController: BridgeViewController, context: Context) {
        context.coordinator.canPop = canPop
        context.coordinator.onAllowedPopStart = onAllowedPopStart
        context.coordinator.onDidAppear = onDidAppear
        context.coordinator.onBlockedAttempt = onBlockedAttempt
        uiViewController.onNavigationContextUpdated = { [weak uiViewController] in
            guard let uiViewController else { return }
            context.coordinator.attachIfNeeded(to: uiViewController)
        }
        uiViewController.onDidAppear = {
            context.coordinator.notifyDidAppear()
        }
        context.coordinator.attachIfNeeded(to: uiViewController)
    }

    /// 断开 UIKit 回调与手势代理，防止页面移除后继续通知 SwiftUI 状态。
    static func dismantleUIViewController(_ uiViewController: BridgeViewController, coordinator: Coordinator) {
        uiViewController.onNavigationContextUpdated = nil
        uiViewController.onDidAppear = nil
        coordinator.detach()
    }

    final class BridgeViewController: UIViewController {
        var onNavigationContextUpdated: (() -> Void)?
        var onDidAppear: (() -> Void)?

        /// 在页面即将可见时恢复当前导航控制器的手势代理。
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            onNavigationContextUpdated?()
        }

        /// 在页面完全可见后通知调用方，包括交互返回取消后的重现。
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            onNavigationContextUpdated?()
            onDidAppear?()
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var canPop = true
        var onAllowedPopStart: () -> Void
        var onDidAppear: () -> Void
        var onBlockedAttempt: () -> Void

        private var attachmentGeneration: UInt64 = 0
        private weak var navigationController: UINavigationController?
        private weak var edgePopGestureRecognizer: UIGestureRecognizer?
        @available(iOS 26.0, *)
        private weak var contentPopGestureRecognizer: UIGestureRecognizer?

        /// 保存手势与页面生命周期的可替换回调。
        init(
            onAllowedPopStart: @escaping () -> Void,
            onDidAppear: @escaping () -> Void,
            onBlockedAttempt: @escaping () -> Void
        ) {
            self.onAllowedPopStart = onAllowedPopStart
            self.onDidAppear = onDidAppear
            self.onBlockedAttempt = onBlockedAttempt
        }

        /// 将协调器安装到桥接页面当前所在的导航控制器。
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

        /// 移除当前手势代理，并使已排队的延迟安装失效。
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

        /// 在系统返回手势尝试开始时区分允许退出与脏状态阻断。
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard (navigationController?.viewControllers.count ?? 0) > 1 else {
                return false
            }

            guard canPop else {
                let generation = attachmentGeneration
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    guard self.attachmentGeneration == generation else { return }
                    self.onBlockedAttempt()
                }
                return false
            }

            onAllowedPopStart()
            return true
        }

        /// 转发桥接控制器的 `viewDidAppear` 事件给最新调用方。
        func notifyDidAppear() {
            onDidAppear()
        }

        /// 同时接管系统边缘返回与 iOS 26 内容区返回手势。
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
