/**
 * [INPUT]: 接收回顾启动负载、唯一 Session、共享单画布总览与现有单条阅读 Cell
 * [OUTPUT]: 提供三模式生产回顾、稳定身份、业务操作和确认后偏好保存，统一中性深色纸面与文字角色，不额外标记当前条目
 * [POS]: 书摘回顾页面 owner；总览与测试中心共用实现，业务会话不进入画布
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import SwiftUI
import UIKit
import ImageIO
import os

/// 生产页面持有唯一模式协调器；子总览只处理自己的滚动表面，不接管业务或导航。
@MainActor
final class NoteReviewViewController: UIViewController {
    private enum Constants { static let preferredModeKey = "noteReview.presentationMode.v2" }
    private let session: NoteReviewUIKitSession
    private let repositories: RepositoryContainer
    private let toastCenter: XMToastCenter
    private let onDismiss: () -> Void
    private let onOpenDetail: (Int64, ContentViewerSourceContext) -> Void
    private let onError: (String) -> Void
    private let immersiveLayout = ImmersiveReviewFlowLayout()
    private lazy var collectionView = NoteReviewCollectionView(frame: .zero, collectionViewLayout: immersiveLayout)
    private let overview = NoteReviewCanvasOverviewController()
    private let coordinator = NoteReviewCanvasModeCoordinator()
    private var mode: NoteReviewPresentationMode { coordinator.settledMode }
    private var hasRequestedOverview = false
    private var hasOverviewState: Bool {
        hasRequestedOverview || overview.preparedModel != nil || overview.modelPreparation != nil
    }
    private var transientReturnMode: NoteReviewPresentationMode?
    private var observedSettings: NoteReviewSettings
    private var presentedOrderedIDs: [Int64]
    private var pendingExplicitMode: NoteReviewPresentationMode?
    private var isDisposed = false
    private var transitionTask: Task<Void, Never>?
    private var transitionRequestGeneration = 0
    private var interruptedSource: (endpoint: NoteReviewCanvasReadingEndpoint?, background: UIView)?
    private var deferredModeAfterHandoff: (mode: NoteReviewPresentationMode, explicit: Bool)?
    private var isPositioning = false
    private var hasPositioned = false
    private var lastSize = CGSize.zero
    private var chromeAnimator: UIViewPropertyAnimator?
    private var areControlsHidden = false
    private var galleryHost: XMJXPhotoBrowserHost?
    private var tagPreparationTask: Task<Void, Never>?
    private var notificationObservers: [NSObjectProtocol] = []
    private weak var activeEdgeScrollView: UIScrollView?
    private let closeButton = UIButton(type: .system)
    private let tagButton = NoteReviewChromeMenuButton(frame: .zero)
    private let overviewButton = UIButton(type: .system)
    private let moreButton = NoteReviewChromeMenuButton(frame: .zero)
    private let progressState = NoteReviewProgressState()
    private lazy var progressHost = UIHostingController(rootView: NoteReviewProgressView(state: progressState))
    private var progressLabel: UIView { progressHost.view }
    private let emptyLabel = UILabel()
    private let topChromeContainer = NoteReviewPassthroughChromeView()
    private let bottomChromeContainer = NoteReviewPassthroughChromeView()
    private let closeGlass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let tagGlass = UIView()
    private let overviewGlass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let moreGlass = UIView()
    private let topEdgeInteraction = UIScrollEdgeElementContainerInteraction()
    private let bottomEdgeInteraction = UIScrollEdgeElementContainerInteraction()
    private lazy var blankTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleBlankTap))
    private let feedback = NoteReviewCanvasPageFeedback()
    private var feedbackHost: UIHostingController<NoteReviewCanvasPageFeedbackView>?
    private var deferredNoteAction: (() -> Void)?
    private var readingObjectMenuConfiguration: UIContextMenuConfiguration?
    private var isReadingObjectMenuPresented: Bool {
        readingObjectMenuConfiguration != nil
    }
    private var deleteTasks: [Int64: Task<Void, Never>] = [:]
    private var actionItemTask: Task<Void, Never>?
    private let selectionFeedback = UISelectionFeedbackGenerator()
    private let modeSignposter = OSSignposter(subsystem: "com.wangke.xmnote", category: "CanvasModePreparation")
    private var modePreparationInterval: OSSignpostIntervalState?
    private var modeRequestStartedAt: CFTimeInterval?

    /// 保留原启动负载与业务动作；模式偏好只在显式请求落稳后写入原键。
    init(payload: NoteReviewLaunchPayload, repositories: RepositoryContainer, toastCenter: XMToastCenter,
         onDismiss: @escaping () -> Void, onOpenDetail: @escaping (Int64, ContentViewerSourceContext) -> Void,
         onError: @escaping (String) -> Void) {
        session = NoteReviewUIKitSession(payload: payload, repository: repositories.noteRepository, usesDirectory: true)
        self.repositories = repositories
        self.toastCenter = toastCenter
        self.onDismiss = onDismiss
        self.onOpenDetail = onOpenDetail
        self.onError = onError
        observedSettings = payload.settings
        presentedOrderedIDs = session.orderedIDs
        super.init(nibName: nil, bundle: nil)
        modalPresentationCapturesStatusBarAppearance = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 永久关闭立即取消，不等待正在执行的系统排版或仓储调用结束。
    func disposeReviewSession() {
        guard !isDisposed else { return }
        isDisposed = true
        deferredModeAfterHandoff = nil
        endModePreparationTiming(cancelled: true)
        transitionTask?.cancel()
        interruptedSource?.background.removeFromSuperview(); interruptedSource = nil
        tagPreparationTask?.cancel()
        deleteTasks.values.forEach { $0.cancel() }
        deleteTasks.removeAll()
        actionItemTask?.cancel()
        deferredNoteAction = nil
        readingObjectMenuConfiguration = nil
        coordinator.dispose()
        overview.disposeCanvas()
        session.dispose()
        feedback.gate.hideImmediately()
        updateModeLoadingIndicator(isVisible: false)
        notificationObservers.forEach(NotificationCenter.default.removeObserver)
        notificationObservers.removeAll()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildCollectionView()
        buildOverview()
        buildChrome()
        buildFeedback()
        bindSession()
        observeSystemChanges()
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) {
            (controller: NoteReviewViewController, _) in
            guard !controller.isDisposed else { return }
            controller.refreshVisibleCells(changedIDs: Set(controller.collectionView.indexPathsForVisibleItems.compactMap {
                controller.session.noteID(at: $0.item)
            }))
            controller.updateModeAppearance()
        }
        session.start()
        updateProgress()
        updateModeAppearance()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        overview.setContentOcclusionInsets(immersiveChromeInsets)
        if collectionView.bounds.size != lastSize {
            lastSize = collectionView.bounds.size
            immersiveLayout.invalidateLayout()
            if coordinator.state == .idle { restoreImmersiveAnchor() }
        }
        if !hasPositioned, collectionView.bounds.height > 0 {
            hasPositioned = true
            restoreImmersiveAnchor()
            // This entry explicitly means full-screen single-note reading. A saved overview
            // preference must not issue a second navigation request after the first layout.
        }
        updateVisibleCellChromeInsets()
        updateActiveEdgeEffects()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        overview.resumeCanvas()
        coordinator.setPaused(false)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        deferredNoteAction = nil
        readingObjectMenuConfiguration = nil
        if !isDisposed { overview.pauseCanvas(); coordinator.setPaused(true) }
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        overview.didReceiveMemoryWarning()
    }

    /// 原 Collection View 只保留现有单条阅读与分页物理。
    private func buildCollectionView() {
        view.backgroundColor = session.settings.cardAppearance.uiSurface
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.isPagingEnabled = true
        collectionView.alwaysBounceVertical = true
        collectionView.showsVerticalScrollIndicator = false
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.register(NoteReviewCollectionCell.self, forCellWithReuseIdentifier: NoteReviewCollectionCell.reuseIdentifier)
        collectionView.onAccessibilityScroll = { [weak self] direction in
            self?.moveAccessibility(by: direction == .up ? 1 : -1) ?? false
        }
        blankTapGesture.cancelsTouchesInView = false
        blankTapGesture.delegate = self
        collectionView.addGestureRecognizer(blankTapGesture)
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    /// 总览延伸到整个页面；安全区仅约束控件和首尾停靠，不裁断纸张的滚动区域。
    private func buildOverview() {
        overview.automaticallyPreparesOverview = false
        overview.extendsUnderSafeArea = true
        addChild(overview)
        overview.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overview.view)
        NSLayoutConstraint.activate([
            overview.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overview.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overview.view.topAnchor.constraint(equalTo: view.topAnchor),
            overview.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        overview.didMove(toParent: self)
        overview.view.alpha = 0
        overview.view.isUserInteractionEnabled = false
        overview.sourceReader = { [weak session] ids, priority in
            guard let session else { throw CancellationError() }
            return try await session.readOverviewSources(noteIDs: ids, priority: priority)
        }
        overview.directoryRegionReader = { [weak session] id in
            guard let session else { throw CancellationError() }
            return try await session.readDirectoryRegion(noteID: id)
        }
        overview.stackGroupReader = { [weak session] request in
            guard let session else { throw CancellationError() }
            return try await session.readDesktopStack(request)
        }
        overview.onGroupCapacityChanged = { [weak session] capacity in session?.updateDesktopGroupCapacity(capacity) }
        overview.directoryWaterfallPageReader = { [weak session] id in
            guard let session else { throw CancellationError() }
            return try await session.readDirectoryWaterfallPage(around: id)
        }
        session.canApplyReadingWindow = { [weak self] in
            guard let self else { return false }
            return coordinator.state != .animating && coordinator.state != .settling
        }
        overview.canCommitBackgroundGeometry = { [weak self] in
            guard let self else { return false }
            return coordinator.state == .idle || (coordinator.state == .preparing && transitionTask == nil)
        }
        overview.onResidentRegionIDs = { [weak session] ids in session?.retainDirectoryRegionIDs(ids) }
        overview.backgroundReader = { [weak session] value in
            guard let session, let url = URL(string: value) else { return nil }
            let data = try await session.readCanvasBackground(url: url)
            return await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil as CGImage? }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1_024
                ] as CFDictionary)
            }.value
        }
        overview.onCurrentChanged = { [weak self] id in
            guard let self, coordinator.state == .idle, mode != .immersive else { return }
            session.setCurrentNoteID(id)
            updateProgress()
        }
        overview.onActivate = { [weak self] id in
            guard let self else { return }
            session.setCurrentNoteID(id)
            transientReturnMode = mode
            requestMode(.immersive, explicit: false)
        }
        overview.onBlankTap = { [weak self] in self?.handleBlankTap() }
        overview.onUserInteractionBegan = { [weak self] in self?.cancelSwitchForDirectManipulation() }
        overview.onNoteActionMenu = { [weak self] id in self?.noteActionMenu(noteID: id) }
        overview.onNoteAccessibilityActions = { [weak self] id in self?.noteAccessibilityActions(noteID: id) ?? [] }
        overview.onObjectMenuDidEnd = { [weak self] in self?.performDeferredNoteAction() }
        overview.onConfirmedWidth = { [weak session] width in session?.updateDesktopCardWidth(width) }
        overview.onControlsChanged = { [weak self] in
            self?.updateModeAppearance()
            self?.updateMoreMenu()
            self?.updateOverviewChromeOwnership()
            self?.updateActiveEdgeEffects()
        }
        coordinator.onSurfaceChanged = { [weak self] in self?.updateActiveEdgeEffects() }
        coordinator.onReadingProgress = { [weak self] from, to, progress in
            self?.updateTransitionChrome(from: from, to: to, progress: progress)
        }
        overview.onModeTransitionProgress = { [weak self] from, to, progress in
            self?.updateTransitionChrome(from: from == .desktop ? .desktop : .waterfall,
                to: to == .desktop ? .desktop : .waterfall, progress: progress)
        }
        overview.onDemand = { [weak self] visible, predicted in
            guard let self, mode != .immersive else { return }
            session.updateVisibleIDs(visible)
            session.updateSpatialPrefetch(noteIDs: predicted)
        }
        overview.onSettledMode = { [weak self] value in
            guard let self, coordinator.isOverviewTransition else { return }
            finishMode(value == .desktop ? .desktop : .waterfall)
        }
        overview.onPreparationChanged = { [weak self] preparing, error in
            guard let self else { return }
            if error != nil {
                if coordinator.requestedMode != nil { presentReadingRecovery() }
                else if mode != .immersive { failedMode = mode; updateMoreMenu() }
                return
            }
            if preparing, coordinator.requestedMode != nil || (mode != .immersive && !overview.isMenuPrewarming) {
                feedback.setWaiting(true)
            }
            if !preparing, coordinator.requestedMode == nil { feedback.setWaiting(false) }
            if !preparing, coordinator.isOverviewTransition, overview.transitionState == .animating {
                endModePreparationTiming(cancelled: false)
                coordinator.markAnimating()
                feedback.setWaiting(false)
                updateModeLoadingIndicator(isVisible: false)
            }
        }
        overview.onReady = { [weak self] in self?.continueRequestedMode() }
        overview.onWidthEnded = { [weak self] in self?.continueRequestedMode() }
        overview.onMissingIDs = { [weak self] _ in
            guard let self else { return }
            session.refreshCanvasSnapshot()
        }
        coordinator.reverseOverview = { [weak self] target in
            guard let self, target != .immersive else { return false }
            overview.requestMode(target == .desktop ? .desktop : .waterfall)
            return true
        }
    }

    /// 宿主只消费总览准备状态，通用加载与错误外观交给项目现有组件。
    private func buildFeedback() {
        feedback.retry = { [weak self] in
            guard let self else { return }
            if let target = failedMode {
                requestMode(target, explicit: true)
            } else if hasRequestedOverview {
                overview.requestPreparation(count: session.count, preservingCurrentID: session.currentNoteID)
            }
        }
        let host = UIHostingController(rootView: NoteReviewCanvasPageFeedbackView(state: feedback))
        addChild(host)
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Spacing.screenEdge),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Spacing.screenEdge),
            host.view.topAnchor.constraint(equalTo: topChromeContainer.bottomAnchor, constant: Spacing.base),
            host.view.heightAnchor.constraint(greaterThanOrEqualToConstant: 0)
        ])
        host.didMove(toParent: self)
        feedbackHost = host
        observeLoadingFeedback()
    }

    /// Gate 只控制按钮反馈延迟；结束即恢复省略号，不延长源页面可操作的准备阶段。
    private func observeLoadingFeedback() {
        withObservationTracking {
            updateModeLoadingIndicator(isVisible: feedback.gate.isVisible)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !isDisposed else { return }
                observeLoadingFeedback()
            }
        }
    }

    /// 使用原生按钮的图像槽显示等待；菜单收起期间由按钮合并配置，页面始终不被遮罩。
    private func updateModeLoadingIndicator(isVisible: Bool) {
        moreButton.setReviewLoading(isVisible && !isDisposed && feedback.isWaiting
            && (coordinator.requestedMode != nil || overview.stackWork != nil))
    }

    private var failedMode: NoteReviewPresentationMode?

    /// 取消或失败保留已落稳表面，主 actor 撤销全部待切换资格，迟到端点不再交付。
    private func cancelRequestedMode() {
        endModePreparationTiming(cancelled: true)
        transitionRequestGeneration += 1
        transitionTask?.cancel(); transitionTask = nil
        let original = mode
        overview.cancelPendingPresentation()
        coordinator.settle(original)
        pendingExplicitMode = nil
        feedback.needsReadingRecovery = false
        feedback.setWaiting(false)
        updateModeLoadingIndicator(isVisible: false)
        interruptedSource?.background.removeFromSuperview(); interruptedSource = nil
        finishMode(original)
    }

    /// 失败保留可信源画面；恢复入口只在下次主动打开菜单时出现，不打断阅读。
    private func presentReadingRecovery() {
        endModePreparationTiming(cancelled: true)
        failedMode = coordinator.requestedMode
        transitionRequestGeneration += 1
        transitionTask?.cancel(); transitionTask = nil
        overview.cancelPendingPresentation()
        coordinator.settle(mode)
        pendingExplicitMode = nil
        feedback.error = nil
        feedback.needsReadingRecovery = false
        feedback.setWaiting(false)
        updateModeLoadingIndicator(isVisible: false)
        updateMoreMenu()
    }

    /// Session 是唯一业务真相源；完整数据变更不再触发旧总览测量或 Tile/Cell 切换。
    private func bindSession() {
        session.automaticallyPreparesOverview = false
        session.onOverviewInvalidated = { [weak self] in
            guard let self, hasOverviewState else { return }
            overview.requestPreparation(count: session.count, preservingCurrentID: session.currentNoteID)
        }
        session.onManifestChanged = { [weak self] in
            guard let self, !isDisposed else { return }
            let changed = presentedOrderedIDs != session.orderedIDs
            presentedOrderedIDs = session.orderedIDs
            if changed { collectionView.reloadData(); restoreImmersiveAnchor() }
            if hasOverviewState {
                overview.applySnapshot(ids: session.orderedIDs, currentID: session.currentNoteID, settings: session.settings)
            }
            feedback.isEmpty = session.count == 0
            updateProgress()
            continueRequestedMode()
        }
        session.onItemsChanged = { [weak self] ids in
            guard let self, !isDisposed else { return }
            refreshVisibleCells(changedIDs: ids)
            updateProgress()
            continueRequestedMode()
        }
        session.onSettingsChanged = { [weak self] in
            guard let self else { return }
            let old = observedSettings
            observedSettings = session.settings
            if hasOverviewState { overview.applySettings(session.settings, previous: old) }
            refreshVisibleCells(changedIDs: Set(collectionView.indexPathsForVisibleItems.compactMap { self.session.noteID(at: $0.item) }))
            updateModeAppearance()
            updateMoreMenu()
        }
        session.onError = { [weak self] _ in
            guard let self else { return }
            if coordinator.state == .preparing, coordinator.requestedMode != nil { presentReadingRecovery() }
            else { feedback.error = "暂时无法更新回顾内容" }
        }
    }

    /// 前后台只暂停渲染工作，保持业务 Session 和两个总览视口。
    private func observeSystemChanges() {
        notificationObservers = [
            NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.overview.pauseCanvas(); self?.coordinator.setPaused(true) }
            },
            NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.overview.resumeCanvas(); self?.coordinator.setPaused(false) }
            }
        ]
    }

    /// 请求立即更新控件反馈；准备期间保持完整源画面。
    private func requestMode(_ target: NoteReviewPresentationMode, explicit: Bool) {
        guard !isDisposed else { return }
        guard target == .immersive || session.count > 0 else { return }
        deferredNoteAction = nil
        failedMode = nil
        feedback.error = nil
        feedback.needsReadingRecovery = false
        if explicit { pendingExplicitMode = target; transientReturnMode = nil }
        deferredModeAfterHandoff = nil
        if coordinator.reverseIfPossible(to: target) { updateMoreMenu(); return }
        let cover = coordinator.state == .animating ? contentSnapshotForInterruption() : nil
        if coordinator.state == .animating, cover == nil {
            // A failed capture must not remove the only trustworthy displayed scene.
            deferredModeAfterHandoff = (target, explicit)
            return
        }
        endModePreparationTiming(cancelled: true)
        modePreparationInterval = modeSignposter.beginInterval("Mode request to animation")
        modeRequestStartedAt = CACurrentMediaTime()
        transitionRequestGeneration += 1
        transitionTask?.cancel(); transitionTask = nil
        if coordinator.state == .animating {
            if let cover { view.insertSubview(cover, belowSubview: topChromeContainer) }
            let wasOverview = coordinator.isOverviewTransition
            let reading = coordinator.interrupt(in: view)
            let endpoint = wasOverview ? overview.interruptModeTransition(in: view) : reading
            if let cover { interruptedSource = (endpoint, cover) }
            else { cover?.removeFromSuperview() }
        }
        coordinator.request(target)
        updateActiveEdgeEffects()
        feedback.setWaiting(target != mode || interruptedSource != nil)
        if target != .immersive {
            hasRequestedOverview = true
            overview.requestedPreparationMode = target == .desktop ? .desktop : .waterfall
            overview.applySnapshot(ids: session.orderedIDs, currentID: session.currentNoteID, settings: session.settings)
        }
        if let width = overview.widthSession {
            width.closeAfterCommit = true
            overview.settleWidth(width)
            return
        }
        continueRequestedMode()
        updateMoreMenu()
    }

    /// 第三目标只接管正在展示的内容，固定玻璃按钮及模态层不进入冻结像素。
    /// 主 actor 在中断事件中执行一次；正常逐帧动画不截屏，不遍历书摘清单。
    private func contentSnapshotForInterruption() -> UIView? {
        if let scene = coordinator.presentationScrollView as? NoteReviewCanvasTransitionSurface {
            return scene.frozenContentSurface(in: view)
        }
        if coordinator.isOverviewTransition {
            return (overview.presentationScrollView as? NoteReviewCanvasTransitionSurface)?.frozenContentSurface(in: view)
        }
        // The short recovery dissolve owns sibling content surfaces rather than a paper scene.
        // Compose only siblings below chrome, never a screenshot of the parent screen.
        let snapshot = UIView(frame: view.bounds)
        snapshot.backgroundColor = view.backgroundColor
        for surface in view.subviews.prefix(while: { $0 !== topChromeContainer }) {
            let opacity = CGFloat(surface.layer.presentation()?.opacity ?? Float(surface.alpha))
            guard !surface.isHidden, opacity > 0, let layer = surface.snapshotView(afterScreenUpdates: false) else { continue }
            layer.frame = surface.convert(surface.bounds, to: view)
            layer.alpha = opacity
            snapshot.addSubview(layer)
        }
        return snapshot.subviews.isEmpty ? nil : snapshot
    }

    /// 无同步等待；正文到达或总览就绪回调会重新尝试目标端点。
    private func continueRequestedMode() {
        guard !isDisposed, coordinator.state == .preparing,
              overview.widthSession == nil, let target = coordinator.requestedMode else { return }
        guard transitionTask == nil else { return }
        guard overview.flushDeletionForModeRequest() else { return }
        if overview.stackBrowser != nil, mode == .desktop {
            overview.dismissStackBrowser()
            return
        }
        guard !overview.isStackHandoffPending else { return }
        if target == mode, interruptedSource == nil { finishMode(target); return }
        if target != .immersive, overview.preparedModel == nil {
            feedback.setWaiting(true)
            if overview.modelPreparation == nil {
                overview.requestPreparation(count: session.count, preservingCurrentID: session.currentNoteID)
            }
            return
        }
        overview.currentNoteID = session.currentNoteID
        if target == .desktop, overview.preparedModel?.canvasGeometry.indexByID[session.currentNoteID] == nil {
            feedback.setWaiting(true)
            if overview.modelPreparation == nil {
                overview.requestPreparation(count: session.count, preservingCurrentID: session.currentNoteID)
            }
            return
        }
        if target == .waterfall, !overview.ensureWaterfallPrepared() {
            feedback.setWaiting(true)
            return
        }
        let id = session.currentNoteID
        if target == .immersive, !session.isCurrentReadingWindowReady {
            session.prepareReadingWindow(around: id)
            feedback.setWaiting(true)
            return
        }
        session.updateTransitionProtection(noteIDs: [id])
        if target == .immersive, session.item(for: id) == nil {
            feedback.setWaiting(true)
            return
        }
        overview.currentNoteID = id
        if mode != .immersive && target != .immersive && interruptedSource == nil {
            coordinator.isOverviewTransition = true
            overview.requestMode(target == .desktop ? .desktop : .waterfall)
            return
        }
        startReadingTransition(to: target, noteID: id)
    }

    /// 使用真实单条视图与同源总览绘制端点；真实表面在交还前不提前显露。
    private func startReadingTransition(to target: NoteReviewPresentationMode, noteID: Int64) {
        let requestGeneration = transitionRequestGeneration
        let from = mode
        coordinator.markPreparing()
        if target == .immersive {
            restoreImmersiveAnchor()
            collectionView.layoutIfNeeded()
        } else {
            overview.showModeImmediately(target == .desktop ? .desktop : .waterfall, noteID: noteID)
        }
        transitionTask = Task { [weak self] in
            guard let self else { return }
            if target != .immersive {
                do { try await overview.prepareReadableSurface(target == .desktop ? .desktop : .waterfall, noteID: noteID) }
                catch {
                    guard !Task.isCancelled, transitionRequestGeneration == requestGeneration else { return }
                    presentReadingRecovery(); return
                }
            }
            let overviewEndpoint = await overview.readingEndpoint(noteID: noteID, in: view, requestGeneration: requestGeneration)
            let overviewBackground = await overview.readingTransitionBackground(in: view)
            defer { if transitionRequestGeneration == requestGeneration { transitionTask = nil } }
            guard !Task.isCancelled, !isDisposed, transitionRequestGeneration == requestGeneration,
                  session.currentNoteID == noteID, coordinator.requestedMode == target else { return }
            guard let overviewEndpoint, let overviewBackground,
                  let cell = collectionView.cellForItem(at: IndexPath(item: session.localCurrentIndex, section: 0)) as? NoteReviewCollectionCell,
                  let reading = cell.immersiveTransitionEndpoint(in: view, insets: immersiveChromeInsets,
                      surfaceColor: session.settings.cardAppearance.uiSurface, requestGeneration: requestGeneration),
                  let identity = reading.identity, let overviewIdentity = overviewEndpoint.identity,
                  identity.belongsToSameRequest(as: overviewIdentity), identity.noteID == noteID else {
                await startReadingDissolve(to: target, noteID: noteID, requestGeneration: requestGeneration)
                return
            }
            feedback.setWaiting(false)
            updateModeLoadingIndicator(isVisible: false)
            let source = interruptedSource?.endpoint ?? (from == .immersive ? reading : overviewEndpoint)
            let destination = target == .immersive ? reading : overviewEndpoint
            NoteReviewCanvasHandoffDiagnostics.event("endpoints request=\(requestGeneration) sourceSize=\(source.logicalSize) targetSize=\(destination.logicalSize) sourceFrame=\(source.frame) targetFrame=\(destination.frame) sourceRotation=\(source.rotation) targetRotation=\(destination.rotation) readingContentVersion=\(identity.contentVersion) readingAppearanceVersion=\(identity.appearanceVersion)")
            NoteReviewCanvasHandoffDiagnostics.save(source.image, stage: "source-ink")
            NoteReviewCanvasHandoffDiagnostics.save(destination.image, stage: "target-ink")
            guard let readingImage = reading.viewportImage, let readingFrame = reading.viewportFrame else {
                await startReadingDissolve(to: target, noteID: noteID, requestGeneration: requestGeneration)
                return
            }
            let readingBackground = UIImageView(image: readingImage)
            readingBackground.frame = readingFrame
            readingBackground.backgroundColor = reading.backdropColor
            let frozen = interruptedSource?.background as? NoteReviewCanvasTransitionSurface
            let sourceBackground = frozen?.contentForHandoff() ?? interruptedSource?.background
                ?? (from == .immersive ? readingBackground : overviewBackground)
            let destinationBackground = target == .immersive ? readingBackground : overviewBackground
            let clip = view.bounds
            endModePreparationTiming(cancelled: false)
            coordinator.animateReading(from: from, to: target, source: source, destination: destination,
                sourceBackground: sourceBackground, targetBackground: destinationBackground,
                clip: clip, container: view, below: topChromeContainer,
                takeOwnership: { [weak self] in
                    frozen?.removeFromSuperview()
                    self?.collectionView.alpha = 0; self?.overview.view.alpha = 0
                    self?.collectionView.isUserInteractionEnabled = false; self?.overview.view.isUserInteractionEnabled = false
                }, completion: { [weak self] result in
                    guard let self, !isDisposed, transitionRequestGeneration == requestGeneration else { return }
                    finishMode(result)
                })
            interruptedSource = nil
            feedback.setWaiting(false)
        }
    }

    /// 共享纸张或快照不可用不等于阅读失败；目标真实内容准备好后用短淡变完成同一模式请求。
    /// 主 actor 管理显示权，异步总览恢复仍受请求 generation 和任务取消保护。
    private func startReadingDissolve(to target: NoteReviewPresentationMode, noteID: Int64, requestGeneration: Int) async {
        Logger(subsystem: "com.wangke.xmnote", category: "CanvasTransition").notice("Reading transition uses surface dissolve")
        if target == .immersive {
            guard session.item(for: noteID) != nil else { presentReadingRecovery(); return }
            restoreImmersiveAnchor()
            collectionView.layoutIfNeeded()
            guard let cell = collectionView.cellForItem(at: IndexPath(item: session.localCurrentIndex, section: 0)) as? NoteReviewCollectionCell else {
                presentReadingRecovery(); return
            }
            configure(cell: cell, noteID: noteID)
        } else {
            do { try await overview.prepareReadableSurface(target == .desktop ? .desktop : .waterfall, noteID: noteID) }
            catch {
                guard !Task.isCancelled, transitionRequestGeneration == requestGeneration else { return }
                presentReadingRecovery(); return
            }
        }
        guard !Task.isCancelled, !isDisposed, transitionRequestGeneration == requestGeneration,
              coordinator.requestedMode == target else { return }
        feedback.setWaiting(false)
        updateModeLoadingIndicator(isVisible: false)
        let from = mode
        endModePreparationTiming(cancelled: false)
        coordinator.animateDissolve(from: from, to: target,
            source: from == .immersive ? collectionView : overview.view,
            target: target == .immersive ? collectionView : overview.view,
            frozenSource: interruptedSource?.background, container: view, below: topChromeContainer
        ) { [weak self] result in self?.finishMode(result) }
        interruptedSource = nil
    }

    /// 落稳后一次提交模式、偏好、需求和无障碍焦点。
    private func finishMode(_ result: NoteReviewPresentationMode) {
        endModePreparationTiming(cancelled: false)
        coordinator.settle(result) { [self] in
            collectionView.alpha = result == .immersive ? 1 : 0
            collectionView.isUserInteractionEnabled = result == .immersive
            collectionView.accessibilityElementsHidden = result != .immersive
            overview.view.alpha = result == .immersive ? 0 : 1
            overview.view.isUserInteractionEnabled = result != .immersive
            overview.view.accessibilityElementsHidden = result == .immersive
            updateModeAppearance()
        }
        if let explicit = pendingExplicitMode, explicit == result {
            UserDefaults.standard.set(result.rawValue, forKey: Constants.preferredModeKey)
            pendingExplicitMode = nil
        }
        session.cancelTransitionProtection()
        session.applyPendingReadingWindow()
        overview.commitDeferredModelIfPossible()
        feedback.setWaiting(false)
        updateModeLoadingIndicator(isVisible: false)
        refreshVisibleRange()
        updateProgress()
        updateActiveEdgeEffects()
        NoteReviewCanvasHandoffDiagnostics.record("settled-live", view: result == .immersive ? collectionView : overview.view)
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .layoutChanged, argument: result == .immersive
                ? collectionView.cellForItem(at: IndexPath(item: session.localCurrentIndex, section: 0))
                : overview.focusedAccessibilityElement)
        }
        if let deferred = deferredModeAfterHandoff {
            deferredModeAfterHandoff = nil
            requestMode(deferred.mode, explicit: deferred.explicit)
        }
    }

    /// 分开记录用户等待与实际准备阶段；只含耗时和结果，不记录书摘身份或正文。
    private func endModePreparationTiming(cancelled: Bool) {
        guard let interval = modePreparationInterval else { return }
        modeSignposter.endInterval("Mode request to animation", interval)
        if let start = modeRequestStartedAt {
            let milliseconds = (CACurrentMediaTime() - start) * 1_000
            Logger(subsystem: "com.wangke.xmnote", category: "CanvasModePreparation")
                .notice("Mode preparation \(milliseconds, format: .fixed(precision: 1))ms cancelled=\(cancelled)")
        }
        modePreparationInterval = nil
        modeRequestStartedAt = nil
    }

    /// 单条阅读保持原本富文本、图片和来源操作，不引入第二份阅读器。
    private func configure(cell: NoteReviewCollectionCell, noteID: Int64) {
        cell.onOpenImages = { [weak self] item, index in self?.openImages(item: item, index: index) }
        cell.onDirectManipulation = { [weak self] in self?.cancelSwitchForDirectManipulation() }
        guard let item = session.item(for: noteID) else {
            cell.configurePlaceholder(noteID: noteID, mode: .immersive)
            return
        }
        cell.configure(item: item, mode: .immersive, settings: session.settings, overviewSnapshot: nil,
            overviewMeasurement: nil, paperWidth: collectionView.bounds.width, chromeInsets: immersiveChromeInsets)
        cell.setNoteAccessibilityActions(noteAccessibilityActions(noteID: noteID))
    }

    private func restoreImmersiveAnchor() {
        guard session.count > 0, collectionView.bounds.height > 0 else { return }
        isPositioning = true
        collectionView.layoutIfNeeded()
        collectionView.setContentOffset(CGPoint(x: 0, y: CGFloat(session.localCurrentIndex) * collectionView.bounds.height), animated: false)
        isPositioning = false
    }

    private func refreshVisibleCells(changedIDs: Set<Int64>) {
        for path in collectionView.indexPathsForVisibleItems {
            guard let id = session.noteID(at: path.item), changedIDs.contains(id),
                  let cell = collectionView.cellForItem(at: path) as? NoteReviewCollectionCell else { continue }
            configure(cell: cell, noteID: id)
        }
    }

    private func refreshVisibleRange() {
        if mode == .immersive {
            session.updateVisibleIDs(collectionView.indexPathsForVisibleItems.compactMap { session.noteID(at: $0.item) })
        } else { overview.reportDemand() }
    }

    private func updateProgress() {
        let count = session.count == 0 ? 0 : session.currentIndex + 1
        progressState.update(current: count, total: session.count,
            animated: mode != .desktop && coordinator.state == .idle && !areControlsHidden && view.window != nil)
        emptyLabel.isHidden = true
        tagButton.isEnabled = session.count > 0 && tagPreparationTask == nil
        overviewButton.isEnabled = session.count > 0
        feedback.isEmpty = session.count == 0
        updateTagButton()
        updateMoreMenu()
        updateAccessibilityActions()
    }

    private func updateMoreMenu() {
        tagButton.isEnabled = session.count > 0 && tagPreparationTask == nil && (coordinator.state == .idle || coordinator.state == .preparing)
        let modes = NoteReviewPresentationMode.allCases.map { value in
            let pending = coordinator.state == .preparing && coordinator.requestedMode == value && value != mode
            return UIAction(title: title(for: value), subtitle: pending ? "准备中" : nil,
                     image: UIImage(systemName: iconName(for: value)),
                     state: mode == value ? .on : .off) { [weak self] _ in self?.requestMode(value, explicit: true) }
        }
        var utilities: [UIMenuElement] = []
        if mode == .desktop, coordinator.state == .idle, overview.stackBrowser == nil {
            utilities.append(overview.desktopWidthMenu())
            utilities.append(overview.desktopGroupMenu())
        }
        utilities.append(
            UIAction(title: "显示内容", image: UIImage(systemName: "textformat.size"),
                     attributes: coordinator.state == .animating || coordinator.state == .settling ? .disabled : []) { [weak self] _ in
                self?.cancelSwitchForDirectManipulation()
                self?.presentDisplaySettings()
            }
        )
        if coordinator.state == .preparing {
            utilities.append(UIAction(title: "取消切换", image: UIImage(systemName: "xmark")) { [weak self] _ in self?.cancelRequestedMode() })
        } else if overview.stackWork != nil {
            utilities.append(UIAction(title: "取消准备", image: UIImage(systemName: "xmark")) { [weak self] _ in
                self?.overview.cancelStackTargetPreparation()
                self?.updateMoreMenu()
            })
        } else if let retryMode = failedMode {
            utilities.append(UIAction(title: "重试切换", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                self?.requestMode(retryMode, explicit: true)
            })
        }
        if session.settings.sortRule == .random {
            utilities.append(UIAction(title: "换一组", image: UIImage(systemName: "shuffle")) { [weak self] _ in self?.session.reshuffle() })
        }
        moreButton.setReviewMenu(UIMenu(children: [UIMenu(title: "回顾方式", options: .displayInline, children: modes),
                                             UIMenu(options: .displayInline, children: utilities)]))
    }

    private func updateModeAppearance() {
        tagGlass.alpha = 1
        overviewGlass.alpha = 1
        view.backgroundColor = mode == .immersive ? session.settings.cardAppearance.uiSurface : NoteReviewCanvasAppearance.backgroundColor
        tagGlass.isHidden = mode != .immersive
        progressLabel.isHidden = mode == .desktop
        progressLabel.alpha = mode == .desktop ? 0 : 1
        progressLabel.accessibilityElementsHidden = mode == .desktop
        overviewGlass.isHidden = mode != .desktop
        closeButton.configuration?.image = UIImage(systemName: mode == .immersive && transientReturnMode != nil ? "chevron.left" : "xmark")
        overviewButton.configuration?.image = UIImage(systemName: overview.desktopOverviewIcon)
        overviewButton.accessibilityLabel = overview.desktopOverviewLabel
    }

    /// 固定按钮保留同一实例；仅在已有纸张时间轴内交叉淡变模式专属入口。
    private func updateTransitionChrome(from: NoteReviewPresentationMode, to: NoteReviewPresentationMode, progress: CGFloat) {
        let p = min(1, max(0, progress))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tagGlass.isHidden = from != .immersive && to != .immersive
        overviewGlass.isHidden = from != .desktop && to != .desktop
        tagGlass.alpha = (from == .immersive ? 1 - p : 0) + (to == .immersive ? p : 0)
        overviewGlass.alpha = (from == .desktop ? 1 - p : 0) + (to == .desktop ? p : 0)
        progressLabel.isHidden = from == .desktop && to == .desktop
        progressLabel.alpha = (from != .desktop ? 1 - p : 0) + (to != .desktop ? p : 0)
        progressLabel.accessibilityElementsHidden = true
        CATransaction.commit()
    }

    private func updateActiveEdgeEffects() {
        let scroll = coordinator.presentationScrollView ?? (interruptedSource?.background as? UIScrollView) ?? (mode == .immersive
            ? ((collectionView.cellForItem(at: IndexPath(item: session.localCurrentIndex, section: 0)) as? NoteReviewCollectionCell)?.activeContentScrollView ?? collectionView)
            : overview.presentationScrollView)
        if activeEdgeScrollView !== scroll {
            activeEdgeScrollView?.topEdgeEffect.isHidden = true
            activeEdgeScrollView?.bottomEdgeEffect.isHidden = true
        }
        activeEdgeScrollView = scroll
        scroll.topEdgeEffect.isHidden = areControlsHidden || NoteReviewCanvasHandoffDiagnostics.disablesEdges
        scroll.bottomEdgeEffect.isHidden = areControlsHidden || NoteReviewCanvasHandoffDiagnostics.disablesEdges
        scroll.topEdgeEffect.style = .soft
        scroll.bottomEdgeEffect.style = .soft
        topEdgeInteraction.scrollView = scroll
        bottomEdgeInteraction.scrollView = overview.widthSession?.showsToolbar == true ? nil : scroll
    }

    /// 调宽工具栏临时取代底部操作，避免进度与全景按钮挡住“取消／完成”；不改变画布尺寸。
    private func updateOverviewChromeOwnership() {
        let adjusting = overview.widthSession?.showsToolbar == true
        bottomChromeContainer.isHidden = areControlsHidden || adjusting
        bottomChromeContainer.isUserInteractionEnabled = !areControlsHidden && !adjusting
        bottomChromeContainer.accessibilityElementsHidden = areControlsHidden || adjusting
    }

    private func updateAccessibilityActions() {
        view.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "上一条书摘") { [weak self] _ in self?.moveAccessibility(by: -1) ?? false },
            UIAccessibilityCustomAction(name: "下一条书摘") { [weak self] _ in self?.moveAccessibility(by: 1) ?? false }
        ]
    }

    private func moveAccessibility(by distance: Int) -> Bool {
        guard coordinator.state == .idle, let id = session.noteID(at: session.localCurrentIndex + distance) else { return false }
        session.setCurrentNoteID(id)
        if mode == .immersive { restoreImmersiveAnchor() } else { overview.locate(noteID: id) }
        updateProgress()
        return true
    }

    /// 直接操作表达“继续阅读当前页”；只取消未接管画面的请求，不打断已经开始的共享动画。
    private func cancelSwitchForDirectManipulation() {
        if coordinator.state == .preparing { cancelRequestedMode() }
    }

    /// 所有入口共享同一动作定义；菜单闭包锁定的身份与浏览锚点互相独立。
    private enum NoteAction: CaseIterable {
        case detail, tags, original, delete
        var title: String {
            switch self {
            case .detail: "查看书摘详情"
            case .tags: "设置标签"
            case .original: "查看微信读书原文"
            case .delete: "删除书摘"
            }
        }
        var symbol: String {
            switch self {
            case .detail: "doc.text.magnifyingglass"
            case .tags: "tag"
            case .original: "arrow.up.right.square"
            case .delete: "trash"
            }
        }
    }

    /// 来源菜单异步取得完整上下文，但每个动作始终绑定长按时的 noteID；不修改回顾进度。
    private func noteActionMenu(noteID: Int64) -> UIMenu? {
        guard session.index(of: noteID) != nil, !isDisposed else { return nil }
        let actions: [UIMenuElement] = [NoteAction.detail, .tags].map { noteMenuAction($0, noteID: noteID) }
        let original = UIDeferredMenuElement.uncached { [weak self] completion in
            Task { @MainActor [weak self] in
                guard let self, !isDisposed else { completion([]); return }
                actionItemTask?.cancel()
                actionItemTask = Task { [weak self] in
                    guard let self else { completion([]); return }
                    do {
                        let item = try await session.fetchActionItem(noteID: noteID)
                        try Task.checkCancellation()
                        guard !isDisposed, session.index(of: noteID) != nil,
                              let value = item.weReadOriginalURL, let url = URL(string: value) else { completion([]); return }
                        completion([noteMenuAction(.original, noteID: noteID, originalURL: url)])
                    } catch { completion([]) }
                }
            }
        }
        return UIMenu(children: [
            UIMenu(options: .displayInline, children: actions + [original]),
            UIMenu(options: .displayInline, children: [noteMenuAction(.delete, noteID: noteID)])
        ])
    }

    /// 创建真实对象动作，破坏性项以系统语义标红；已在删除的对象不可重复提交。
    private func noteMenuAction(_ action: NoteAction, noteID: Int64, originalURL: URL? = nil) -> UIAction {
        var attributes: UIMenuElement.Attributes = action == .delete ? .destructive : []
        if session.deletingNoteIDs.contains(noteID) { attributes.insert(.disabled) }
        return UIAction(title: action.title, image: UIImage(systemName: action.symbol), attributes: attributes) { [weak self] _ in
            self?.requestNoteAction(action, noteID: noteID, originalURL: originalURL)
        }
    }

    /// VoiceOver 与长按共用业务动作及稳定身份，不要求用户额外探索长按手势。
    private func noteAccessibilityActions(noteID: Int64) -> [UIAccessibilityCustomAction] {
        NoteAction.allCases.filter { $0 != .original || session.item(for: noteID)?.weReadOriginalURL != nil }.map { action in
            UIAccessibilityCustomAction(name: action.title) { [weak self] _ in
                guard let self, session.index(of: noteID) != nil else { return false }
                requestNoteAction(action, noteID: noteID)
                return true
            }
        }
    }

    /// 等系统菜单完成收起后再导航或确认，避免与玻璃菜单的呈现通道争用。
    private func requestNoteAction(_ action: NoteAction, noteID: Int64, originalURL: URL? = nil) {
        guard !isDisposed, session.index(of: noteID) != nil else { return }
        cancelSwitchForDirectManipulation()
        guard coordinator.state == .idle else { return }
        deferredNoteAction = { [weak self] in
            guard let self, !isDisposed, session.index(of: noteID) != nil else { return }
            switch action {
            case .detail: onOpenDetail(noteID, session.detailSource)
            case .tags: handleTag(noteID: noteID)
            case .original:
                if let url = originalURL ?? session.item(for: noteID)?.weReadOriginalURL.flatMap(URL.init(string:)) {
                    UIApplication.shared.open(url)
                }
            case .delete: confirmDelete(noteID: noteID)
            }
        }
        performDeferredNoteAction()
    }

    /// 一次性消费已经固定目标的动作；任何较晚的列表/进度更新都不能替换目标。
    private func performDeferredNoteAction() {
        guard !isDisposed, !isReadingObjectMenuPresented, !overview.isObjectMenuPresented else { return }
        let action = deferredNoteAction
        deferredNoteAction = nil
        action?()
    }

    /// 删除只在用户确认后提交；这里使用系统中心确认，等待反馈不占用此破坏性决策容器。
    private func confirmDelete(noteID: Int64) {
        guard session.index(of: noteID) != nil, deleteTasks[noteID] == nil, presentedViewController == nil else { return }
        overview.isObjectMenuPresented = true
        XMSystemAlertController.present(on: self, descriptor: XMSystemAlertDescriptor(
            title: "删除这条书摘？", message: "书摘、附图和标签关系将永久删除，此操作无法撤销。",
            actions: [
                XMSystemAlertAction(title: "取消", role: .cancel) { [weak self] in self?.finishDeleteConfirmation() },
                XMSystemAlertAction(title: "删除", role: .destructive) { [weak self] in
                    guard let self else { return }
                    finishDeleteConfirmation()
                    deleteTasks[noteID] = Task { [weak self] in
                        guard let self else { return }
                        defer { deleteTasks[noteID] = nil }
                        do { try await session.deleteNote(noteID: noteID) }
                        catch is CancellationError { return }
                        catch { if !isDisposed { onError("删除失败：\(error.localizedDescription)") } }
                    }
                }
            ]))
    }

    /// 系统 Alert 结束后才允许观察回流补位；使用真实转场完成回调而非猜测延时。
    private func finishDeleteConfirmation() {
        if let alert = presentedViewController {
            alert.dismiss(animated: true) { [weak self] in self?.overview.isObjectMenuPresented = false }
        } else { overview.isObjectMenuPresented = false }
    }

    @objc private func handleBlankTap() { setControlsHidden(!areControlsHidden) }
    @objc private func handleOverview() { overview.toggleFullDesktop(); updateModeAppearance() }
    @objc private func handleClose() {
        if mode == .immersive, let target = transientReturnMode {
            transientReturnMode = nil
            requestMode(target, explicit: false)
        } else { disposeReviewSession(); onDismiss() }
    }

    func buildChrome() {
        configureChromeButton(closeButton, systemName: "xmark", accessibilityLabel: "关闭全屏回顾")
        configureChromeButton(tagButton, systemName: "tag", accessibilityLabel: "设置标签")
        tagButton.configuration?.image = UIImage(resource: .reiconTag2Outline).withRenderingMode(.alwaysTemplate)
        tagButton.showsMenuAsPrimaryAction = false
        tagButton.addAction(UIAction { [weak self] _ in
            guard let self, mode == .immersive, session.count > 0,
                  coordinator.state == .idle || coordinator.state == .preparing else { return }
            let id = session.currentNoteID
            cancelSwitchForDirectManipulation()
            handleTag(noteID: id)
        }, for: .touchUpInside)
        tagButton.loadingAccessibilityValue = "正在读取标签"
        configureChromeButton(overviewButton, systemName: "scope", accessibilityLabel: "回到全景")
        configureChromeButton(moreButton, systemName: "ellipsis", accessibilityLabel: "更多操作")
        closeButton.addTarget(self, action: #selector(handleClose), for: .touchUpInside)
        overviewButton.addTarget(self, action: #selector(handleOverview), for: .touchUpInside)
        moreButton.showsMenuAsPrimaryAction = true
        moreButton.onMenuWillDisplay = { [weak self] in
            guard let self, coordinator.state == .idle else { return }
            overview.beginMenuPrewarming(ids: session.orderedIDs, currentID: session.currentNoteID, settings: session.settings)
        }
        moreButton.onMenuDidEnd = { [weak self] in
            guard let self else { return }
            let requested = coordinator.requestedMode.map { $0 != .immersive } ?? false
            overview.endMenuPrewarming(cancelUnrequestedPreparation: !requested && mode == .immersive)
        }

        [closeGlass, overviewGlass].forEach(configureGlassHost)
        tagGlass.translatesAutoresizingMaskIntoConstraints = false
        // The menu button owns its glass and capsule; this outer view only positions it.
        moreGlass.translatesAutoresizingMaskIntoConstraints = false
        embed(closeButton, in: closeGlass)
        embed(tagButton, in: tagGlass)
        embed(overviewButton, in: overviewGlass)
        embed(moreButton, in: moreGlass)

        topChromeContainer.translatesAutoresizingMaskIntoConstraints = false
        bottomChromeContainer.translatesAutoresizingMaskIntoConstraints = false
        topChromeContainer.addInteraction(topEdgeInteraction)
        bottomChromeContainer.addInteraction(bottomEdgeInteraction)
        topEdgeInteraction.edge = .top
        bottomEdgeInteraction.edge = .bottom
        topChromeContainer.addSubview(closeGlass)
        topChromeContainer.addSubview(moreGlass)
        bottomChromeContainer.addSubview(tagGlass)
        bottomChromeContainer.addSubview(overviewGlass)

        progressLabel.translatesAutoresizingMaskIntoConstraints = false
        progressHost.view.backgroundColor = .clear
        progressHost.sizingOptions = .intrinsicContentSize
        addChild(progressHost)
        bottomChromeContainer.addSubview(progressLabel)
        progressHost.didMove(toParent: self)

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.text = "当前筛选下没有书摘"
        emptyLabel.font = ReadingContentTypography.uiBody
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.textAlignment = .center
        emptyLabel.isHidden = true

        view.addSubview(topChromeContainer)
        view.addSubview(bottomChromeContainer)
        view.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            topChromeContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topChromeContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topChromeContainer.topAnchor.constraint(equalTo: view.topAnchor),
            topChromeContainer.bottomAnchor.constraint(equalTo: closeGlass.bottomAnchor, constant: 10),
            closeGlass.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: Spacing.screenEdge),
            closeGlass.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            closeGlass.widthAnchor.constraint(equalToConstant: 48),
            closeGlass.heightAnchor.constraint(equalToConstant: 48),
            moreGlass.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -Spacing.screenEdge),
            moreGlass.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            moreGlass.widthAnchor.constraint(equalToConstant: 48),
            moreGlass.heightAnchor.constraint(equalToConstant: 48),

            bottomChromeContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomChromeContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomChromeContainer.topAnchor.constraint(equalTo: tagGlass.topAnchor, constant: -10),
            bottomChromeContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            tagGlass.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -Spacing.screenEdge),
            tagGlass.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10),
            tagGlass.widthAnchor.constraint(equalToConstant: 48),
            tagGlass.heightAnchor.constraint(equalToConstant: 48),
            overviewGlass.centerXAnchor.constraint(equalTo: tagGlass.centerXAnchor),
            overviewGlass.centerYAnchor.constraint(equalTo: tagGlass.centerYAnchor),
            overviewGlass.widthAnchor.constraint(greaterThanOrEqualToConstant: 48),
            overviewGlass.heightAnchor.constraint(equalToConstant: 48),
            progressLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            progressLabel.centerYAnchor.constraint(equalTo: tagGlass.centerYAnchor),
            progressLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: Spacing.screenEdge),
            progressLabel.trailingAnchor.constraint(lessThanOrEqualTo: tagGlass.leadingAnchor, constant: -Spacing.base),

            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: Spacing.double),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -Spacing.double)
        ])
        updateChromeColors()
    }
    /// 保留现有回顾页面的 业务展示行为。
    func configureChromeButton(_ button: UIButton, systemName: String, accessibilityLabel: String) {
        var configuration = button.configuration ?? UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: systemName)
        configuration.baseForegroundColor = .label
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            pointSize: 17,
            weight: .medium
        )
        button.configuration = configuration
        button.accessibilityLabel = accessibilityLabel
    }

    /// 保留现有回顾页面的 业务展示行为。
    func configureGlassHost(_ host: UIVisualEffectView) {
        host.translatesAutoresizingMaskIntoConstraints = false
        host.clipsToBounds = true
        host.layer.cornerRadius = 24
        host.layer.cornerCurve = .continuous
        if let glass = host.effect as? UIGlassEffect {
            glass.isInteractive = true
        }
    }

    /// 保留现有回顾页面的 业务展示行为。
    func embed(_ button: UIButton, in host: UIView) {
        button.translatesAutoresizingMaskIntoConstraints = false
        let content = (host as? UIVisualEffectView)?.contentView ?? host
        content.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            button.topAnchor.constraint(equalTo: content.topAnchor),
            button.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
    }

    /// 保留现有回顾页面的 业务展示行为。
    func updateTagButton() {
        tagButton.accessibilityLabel = "设置标签"
    }

    /// 保留现有回顾页面的 业务展示行为。
    func title(for mode: NoteReviewPresentationMode) -> String {
        switch mode {
        case .immersive: "单条回顾"
        case .desktop: "桌面"
        case .waterfall: "瀑布流"
        }
    }

    /// 保留现有回顾页面的 业务展示行为。
    func iconName(for mode: NoteReviewPresentationMode) -> String {
        switch mode {
        case .immersive: "rectangle.portrait"
        case .desktop: "square.grid.2x2"
        case .waterfall: "rectangle.grid.2x2"
        }
    }

    /// 保留现有回顾页面的 业务展示行为。
    func updateChromeColors() {
        [closeButton, tagButton, overviewButton, moreButton].forEach {
            $0.configuration?.baseForegroundColor = NoteReviewCanvasAppearance.chromeForeground
        }
    }

    /// 保留现有回顾页面的 阅读安全区域。
    var immersiveChromeInsets: UIEdgeInsets {
        UIEdgeInsets(
            top: view.safeAreaInsets.top + 10 + 48 + Spacing.base,
            left: 0,
            bottom: view.safeAreaInsets.bottom + 10 + 48 + Spacing.base,
            right: 0
        )
    }

    /// 保留现有回顾页面的 业务展示行为。
    func updateVisibleCellChromeInsets() {
        let insets = immersiveChromeInsets
        for case let cell as NoteReviewCollectionCell in collectionView.visibleCells {
            cell.updateChromeInsets(top: insets.top, bottom: insets.bottom)
        }
    }

    /// 保留现有回顾页面的 固定控件显隐。
    func setControlsHidden(_ hidden: Bool) {
        guard areControlsHidden != hidden else { return }
        areControlsHidden = hidden
        chromeAnimator?.stopAnimation(true)
        let containers = [topChromeContainer, bottomChromeContainer]
        if !hidden { containers.forEach { $0.isHidden = false } }
        containers.forEach {
            $0.isUserInteractionEnabled = !hidden
            $0.accessibilityElementsHidden = hidden
        }
        updateAccessibilityActions()
        updateActiveEdgeEffects()
        guard !UIAccessibility.isReduceMotionEnabled else {
            containers.forEach { $0.alpha = hidden ? 0 : 1; $0.isHidden = hidden }
            return
        }
        let animator = UIViewPropertyAnimator(duration: 0.18, curve: .easeInOut) {
            containers.forEach { $0.alpha = hidden ? 0 : 1 }
        }
        animator.addCompletion { [weak self] position in
            guard let self, position == .end, areControlsHidden == hidden else { return }
            containers.forEach { $0.isHidden = hidden }
            chromeAnimator = nil
        }
        chromeAnimator = animator
        animator.startAnimation()
    }

    /// 保留现有回顾页面的 标签读取与编辑入口。
    func handleTag(noteID: Int64) {
        guard tagPreparationTask == nil, session.index(of: noteID) != nil else { return }
        setTagLoading(true)
        tagPreparationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                tagPreparationTask = nil
                setTagLoading(false)
            }
            do {
                let snapshot = try await session.fetchTagEditSnapshot(noteID: noteID)
                try Task.checkCancellation()
                guard !isDisposed, session.index(of: noteID) != nil else { return }
                presentTagEditor(noteID: noteID, snapshot: snapshot)
            } catch is CancellationError {
                return
            } catch {
                if !isDisposed, !Task.isCancelled { onError("读取标签失败：\(error.localizedDescription)") }
            }
        }
    }

    /// 保留现有回顾页面的 业务展示行为。
    func setTagLoading(_ isLoading: Bool) {
        tagButton.setReviewLoading(isLoading)
        tagButton.isEnabled = session.count > 0 && !isLoading
        tagButton.accessibilityLabel = isLoading ? "正在读取标签" : "设置标签"
    }

    /// 保留现有回顾页面的 图片浏览入口。
    func openImages(item: NoteReviewCardItem, index: Int) {
        let galleryItems = item.imageURLs.enumerated().map { offset, url in
            XMJXGalleryItem(
                id: "note-review-\(item.id)-\(offset)",
                thumbnailURL: url,
                originalURL: url,
                accessibilityLabel: "书摘图片 \(offset + 1)"
            )
        }
        guard !galleryItems.isEmpty else { return }
        let host = XMJXPhotoBrowserHost(initialItems: galleryItems)
        galleryHost = host
        host.open(
            at: max(0, min(index, galleryItems.count - 1)),
            wallID: "note-review-\(item.id)",
            tapSequence: 1
        )
    }

    /// 保留现有回顾页面的 业务展示行为。
    func presentTagEditor(noteID: Int64, snapshot: NoteReviewTagEditSnapshot) {
        let editor = NoteReviewTagEditSheet(
            snapshot: snapshot,
            onCreateTag: { [weak session] name in
                guard let session else { throw CancellationError() }
                return try await session.createTag(named: name)
            },
            onTagCatalogMutation: { [weak session] mutation in
                session?.applyTagCatalogMutation(mutation)
            },
            onSave: { [weak session] tags in
                guard let session else { return false }
                return await session.replaceTags(tags, noteID: noteID)
            }
        )
        .environment(repositories)
        .environment(toastCenter)
        let hosting = UIHostingController(rootView: editor)
        hosting.modalPresentationStyle = .pageSheet
        if let sheet = hosting.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(hosting, animated: true)
    }

    /// 保留现有回顾页面的 业务展示行为。
    func presentDisplaySettings() {
        let controller = NoteReviewDisplaySettingsViewController(
            settings: session.settings.immersiveDisplay,
            overviewOnly: mode != .immersive,
            onChange: { [weak session] display in session?.updateDisplaySettings(display) }
        )
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .pageSheet
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(navigation, animated: true)
    }
}

extension NoteReviewViewController: UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching, UIGestureRecognizerDelegate {
    /// 只在允许的纸面区域建立对象菜单；立即从索引转为身份，之后不再读取 currentNoteID。
    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard mode == .immersive, coordinator.state == .idle || coordinator.state == .preparing, let path = indexPaths.first,
              let id = session.noteID(at: path.item),
              let cell = collectionView.cellForItem(at: path) as? NoteReviewCollectionCell,
              cell.allowsNoteActions(at: cell.convert(point, from: collectionView)) else { return nil }
        cancelSwitchForDirectManipulation()
        return UIContextMenuConfiguration(identifier: NSNumber(value: id), previewProvider: nil) { [weak self] _ in
            self?.noteActionMenu(noteID: id)
        }
    }
    /// 原生菜单实际展示时记录配置身份，与右下操作入口分别持有保护。
    func collectionView(_ collectionView: UICollectionView, willDisplayContextMenu configuration: UIContextMenuConfiguration,
                        animator: (any UIContextMenuInteractionAnimating)?) {
        guard !isDisposed else { return }
        readingObjectMenuConfiguration = configuration
    }
    /// 收起完成只释放同一次菜单；旧回调不能提前执行新菜单中的业务动作。
    func collectionView(_ collectionView: UICollectionView, willEndContextMenuInteraction configuration: UIContextMenuConfiguration,
                        animator: (any UIContextMenuInteractionAnimating)?) {
        let finish = { [weak self] in
            guard let self, readingObjectMenuConfiguration === configuration else { return }
            readingObjectMenuConfiguration = nil
            performDeferredNoteAction()
        }
        if let animator { animator.addCompletion(finish) } else { finish() }
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        session.isReadingInteractionActive = true
        cancelSwitchForDirectManipulation()
    }
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { session.loadedCount }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: NoteReviewCollectionCell.reuseIdentifier, for: indexPath) as! NoteReviewCollectionCell
        if let id = session.noteID(at: indexPath.item) { configure(cell: cell, noteID: id) }
        return cell
    }
    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? NoteReviewCollectionCell)?.didEndDisplaying()
    }
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        session.prefetch(noteIDs: indexPaths.compactMap { session.noteID(at: $0.item) })
    }
    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        session.cancelPrefetch(noteIDs: indexPaths.compactMap { session.noteID(at: $0.item) })
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard mode == .immersive, !isPositioning, coordinator.state == .idle else { return }
        refreshVisibleRange()
        if collectionView.bounds.height > 0,
           let id = session.noteID(at: Int((collectionView.contentOffset.y / collectionView.bounds.height).rounded())) {
            session.prepareReadingWindow(around: id)
        }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settleReading() }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { settleReading() } }
    private func settleReading() {
        session.isReadingInteractionActive = false
        guard mode == .immersive, coordinator.state == .idle, collectionView.bounds.height > 0 else { return }
        let index = Int((collectionView.contentOffset.y / collectionView.bounds.height).rounded())
        guard let id = session.noteID(at: index) else { return }
        if id != session.currentNoteID { session.setCurrentNoteID(id); selectionFeedback.selectionChanged() }
        session.applyPendingReadingWindow()
        updateProgress()
        updateActiveEdgeEffects()
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === blankTapGesture, mode == .immersive else { return false }
        let path = collectionView.indexPathForItem(at: touch.location(in: collectionView))
        return path.flatMap { collectionView.cellForItem(at: $0) as? NoteReviewCollectionCell }?.isBlankChromeToggleTarget(touch.view) ?? false
    }
}

/// 把 VoiceOver 三指滚动交给当前概览模式逐条导航。
private final class NoteReviewCollectionView: UICollectionView {
    var onAccessibilityScroll: ((UIAccessibilityScrollDirection) -> Bool)?
    var onAccessibilityActivate: (() -> Bool)?

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        if onAccessibilityScroll?(direction) == true { return true }
        return super.accessibilityScroll(direction)
    }

    override func accessibilityActivate() -> Bool {
        if onAccessibilityActivate?() == true { return true }
        return super.accessibilityActivate()
    }
}

/// 透明 chrome 容器只让实际控件参与命中，空白继续交给画布。
private final class NoteReviewPassthroughChromeView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let target = super.hitTest(point, with: event)
        return target === self ? nil : target
    }
}

/// 单条与概览共享的内容设置 Sheet；正文固定显示，其余层级即时写回现有偏好。
@MainActor
private final class NoteReviewDisplaySettingsViewController: UITableViewController {
    private enum Row: Int, CaseIterable {
        case idea, images, bookInfo, createdDate, chapter, position, tags

        var title: String {
            switch self {
            case .idea: "想法"
            case .images: "图片"
            case .bookInfo: "书籍"
            case .createdDate: "日期"
            case .chapter: "章节"
            case .position: "位置"
            case .tags: "标签"
            }
        }
    }

    private var settings: NoteReviewImmersiveDisplaySettings
    private let onChange: (NoteReviewImmersiveDisplaySettings) -> Void
    private let rows: [Row]

    /// 注入当前显示设置与即时保存回调。
    init(
        settings: NoteReviewImmersiveDisplaySettings,
        overviewOnly: Bool,
        onChange: @escaping (NoteReviewImmersiveDisplaySettings) -> Void
    ) {
        self.settings = settings
        rows = overviewOnly ? [.idea, .bookInfo, .chapter] : Row.allCases
        self.onChange = onChange
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "显示内容"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .close,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
        )
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "display")
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let row = rows[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "display", for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.text = row.title
        cell.contentConfiguration = content
        let toggle = UISwitch()
        toggle.isOn = value(for: row)
        toggle.tag = row.rawValue
        toggle.addTarget(self, action: #selector(handleToggle(_:)), for: .valueChanged)
        cell.accessoryView = toggle
        cell.selectionStyle = .none
        return cell
    }

    /// 将单行开关写入快照并立即通知页面会话。
    @objc private func handleToggle(_ sender: UISwitch) {
        guard let row = Row(rawValue: sender.tag) else { return }
        setValue(sender.isOn, for: row)
        onChange(settings)
    }

    /// 读取行对应布尔值。
    private func value(for row: Row) -> Bool {
        switch row {
        case .idea: settings.showsIdea
        case .images: settings.showsImages
        case .bookInfo: settings.showsBookInfo
        case .createdDate: settings.showsCreatedDate
        case .chapter: settings.showsChapter
        case .position: settings.showsPosition
        case .tags: settings.showsTags
        }
    }

    /// 写入行对应布尔值。
    private func setValue(_ value: Bool, for row: Row) {
        switch row {
        case .idea: settings.showsIdea = value
        case .images: settings.showsImages = value
        case .bookInfo: settings.showsBookInfo = value
        case .createdDate: settings.showsCreatedDate = value
        case .chapter: settings.showsChapter = value
        case .position: settings.showsPosition = value
        case .tags: settings.showsTags = value
        }
    }
}
