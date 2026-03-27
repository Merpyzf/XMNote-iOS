/**
 * [INPUT]: 依赖 xmnote/Utilities/DesignTokens.swift 的颜色、间距、圆角设计令牌
 * [OUTPUT]: 对外提供 CardContainer（支持圆角/描边颜色可配置）、EmptyStateView、HomeTopHeaderGradient 三个通用表层组件
 * [POS]: UIComponents/Foundation 的基础表层组件集合，被各业务页面直接复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

// MARK: - Card Container

/// 内容卡片容器，对应 Android 端的 ContentBox
/// 默认仅提供背景与圆角，按需显式开启描边。
struct CardContainer<Content: View>: View {
    let cornerRadius: CGFloat
    let showsBorder: Bool
    let borderColor: Color
    let content: Content

    /// 注入圆角、边框与内容闭包，组装基础容器外观。
    init(
        cornerRadius: CGFloat = CornerRadius.blockLarge,
        showsBorder: Bool = false,
        borderColor: Color = .surfaceBorderStrong,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.showsBorder = showsBorder
        self.borderColor = borderColor
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                if showsBorder {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(borderColor, lineWidth: CardStyle.borderWidth)
                }
            }
    }
}

// MARK: - Empty State View

/// 通用占位视图，品牌绿图标 + 灰色文字
struct EmptyStateView: View {
    let icon: String
    let message: String

    var body: some View {
        VStack(spacing: Spacing.base) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(Color.brand.opacity(0.3))
            Text(message)
                .font(AppTypography.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Loading State View

/// 通用加载视图，支持轻量 inline 与卡片两种表达。
struct LoadingStateView: View {
    enum Style {
        case inline
        case card
    }

    let message: String?
    let style: Style

    init(_ message: String? = nil, style: Style = .inline) {
        self.message = message
        self.style = style
    }

    var body: some View {
        Group {
            switch style {
            case .inline:
                progressContent
            case .card:
                progressContent
                    .padding(Spacing.contentEdge)
                    .background(
                        Color.surfaceCard,
                        in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                    )
            }
        }
    }

    @ViewBuilder
    private var progressContent: some View {
        if let message, !message.isEmpty {
            ProgressView(message)
                .font(AppTypography.body)
        } else {
            ProgressView()
        }
    }
}

// MARK: - Home Header Gradient

/// 首页顶部氛围渐变背景，用于衬托顶部切换栏与首屏内容层次。
struct HomeTopHeaderGradient: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(light: Color.brand.opacity(0.2), dark: Color(hex: 0x1E2A25)),
                Color.surfacePage.opacity(0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 150)
        .ignoresSafeArea(edges: .top)
    }
}

// MARK: - Navigation Pop Guard

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

    /// 封装dismantleUIViewController对应的业务步骤，确保调用方可以稳定复用该能力。
    static func dismantleUIViewController(_ uiViewController: BridgeViewController, coordinator: Coordinator) {
        coordinator.detach()
    }

    /// BridgeViewController 负责当前场景的class定义，明确职责边界并组织相关能力。
    final class BridgeViewController: UIViewController {
        var onNavigationContextUpdated: (() -> Void)?

        /// 封装viewWillAppear对应的业务步骤，确保调用方可以稳定复用该能力。
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            onNavigationContextUpdated?()
        }

        /// 封装viewDidAppear对应的业务步骤，确保调用方可以稳定复用该能力。
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            onNavigationContextUpdated?()
        }
    }

    /// Coordinator 负责当前场景的class定义，明确职责边界并组织相关能力。
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var canPop = true
        var onBlockedAttempt: () -> Void

        private weak var navigationController: UINavigationController?
        private weak var edgePopGestureRecognizer: UIGestureRecognizer?
        @available(iOS 26.0, *)
        private weak var contentPopGestureRecognizer: UIGestureRecognizer?

        init(onBlockedAttempt: @escaping () -> Void) {
            self.onBlockedAttempt = onBlockedAttempt
        }

        func attachIfNeeded(to viewController: UIViewController) {
            guard let navigationController = viewController.navigationController else {
                DispatchQueue.main.async { [weak self, weak viewController] in
                    guard let self, let viewController else { return }
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

        /// 封装installGestures对应的业务步骤，确保调用方可以稳定复用该能力。
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

#Preview("CardContainer") {
    ZStack {
        Color.surfacePage.ignoresSafeArea()
        CardContainer {
            VStack(spacing: Spacing.none) {
                Text("卡片内容示例")
                    .padding(Spacing.screenEdge)
            }
        }
        .padding(Spacing.screenEdge)
    }
}

#Preview("EmptyState") {
    EmptyStateView(icon: "book.pages", message: "暂无在读书籍")
}
