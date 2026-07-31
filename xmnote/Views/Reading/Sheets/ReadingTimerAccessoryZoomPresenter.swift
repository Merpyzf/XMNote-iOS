import OSLog
import SwiftUI
import UIKit

/**
 * [INPUT]: 依赖 UIKit UIViewController.Transition.zoom、UIHostingController 与 SwiftUI UIViewControllerRepresentable，接收稳定来源 ID、计时呈现票据和类型化关闭回调
 * [OUTPUT]: 对外提供 ReadingTimerAccessoryZoomPresentationOwner、ReadingTimerAccessoryZoomPresenter 与关闭请求，以完整 Bottom Accessory 为来源呈现系统全屏 Zoom
 * [POS]: Reading 模块生产转场窄桥接；稳定 owner 归属 MainTabView，Representable 仅承载当前来源 UIView，不读写计时业务或自定义动画参数
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 把 MainTabView 已冻结的关闭原因传给 UIKit 呈现 owner，避免桥接层读取业务状态。
struct ReadingTimerAccessoryZoomDismissalRequest: Equatable {
    let presentationID: UUID
    let reason: ReadingTimerDismissReason
}

/// 只在调试构建记录生产桥接生命周期，不向用户界面叠加诊断信息。
private enum ReadingTimerAccessoryZoomLog {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.merpyzf.xmnote",
        category: "ReadingTimerAccessoryZoom"
    )

    /// 写入一次公开级调试事件，便于模拟器录屏与系统日志对齐。
    static func event(_ message: String) {
        #if DEBUG
        logger.info("\(message, privacy: .public)")
        #endif
    }
}

/// 跨 SwiftUI Accessory 重建保持稳定的 UIKit 呈现 owner，完整生命周期与 MainTabView 对齐。
@MainActor
final class ReadingTimerAccessoryZoomPresentationOwner {
    private enum Phase {
        case idle
        case presenting
        case presented
        case dismissing
    }

    private let sourceRegistry = ReadingTimerAccessoryZoomSourceRegistry()
    private weak var presentedController: UIViewController?
    private weak var appearanceOwner: UIViewController?
    private var previousBackgroundColor: UIColor?
    private var previousIsOpaque = false
    private var previousAccessibilityElementsHidden = false
    private var hasSavedAppearance = false
    private var activePresentationID: UUID?
    private var activeSourceID: AnyHashable?
    private var activeDismissalReason: ReadingTimerDismissReason?
    private var queuedDismissalReason: ReadingTimerDismissReason?
    private var onDismissalRequested: ((ReadingTimerDismissReason) -> Void)?
    private var onDismissalCompleted: ((ReadingTimerDismissReason) -> Void)?
    private var isInteractiveDismissEnabled = true
    private var phase: Phase = .idle

    /// 注册系统当前持有的完整 Accessory UIView；新来源会覆盖相同 record ID 的旧弱引用。
    func registerSource(_ view: UIView, sourceID: AnyHashable) {
        sourceRegistry.register(view, for: sourceID)
    }

    /// 只注销仍对应指定 UIView 的映射，避免旧 representable 卸载时移除新来源。
    func unregisterSource(_ view: UIView, sourceID: AnyHashable) {
        sourceRegistry.unregister(sourceID, matching: view)
    }

    /// 同步写入门闩与外部关闭请求；来源重建不会改变当前 presentation phase。
    func update(
        isInteractiveDismissEnabled: Bool,
        dismissalRequest: ReadingTimerAccessoryZoomDismissalRequest?
    ) {
        self.isInteractiveDismissEnabled = isInteractiveDismissEnabled
        guard let dismissalRequest,
              dismissalRequest.presentationID == activePresentationID else {
            return
        }
        requestProgrammaticDismissal(
            dismissalRequest.reason,
            presentationID: dismissalRequest.presentationID
        )
    }

    /// 解析最新来源并构建真实 SwiftUI 目标；所有泛型值在进入稳定 owner 后转换成闭包和 UIViewController。
    func present<Presentation: Identifiable, Destination: View>(
        sourceID: AnyHashable,
        sourceWindow: UIWindow?,
        surfaceColor: UIColor,
        preparePresentation: () -> Presentation?,
        onDismissalRequested: @escaping (Presentation, ReadingTimerDismissReason) -> Void,
        onDismissalCompleted: @escaping (Presentation, ReadingTimerDismissReason) -> Void,
        @ViewBuilder destinationBuilder: (
            Presentation,
            @escaping (ReadingTimerDismissReason) -> Void
        ) -> Destination
    ) where Presentation.ID == UUID {
        ReadingTimerAccessoryZoomLog.event("Accessory open requested")
        guard phase == .idle else {
            ReadingTimerAccessoryZoomLog.event("Open ignored: phase is not idle")
            return
        }
        guard presentedController == nil else {
            ReadingTimerAccessoryZoomLog.event("Open ignored: target is already retained")
            return
        }
        guard sourceRegistry.sourceView(for: sourceID) != nil else {
            ReadingTimerAccessoryZoomLog.event(
                "Open ignored: source view is not visible in a window"
            )
            return
        }
        guard let presenter = topViewController(in: sourceWindow) else {
            ReadingTimerAccessoryZoomLog.event("Open ignored: presenter unavailable")
            return
        }
        guard presenter.presentedViewController == nil else {
            ReadingTimerAccessoryZoomLog.event(
                "Open ignored: presenter already owns another modal"
            )
            return
        }
        guard let presentation = preparePresentation() else {
            ReadingTimerAccessoryZoomLog.event(
                "Open ignored: MainTabView rejected the presentation ticket"
            )
            return
        }

        let dismiss: (ReadingTimerDismissReason) -> Void = { [weak self] reason in
            self?.requestDismissalFromDestination(
                reason,
                presentationID: presentation.id
            )
        }
        let target = ReadingTimerAccessoryZoomDestinationController(
            rootView: destinationBuilder(presentation, dismiss)
        )
        target.modalPresentationStyle = .overFullScreen
        target.modalPresentationCapturesStatusBarAppearance = true
        target.loadViewIfNeeded()
        target.view.backgroundColor = surfaceColor
        target.view.isOpaque = true
        target.view.accessibilityViewIsModal = true
        target.onDismissalWillBegin = { [weak self, weak target] in
            guard let self, let target else { return }
            self.prepareForDismissal(
                target: target,
                presentationID: presentation.id
            )
        }
        target.onDismissalTransitionFinished = { [weak self, weak target] isCancelled in
            guard let self, let target else { return }
            self.dismissalTransitionFinished(
                target: target,
                presentationID: presentation.id,
                isCancelled: isCancelled
            )
        }
        target.onDetachedAfterDismissal = { [weak self, weak target] in
            guard let self, let target else { return }
            self.finishDismissal(
                target: target,
                presentationID: presentation.id
            )
        }

        saveAndApplyOpaquePresenterSurface(
            to: presenter,
            surfaceColor: surfaceColor
        )
        configureStableTransition(for: target, sourceID: sourceID)

        self.onDismissalRequested = { reason in
            onDismissalRequested(presentation, reason)
        }
        self.onDismissalCompleted = { reason in
            onDismissalCompleted(presentation, reason)
        }
        phase = .presenting
        activePresentationID = presentation.id
        activeSourceID = sourceID
        presentedController = target
        ReadingTimerAccessoryZoomLog.event("Presenting system overFullScreen zoom")
        presenter.present(target, animated: true) { [weak self, weak target] in
            guard let self,
                  let target,
                  self.activePresentationID == presentation.id,
                  self.presentedController === target else {
                return
            }
            if self.phase == .presenting {
                self.phase = .presented
                ReadingTimerAccessoryZoomLog.event("Presentation completed")
                self.performQueuedDismissalIfNeeded()
            }
        }
    }

    /// 把完整页内部关闭动作交给 MainTabView 冻结语义，再由同一 owner 立即启动系统退场。
    private func requestDismissalFromDestination(
        _ reason: ReadingTimerDismissReason,
        presentationID: UUID
    ) {
        guard activePresentationID == presentationID else { return }
        ReadingTimerAccessoryZoomLog.event(
            "Destination requested dismissal: \(String(describing: reason))"
        )
        onDismissalRequested?(reason)
        requestProgrammaticDismissal(reason, presentationID: presentationID)
    }

    /// 在呈现尚未完成时排队一次关闭；稳定后仍复用原始 preferredTransition。
    private func requestProgrammaticDismissal(
        _ reason: ReadingTimerDismissReason,
        presentationID: UUID
    ) {
        guard activePresentationID == presentationID else { return }
        switch phase {
        case .idle, .dismissing:
            return
        case .presenting:
            queuedDismissalReason = reason
        case .presented:
            beginProgrammaticDismissal(reason)
        }
    }

    /// 触发系统程序化退场，不在 viewWillDisappear 中重配转场或写业务状态。
    private func beginProgrammaticDismissal(
        _ reason: ReadingTimerDismissReason
    ) {
        guard phase == .presented,
              let target = presentedController,
              let presentationID = activePresentationID else {
            return
        }
        phase = .dismissing
        activeDismissalReason = reason
        ReadingTimerAccessoryZoomLog.event(
            "Beginning programmatic dismissal: \(String(describing: reason))"
        )
        target.dismiss(animated: true) { [weak self, weak target] in
            guard let self, let target else { return }
            self.finishDismissal(
                target: target,
                presentationID: presentationID
            )
        }
    }

    /// 观察系统交互开始但不冻结业务关闭原因，确保取消手势没有外部副作用。
    private func prepareForDismissal(
        target: UIViewController,
        presentationID: UUID
    ) {
        guard activePresentationID == presentationID,
              presentedController === target else {
            return
        }
        if phase == .presenting || phase == .presented {
            phase = .dismissing
            ReadingTimerAccessoryZoomLog.event("System dismissal lifecycle began")
        }
    }

    /// 根据 transition coordinator 的取消标记恢复页面，只有完成退场才通知业务层。
    private func dismissalTransitionFinished(
        target: UIViewController,
        presentationID: UUID,
        isCancelled: Bool
    ) {
        guard activePresentationID == presentationID,
              presentedController === target else {
            return
        }
        if isCancelled {
            phase = .presented
            activeDismissalReason = nil
            ReadingTimerAccessoryZoomLog.event("Interactive dismissal cancelled")
        } else {
            finishDismissal(target: target, presentationID: presentationID)
        }
    }

    /// 呈现完成后消费一次排队关闭；MainActor 仅让出当前 UIKit completion 调用栈，任务无需持有取消句柄，phase 门闩负责淘汰过期请求。
    private func performQueuedDismissalIfNeeded() {
        guard phase == .presented,
              let reason = queuedDismissalReason else {
            return
        }
        queuedDismissalReason = nil
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.beginProgrammaticDismissal(reason)
        }
    }

    /// 设置一次稳定系统 Zoom；source provider 始终按本次 record ID 查询最新 UIView。
    private func configureStableTransition(
        for target: UIViewController,
        sourceID: AnyHashable
    ) {
        let source = sourceRegistry.sourceView(for: sourceID)
        let shouldCrossFade = UIAccessibility.isReduceMotionEnabled ||
            UIAccessibility.prefersCrossFadeTransitions ||
            source == nil

        guard !shouldCrossFade else {
            ReadingTimerAccessoryZoomLog.event(
                "Using cross dissolve fallback; reduceMotion=\(UIAccessibility.isReduceMotionEnabled), prefersCrossFade=\(UIAccessibility.prefersCrossFadeTransitions), sourceAvailable=\(source != nil)"
            )
            target.preferredTransition = .crossDissolve
            return
        }

        // TODO(reading-timer-accessory-glass): iOS 26.5 模拟器的纯 SwiftUI/纯 UIKit
        // 最小复现均会在交互式 Zoom 退场后短暂丢失 Bottom Accessory 液态玻璃；
        // 需在真机复核后决定是否提交 Apple Feedback 或采取规避。
        let options = UIViewController.Transition.ZoomOptions()
        options.interactiveDismissShouldBegin = { [weak self] context in
            guard let self else { return false }
            return context.willBegin && self.isInteractiveDismissEnabled
        }
        target.preferredTransition = .zoom(options: options) { [weak self] _ in
            self?.sourceRegistry.sourceView(for: sourceID)
        }
    }

    /// 以 presentation ID 幂等收口，并在恢复底层表面后才回调 MainTabView。
    private func finishDismissal(
        target: UIViewController,
        presentationID: UUID
    ) {
        guard activePresentationID == presentationID,
              presentedController === target else {
            return
        }
        let reason = activeDismissalReason ?? .minimize
        let completion = onDismissalCompleted
        ReadingTimerAccessoryZoomLog.event(
            "Dismissal completed: \(String(describing: reason))"
        )
        restorePresenterAppearance()
        resetPresentationState()
        completion?(reason)
    }

    /// 临时补齐底层控制器的不透明表面，避免系统 Zoom 暴露安全区矩形边界。
    private func saveAndApplyOpaquePresenterSurface(
        to presenter: UIViewController,
        surfaceColor: UIColor
    ) {
        presenter.loadViewIfNeeded()
        appearanceOwner = presenter
        previousBackgroundColor = presenter.view.backgroundColor
        previousIsOpaque = presenter.view.isOpaque
        previousAccessibilityElementsHidden = presenter.view.accessibilityElementsHidden
        hasSavedAppearance = true
        presenter.view.backgroundColor = surfaceColor
        presenter.view.isOpaque = true
        presenter.view.accessibilityElementsHidden = true
    }

    /// 恢复进入转场前的底层 UIKit 表面属性。
    private func restorePresenterAppearance() {
        guard hasSavedAppearance else { return }
        appearanceOwner?.view.backgroundColor = previousBackgroundColor
        appearanceOwner?.view.isOpaque = previousIsOpaque
        appearanceOwner?.view.accessibilityElementsHidden = previousAccessibilityElementsHidden
        appearanceOwner = nil
        previousBackgroundColor = nil
        previousIsOpaque = false
        previousAccessibilityElementsHidden = false
        hasSavedAppearance = false
    }

    /// 清空单次呈现引用；来源 registry 独立保留，等待 SwiftUI 注册下一实例。
    private func resetPresentationState() {
        presentedController = nil
        activePresentationID = nil
        activeSourceID = nil
        activeDismissalReason = nil
        queuedDismissalReason = nil
        onDismissalRequested = nil
        onDismissalCompleted = nil
        phase = .idle
    }

    /// 从来源 window 解析当前最上层可呈现控制器。
    private func topViewController(in window: UIWindow?) -> UIViewController? {
        guard let root = window?.rootViewController else { return nil }
        return topViewController(from: root)
    }

    /// 递归穿过系统导航、Tab 与已呈现层级，定位真实 presentation owner。
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

/// 以稳定 UIKit 来源承载完整 SwiftUI Accessory；呈现 owner 由 MainTabView 注入并跨重建保留。
@MainActor
struct ReadingTimerAccessoryZoomPresenter<Presentation: Identifiable, Source: View, Destination: View>: UIViewControllerRepresentable where Presentation.ID == UUID {
    typealias SourceBuilder = (@escaping () -> Void) -> Source
    typealias DestinationBuilder = (
        Presentation,
        @escaping (ReadingTimerDismissReason) -> Void
    ) -> Destination

    let owner: ReadingTimerAccessoryZoomPresentationOwner
    let sourceID: AnyHashable
    let dismissalRequest: ReadingTimerAccessoryZoomDismissalRequest?
    let isInteractiveDismissEnabled: Bool
    let preparePresentation: () -> Presentation?
    let onDismissalRequested: (Presentation, ReadingTimerDismissReason) -> Void
    let onDismissalCompleted: (Presentation, ReadingTimerDismissReason) -> Void
    let sourceBuilder: SourceBuilder
    let destinationBuilder: DestinationBuilder

    private let surfaceColor = UIColor(Color.surfacePage)

    /// 注入稳定 owner、生产票据与来源/目标内容；Representable 不拥有转场 phase。
    init(
        owner: ReadingTimerAccessoryZoomPresentationOwner,
        sourceID: AnyHashable,
        dismissalRequest: ReadingTimerAccessoryZoomDismissalRequest?,
        isInteractiveDismissEnabled: Bool,
        preparePresentation: @escaping () -> Presentation?,
        onDismissalRequested: @escaping (Presentation, ReadingTimerDismissReason) -> Void,
        onDismissalCompleted: @escaping (Presentation, ReadingTimerDismissReason) -> Void,
        @ViewBuilder source: @escaping SourceBuilder,
        @ViewBuilder destination: @escaping DestinationBuilder
    ) {
        self.owner = owner
        self.sourceID = sourceID
        self.dismissalRequest = dismissalRequest
        self.isInteractiveDismissEnabled = isInteractiveDismissEnabled
        self.preparePresentation = preparePresentation
        self.onDismissalRequested = onDismissalRequested
        self.onDismissalCompleted = onDismissalCompleted
        sourceBuilder = source
        destinationBuilder = destination
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(configuration: self)
    }

    func makeUIViewController(
        context: Context
    ) -> ReadingTimerAccessoryZoomSourceController<Source> {
        let coordinator = context.coordinator
        let controller = ReadingTimerAccessoryZoomSourceController(
            rootView: sourceBuilder { [weak coordinator] in
                coordinator?.presentDestination()
            }
        )
        coordinator.update(configuration: self)
        coordinator.connect(sourceController: controller)
        return controller
    }

    func updateUIViewController(
        _ uiViewController: ReadingTimerAccessoryZoomSourceController<Source>,
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
        uiViewController: ReadingTimerAccessoryZoomSourceController<Source>,
        context: Context
    ) -> CGSize? {
        uiViewController.sizeThatFits(proposal)
    }

    static func dismantleUIViewController(
        _ uiViewController: ReadingTimerAccessoryZoomSourceController<Source>,
        coordinator: Coordinator
    ) {
        coordinator.dismantle(sourceController: uiViewController)
    }

    /// 保存当前 SwiftUI builders，并把 UIView 注册转交给 MainTabView 持有的稳定 owner。
    @MainActor
    final class Coordinator {
        private var configuration: ReadingTimerAccessoryZoomPresenter
        private var registeredSourceID: AnyHashable?

        /// 保存首次配置；后续 SwiftUI 重绘会通过 update 覆盖为最新闭包。
        init(configuration: ReadingTimerAccessoryZoomPresenter) {
            self.configuration = configuration
        }

        /// 同步 owner 的交互门闩与关闭请求，不改变当前来源 UIView 身份。
        func update(configuration: ReadingTimerAccessoryZoomPresenter) {
            self.configuration = configuration
            configuration.owner.update(
                isInteractiveDismissEnabled: configuration.isInteractiveDismissEnabled,
                dismissalRequest: configuration.dismissalRequest
            )
        }

        /// 注册当前 Hosting Controller 的完整内容 UIView。
        func connect(
            sourceController: ReadingTimerAccessoryZoomSourceController<Source>
        ) {
            sourceController.loadViewIfNeeded()
            if let registeredSourceID,
               registeredSourceID != configuration.sourceID {
                configuration.owner.unregisterSource(
                    sourceController.transitionSourceView,
                    sourceID: registeredSourceID
                )
            }
            registeredSourceID = configuration.sourceID
            configuration.owner.registerSource(
                sourceController.transitionSourceView,
                sourceID: configuration.sourceID
            )
        }

        /// 来源按钮触发时把泛型内容交给稳定 owner 建立一次系统呈现。
        func presentDestination() {
            guard let sourceView = configuration.owner.ownerSourceViewFallback(
                sourceID: configuration.sourceID
            ) else {
                return
            }
            configuration.owner.present(
                sourceID: configuration.sourceID,
                sourceWindow: sourceView.window,
                surfaceColor: configuration.surfaceColor,
                preparePresentation: configuration.preparePresentation,
                onDismissalRequested: configuration.onDismissalRequested,
                onDismissalCompleted: configuration.onDismissalCompleted,
                destinationBuilder: configuration.destinationBuilder
            )
        }

        /// 只解除旧 UIView 注册；稳定 owner 与在场目标不随 representable 重建销毁。
        func dismantle(
            sourceController: ReadingTimerAccessoryZoomSourceController<Source>
        ) {
            guard let registeredSourceID else { return }
            ReadingTimerAccessoryZoomLog.event("Source representable dismantled")
            configuration.owner.unregisterSource(
                sourceController.transitionSourceView,
                sourceID: registeredSourceID
            )
            self.registeredSourceID = nil
        }
    }
}

private extension ReadingTimerAccessoryZoomPresentationOwner {
    /// 为 Representable 获取当前来源 window；正式几何校验仍由 present 内部再次完成。
    func ownerSourceViewFallback(sourceID: AnyHashable) -> UIView? {
        sourceRegistry.sourceView(for: sourceID)
    }
}

/// 用不会随 SwiftUI placement 更新而替换内部 Hosting Controller 的 UIViewController 持有来源像素。
@MainActor
final class ReadingTimerAccessoryZoomSourceController<Content: View>: UIViewController {
    private let hostingController: UIHostingController<Content>

    var transitionSourceView: UIView {
        hostingController.view
    }

    /// 创建透明 UIKit 容器，实际来源边界由 SwiftUI Accessory 内容决定。
    init(rootView: Content) {
        hostingController = UIHostingController(rootView: rootView)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 建立透明根视图，避免来源外层多出第二块背景。
    override func loadView() {
        let rootView = UIView()
        rootView.backgroundColor = .clear
        rootView.isOpaque = false
        view = rootView
    }

    /// 把 Hosting Controller 约束到完整来源边界，并保留 SwiftUI Button 语义。
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

    /// 同步计时秒数、状态与 placement，不替换内部 UIKit 来源控制器。
    func update(rootView: Content) {
        hostingController.rootView = rootView
    }

    /// 把 SwiftUI 内容的理想尺寸反馈给 tabViewBottomAccessory。
    func sizeThatFits(_ proposal: ProposedViewSize) -> CGSize {
        let maximumSize = CGSize(
            width: proposal.width ?? UIView.layoutFittingExpandedSize.width,
            height: proposal.height ?? UIView.layoutFittingExpandedSize.height
        )
        return hostingController.sizeThatFits(in: maximumSize)
    }
}

/// 观察系统退场的完成与取消，不在生命周期回调中改变 preferredTransition。
@MainActor
private final class ReadingTimerAccessoryZoomDestinationController<Content: View>: UIHostingController<Content> {
    var onDismissalWillBegin: (() -> Void)?
    var onDismissalTransitionFinished: ((Bool) -> Void)?
    var onDetachedAfterDismissal: (() -> Void)?

    private var isObservingDismissal = false

    /// 绑定当前系统 transition coordinator，交互取消由 context.isCancelled 作为唯一真相。
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        ReadingTimerAccessoryZoomLog.event(
            "Target viewWillDisappear; interactive=\(transitionCoordinator?.isInteractive == true)"
        )
        guard !isObservingDismissal else { return }
        isObservingDismissal = true
        onDismissalWillBegin?()

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

    /// 系统取消退场后恢复可观察状态，允许下一次手势重新绑定 coordinator。
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isObservingDismissal = false
    }

    /// 为无 coordinator 的异常路径提供最终解绑兜底，正常完成路径仍由幂等 ID 去重。
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if presentingViewController == nil {
            ReadingTimerAccessoryZoomLog.event("Target detached from presenter")
            onDetachedAfterDismissal?()
        }
    }
}

/// provider 每次按稳定 record ID 查询当前来源，避免闭包捕获已复用或卸载的 UIView。
@MainActor
private final class ReadingTimerAccessoryZoomSourceRegistry {
    private final class WeakView {
        weak var value: UIView?

        init(_ value: UIView) {
            self.value = value
        }
    }

    private var sources: [AnyHashable: WeakView] = [:]

    /// 注册当前完整 Accessory UIView。
    func register(_ view: UIView, for sourceID: AnyHashable) {
        sources[sourceID] = WeakView(view)
    }

    /// 只注销仍指向指定 UIView 的映射，避免旧宿主清理覆盖新来源。
    func unregister(_ sourceID: AnyHashable, matching view: UIView) {
        guard sources[sourceID]?.value === view else { return }
        sources[sourceID] = nil
    }

    /// 返回仍附着 window、可见且有有效几何的最新来源。
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
