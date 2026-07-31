#if DEBUG
import SwiftUI
import UIKit

/**
 * [INPUT]: 依赖 UIKit UIViewController.Transition.zoom、UIHostingController 与 SwiftUI UIViewControllerRepresentable
 * [OUTPUT]: 对外提供 AppleMusicTransitionLabUIKitZoomBridge（稳定承载 SwiftUI Accessory 并执行系统视觉全屏 Zoom）
 * [POS]: Apple Music 转场实验的 Debug 专用窄桥接，只接管来源视图所有权和 UIKit 呈现生命周期
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 让 UIKit 直接拥有完整 SwiftUI 来源像素，并从该稳定 UIView 呈现全屏目标。
@MainActor
struct AppleMusicTransitionLabUIKitZoomBridge<Source: View, Destination: View>: UIViewControllerRepresentable {
    typealias SourceBuilder = (@escaping () -> Void) -> Source
    typealias DestinationBuilder = (@escaping () -> Void) -> Destination

    let sourceID: AnyHashable
    let surfaceColor: UIColor
    let sourceBuilder: SourceBuilder
    let destinationBuilder: DestinationBuilder

    init(
        sourceID: AnyHashable,
        surfaceColor: UIColor,
        @ViewBuilder source: @escaping SourceBuilder,
        @ViewBuilder destination: @escaping DestinationBuilder
    ) {
        self.sourceID = sourceID
        self.surfaceColor = surfaceColor
        sourceBuilder = source
        destinationBuilder = destination
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(configuration: self)
    }

    func makeUIViewController(context: Context) -> AppleMusicTransitionLabSourceController<Source> {
        let coordinator = context.coordinator
        let controller = AppleMusicTransitionLabSourceController(
            rootView: sourceBuilder { [weak coordinator] in
                coordinator?.presentDestination()
            }
        )
        coordinator.connect(sourceController: controller)
        return controller
    }

    func updateUIViewController(
        _ uiViewController: AppleMusicTransitionLabSourceController<Source>,
        context: Context
    ) {
        let coordinator = context.coordinator
        coordinator.update(configuration: self)
        uiViewController.update(
            rootView: sourceBuilder { [weak coordinator] in
                coordinator?.presentDestination()
            }
        )
        coordinator.connect(sourceController: uiViewController)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiViewController: AppleMusicTransitionLabSourceController<Source>,
        context: Context
    ) -> CGSize? {
        uiViewController.sizeThatFits(proposal)
    }

    static func dismantleUIViewController(
        _ uiViewController: AppleMusicTransitionLabSourceController<Source>,
        coordinator: Coordinator
    ) {
        coordinator.dismantle(sourceController: uiViewController)
    }

    /// 单次实验呈现的 owner；来源、目标与背景恢复都在同一生命周期内收口。
    @MainActor
    final class Coordinator {
        private enum Phase {
            case idle
            case presenting
            case presented
            case dismissing
        }

        private var configuration: AppleMusicTransitionLabUIKitZoomBridge
        private let sourceRegistry = AppleMusicTransitionLabSourceRegistry()
        private weak var sourceController: AppleMusicTransitionLabSourceController<Source>?
        private weak var presentedController: AppleMusicTransitionLabDestinationController<Destination>?
        private weak var appearanceOwner: UIViewController?
        private var previousBackgroundColor: UIColor?
        private var previousIsOpaque = false
        private var hasSavedAppearance = false
        private var phase: Phase = .idle
        private var presentationID: UUID?
        private var capturedSourceFrameInWindow: CGRect?

        init(configuration: AppleMusicTransitionLabUIKitZoomBridge) {
            self.configuration = configuration
        }

        func update(configuration: AppleMusicTransitionLabUIKitZoomBridge) {
            self.configuration = configuration
        }

        func connect(sourceController: AppleMusicTransitionLabSourceController<Source>) {
            self.sourceController = sourceController
            sourceController.loadViewIfNeeded()
            sourceRegistry.register(
                sourceController.transitionSourceView,
                for: configuration.sourceID
            )
        }

        func presentDestination() {
            guard phase == .idle,
                  presentedController == nil,
                  let sourceController,
                  let presenter = topViewController(in: sourceController.view.window),
                  presenter.presentedViewController == nil else {
                AppleMusicTransitionLabLogger.event(
                    "UIKit ignored duplicate or unavailable presentation"
                )
                return
            }

            let currentPresentationID = UUID()
            let destination = configuration.destinationBuilder { [weak self] in
                self?.dismissDestination()
            }
            let target = AppleMusicTransitionLabDestinationController(rootView: destination)
            target.modalPresentationStyle = .overFullScreen
            target.modalPresentationCapturesStatusBarAppearance = true
            target.loadViewIfNeeded()
            target.view.backgroundColor = configuration.surfaceColor
            target.view.isOpaque = true
            target.onDismissalWillBegin = { [weak self, weak target] isInteractive in
                guard let self, let target else { return }
                self.prepareForDismissal(
                    target: target,
                    presentationID: currentPresentationID,
                    isInteractive: isInteractive
                )
            }
            target.onDismissalTransitionFinished = { [weak self, weak target] isCancelled in
                guard let self, let target else { return }
                self.dismissalTransitionFinished(
                    target: target,
                    presentationID: currentPresentationID,
                    isCancelled: isCancelled
                )
            }
            target.onDetachedAfterDismissal = { [weak self, weak target] in
                guard let self, let target else { return }
                self.finishDismissal(
                    target: target,
                    presentationID: currentPresentationID
                )
            }

            saveAndApplyOpaquePresenterSurface(to: presenter)
            capturedSourceFrameInWindow = sourceRegistry
                .sourceView(for: configuration.sourceID)
                .map { $0.convert($0.bounds, to: $0.window) }
            configureStableTransition(for: target)

            phase = .presenting
            presentationID = currentPresentationID
            presentedController = target
            AppleMusicTransitionLabLogger.event(
                "UIKit present Over Full Screen; presenter=\(String(describing: type(of: presenter)))"
            )
            presenter.present(target, animated: true) { [weak self, weak target] in
                guard let self,
                      let target,
                      self.presentationID == currentPresentationID,
                      self.presentedController === target else {
                    return
                }
                if self.phase == .presenting {
                    self.phase = .presented
                    AppleMusicTransitionLabLogger.event("UIKit presentation completed")
                }
            }
        }

        func dismantle(sourceController: AppleMusicTransitionLabSourceController<Source>) {
            sourceRegistry.unregister(
                configuration.sourceID,
                matching: sourceController.transitionSourceView
            )
            guard self.sourceController === sourceController else { return }
            self.sourceController = nil

            if let target = presentedController {
                let id = presentationID
                target.dismiss(animated: false) { [weak self, weak target] in
                    guard let self, let target, let id else { return }
                    self.finishDismissal(target: target, presentationID: id)
                }
            } else {
                restorePresenterAppearance()
                resetPresentationState()
            }
        }

        private func dismissDestination() {
            guard let target = presentedController,
                  let presentationID,
                  phase == .presenting || phase == .presented else {
                return
            }

            phase = .dismissing
            AppleMusicTransitionLabLogger.event("UIKit programmatic dismissal requested")
            target.dismiss(animated: true) { [weak self, weak target] in
                guard let self, let target else { return }
                self.finishDismissal(
                    target: target,
                    presentationID: presentationID
                )
            }
        }

        private func prepareForDismissal(
            target: AppleMusicTransitionLabDestinationController<Destination>,
            presentationID: UUID,
            isInteractive: Bool
        ) {
            guard self.presentationID == presentationID,
                  presentedController === target else {
                return
            }
            if phase != .dismissing {
                phase = .dismissing
                AppleMusicTransitionLabLogger.event(
                    isInteractive
                        ? "UIKit interactive dismissal began with stable zoom"
                        : "UIKit external noninteractive dismissal began with stable zoom"
                )
            }
        }

        private func dismissalTransitionFinished(
            target: AppleMusicTransitionLabDestinationController<Destination>,
            presentationID: UUID,
            isCancelled: Bool
        ) {
            guard self.presentationID == presentationID,
                  presentedController === target else {
                return
            }
            if isCancelled {
                phase = .presented
                AppleMusicTransitionLabLogger.event("UIKit interactive dismissal cancelled")
            } else {
                finishDismissal(target: target, presentationID: presentationID)
            }
        }

        private func configureStableTransition(for target: UIViewController) {
            let source = sourceRegistry.sourceView(for: configuration.sourceID)
            let shouldCrossFade = UIAccessibility.isReduceMotionEnabled ||
                UIAccessibility.prefersCrossFadeTransitions ||
                source == nil

            if shouldCrossFade {
                target.preferredTransition = .crossDissolve
                AppleMusicTransitionLabLogger.event(
                    "UIKit presentation and dismissal use cross dissolve; reduceMotion=\(UIAccessibility.isReduceMotionEnabled), prefersCrossFade=\(UIAccessibility.prefersCrossFadeTransitions), sourceAvailable=\(source != nil)"
                )
                return
            }

            let options = UIViewController.Transition.ZoomOptions()
            options.interactiveDismissShouldBegin = { context in
                AppleMusicTransitionLabLogger.event(
                    "UIKit interactive dismissal decision; willBegin=\(context.willBegin), location=\(NSCoder.string(for: context.location)), velocity=(\(context.velocity.dx), \(context.velocity.dy))"
                )
                return context.willBegin
            }
            target.preferredTransition = .zoom(options: options) { [weak self] context in
                guard let self else { return nil }
                let view = self.sourceRegistry.sourceView(for: self.configuration.sourceID)
                self.logSourceProvider(view: view, context: context)
                return view
            }
            AppleMusicTransitionLabLogger.event(
                "UIKit presentation and dismissal share one stable system zoom"
            )
        }

        private func logSourceProvider(
            view: UIView?,
            context: UIViewController.Transition.ZoomSourceViewProviderContext
        ) {
            let rectDescription: String
            let driftDescription: String
            if let view {
                let rect = view.convert(view.bounds, to: view.window)
                rectDescription = NSCoder.string(for: rect)
                if let capturedSourceFrameInWindow {
                    driftDescription = String(
                        format: "delta=(%.2f, %.2f, %.2f, %.2f)",
                        rect.minX - capturedSourceFrameInWindow.minX,
                        rect.minY - capturedSourceFrameInWindow.minY,
                        rect.width - capturedSourceFrameInWindow.width,
                        rect.height - capturedSourceFrameInWindow.height
                    )
                } else {
                    driftDescription = "delta=unavailable"
                }
            } else {
                rectDescription = "unavailable"
                driftDescription = "delta=unavailable"
            }
            AppleMusicTransitionLabLogger.event(
                "UIKit source provider; rect=\(rectDescription), \(driftDescription), transform=\(String(describing: view?.transform)), windowAttached=\(view?.window != nil), source=\(String(describing: type(of: context.sourceViewController))), zoomed=\(String(describing: type(of: context.zoomedViewController)))"
            )
        }

        private func finishDismissal(
            target: AppleMusicTransitionLabDestinationController<Destination>,
            presentationID: UUID
        ) {
            guard self.presentationID == presentationID,
                  presentedController === target else {
                return
            }
            AppleMusicTransitionLabLogger.event("UIKit dismissal completed")
            restorePresenterAppearance()
            resetPresentationState()
        }

        private func saveAndApplyOpaquePresenterSurface(to presenter: UIViewController) {
            presenter.loadViewIfNeeded()
            appearanceOwner = presenter
            previousBackgroundColor = presenter.view.backgroundColor
            previousIsOpaque = presenter.view.isOpaque
            hasSavedAppearance = true
            presenter.view.backgroundColor = configuration.surfaceColor
            presenter.view.isOpaque = true
        }

        private func restorePresenterAppearance() {
            guard hasSavedAppearance else { return }
            appearanceOwner?.view.backgroundColor = previousBackgroundColor
            appearanceOwner?.view.isOpaque = previousIsOpaque
            appearanceOwner = nil
            previousBackgroundColor = nil
            previousIsOpaque = false
            hasSavedAppearance = false
        }

        private func resetPresentationState() {
            presentedController = nil
            presentationID = nil
            capturedSourceFrameInWindow = nil
            phase = .idle
        }

        private func topViewController(in window: UIWindow?) -> UIViewController? {
            guard let root = window?.rootViewController else { return nil }
            return topViewController(from: root)
        }

        private func topViewController(from root: UIViewController) -> UIViewController {
            if let presented = root.presentedViewController {
                return topViewController(from: presented)
            }
            if let navigationController = root as? UINavigationController,
               let visible = navigationController.visibleViewController {
                return topViewController(from: visible)
            }
            if let tabBarController = root as? UITabBarController,
               let selected = tabBarController.selectedViewController {
                return topViewController(from: selected)
            }
            return root
        }
    }
}

/// 用一个不会随 SwiftUI placement 更新而替换的 UIViewController 持有完整 Accessory 像素。
@MainActor
final class AppleMusicTransitionLabSourceController<Content: View>: UIViewController {
    private let hostingController: UIHostingController<Content>

    var transitionSourceView: UIView {
        hostingController.view
    }

    init(rootView: Content) {
        hostingController = UIHostingController(rootView: rootView)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let rootView = UIView()
        rootView.backgroundColor = .clear
        rootView.isOpaque = false
        view = rootView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(hostingController)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        hostingController.view.backgroundColor = .clear
        hostingController.view.isOpaque = false
        view.addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        hostingController.didMove(toParent: self)
    }

    func update(rootView: Content) {
        hostingController.rootView = rootView
    }

    func sizeThatFits(_ proposal: ProposedViewSize) -> CGSize {
        let maximumSize = CGSize(
            width: proposal.width ?? UIView.layoutFittingExpandedSize.width,
            height: proposal.height ?? UIView.layoutFittingExpandedSize.height
        )
        return hostingController.sizeThatFits(in: maximumSize)
    }
}

/// 观察系统交互式退场的完成/取消结果，避免把取消手势误判成已关闭。
@MainActor
private final class AppleMusicTransitionLabDestinationController<Content: View>: UIHostingController<Content> {
    var onDismissalWillBegin: ((Bool) -> Void)?
    var onDismissalTransitionFinished: ((Bool) -> Void)?
    var onDetachedAfterDismissal: (() -> Void)?
    private var isObservingDismissal = false

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard !isObservingDismissal else { return }
        isObservingDismissal = true
        onDismissalWillBegin?(transitionCoordinator?.isInteractive == true)

        guard let transitionCoordinator else {
            isObservingDismissal = false
            return
        }
        transitionCoordinator.animate(alongsideTransition: nil) { [weak self] context in
            guard let self else { return }
            self.isObservingDismissal = false
            self.onDismissalTransitionFinished?(context.isCancelled)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isObservingDismissal = false
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if presentingViewController == nil {
            onDetachedAfterDismissal?()
        }
    }
}

/// provider 每次按稳定 ID 查询当前来源，避免闭包捕获过期的 UIView。
@MainActor
private final class AppleMusicTransitionLabSourceRegistry {
    private final class WeakView {
        weak var value: UIView?

        init(_ value: UIView) {
            self.value = value
        }
    }

    private var sources: [AnyHashable: WeakView] = [:]

    func register(_ view: UIView, for sourceID: AnyHashable) {
        sources[sourceID] = WeakView(view)
    }

    func unregister(_ sourceID: AnyHashable, matching view: UIView) {
        guard sources[sourceID]?.value === view else { return }
        sources[sourceID] = nil
    }

    func sourceView(for sourceID: AnyHashable) -> UIView? {
        guard let view = sources[sourceID]?.value,
              view.window != nil,
              !view.isHidden,
              view.alpha > 0.001,
              view.bounds.width > 0,
              view.bounds.height > 0 else {
            return nil
        }
        return view
    }
}
#endif
