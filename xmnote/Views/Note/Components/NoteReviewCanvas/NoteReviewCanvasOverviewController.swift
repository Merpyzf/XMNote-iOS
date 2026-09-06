/**
 * [INPUT]: 接收有序书摘身份、可取消源读取闭包、外观及页面动作回调
 * [OUTPUT]: 提供生产与测试中心共用的单画布、瀑布流、调宽和连续纸张转场
 * [POS]: NoteReviewCanvas 页面内部总览实现；不访问 Repository、偏好或导航
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import CoreText
import os
import QuartzCore
import SwiftUI
import UIKit

// MARK: - CanvasOverview controller

/// 在同一 UIKit 生命周期中管理单画布、瀑布流和可反向共享纸张转场。
@MainActor
class NoteReviewCanvasOverviewController: UIViewController {
    enum Mode: Int {
        case desktop
        case waterfall
    }

    enum Metrics {
        static let controlInset: CGFloat = Spacing.screenEdge
        static let controlHeight: CGFloat = 48
        static let diagnosticRefreshInterval: TimeInterval = 0.25
    }

    let preparationQueue = DispatchQueue(
        label: "com.wangke.xmnote.debug.single-canvas-preparation",
        qos: .userInitiated
    )
    let signposter = OSSignposter(subsystem: "com.wangke.xmnote", category: "SingleCanvasLab")
    let previewStore = CanvasOverviewPreviewStore()
    let rasterPreparationCache = CanvasOverviewRasterPreparationCache()
    let previewBatchCoordinator = CanvasOverviewPreviewBatchCoordinator()
    var isMenuPrewarming = false
    var menuPreparationGeneration: Int?
    var menuPrewarmRequestGeneration = 0
    var menuPrewarmTask: Task<Void, Never>?
    var programmaticPositionGeneration = 0
    var pendingProgrammaticPosition: (generation: Int, mode: Mode, noteID: Int64)?
    var isApplyingProgrammaticZoomSynchronously = false
    var positionPreviewTask: Task<Void, Never>?
    var previewTask: Task<Void, Never>?
    var previewWorkerGeneration = 0
    var previewDrawingPins: [CanvasOverviewResourceKey: NoteReviewCanvasResourceLease<CanvasOverviewDrawingPayload>] = [:]
    var transitionPreviewPins: [CanvasOverviewResourceKey: NoteReviewCanvasResourceLease<CanvasOverviewDrawingPayload>] = [:]
    var previewVisibleDemand: [Int64] = []
    var previewAttemptedIDs = Set<Int64>()
    var previewRetryAfter: CFTimeInterval = 0
    var previewSourcePins: [CanvasOverviewResourceKey: NoteReviewCanvasResourceLease<CanvasOverviewPreviewPayload>] = [:]
    var lastPreviewRequestTime: CFTimeInterval = 0
    var previewDemand: [Int64] = []
    var transitionWarmTask: Task<Void, Never>?
    var modeDissolve: NoteReviewCanvasSurfaceDissolve?
    var deletionUpdate: CanvasOverviewDeletionUpdate?
    var pendingDeletionSnapshot: CanvasOverviewDeletionSnapshot?
    var isObjectMenuPresented = false {
        didSet { if !isObjectMenuPresented { commitDeferredModelIfPossible() } }
    }
    var objectMenuConfiguration: UIContextMenuConfiguration?
    var objectMenuPreview: UITargetedPreview?
    var desktopObjectMenuInteraction: UIContextMenuInteraction?

    let tintBackdropView = UIView()
    let desktopScrollView = UIScrollView()
    let zoomContentView = CanvasOverviewZoomContentView()
    let waterfallLayout = CanvasOverviewWaterfallLayout()
    lazy var waterfallView = UICollectionView(frame: .zero, collectionViewLayout: waterfallLayout)

    let topControlPanel = UIView()
    let bottomControlPanel = UIView()
    let modeControl = UISegmentedControl(items: ["桌面", "瀑布流"])
    let countButton = UIButton(type: .system)
    let diagnosticsButton = UIButton(type: .system)
    let currentButton = UIButton(type: .system)
    let fullDesktopButton = UIButton(type: .system)
    let reduceMotionLabel = UILabel()
    let reduceMotionSwitch = UISwitch()
    let diagnosticsLabel = UILabel()
    let loadingContainer = UIView()
    let loadingIndicator = UIActivityIndicatorView(style: .medium)
    let loadingLabel = UILabel()

    var preparedModel: CanvasOverviewPreparedModel?
    var currentMode: Mode = .desktop
    var currentNoteID: Int64?
    var selectedCount = 374
    var selectedDesktopCardWidth = CanvasOverviewDesktopCardWidth.defaultValue
    var desktopPacking: CanvasOverviewDesktopPacking = .compactPairs
    var isPreparingDesktopWidth = false
    var widthSession: CanvasOverviewWidthSession?
    var widthDisplayLink: CADisplayLink?
    let widthToolbar = CanvasOverviewWidthToolbar()
    let widthEdgeInteraction = UIScrollEdgeElementContainerInteraction()
    let widthQueue = DispatchQueue(label: "com.wangke.xmnote.debug.width-preview", qos: .userInitiated)
    let widthRasterQueue = DispatchQueue(label: "com.wangke.xmnote.debug.width-raster", qos: .userInteractive)
    typealias SourceReader = @MainActor ([Int64], TaskPriority) async throws -> [NoteReviewOverviewLayoutSource]
    var sourceReader: SourceReader?
    var stackGroupReader: (@MainActor (NoteReviewCanvasStackRequest) async throws -> NoteReviewCanvasStackGroup?)?
    var onGroupCapacityChanged: ((Int) -> Void)?
    var stackBrowser: CanvasStackBrowserView?
    var stackSession: CanvasStackBrowsingSession?
    let startStackAnimation: (UIViewPropertyAnimator) -> Void
    var stackTask: Task<Void, Never>?
    var stackNeighborTask: Task<Void, Never>?
    var stackWork: CanvasOverviewTransitionPreparation?
    var stackRequestGeneration = 0
    var stackPreviews: [CanvasStackPreview] = []
    var stackViewports: [NoteReviewCanvasStackID: CanvasOverviewViewportState] = [:]
    var stackAllIDs: [Int64] = []
    var stackFixtureSnapshot = UUID()
    var selectedGroupCapacity = 96
    var directoryRegionReader: (@MainActor (Int64) async throws -> NoteReviewCanvasDirectoryRegion)?
    var directoryNeighborReader: (@MainActor (NoteReviewDirectoryGroupID) async throws -> NoteReviewCanvasDirectoryRegion?)?
    var directoryCatalogReader: (@MainActor (NoteReviewDirectoryGroupID?, Int) async throws -> NoteReviewCanvasDirectoryCatalog)?
    var directoryWaterfallPageReader: (@MainActor (Int64) async throws -> NoteReviewDirectoryPage?)?
    var directoryWaterfallPage: NoteReviewDirectoryPage?
    var waterfallPageTask: Task<Void, Never>?
    var waterfallPageWork: CanvasOverviewTransitionPreparation?
    var waterfallPageGeneration = 0
    var pendingWaterfallPage: (NoteReviewDirectoryPage, CanvasOverviewWaterfallGeometry)?
    var directoryCatalog: NoteReviewCanvasDirectoryCatalog?
    var directoryCatalogTask: Task<Void, Never>?
    var directoryCatalogGeneration = 0
    var isCatalogHandoffPending = false
    var canCommitBackgroundGeometry: (() -> Bool)?
    let directoryCatalogView = NoteReviewCanvasCatalogView()
    var onResidentRegionIDs: ((Set<Int64>) -> Void)?
    var regionalModels: [NoteReviewDirectoryGroupID: CanvasOverviewPreparedModel] = [:]
    var regionalMetadata: [NoteReviewDirectoryGroupID: NoteReviewCanvasDirectoryRegion] = [:]
    var regionalWindow: NoteReviewCanvasRegionWindow?
    var regionalTask: Task<Void, Never>?
    var regionalWork: CanvasOverviewTransitionPreparation?
    var regionalRequestGeneration = 0
    var regionalDesiredIDs: [NoteReviewDirectoryGroupID] = []
    var regionalUnavailableIDs = Set<NoteReviewDirectoryGroupID>()
    var regionalLastDemand: CFTimeInterval = 0
    var directoryInputGeneration: UInt64?
    var activeDirectoryRegion: NoteReviewCanvasDirectoryRegion?
    var requestedPreparationMode: Mode = .desktop
    var backgroundReader: (@MainActor (String) async throws -> CGImage?)?
    var preparedBackgroundURL: String?
    var preparedBackgroundImage: CGImage?
    var resolveDataIDs: (() async throws -> [Int64])?
    var dataIDs: [Int64] = []
    var renderingSettings: NoteReviewSettings?
    var showsDiagnosticControls = false
    var extendsUnderSafeArea = false
    var contentOcclusionInsets: UIEdgeInsets = .zero
    var onCurrentChanged: ((Int64) -> Void)?
    var onActivate: ((Int64) -> Void)?
    var onBlankTap: (() -> Void)?
    var onSettledMode: ((Mode) -> Void)?
    var onConfirmedWidth: ((Int) -> Void)?
    var onControlsChanged: (() -> Void)?
    var onModeTransitionProgress: ((Mode, Mode, CGFloat) -> Void)?
    var onPreparationChanged: ((Bool, String?) -> Void)?
    var onReady: (() -> Void)?
    var onDemand: (([Int64], [Int64]) -> Void)?
    var onWidthEnded: (() -> Void)?
    var onMissingIDs: ((Set<Int64>) -> Void)?
    var onUserInteractionBegan: (() -> Void)?
    var onNoteActionMenu: ((Int64) -> UIMenu?)?
    var onNoteAccessibilityActions: ((Int64) -> [UIAccessibilityCustomAction])?
    var onObjectMenuDidEnd: (() -> Void)?
    var isDisposed = false
    var isCanvasPaused = false
    var pausedAt: CFTimeInterval?
    var deferredModel: (model: CanvasOverviewPreparedModel, anchor: Int64?, generation: Int)?
    var usesRealData = false
    var usesAlternateWaterfallStyle = false
    var realDataTask: Task<Void, Never>?
    var modelPreparation: CanvasOverviewTransitionPreparation?
    var preparationIsPending = false
    var generation = 0
    var requestedInitialPreparation = false
    var automaticallyPreparesOverview = true
    var lastPreparedViewportSize: CGSize = .zero
    var isShowingFullDesktop = false
    var diagnosticsTimer: Timer?
    var transitionContext: CanvasOverviewTransitionContext?
    var transitionState: CanvasOverviewTransitionState = .idle
    var transitionGeneration = 0
    var transitionPreparation: CanvasOverviewTransitionPreparation?
    var pendingMode: Mode?
    var desktopViewport: CanvasOverviewViewportState?
    var waterfallViewport: CanvasOverviewViewportState?
    var environmentCover: UIView?
    var isPositioningViewport = false
    var transitionDisplayLink: CADisplayLink?
    var lastTransitionParticipantCount = 0
    var lastStableWaterfallOffset: CGPoint = .zero
    var appearanceTraitRegistration: (any UITraitChangeRegistration)?

    /// 生产默认立即运行原生时间轴；限定测试可注入同步暂停的时钟驱动，不读取任何诊断偏好。
    init(startStackAnimation: @escaping (UIViewPropertyAnimator) -> Void = { $0.startAnimation() }) {
        self.startStackAnimation = startStackAnimation
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureHierarchy()
        configureControls()
        configureWidthToolbar()
        configureGestures()
        topControlPanel.isHidden = !showsDiagnosticControls
        bottomControlPanel.isHidden = !showsDiagnosticControls
        updateAppearance()
        appearanceTraitRegistration = registerForTraitChanges(
            [
                UITraitUserInterfaceStyle.self,
                UITraitPreferredContentSizeCategory.self,
                UITraitAccessibilityContrast.self,
            ]
        ) { (controller: NoteReviewCanvasOverviewController, _) in
            controller.updateAppearance()
            guard controller.preparedModel != nil else { return }
            controller.requestPreparation(
                count: controller.selectedCount,
                preservingCurrentID: controller.currentNoteID
            )
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        resumeCanvas()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        pauseCanvas()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !isCanvasPaused, view.bounds.width > 0, view.bounds.height > 0 else { return }

        if !requestedInitialPreparation {
            requestPreparationIfNeeded()
        } else if preparedModel != nil,
                  (abs(lastPreparedViewportSize.width - desktopScrollView.bounds.width) > 1
                   || abs(lastPreparedViewportSize.height - desktopScrollView.bounds.height) > 1) {
            requestPreparation(count: selectedCount, preservingCurrentID: currentNoteID)
        }
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        rasterPreparationCache.removeAll()
        previewStore.removeUnprotected()
        previewDemand = []
        guard let session = widthSession else { return }
        // Keep the displayed endpoint; discard only replaceable work, never expose the hidden canvas.
        session.previewTask?.cancel()
        session.previewTask = nil
        session.queuedPreview = nil
        if session.blend >= 1, session.automaticCover == nil {
            session.previous = session.current
            if let current = session.current { session.scene?.bind(source: current, target: current) }
        }
        wakeWidthDisplayLink()
    }

    func configureHierarchy() {
        view.backgroundColor = NoteReviewCanvasAppearance.page

        tintBackdropView.translatesAutoresizingMaskIntoConstraints = false
        tintBackdropView.isUserInteractionEnabled = false
        view.addSubview(tintBackdropView)

        desktopScrollView.translatesAutoresizingMaskIntoConstraints = false
        desktopScrollView.delegate = self
        desktopScrollView.backgroundColor = .clear
        desktopScrollView.showsHorizontalScrollIndicator = false
        desktopScrollView.showsVerticalScrollIndicator = false
        desktopScrollView.alwaysBounceHorizontal = true
        desktopScrollView.alwaysBounceVertical = true
        desktopScrollView.decelerationRate = .normal
        desktopScrollView.contentInsetAdjustmentBehavior = .never
        view.addSubview(desktopScrollView)

        desktopScrollView.addSubview(zoomContentView)

        waterfallView.translatesAutoresizingMaskIntoConstraints = false
        waterfallView.backgroundColor = .clear
        waterfallView.contentInsetAdjustmentBehavior = .never
        waterfallView.alwaysBounceVertical = true
        waterfallView.showsVerticalScrollIndicator = false
        waterfallView.dataSource = self
        waterfallView.delegate = self
        waterfallView.register(CanvasOverviewWaterfallCell.self, forCellWithReuseIdentifier: CanvasOverviewWaterfallCell.reuseID)
        waterfallView.alpha = 0
        waterfallView.isUserInteractionEnabled = false
        view.addSubview(waterfallView)

        configureControlPanel(topControlPanel)
        configureControlPanel(bottomControlPanel)
        view.addSubview(topControlPanel)
        view.addSubview(bottomControlPanel)

        diagnosticsLabel.translatesAutoresizingMaskIntoConstraints = false
        diagnosticsLabel.numberOfLines = 0
        diagnosticsLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        diagnosticsLabel.textColor = NoteReviewCanvasAppearance.secondary
        diagnosticsLabel.backgroundColor = NoteReviewCanvasAppearance.paper.withAlphaComponent(0.94)
        diagnosticsLabel.layer.cornerRadius = CornerRadius.blockLarge
        diagnosticsLabel.layer.masksToBounds = true
        diagnosticsLabel.isHidden = true
        diagnosticsLabel.accessibilityIdentifier = "singleCanvasDiagnostics"
        view.addSubview(diagnosticsLabel)

        loadingContainer.translatesAutoresizingMaskIntoConstraints = false
        loadingContainer.backgroundColor = NoteReviewCanvasAppearance.paper.withAlphaComponent(0.96)
        loadingContainer.layer.cornerRadius = CornerRadius.containerMedium
        loadingContainer.layer.shadowColor = UIColor.black.cgColor
        loadingContainer.layer.shadowOpacity = 0.08
        loadingContainer.layer.shadowRadius = 12
        loadingContainer.layer.shadowOffset = CGSize(width: 0, height: 4)
        view.addSubview(loadingContainer)

        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingLabel.translatesAutoresizingMaskIntoConstraints = false
        loadingLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        loadingLabel.textColor = NoteReviewCanvasAppearance.secondary
        loadingLabel.text = "正在准备稳定画布…"
        let loadingStack = UIStackView(arrangedSubviews: [loadingIndicator, loadingLabel])
        loadingStack.translatesAutoresizingMaskIntoConstraints = false
        loadingStack.axis = .horizontal
        loadingStack.alignment = .center
        loadingStack.spacing = Spacing.cozy
        loadingContainer.addSubview(loadingStack)

        NSLayoutConstraint.activate([
            tintBackdropView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tintBackdropView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tintBackdropView.topAnchor.constraint(equalTo: view.topAnchor),
            tintBackdropView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            desktopScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            desktopScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            desktopScrollView.topAnchor.constraint(equalTo: extendsUnderSafeArea ? view.topAnchor : view.safeAreaLayoutGuide.topAnchor),
            desktopScrollView.bottomAnchor.constraint(equalTo: extendsUnderSafeArea ? view.bottomAnchor : view.safeAreaLayoutGuide.bottomAnchor),

            waterfallView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            waterfallView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            waterfallView.topAnchor.constraint(equalTo: extendsUnderSafeArea ? view.topAnchor : view.safeAreaLayoutGuide.topAnchor),
            waterfallView.bottomAnchor.constraint(equalTo: extendsUnderSafeArea ? view.bottomAnchor : view.safeAreaLayoutGuide.bottomAnchor),

            topControlPanel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            topControlPanel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Spacing.cozy),
            topControlPanel.heightAnchor.constraint(equalToConstant: Metrics.controlHeight),
            topControlPanel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: Metrics.controlInset),
            topControlPanel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -Metrics.controlInset),

            bottomControlPanel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            bottomControlPanel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -Spacing.base),
            bottomControlPanel.heightAnchor.constraint(equalToConstant: Metrics.controlHeight),
            bottomControlPanel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: Metrics.controlInset),
            bottomControlPanel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -Metrics.controlInset),

            diagnosticsLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Spacing.screenEdge),
            diagnosticsLabel.topAnchor.constraint(equalTo: topControlPanel.bottomAnchor, constant: Spacing.cozy),
            diagnosticsLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 270),

            loadingContainer.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingContainer.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            loadingStack.leadingAnchor.constraint(equalTo: loadingContainer.leadingAnchor, constant: Spacing.contentEdge),
            loadingStack.trailingAnchor.constraint(equalTo: loadingContainer.trailingAnchor, constant: -Spacing.contentEdge),
            loadingStack.topAnchor.constraint(equalTo: loadingContainer.topAnchor, constant: Spacing.base),
            loadingStack.bottomAnchor.constraint(equalTo: loadingContainer.bottomAnchor, constant: -Spacing.base),
        ])
    }

    func configureControlPanel(_ panel: UIView) {
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.backgroundColor = NoteReviewCanvasAppearance.paper.withAlphaComponent(0.96)
        panel.layer.cornerRadius = CornerRadius.containerMedium
        panel.layer.borderWidth = StrokeWidth.hairline
        panel.layer.borderColor = NoteReviewCanvasAppearance.subtleBorder.cgColor
        panel.layer.shadowColor = UIColor.black.cgColor
        panel.layer.shadowOpacity = 0.08
        panel.layer.shadowRadius = 10
        panel.layer.shadowOffset = CGSize(width: 0, height: 4)
    }

    func configureControls() {
        modeControl.selectedSegmentIndex = Mode.desktop.rawValue
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        modeControl.accessibilityIdentifier = "singleCanvasModeControl"

        var countConfiguration = UIButton.Configuration.plain()
        countConfiguration.image = UIImage(systemName: "rectangle.stack")
        countConfiguration.imagePadding = Spacing.compact
        countButton.configuration = countConfiguration
        countButton.showsMenuAsPrimaryAction = true
        countButton.accessibilityIdentifier = "singleCanvasCountButton"
        updateCountMenu()

        var diagnosticConfiguration = UIButton.Configuration.plain()
        diagnosticConfiguration.image = UIImage(systemName: "waveform.path.ecg")
        diagnosticsButton.configuration = diagnosticConfiguration
        diagnosticsButton.accessibilityLabel = "显示或隐藏诊断信息"
        diagnosticsButton.accessibilityIdentifier = "singleCanvasDiagnosticsButton"
        diagnosticsButton.addTarget(self, action: #selector(toggleDiagnostics), for: .touchUpInside)

        let topStack = UIStackView(arrangedSubviews: [modeControl, countButton, diagnosticsButton])
        topStack.translatesAutoresizingMaskIntoConstraints = false
        topStack.axis = .horizontal
        topStack.alignment = .center
        topStack.spacing = Spacing.cozy
        topControlPanel.addSubview(topStack)

        var currentConfiguration = UIButton.Configuration.plain()
        currentConfiguration.image = UIImage(systemName: "scope")
        currentConfiguration.imagePadding = Spacing.compact
        currentButton.configuration = currentConfiguration
        currentButton.accessibilityIdentifier = "singleCanvasCurrentButton"
        currentButton.addTarget(self, action: #selector(returnToCurrent), for: .touchUpInside)

        var fullConfiguration = UIButton.Configuration.plain()
        fullConfiguration.image = UIImage(systemName: "arrow.down.right.and.arrow.up.left")
        fullDesktopButton.configuration = fullConfiguration
        fullDesktopButton.accessibilityLabel = "查看完整桌面"
        fullDesktopButton.accessibilityIdentifier = "singleCanvasFullDesktopButton"
        fullDesktopButton.addTarget(self, action: #selector(toggleFullDesktop), for: .touchUpInside)

        reduceMotionLabel.text = "减弱"
        reduceMotionLabel.font = UIFont.preferredFont(forTextStyle: .caption1)
        reduceMotionLabel.textColor = NoteReviewCanvasAppearance.secondary
        reduceMotionSwitch.accessibilityLabel = "强制预览减少动态效果"
        reduceMotionSwitch.accessibilityIdentifier = "singleCanvasReduceMotionSwitch"

        let reduceStack = UIStackView(arrangedSubviews: [reduceMotionLabel, reduceMotionSwitch])
        reduceStack.axis = .horizontal
        reduceStack.alignment = .center
        reduceStack.spacing = Spacing.compact

        let bottomStack = UIStackView(arrangedSubviews: [currentButton, fullDesktopButton, reduceStack])
        bottomStack.translatesAutoresizingMaskIntoConstraints = false
        bottomStack.axis = .horizontal
        bottomStack.alignment = .center
        bottomStack.spacing = Spacing.cozy
        bottomControlPanel.addSubview(bottomStack)

        NSLayoutConstraint.activate([
            topStack.leadingAnchor.constraint(equalTo: topControlPanel.leadingAnchor, constant: Spacing.cozy),
            topStack.trailingAnchor.constraint(equalTo: topControlPanel.trailingAnchor, constant: -Spacing.cozy),
            topStack.centerYAnchor.constraint(equalTo: topControlPanel.centerYAnchor),
            modeControl.widthAnchor.constraint(equalToConstant: 172),

            bottomStack.leadingAnchor.constraint(equalTo: bottomControlPanel.leadingAnchor, constant: Spacing.cozy),
            bottomStack.trailingAnchor.constraint(equalTo: bottomControlPanel.trailingAnchor, constant: -Spacing.cozy),
            bottomStack.centerYAnchor.constraint(equalTo: bottomControlPanel.centerYAnchor),
        ])
    }

    func configureGestures() {
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(desktopTapped(_:)))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(desktopDoubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        singleTap.require(toFail: doubleTap)
        singleTap.cancelsTouchesInView = false
        doubleTap.cancelsTouchesInView = false
        desktopScrollView.addGestureRecognizer(singleTap)
        desktopScrollView.addGestureRecognizer(doubleTap)
        configureObjectActions()
    }

    func updateAppearance() {
        view.backgroundColor = NoteReviewCanvasAppearance.page
        tintBackdropView.backgroundColor = NoteReviewCanvasAppearance.accent.withAlphaComponent(0.025)
        zoomContentView.backgroundColor = .clear
        waterfallView.backgroundColor = .clear
        topControlPanel.backgroundColor = NoteReviewCanvasAppearance.paper.withAlphaComponent(0.96)
        bottomControlPanel.backgroundColor = NoteReviewCanvasAppearance.paper.withAlphaComponent(0.96)
        diagnosticsLabel.backgroundColor = NoteReviewCanvasAppearance.paper.withAlphaComponent(0.94)
    }

    // MARK: Preparation

    func requestPreparationIfNeeded() {
        guard !isDisposed, sourceReader != nil,
              automaticallyPreparesOverview || requestedInitialPreparation,
              (!requestedInitialPreparation || (preparationIsPending && modelPreparation == nil)),
              desktopScrollView.bounds.width > 0, desktopScrollView.bounds.height > 0 else { return }
        requestedInitialPreparation = true
        requestPreparation(count: selectedCount, preservingCurrentID: currentNoteID)
    }

    /// 主 actor 接受输入，后台队列只消费不可变值；每批完成才读取下一批，代次和取消共同保护提交。
    func requestPreparation(count: Int, preservingCurrentID: Int64?) {
        guard !isDisposed, !isCanvasPaused, desktopScrollView.bounds.width > 0 else { return }
        cancelStackBrowsingImmediately()
        selectedCount = count
        cancelRegionalPreparation()
        cancelWaterfallPagePreparation()
        cancelDeletionUpdate()
        pendingDeletionSnapshot = nil
        cancelProgrammaticPositioning()
        rasterPreparationCache.removeAll()
        previewBatchCoordinator.cancelAll()
        menuPrewarmRequestGeneration += 1
        menuPrewarmTask?.cancel(); menuPrewarmTask = nil
        cancelPreviewWorker()
        requestedInitialPreparation = true
        deferredModel = nil
        modelPreparation?.cancel()
        realDataTask?.cancel()
        let work = CanvasOverviewTransitionPreparation()
        modelPreparation = work
        preparationIsPending = true
        generation += 1
        let token = generation
        let size = desktopScrollView.bounds.size
        let previousGroup = activeDirectoryRegion?.stackID
        let previousColumns = lastPreparedViewportSize == size ? preparedModel?.canvasGeometry.columnCount : nil
        lastPreparedViewportSize = size
        var style = CanvasOverviewPaperStyle(traits: traitCollection, settings: renderingSettings)
        var waterfallStyle = CanvasOverviewPaperStyle(traits: traitCollection,
            isFlat: usesAlternateWaterfallStyle, settings: renderingSettings)
        let backgroundURL = renderingSettings?.cardAppearance.backgroundImageURL
        let scale = traitCollection.displayScale
        let width = selectedDesktopCardWidth
        let packing = desktopPacking
        if preparedModel == nil { setLoadingVisible(true) }
        onPreparationChanged?(true, nil)
        realDataTask = Task(priority: isMenuPrewarming ? .utility : .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let ids: [Int64]
                if let directoryRegionReader, let id = preservingCurrentID {
                    let region = try await directoryRegionReader(id)
                    try Task.checkCancellation()
                    guard generation == token else { return }
                    activeDirectoryRegion = region
                    selectedCount = Int(region.totalCount)
                    ids = region.members.map(\.record.noteID)
                } else {
                    let all = try await resolveDataIDs?() ?? (stackAllIDs.isEmpty ? dataIDs : stackAllIDs)
                    stackAllIDs = all
                    let group = fixtureStack(containing: preservingCurrentID ?? all.first ?? 0)
                        ?? all.first.flatMap { self.fixtureStack(containing: $0) }
                    activeDirectoryRegion = group?.region
                    ids = group?.noteIDs ?? []
                }
                try Task.checkCancellation()
                guard generation == token else { return }
                dataIDs = ids
                if let backgroundURL, backgroundURL != preparedBackgroundURL, let backgroundReader {
                    let image = try await backgroundReader(backgroundURL)
                    try Task.checkCancellation()
                    guard generation == token else { return }
                    preparedBackgroundURL = backgroundURL
                    preparedBackgroundImage = image
                }
                style.backgroundImage = backgroundURL == nil ? nil : preparedBackgroundImage
                waterfallStyle.backgroundImage = style.backgroundImage
                let model = try await prepareModel(ids: ids, style: style, waterfallStyle: waterfallStyle,
                    size: size, scale: scale, width: width, packing: packing, work: work,
                    fixedColumns: previousGroup != nil && previousGroup == activeDirectoryRegion?.stackID ? previousColumns : nil,
                    preparesWaterfall: requestedPreparationMode == .waterfall)
                try Task.checkCancellation()
                guard generation == token else { return }
                modelPreparation = nil
                realDataTask = nil
                preparationIsPending = false
                if var model {
                    if directoryRegionReader != nil, currentMode == .waterfall, let old = preparedModel {
                        model.waterfallGeometry = old.waterfallGeometry
                        model.isWaterfallPrepared = old.isWaterfallPrepared
                    }
                    commit(model: seedRegionalWindow(model), preservingCurrentID: preservingCurrentID)
                } else if ids.isEmpty {
                    preparedModel = nil
                    waterfallLayout.geometry = nil
                    waterfallView.reloadData()
                    zoomContentView.isHidden = true
                    currentNoteID = nil
                    setLoadingVisible(false)
                }
                onPreparationChanged?(false, nil)
                prewarmPreparedMenuTargetsIfNeeded()
                onReady?()
            } catch is CancellationError {
                // The next request or permanent close owns any subsequent presentation.
            } catch {
                guard generation == token else { return }
                modelPreparation = nil
                realDataTask = nil
                preparationIsPending = false
                setLoadingVisible(false)
                onPreparationChanged?(false, "暂时无法整理回顾内容，请重试")
            }
        }
    }

    /// 读取入口由宿主注入；此组件不持有 Repository 或业务会话。
    func prepareModel(ids: [Int64], style: CanvasOverviewPaperStyle, waterfallStyle: CanvasOverviewPaperStyle,
        size: CGSize, scale: CGFloat, width: CGFloat, packing: CanvasOverviewDesktopPacking,
        work: CanvasOverviewTransitionPreparation, fixedColumns: Int? = nil,
        preparesWaterfall: Bool = true, preparesInitialViewport: Bool = true,
        requestedAnchor: Int64? = nil) async throws -> CanvasOverviewPreparedModel? {
        guard let sourceReader else { throw CancellationError() }
        let queue = preparationQueue
        let store = previewStore
        let anchorID = requestedAnchor ?? currentNoteID
        let overviewLongEdge: CGFloat = ids.count <= 128 ? 1_024 : 2_048
        let anchorIndex = anchorID.flatMap { ids.firstIndex(of: $0) } ?? ids.count / 2
        let protectedStart = max(0, min(anchorIndex - 9, ids.count - 20))
        let initialProtectedIDs = Set(ids[protectedStart..<min(ids.count, protectedStart + 20)])
        let builder: CanvasOverviewBatchPreparation = await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: CanvasOverviewBatchPreparation(count: ids.count, store: store, style: style,
                    waterfallStyle: waterfallStyle, width: width, size: size, scale: scale, packing: packing,
                    fixedColumns: fixedColumns, anchorID: anchorID, initialProtectedIDs: initialProtectedIDs,
                    preparesWaterfall: preparesWaterfall, overviewLongEdge: overviewLongEdge))
            }
        }
        defer { withExtendedLifetime(builder) {} }
        var missing = Set<Int64>()
        let prioritizedReader: SourceReader = { [weak self] ids, _ in
            guard let self, !self.isDisposed, !self.isCanvasPaused, !work.isCancelled else { throw CancellationError() }
            // Selecting a mode promotes subsequent batches without cancelling an already useful read.
            return try await sourceReader(ids, self.isMenuPrewarming ? .utility : .userInitiated)
        }
        try await NoteReviewCanvasSourceAdapter(read: prioritizedReader).consume(ids: ids) { batch in
            missing.formUnion(batch.missingIDs)
            try Task.checkCancellation()
            guard !work.isCancelled else { throw CancellationError() }
            let queueInterval = CanvasOverviewPreparationMetrics.signposter.beginInterval("Layout queue wait")
            await withCheckedContinuation { continuation in
                queue.async {
                    CanvasOverviewPreparationMetrics.signposter.endInterval("Layout queue wait", queueInterval)
                    autoreleasepool { builder.append(batch.sources, cancellation: work) }
                    continuation.resume()
                }
            }
        }
        try Task.checkCancellation()
        if !missing.isEmpty {
            onMissingIDs?(missing)
            throw CancellationError()
        }
        var model: CanvasOverviewPreparedModel? = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: autoreleasepool { builder.finish(cancellation: work) }) }
        }
        if preparesInitialViewport, let prepared = model, !prepared.notes.isEmpty {
            let id = anchorID ?? prepared.notes[prepared.notes.count / 2].id
            let initialIDs = readablePreviewIDs(model: prepared, mode: .desktop, noteID: id,
                canvasRect: prepared.initialViewportRect,
                zoomScale: prepared.canvasGeometry.readableZoomScale(in: size))
            try await warmPreviews(ids: initialIDs, model: prepared, work: work, modes: [.desktop])
            let image = await preparedViewportImage(model: prepared, canvasRect: prepared.initialViewportRect,
                                                    size: size, scale: scale)
            try Task.checkCancellation()
            model?.initialViewportImage = image
        }
        return model
    }

    func commit(model: CanvasOverviewPreparedModel, preservingCurrentID: Int64?,
                        restoringWidthViewport: CanvasOverviewViewportState? = nil,
                        animatesEnvironmentChange: Bool = true) {
        guard !isCanvasPaused, !isObjectMenuPresented, !desktopScrollView.isDragging, !desktopScrollView.isDecelerating,
              !desktopScrollView.isZooming, !waterfallView.isDragging, !waterfallView.isDecelerating,
              transitionState == .idle, widthSession == nil else {
            deferredModel = (model, preservingCurrentID, generation)
            return
        }
        let wasCatalog = directoryCatalog != nil
        if let id = currentNoteID, preparedModel != nil {
            if !wasCatalog, stackBrowser == nil { saveViewport(for: currentMode, noteID: id) }
            if animatesEnvironmentChange, environmentCover == nil {
                environmentCover = view.snapshotView(afterScreenUpdates: false)
                if let cover = environmentCover { cover.frame = view.bounds; view.addSubview(cover) }
            }
        }
        let savedDesktop = restoringWidthViewport ?? desktopViewport
        let savedWaterfall = waterfallViewport
        let savedFullDesktop = !wasCatalog && isShowingFullDesktop
        let modeToRestore = currentMode
        transitionContext?.animator.stopAnimation(true)
        cleanUpTransition(settledMode: currentMode)
        transitionState = .settling
        isPositioningViewport = true

        clearDirectoryCatalogSurface()

        preparedModel = model
        zoomContentView.isHidden = false
        selectedDesktopCardWidth = model.canvasGeometry.cardWidth
        desktopPacking = model.canvasGeometry.parameters.packing
        usesRealData = model.isRealData
        selectedCount = activeDirectoryRegion.map { Int($0.totalCount) } ?? model.notes.count
        let nextID = preservingCurrentID.flatMap { model.canvasGeometry.indexByID[$0] == nil ? nil : $0 }
            ?? (model.isRealData ? model.previewRichNoteIDs.first : nil)
            ?? model.notes[model.notes.count / 2].id
        currentNoteID = nextID

        desktopScrollView.setZoomScale(1, animated: false)
        zoomContentView.transform = .identity
        zoomContentView.frame = CGRect(origin: .zero, size: model.canvasGeometry.contentSize)
        zoomContentView.layoutIfNeeded()
        if model.canvasGeometry.regionSlices.isEmpty {
            zoomContentView.configure(geometry: model.canvasGeometry, overviewImage: model.overviewImage,
                style: model.style, viewportSize: desktopScrollView.bounds.size)
        } else {
            zoomContentView.configureRegional(geometry: model.canvasGeometry, models: regionalModels,
                style: model.style, viewportSize: desktopScrollView.bounds.size)
        }
        desktopScrollView.contentSize = model.canvasGeometry.contentSize
        configureDesktopZoom(for: model.canvasGeometry)

        if let saved = savedDesktop, model.canvasGeometry.indexByID[saved.noteID] != nil {
            desktopScrollView.minimumZoomScale = min(desktopScrollView.minimumZoomScale, saved.zoomScale)
            desktopScrollView.maximumZoomScale = max(desktopScrollView.maximumZoomScale, saved.zoomScale)
            desktopScrollView.setZoomScale(saved.zoomScale, animated: false)
            updateDesktopContentInset()
            align(noteID: saved.noteID, in: .desktop,
                to: saved.anchor(in: desktopScrollView.convert(desktopScrollView.bounds, to: view)),
                allowingCanvasPadding: true)
            isShowingFullDesktop = savedFullDesktop
            saveViewport(for: .desktop, noteID: saved.noteID)
        }
        if restoringWidthViewport == nil {
            waterfallLayout.geometry = model.waterfallGeometry
            waterfallView.reloadData()
            waterfallView.layoutIfNeeded()
            if let saved = savedWaterfall, model.waterfallGeometry.indexByID[saved.noteID] != nil {
                align(noteID: saved.noteID, in: .waterfall,
                    to: saved.anchor(in: waterfallView.convert(waterfallView.bounds, to: view)))
                saveViewport(for: .waterfall, noteID: saved.noteID)
            } else {
                positionWaterfall(on: nextID, animated: false)
            }
        }

        currentMode = modeToRestore
        modeControl.selectedSegmentIndex = modeToRestore.rawValue
        desktopScrollView.alpha = modeToRestore == .desktop ? 1 : 0
        desktopScrollView.isUserInteractionEnabled = modeToRestore == .desktop
        waterfallView.alpha = modeToRestore == .waterfall ? 1 : 0
        waterfallView.isUserInteractionEnabled = modeToRestore == .waterfall
        zoomContentView.installViewportUnderlay(model.initialViewportImage,
            canvasRect: model.initialViewportRect, generation: generation)
        preparedModel?.initialViewportImage = nil
        isPositioningViewport = false
        isPreparingDesktopWidth = false
        transitionState = .idle

        setLoadingVisible(false)
        updateCurrentPresentation()
        updateCanvasAccessibility()

        if animatesEnvironmentChange, let cover = environmentCover {
            environmentCover = nil
            isCatalogHandoffPending = wasCatalog
            UIView.animate(withDuration: 0.12, animations: { cover.alpha = 0 }) { [weak self] _ in
                cover.removeFromSuperview()
                guard let self, wasCatalog else { return }
                isCatalogHandoffPending = false
                if !isDisposed, !isCanvasPaused { onReady?() }
            }
        }
        updateCountMenu()
        if let id = currentNoteID {
            saveViewport(for: .desktop, noteID: id)
            saveViewport(for: .waterfall, noteID: id)
            if wasCatalog { onCurrentChanged?(id) }
        }
    }

    func configureDesktopZoom(for geometry: CanvasOverviewCanvasGeometry) {
        let bounds = desktopScrollView.bounds.size
        let fit = geometry.fitZoomScale(in: bounds)
        let readable = geometry.readableZoomScale(in: bounds)
        desktopScrollView.minimumZoomScale = max(0.01, fit * 0.72)
        desktopScrollView.maximumZoomScale = max(1.4, readable * 1.55)
        desktopScrollView.zoomScale = readable
        updateDesktopContentInset()
        positionDesktop(on: currentNoteID, zoomScale: readable, animated: false)
        isShowingFullDesktop = false
    }

    func setLoadingVisible(_ isVisible: Bool) {
        loadingContainer.isHidden = !isVisible || !showsDiagnosticControls
        if isVisible {
            loadingIndicator.startAnimating()
        } else {
            loadingIndicator.stopAnimating()
        }
    }

    // MARK: Controls

    func desktopWidthMenu() -> UIMenu {
        let presets = CanvasOverviewDesktopCardWidth.presets.map { width in
            UIAction(title: width == CanvasOverviewDesktopCardWidth.defaultValue ? "220 pt（默认）" : "\(Int(width)) pt",
                     state: selectedDesktopCardWidth == width ? .on : .off) { [weak self] _ in
                self?.changeDesktopCardWidth(to: width)
            }
        }
        let custom = UIAction(title: "自定义…") { [weak self] _ in self?.presentDesktopWidthInput() }
        if widthSession != nil { custom.attributes = .disabled }
        let live = UIAction(title: "实时调整…", image: UIImage(systemName: "slider.horizontal.3")) { [weak self] _ in
            self?.beginWidthAdjustment(showToolbar: true)
        }
        if preparedModel == nil || (isPreparingDesktopWidth && widthSession == nil) {
            (presets + [custom]).forEach { $0.attributes = .disabled }
        }
        if currentMode != .desktop || transitionState != .idle || widthSession != nil { live.attributes = .disabled }
        return UIMenu(title: "卡片宽度", children: presets + [custom, live])
    }

    func presentDesktopWidthInput() {
        guard transitionState == .idle, !isPreparingDesktopWidth, environmentCover == nil else { return }
        var draft = String(Int(selectedDesktopCardWidth))
        XMSystemAlertController.present(on: self, descriptor: XMSystemAlertDescriptor(
            title: "桌面卡宽",
            message: "输入 180–360 的整数（pt）。统一调整所有桌面卡片，字体大小、相机缩放和瀑布流卡宽不变。",
            actions: [
                XMSystemAlertAction(title: "取消", role: .cancel) {},
                XMSystemAlertAction(id: "applyWidth", title: "应用") { [weak self] in
                    guard let width = CanvasOverviewDesktopCardWidth.parse(draft) else { return }
                    self?.changeDesktopCardWidth(to: width)
                },
            ],
            textFields: [XMSystemAlertTextField(text: { draft }, setText: { draft = $0 },
                                               placeholder: "180–360", keyboardType: .numberPad)],
            preferredActionID: "applyWidth"
        ))
        if let alert = presentedViewController as? UIAlertController, let field = alert.textFields?.first {
            field.accessibilityIdentifier = "singleCanvasCardWidthInput"
            field.addAction(UIAction { [weak alert, weak field] _ in
                alert?.preferredAction?.isEnabled = CanvasOverviewDesktopCardWidth.parse(field?.text ?? "") != nil
            }, for: .editingChanged)
        }
    }

    /// 主线程捕获视口，后台只重排已解析的不可变内容；generation 丢弃离场或后续请求的过期结果。
    func changeDesktopCardWidth(to width: CGFloat, packing: CanvasOverviewDesktopPacking? = nil) {
        if currentMode == .desktop, packing == nil {
            guard CanvasOverviewDesktopCardWidth.range.contains(Int(width)) else { return }
            if widthSession == nil { beginWidthAdjustment(showToolbar: false) }
            guard let session = widthSession else { return }
            animateWidth(to: width, in: session)
            session.closeAfterCommit = !session.showsToolbar
            return
        }
        guard transitionState == .idle, !isPreparingDesktopWidth, environmentCover == nil,
              (width != selectedDesktopCardWidth || packing != nil),
              CanvasOverviewDesktopCardWidth.range.contains(Int(width)),
              let model = preparedModel, let currentID = currentNoteID else { return }
        desktopScrollView.stopScrollingAndZooming()
        waterfallView.stopScrollingAndZooming()
        let anchorID = currentMode == .desktop ? currentID : (desktopViewport?.noteID ?? currentID)
        guard let pose = paperPose(in: .desktop, noteID: anchorID) else { return }
        let saved = CanvasOverviewViewportState(noteID: anchorID, offset: desktopScrollView.contentOffset,
            zoomScale: desktopScrollView.zoomScale, anchor: pose.center,
            viewportRect: desktopScrollView.convert(desktopScrollView.bounds, to: view))
        let wasFullDesktop = isShowingFullDesktop
        let origin = desktopScrollView.convert(desktopScrollView.bounds.origin, to: view)
        let localAnchor = CGPoint(x: pose.center.x - origin.x, y: pose.center.y - origin.y)
        if currentMode == .desktop, let cover = desktopScrollView.snapshotView(afterScreenUpdates: false) {
            cover.frame = desktopScrollView.convert(desktopScrollView.bounds, to: view)
            cover.isUserInteractionEnabled = false
            cover.accessibilityElementsHidden = true
            view.insertSubview(cover, belowSubview: topControlPanel)
            environmentCover = cover
        }
        isPreparingDesktopWidth = true
        updateCountMenu()
        setSurfaceInteractionEnabled(false)
        loadingLabel.text = "正在调整卡宽…"
        setLoadingVisible(true)
        generation += 1
        let token = generation
        let size = desktopScrollView.bounds.size
        let screenScale = traitCollection.displayScale
        let interval = signposter.beginInterval("Reflow desktop width")
        realDataTask = Task { [weak self] in
            guard let self else { return }
            let work = CanvasOverviewTransitionPreparation()
            modelPreparation = work
            do {
                guard var updated = try await prepareModel(ids: dataIDs, style: model.style,
                    waterfallStyle: model.waterfallStyle, size: size, scale: screenScale, width: width,
                    packing: packing ?? model.canvasGeometry.parameters.packing, work: work,
                    fixedColumns: model.canvasGeometry.columnCount),
                    !Task.isCancelled, generation == token else { return }
                if let paper = updated.canvasGeometry.paper(for: anchorID) {
                    updated.initialViewportRect = CGRect(x: paper.frame.midX - localAnchor.x / saved.zoomScale,
                        y: paper.frame.midY - localAnchor.y / saved.zoomScale,
                        width: size.width / saved.zoomScale, height: size.height / saved.zoomScale)
                    // A viewport with different coverage must not reuse pixels rendered for the initial camera.
                    updated.initialViewportImage = nil
                }
                modelPreparation = nil
                commit(model: updated, preservingCurrentID: currentID, restoringWidthViewport: saved)
                isShowingFullDesktop = wasFullDesktop
                updateFullDesktopButton()
                if packing == nil { onConfirmedWidth?(Int(width)) }
            } catch {
                guard !Task.isCancelled, generation == token else { return }
                isPreparingDesktopWidth = false
                modelPreparation = nil
                onPreparationChanged?(false, "调整未完成，请重试")
                setSurfaceInteractionEnabled(true)
            }
            signposter.endInterval("Reflow desktop width", interval)
        }
    }

    func updateCountMenu() { onControlsChanged?() }

    @objc func modeChanged() {
        guard let target = Mode(rawValue: modeControl.selectedSegmentIndex) else { return }
        requestMode(target)
    }

    @objc func toggleDiagnostics() {
        diagnosticsLabel.isHidden.toggle()
        updateDiagnostics()
    }

    @objc func returnToCurrent() {
        if stackBrowser != nil || stackTask != nil { dismissStackBrowser(); return }
        guard transitionContext == nil, !isPreparingDesktopWidth else { return }
        if directoryCatalog != nil { restoreDirectoryDesktop(); return }
        switch currentMode {
        case .desktop:
            positionDesktop(on: currentNoteID, zoomScale: desktopScrollView.zoomScale, animated: true)
        case .waterfall:
            positionWaterfall(on: currentNoteID, animated: true)
        }
    }

    @objc func toggleFullDesktop() {
        if stackBrowser != nil || stackTask != nil { dismissStackBrowser(); return }
        guard currentMode == .desktop,
              !isPreparingDesktopWidth,
              transitionContext == nil,
              let geometry = preparedModel?.canvasGeometry else { return }
        if hasMultipleStacks {
            presentStackBrowser()
            return
        }
        toggleLocalDesktopScale(geometry)
    }

    /// 缩放只作用于当前完整组，双击不再把正文变成抽象目录。
    func toggleLocalDesktopScale(_ geometry: CanvasOverviewCanvasGeometry) {
        let targetScale = isShowingFullDesktop
            ? geometry.readableZoomScale(in: desktopScrollView.bounds.size)
            : geometry.fitZoomScale(in: desktopScrollView.bounds.size)
        positionDesktop(on: currentNoteID, zoomScale: targetScale, animated: true)
        updateFullDesktopButton()
    }

    @objc func desktopTapped(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended,
              !isObjectMenuPresented,
              transitionContext == nil,
              let geometry = preparedModel?.canvasGeometry else { return }
        if directoryCatalog != nil {
            if let group = directoryCatalogView.group(at: recognizer.location(in: directoryCatalogView)) { expandDirectoryGroup(group) }
            else { onBlankTap?() }
            return
        }
        let point = recognizer.location(in: zoomContentView.canvasView)
        guard let paper = geometry.paper(at: point) else { onBlankTap?(); return }
        setCurrentNoteID(paper.noteID, announce: true)
        if geometry.cardWidth * desktopScrollView.zoomScale < 116 {
            positionDesktop(on: paper.noteID, zoomScale: geometry.readableZoomScale(in: desktopScrollView.bounds.size), animated: true)
        } else { onActivate?(paper.noteID) }
    }

    @objc func desktopDoubleTapped(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended,
              !isObjectMenuPresented,
              transitionContext == nil,
              let geometry = preparedModel?.canvasGeometry else { return }
        let point = recognizer.location(in: zoomContentView.canvasView)
        guard geometry.paper(at: point) == nil else { return }
        toggleLocalDesktopScale(geometry)
    }

    func updateFullDesktopButton() {
        fullDesktopButton.configuration?.image = UIImage(systemName: desktopOverviewIcon)
        fullDesktopButton.accessibilityLabel = desktopOverviewLabel
    }

    // MARK: Position and selection

    func positionDesktop(on noteID: Int64?, zoomScale: CGFloat, animated: Bool) {
        guard let noteID,
              let paper = preparedModel?.canvasGeometry.paper(for: noteID) else { return }
        let targetScale = min(desktopScrollView.maximumZoomScale, max(desktopScrollView.minimumZoomScale, zoomScale))
        let size = CGSize(width: desktopScrollView.bounds.width / targetScale,
                          height: desktopScrollView.bounds.height / targetScale)
        let rect = CGRect(x: paper.frame.midX - size.width / 2, y: paper.frame.midY - size.height / 2,
                          width: size.width, height: size.height)
        beginProgrammaticPositioning(mode: .desktop, noteID: noteID, canvasRect: rect, zoomScale: targetScale)
        if animated, abs(desktopScrollView.zoomScale - targetScale) > 0.0001 {
            desktopScrollView.zoom(to: rect, animated: true)
            return
        }
        if abs(desktopScrollView.zoomScale - targetScale) > 0.0001 {
            isApplyingProgrammaticZoomSynchronously = true
            desktopScrollView.setZoomScale(targetScale, animated: false)
            isApplyingProgrammaticZoomSynchronously = false
            updateDesktopContentInset()
        }

        zoomContentView.layoutIfNeeded()
        let center = zoomContentView.canvasView.convert(paper.frame.center, to: desktopScrollView)
        let target = CGPoint(x: center.x - desktopScrollView.bounds.width / 2,
                             y: center.y - desktopScrollView.bounds.height / 2)
        let offset = clampedDesktopOffset(target)
        if isSameScreenOffset(desktopScrollView.contentOffset, as: offset) {
            finishProgrammaticPositioning(in: desktopScrollView)
            return
        }
        let willAnimate = animated
        desktopScrollView.setContentOffset(offset, animated: willAnimate)
        if !willAnimate { finishProgrammaticPositioning(in: desktopScrollView) }
    }

    func clampedDesktopOffset(_ proposed: CGPoint) -> CGPoint {
        let inset = desktopScrollView.contentInset
        let scaledSize = CGSize(
            width: zoomContentView.bounds.width * desktopScrollView.zoomScale,
            height: zoomContentView.bounds.height * desktopScrollView.zoomScale
        )
        let minX = -inset.left
        let minY = -inset.top
        let maxX = max(minX, scaledSize.width - desktopScrollView.bounds.width + inset.right)
        let maxY = max(minY, scaledSize.height - desktopScrollView.bounds.height + inset.bottom)
        return CGPoint(
            x: min(max(proposed.x, minX), maxX),
            y: min(max(proposed.y, minY), maxY)
        )
    }

    func updateDesktopContentInset() {
        let scaledWidth = zoomContentView.bounds.width * desktopScrollView.zoomScale
        let scaledHeight = zoomContentView.bounds.height * desktopScrollView.zoomScale
        let horizontal = max(0, (desktopScrollView.bounds.width - scaledWidth) / 2)
        let vertical = max(0, (desktopScrollView.bounds.height - scaledHeight) / 2)
        desktopScrollView.contentInset = UIEdgeInsets(
            top: max(vertical, contentOcclusionInsets.top),
            left: horizontal,
            bottom: max(vertical, contentOcclusionInsets.bottom),
            right: horizontal
        )
    }

    func positionWaterfall(on noteID: Int64?, animated: Bool) {
        guard let noteID,
              let index = preparedModel?.waterfallGeometry.indexByID[noteID],
              let frame = preparedModel?.waterfallGeometry.frames[safe: index] else { return }
        let proposedY = frame.midY - waterfallView.bounds.height / 2
        let target = CGPoint(x: 0, y: clampedWaterfallOffsetY(proposedY))
        beginProgrammaticPositioning(mode: .waterfall, noteID: noteID,
            waterfallRect: CGRect(origin: target, size: waterfallView.bounds.size))
        if isSameScreenOffset(waterfallView.contentOffset, as: target) {
            waterfallView.layoutIfNeeded()
            finishProgrammaticPositioning(in: waterfallView)
            return
        }
        let willAnimate = animated
        waterfallView.setContentOffset(target, animated: willAnimate)
        if !willAnimate {
            waterfallView.layoutIfNeeded()
            finishProgrammaticPositioning(in: waterfallView)
        }
    }

    func updateCurrentFromDesktopCenter() {
        guard directoryCatalog == nil, stackBrowser == nil else { return }
        guard transitionState == .idle, !isPositioningViewport, !isPreparingDesktopWidth,
              !isObjectMenuPresented else { return }
        guard let geometry = preparedModel?.canvasGeometry else { return }
        let centerInCanvas = desktopScrollView.convert(
            CGPoint(x: desktopScrollView.bounds.midX, y: desktopScrollView.bounds.midY),
            to: zoomContentView.canvasView
        )
        if let paper = geometry.nearestPaper(to: centerInCanvas) {
            setCurrentNoteID(paper.noteID, announce: false)
            saveViewport(for: .desktop, noteID: paper.noteID)
        }
        updateCanvasAccessibility()
        reportDemand()
        commitDeferredModelIfPossible()
    }

    func updateCurrentFromWaterfallCenter() {
        guard transitionState == .idle, !isPositioningViewport, !isPreparingDesktopWidth,
              !isObjectMenuPresented else { return }
        guard let geometry = preparedModel?.waterfallGeometry else { return }
        let center = CGPoint(
            x: waterfallView.bounds.midX,
            y: waterfallView.bounds.midY
        )
        if let index = geometry.nearestIndex(to: center) {
            setCurrentNoteID(geometry.notes[index].id, announce: false)
            saveViewport(for: .waterfall, noteID: geometry.notes[index].id)
        }
        lastStableWaterfallOffset = waterfallView.contentOffset
        reportDemand()
        commitDeferredModelIfPossible()
    }

    func setCurrentNoteID(_ noteID: Int64, announce: Bool) {
        guard currentNoteID != noteID else { return }
        currentNoteID = noteID
        onCurrentChanged?(noteID)
        updateCurrentPresentation()
        if announce, let note = preparedModel?.noteByID[noteID] {
            UIAccessibility.post(notification: .layoutChanged, argument: note.bookTitle)
        }
    }

    func updateCurrentPresentation() {
        let index = currentNoteID.flatMap { preparedModel?.canvasGeometry.indexByID[$0] }
        let current = index.map { $0 + 1 } ?? 0
        let total = preparedModel?.notes.count ?? selectedCount
        currentButton.configuration?.title = "\(current) / \(total)"
        currentButton.accessibilityLabel = "当前第 \(current) 条，共 \(total) 条，回到当前书摘"
        updateFullDesktopButton()
        updateDiagnostics()
    }

    func updateCanvasAccessibility() {
        guard directoryCatalog == nil else { return }
        guard let geometry = preparedModel?.canvasGeometry else { return }
        zoomContentView.canvasView.onNoteAccessibilityActions = { [weak self] id in
            self?.onNoteAccessibilityActions?(id) ?? []
        }
        zoomContentView.canvasView.onActivateNote = { [weak self] id in
            guard let self else { return false }
            self.setCurrentNoteID(id, announce: false)
            self.onActivate?(id)
            return true
        }
        zoomContentView.canvasView.onOrderedScroll = { [weak self] direction in
            guard let self, let id = self.currentNoteID, let index = geometry.indexByID[id] else { return false }
            let delta: Int
            switch direction { case .up, .left: delta = 1; case .down, .right: delta = -1; default: return false }
            guard let next = geometry.notes[safe: index + delta]?.id else { return false }
            self.setCurrentNoteID(next, announce: false)
            self.locate(noteID: next)
            UIAccessibility.post(notification: .pageScrolled, argument: self.currentButton.accessibilityLabel)
            return true
        }
        let projectedPaperWidth = geometry.cardWidth * desktopScrollView.zoomScale
        if projectedPaperWidth < 44 {
            let currentIndex = currentNoteID.flatMap { geometry.indexByID[$0] }
            zoomContentView.canvasView.updateAccessibilityElements(
                visibleIndexes: currentIndex.map { [$0] } ?? [],
                notes: geometry.notes
            )
            return
        }
        let visibleRect = zoomContentView.canvasView.convert(desktopScrollView.bounds, from: desktopScrollView)
        zoomContentView.canvasView.updateAccessibilityElements(
            visibleIndexes: geometry.indexes(in: visibleRect),
            notes: geometry.notes
        )
    }

    // MARK: Diagnostics

    func startDiagnosticsTimer() {
        diagnosticsTimer?.invalidate()
        diagnosticsTimer = Timer.scheduledTimer(
            withTimeInterval: Metrics.diagnosticRefreshInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateDiagnostics()
            }
        }
    }

    func updateDiagnostics() {
        guard !diagnosticsLabel.isHidden else { return }
        let canvasDiagnostics = zoomContentView.canvasView.diagnostics
        diagnosticsLabel.text = """
          mode  \(currentMode == .desktop ? "desktop" : "waterfall")
          data  \(usesRealData ? "real, read-only" : "fixtures") / rich \(preparedModel?.richTextNoteCount ?? 0)
          id    \(currentNoteID.map(String.init) ?? "-")
          zoom  \(String(format: "%.3f", desktopScrollView.zoomScale))
          width \(Int(preparedModel?.canvasGeometry.cardWidth ?? selectedDesktopCardWidth)) pt / cols \(preparedModel?.canvasGeometry.columnCount ?? 0)
          draw  \(String(format: "%.2fms", canvasDiagnostics.lastDrawMilliseconds)) / \(canvasDiagnostics.candidateCount)
          cells \(waterfallView.visibleCells.count)
          state \(transitionState.rawValue)
          shared \(lastTransitionParticipantCount) / all \(transitionContext?.scene.plan.cards.count ?? 0)
          stacks \(stackPreviews.count) / papers \(stackPreviews.reduce(0) { $0 + $1.papers.count })
          group \(preparedModel?.notes.count ?? 0) / capacity \(selectedGroupCapacity)
          stack pixels \(String(format: "%.1fMB", Double(stackPreviews.reduce(0) { $0 + $1.pixelBytes }) / 1_048_576))
        """
        if let model = preparedModel { diagnosticsLabel.text! += "\n" + model.canvasGeometry.packingSummary }
        if let s = widthSession {
            diagnosticsLabel.text! += "\n  adjust \(s.phase.rawValue) \(Int(s.requestedWidth))/\(Int(s.previewWidth))/\(Int(s.committedWidth))"
            diagnosticsLabel.text! += "\n  preview \(s.seed.rasterMode ? "raster" : "papers") \(s.scene?.activePaperCount ?? 0) / \(String(format: "%.1fMB", Double(s.textureBytes) / 1_048_576))"
            diagnosticsLabel.text! += "\n  submit \(String(format: "%.1fms", s.maximumFrameSubmitMilliseconds)) / first \(Int(s.firstResponseMilliseconds ?? -1))ms"
            diagnosticsLabel.text! += "\n  endpoint \(String(format: "%.3fpt", s.endpointError)) / anchor \(String(format: "%.3fpt", s.anchorError))"
        }
    }
}

// MARK: - Scroll and collection delegates

extension NoteReviewCanvasOverviewController: UIScrollViewDelegate {
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        userInteractionBegan()
        updateCountMenu()
    }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        if let gesture = scrollView.pinchGestureRecognizer, gesture.state == .began || gesture.state == .changed {
            userInteractionBegan()
        }
        updateCountMenu()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        scrollView === desktopScrollView ? zoomContentView : nil
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        guard scrollView === desktopScrollView else { return }
        updateDesktopContentInset()
        if directoryCatalog != nil { isShowingFullDesktop = true; return }
        isShowingFullDesktop = preparedModel.map {
            abs(scrollView.zoomScale - $0.canvasGeometry.fitZoomScale(in: scrollView.bounds.size)) < 0.015
        } ?? false
        updateFullDesktopButton()
    }

    func scrollViewDidEndZooming(
        _ scrollView: UIScrollView,
        with view: UIView?,
        atScale scale: CGFloat
    ) {
        guard scrollView === desktopScrollView else { return }
        guard !isApplyingProgrammaticZoomSynchronously else { return }
        if pendingProgrammaticPosition != nil {
            finishProgrammaticPositioning(in: scrollView)
        } else if isPositioningViewport {
            // Synchronous geometry/width commits own their own final demand and anchor.
            return
        } else {
            updateCurrentFromDesktopCenter()
            invalidateVisiblePreparedPreviews()
        }
        updateCountMenu()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard !decelerate else { return }
        if scrollView === desktopScrollView {
            updateCurrentFromDesktopCenter()
        } else if scrollView === waterfallView {
            updateCurrentFromWaterfallCenter()
        }
        updateCountMenu()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        if scrollView === desktopScrollView {
            updateCurrentFromDesktopCenter()
        } else if scrollView === waterfallView {
            updateCurrentFromWaterfallCenter()
        }
        updateCountMenu()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        if pendingProgrammaticPosition != nil {
            finishProgrammaticPositioning(in: scrollView)
            updateCountMenu()
            return
        }
        if scrollView === desktopScrollView {
            updateCanvasAccessibility()
        }
        if let id = currentNoteID, transitionState == .idle {
            saveViewport(for: scrollView === desktopScrollView ? .desktop : .waterfall, noteID: id)
            reportDemand()
            invalidateVisiblePreparedPreviews()
        }
        updateCountMenu()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard transitionState == .idle, !isPositioningViewport, directoryCatalog == nil else { return }
        if CACurrentMediaTime() - lastPreviewRequestTime > 0.08 { reportDemand() }
        guard scrollView === desktopScrollView else { return }
        let rect = zoomContentView.canvasView.convert(scrollView.bounds, from: scrollView)
        zoomContentView.discardUnderlayIfOutside(rect)
    }
}

extension NoteReviewCanvasOverviewController: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        preparedModel?.waterfallGeometry.notes.count ?? 0
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: CanvasOverviewWaterfallCell.reuseID,
            for: indexPath
        ) as! CanvasOverviewWaterfallCell
        if let model = preparedModel, let note = model.waterfallGeometry.notes[safe: indexPath.item] {
            cell.configure(note: note, geometry: model.waterfallGeometry.contentGeometries[indexPath.item],
                size: model.waterfallGeometry.frames[indexPath.item].size, style: model.waterfallStyle)
            cell.accessibilityCustomActions = onNoteAccessibilityActions?(note.id)
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard !isObjectMenuPresented, let note = preparedModel?.waterfallGeometry.notes[safe: indexPath.item] else { return }
        setCurrentNoteID(note.id, announce: true)
        onActivate?(note.id)
    }
}


// MARK: - Transition

extension NoteReviewCanvasOverviewController {
    func requestMode(_ target: Mode) {
        if stackBrowser != nil {
            pendingMode = target
            dismissStackBrowser()
            return
        }
        if let session = widthSession {
            modeControl.selectedSegmentIndex = target.rawValue
            session.requestedMode = target
            session.closeAfterCommit = true
            settleWidth(session)
            return
        }
        guard !isPreparingDesktopWidth else {
            modeControl.selectedSegmentIndex = currentMode.rawValue
            return
        }
        guard preparedModel != nil, let noteID = currentNoteID else {
            modeControl.selectedSegmentIndex = currentMode.rawValue
            return
        }
        modeControl.selectedSegmentIndex = target.rawValue
        if let modeDissolve {
            pendingMode = target
            modeDissolve.reverse(target == currentMode)
            return
        }
        if let context = transitionContext {
            context.requestedMode = target
            context.animator.isReversed = target == context.fromMode
            return
        }
        if transitionState == .preparing {
            if target == currentMode {
                transitionGeneration += 1
                transitionWarmTask?.cancel(); transitionWarmTask = nil
                transitionPreviewPins.removeAll()
                transitionPreparation?.cancel()
                transitionPreparation = nil
                transitionState = .idle
                pendingMode = nil
                setLoadingVisible(false)
                setSurfaceInteractionEnabled(true)
                environmentCover?.removeFromSuperview()
                environmentCover = nil
                desktopScrollView.alpha = currentMode == .desktop ? 1 : 0
                waterfallView.alpha = currentMode == .waterfall ? 1 : 0
                onPreparationChanged?(false, nil)
                onSettledMode?(currentMode)
            }
            return
        }
        guard target != currentMode else { return }
        if target == .waterfall, !ensureWaterfallPrepared() {
            pendingMode = target
            return
        }
        transitionState = .preparing
        transitionPreviewPins.removeAll()
        onPreparationChanged?(true, nil)
        pendingMode = target
        transitionGeneration += 1
        let token = transitionGeneration
        let from = currentMode
        desktopScrollView.stopScrollingAndZooming()
        waterfallView.stopScrollingAndZooming()
        saveViewport(for: from, noteID: noteID)
        // The trusted source stays directly manipulable until the prepared scene takes ownership.
        // A real new gesture cancels this pending request through userInteractionBegan().
        prepareTargetSurface(target)
        transitionWarmTask?.cancel()
        transitionWarmTask = Task { [weak self] in
            guard let self, let model = self.preparedModel else { return }
            guard let demandPlan = makeTransitionPlan(anchorNoteID: noteID) else {
                recoverModeTransition(target: target, from: from, noteID: noteID, token: token, reason: "shared-demand")
                return
            }
            let demand = transitionPreviewDemand(for: demandPlan)
            do {
                try await warmPreviews(ids: demand.desktop, model: model, work: nil,
                                       modes: [.desktop], protectsTransition: true)
                try await warmPreviews(ids: demand.waterfall, model: model, work: nil,
                                       modes: [.waterfall], protectsTransition: true)
            }
            catch {
                guard !Task.isCancelled, transitionGeneration == token else { return }
                recoverModeTransition(target: target, from: from, noteID: noteID, token: token, reason: "shared-previews")
                return
            }
            guard !Task.isCancelled, transitionGeneration == token, transitionState == .preparing else { return }
            startReadyModeTransition(target: target, from: from, noteID: noteID, token: token)
        }
    }

    /// 目标端点已准备后才交接显示权；该方法不会读取或解析正文。
    func startReadyModeTransition(target: Mode, from: Mode, noteID: Int64, token: Int) {
        guard !isCanvasPaused, !isDisposed, transitionGeneration == token else { return }
        guard let plan = makeTransitionPlan(anchorNoteID: noteID) else {
            recoverModeTransition(target: target, from: from, noteID: noteID, token: token, reason: "shared-endpoints")
            return
        }
        let reduceMotion = reduceMotionSwitch.isOn || UIAccessibility.isReduceMotionEnabled
            || UIAccessibility.prefersCrossFadeTransitions
        transitionPreparation?.cancel()
        let preparation = CanvasOverviewTransitionPreparation()
        transitionPreparation = preparation
        // Endpoint rasters replace reusable viewport rasters within the same temporary-resource budget.
        rasterPreparationCache.removeAll()
        let interval = signposter.beginInterval("Prepare transition endpoints")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.transitionGeneration == token, self.transitionState == .preparing else { return }
            self.loadingLabel.text = "正在准备切换…"
            self.setLoadingVisible(true)
        }
        let queueInterval = CanvasOverviewPreparationMetrics.signposter.beginInterval("Transition queue wait")
        preparationQueue.async { [weak self] in
            CanvasOverviewPreparationMetrics.signposter.endInterval("Transition queue wait", queueInterval)
            let textures = autoreleasepool {
                CanvasOverviewTransitionRasterizer.prepare(plan, preparation: preparation, reducedMotion: reduceMotion)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.signposter.endInterval("Prepare transition endpoints", interval)
                guard !preparation.isCancelled,
                      !self.isCanvasPaused, !self.isDisposed,
                      self.transitionGeneration == token, self.transitionState == .preparing else { return }
                self.transitionPreparation = nil
                guard let textures else {
                    self.recoverModeTransition(target: target, from: from, noteID: noteID, token: token, reason: "shared-textures")
                    return
                }
                self.beginPreparedTransition(plan: plan, textures: textures, from: from, to: target,
                                             reducedMotion: reduceMotion, token: token)
            }
        }
    }

    func beginPreparedTransition(plan: CanvasOverviewTransitionPlan, textures: CanvasOverviewSceneTextures,
                                 from: Mode, to: Mode, reducedMotion: Bool, token: Int) {
        setSurfaceInteractionEnabled(false)
        Logger(subsystem: "com.wangke.xmnote", category: "CanvasPreparation").debug(
            "Transition pixels=\(textures.pixelBytes) reusablePixels=\(self.rasterPreparationCache.cachedBytes) storage=\(textures.pixelFormatSummary, privacy: .public)")
        let scene = CanvasOverviewTransitionSceneView(plan: plan, textures: textures,
                                                fromDesktop: from == .desktop, reducedMotion: reducedMotion)
        scene.layoutIfNeeded()
        scene.render(progress: 0)
        if to == .desktop {
            zoomContentView.installViewportUnderlay(textures.desktopUnderlay,
                canvasRect: plan.desktopCanvasRect, generation: generation)
        }
        view.insertSubview(scene, belowSubview: topControlPanel)
        // Source and scene share the same immutable layout. Ownership changes in one transaction.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        desktopScrollView.alpha = 0
        waterfallView.alpha = 0
        environmentCover?.removeFromSuperview()
        environmentCover = nil
        CATransaction.commit()
        setLoadingVisible(false)
        transitionState = .animating
        onPreparationChanged?(false, nil)
        let animator = reducedMotion
            ? UIViewPropertyAnimator(duration: scene.duration, curve: .easeInOut)
            : UIViewPropertyAnimator(duration: scene.duration, dampingRatio: 0.96)
        animator.addAnimations { scene.clockView.center = CGPoint(x: 1, y: 0) }
        let context = CanvasOverviewTransitionContext(from: from, to: to, animator: animator, scene: scene, generation: token)
        transitionContext = context
        onControlsChanged?()
        onModeTransitionProgress?(from, to, 0)
        lastTransitionParticipantCount = plan.cards.filter { $0.kind == .migrate }.count
        let interval = signposter.beginInterval("Continuous paper reflow")
        animator.addCompletion { [weak self, weak context] position in
            guard let self, let context, self.transitionContext === context else { return }
            context.scene.render(progress: position == .start ? 0 : 1)
            self.onModeTransitionProgress?(context.fromMode, context.toMode, position == .start ? 0 : 1)
            self.signposter.endInterval("Continuous paper reflow", interval)
            self.cleanUpTransition(settledMode: position == .start ? context.fromMode : context.toMode)
        }
        startTransitionDisplayLink()
        animator.startAnimation()
    }

    func saveViewport(for mode: Mode, noteID: Int64) {
        guard let pose = paperPose(in: mode, noteID: noteID) else { return }
        let scroll = mode == .desktop ? desktopScrollView : waterfallView
        let saved = CanvasOverviewViewportState(noteID: noteID, offset: scroll.contentOffset,
                                           zoomScale: mode == .desktop ? desktopScrollView.zoomScale : 1,
                                           anchor: pose.center, viewportRect: scroll.convert(scroll.bounds, to: view))
        if mode == .desktop { desktopViewport = saved } else { waterfallViewport = saved }
    }

    func prepareTargetSurface(_ target: Mode) {
        guard let noteID = currentNoteID,
              let sourcePose = paperPose(in: currentMode, noteID: noteID) else { return }
        let saved = target == .desktop ? desktopViewport : waterfallViewport
        if target == .desktop {
            if let saved {
                desktopScrollView.setZoomScale(saved.zoomScale, animated: false)
                updateDesktopContentInset()
                desktopScrollView.setContentOffset(clampedDesktopOffset(saved.offset), animated: false)
            }
            if saved?.noteID != noteID {
                let desired = saved?.anchor ?? sourcePose.center
                align(noteID: noteID, in: .desktop, to: desired)
            }
            desktopScrollView.layoutIfNeeded()
        } else {
            if let saved {
                waterfallView.setContentOffset(saved.offset, animated: false)
            }
            if saved?.noteID != noteID {
                align(noteID: noteID, in: .waterfall, to: saved?.anchor ?? sourcePose.center)
            }
            waterfallView.layoutIfNeeded()
        }
    }

    func align(noteID: Int64, in mode: Mode, to point: CGPoint, allowingCanvasPadding: Bool = false) {
        guard let actual = paperPose(in: mode, noteID: noteID) else { return }
        if mode == .desktop {
            let offset = CGPoint(x: desktopScrollView.contentOffset.x + actual.center.x - point.x,
                                 y: desktopScrollView.contentOffset.y + actual.center.y - point.y)
            if allowingCanvasPadding {
                var inset = desktopScrollView.contentInset
                inset.left = max(inset.left, -offset.x)
                inset.top = max(inset.top, -offset.y)
                inset.right = max(inset.right, offset.x + desktopScrollView.bounds.width - desktopScrollView.contentSize.width)
                inset.bottom = max(inset.bottom, offset.y + desktopScrollView.bounds.height - desktopScrollView.contentSize.height)
                desktopScrollView.contentInset = inset
            }
            desktopScrollView.setContentOffset(clampedDesktopOffset(offset), animated: false)
        } else {
            let y = waterfallView.contentOffset.y + actual.center.y - point.y
            waterfallView.setContentOffset(CGPoint(x: 0, y: clampedWaterfallOffsetY(y)), animated: false)
        }
    }

    func cleanUpTransition(settledMode: Mode, commitsMode: Bool = true) {
        transitionState = .settling
        transitionDisplayLink?.invalidate()
        transitionDisplayLink = nil
        if settledMode == .desktop, let context = transitionContext, context.generation == transitionGeneration {
            zoomContentView.installViewportUnderlay(context.scene.textures.desktopUnderlay,
                canvasRect: context.scene.plan.desktopCanvasRect, generation: generation)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        currentMode = settledMode
        modeControl.selectedSegmentIndex = settledMode.rawValue
        desktopScrollView.alpha = settledMode == .desktop ? 1 : 0
        waterfallView.alpha = settledMode == .waterfall ? 1 : 0
        transitionContext?.scene.removeFromSuperview()
        transitionContext = nil
        pendingMode = nil
        if commitsMode { onSettledMode?(settledMode) }
        transitionState = .idle
        CATransaction.commit()
        setLoadingVisible(false)
        setSurfaceInteractionEnabled(true)
        if let noteID = currentNoteID { saveViewport(for: settledMode, noteID: noteID) }
        updateCountMenu()
        updateCurrentPresentation()
        updateCanvasAccessibility()
        reportDemand()
        transitionPreviewPins.removeAll()
        releaseHiddenWaterfallProtection()
        if showsDiagnosticControls, UIAccessibility.isVoiceOverRunning {
            let element: Any? = settledMode == .desktop
                ? zoomContentView.canvasView.accessibilityElements?.first
                : currentNoteID.flatMap { preparedModel?.waterfallGeometry.indexByID[$0] }
                    .flatMap { waterfallView.cellForItem(at: IndexPath(item: $0, section: 0)) }
            UIAccessibility.post(notification: .layoutChanged, argument: element)
        }
    }

    func startTransitionDisplayLink() {
        transitionDisplayLink?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(updateTransitionContent))
        link.add(to: .main, forMode: .common)
        transitionDisplayLink = link
    }

    @objc func updateTransitionContent() {
        guard let context = transitionContext else { return }
        let position = context.scene.clockView.layer.presentation()?.position.x
            ?? context.animator.fractionComplete
        context.scene.render(progress: context.animator.fractionComplete, physicalProgress: position)
        onModeTransitionProgress?(context.fromMode, context.toMode, position)
    }

    func setSurfaceInteractionEnabled(_ enabled: Bool) {
        desktopScrollView.isUserInteractionEnabled = enabled && currentMode == .desktop && stackBrowser == nil
        waterfallView.isUserInteractionEnabled = enabled && currentMode == .waterfall
    }

    func surface(for mode: Mode) -> UIView {
        mode == .desktop ? desktopScrollView : waterfallView
    }

    func paperPose(in mode: Mode, noteID: Int64) -> CanvasOverviewPaperPose? {
        guard let model = preparedModel else { return nil }
        if mode == .desktop {
            guard let paper = model.canvasGeometry.paper(for: noteID) else { return nil }
            let center = zoomContentView.canvasView.convert(paper.frame.center, to: view)
            let scale = desktopScrollView.zoomScale
            return CanvasOverviewPaperPose(center: center,
                size: CGSize(width: paper.frame.width * scale, height: paper.frame.height * scale), rotation: paper.rotation)
        }
        guard let index = model.waterfallGeometry.indexByID[noteID] else { return nil }
        let frame = waterfallView.convert(model.waterfallGeometry.frames[index], to: view)
        return CanvasOverviewPaperPose(center: frame.center, size: frame.size, rotation: 0)
    }

    func endpoint(in mode: Mode, noteID: Int64) -> CanvasOverviewRenderEndpoint? {
        guard let model = preparedModel, let note = model.note(for: noteID),
              let pose = paperPose(in: mode, noteID: noteID) else { return nil }
        let mapping = mode == .desktop ? model.canvasGeometry.indexByID : model.waterfallGeometry.indexByID
        guard let index = mapping[noteID] else { return nil }
        let original: CanvasOverviewCanvasPaper
        if mode == .desktop { original = model.canvasGeometry.papers[index] }
        else {
            guard let flowIndex = model.waterfallGeometry.indexByID[noteID] else { return nil }
            original = CanvasOverviewCanvasPaper(index: index, noteID: noteID,
                frame: CGRect(origin: .zero, size: model.waterfallGeometry.frames[flowIndex].size),
                visualFrame: .zero, rotation: 0, contentGeometry: model.waterfallGeometry.contentGeometries[flowIndex])
        }
        let local = CanvasOverviewCanvasPaper(index: index, noteID: noteID,
            frame: CGRect(origin: .zero, size: original.frame.size), visualFrame: .zero,
            rotation: 0, contentGeometry: original.contentGeometry.pinned())
        return CanvasOverviewRenderEndpoint(note: note, paper: local, pose: pose,
                                       style: mode == .desktop ? model.style : model.waterfallStyle)
    }

    func makeTransitionPlan(anchorNoteID: Int64) -> CanvasOverviewTransitionPlan? {
        guard let model = preparedModel, let anchor = endpoint(in: .desktop, noteID: anchorNoteID),
              let waterfallAnchor = endpoint(in: .waterfall, noteID: anchorNoteID) else { return nil }
        let clip = desktopScrollView.convert(desktopScrollView.bounds, to: view).intersection(view.bounds)
        let canvasRect = zoomContentView.canvasView.convert(desktopScrollView.bounds, from: desktopScrollView)
        let desktopVisible = model.canvasGeometry.indexes(in: canvasRect).compactMap {
            endpoint(in: .desktop, noteID: model.notes[$0].id)
        }
        let waterfallVisible = model.waterfallGeometry.indexes(in: waterfallView.bounds.insetBy(dx: 0, dy: -24)).compactMap {
            endpoint(in: .waterfall, noteID: model.waterfallGeometry.notes[$0].id)
        }
        let panorama = anchor.pose.size.width < 116
        let ratio = panorama ? model.canvasGeometry.readableZoomScale(in: clip.size) / desktopScrollView.zoomScale : 1
        let focusAnchor = panorama
            ? CGPoint(x: clip.midX, y: min(clip.maxY - anchor.paper.frame.height / 2, max(clip.minY + anchor.paper.frame.height / 2, waterfallAnchor.pose.center.y)))
            : anchor.pose.center
        var desktopIDs: Set<Int64>
        if panorama {
            // Query focused rows in canvas coordinates; do not materialize panorama card views.
            let center = model.canvasGeometry.papers[model.canvasGeometry.indexByID[anchorNoteID]!].frame.center
            let zoom = desktopScrollView.zoomScale * ratio
            let neighborhood = CGRect(x: center.x - (focusAnchor.x - clip.minX) / zoom,
                                      y: center.y - (focusAnchor.y - clip.minY) / zoom,
                                      width: clip.width / zoom, height: clip.height / zoom)
            desktopIDs = Set(model.canvasGeometry.indexes(in: neighborhood).map { model.notes[$0].id })
        } else {
            desktopIDs = Set(desktopVisible.map { $0.note.id })
        }
        let waterfallIDs = Set(waterfallVisible.map { $0.note.id })
        desktopIDs.insert(anchorNoteID)
        let union = desktopIDs.union(waterfallIDs)
        let limit = traitCollection.horizontalSizeClass == .regular ? 10 : 6
        let ordered = union.sorted {
            if $0 == anchorNoteID { return true }
            if $1 == anchorNoteID { return false }
            let a = paperPose(in: .waterfall, noteID: $0)?.center.distanceSquared(to: waterfallAnchor.pose.center) ?? 0
            let b = paperPose(in: .waterfall, noteID: $1)?.center.distanceSquared(to: waterfallAnchor.pose.center) ?? 0
            return a == b ? $0 < $1 : a < b
        }
        var migrated = 0
        let cards = ordered.compactMap { id -> CanvasOverviewSceneCard? in
            let actualDesktop = endpoint(in: .desktop, noteID: id)
            let actualWaterfall = endpoint(in: .waterfall, noteID: id)
            // A window-only paper has one real endpoint. The unused opposite side carries
            // the same description; exit/enter never draws or prepares that synthetic side.
            guard let desktop = actualDesktop ?? actualWaterfall,
                  let waterfall = actualWaterfall ?? actualDesktop else { return nil }
            let isAnchor = id == anchorNoteID
            var kind: CanvasOverviewSceneCardKind
            if desktopIDs.contains(id), waterfallIDs.contains(id) {
                let start = CGPoint(x: focusAnchor.x + (desktop.pose.center.x - anchor.pose.center.x) * ratio,
                                    y: focusAnchor.y + (desktop.pose.center.y - anchor.pose.center.y) * ratio)
                let crossesAnchor = !isAnchor && CanvasOverviewMotion.pathsConflict(
                    start: start, end: waterfall.pose.center,
                    anchorStart: focusAnchor, anchorEnd: waterfallAnchor.pose.center,
                    clearance: (desktop.pose.size.width * ratio + waterfallAnchor.pose.size.width) * 0.48)
                if isAnchor || (migrated < limit && !crossesAnchor) {
                    kind = .migrate
                    migrated += 1
                } else { kind = .exchange }
            } else if panorama, desktopVisible.contains(where: { $0.note.id == id }), waterfallIDs.contains(id) {
                kind = .exchange
            } else { kind = desktopIDs.contains(id) ? .exit : .enter }
            let distance = sqrt(waterfall.pose.center.distanceSquared(to: waterfallAnchor.pose.center))
            return CanvasOverviewSceneCard(desktop: desktop, waterfall: waterfall, kind: kind,
                                      isAnchor: isAnchor, delay: isAnchor ? 0 : min(0.02, distance / max(1, clip.height) * 0.02))
        }
        return CanvasOverviewTransitionPlan(clip: clip, cards: cards, desktopVisible: desktopVisible,
            waterfallVisible: waterfallVisible, style: model.style, isPanorama: panorama, focusRatio: ratio,
            desktopAnchor: anchor.pose.center, focusAnchor: focusAnchor,
            screenScale: traitCollection.displayScale, generation: generation,
            desktopCanvasRect: canvasRect, model: model)
    }
}

// MARK: - Immutable model

/// 仅实验页的逻辑排版宽度；不作为全局设计令牌，也不写入生产偏好。
nonisolated enum CanvasOverviewDesktopCardWidth {
    static let defaultValue: CGFloat = 220
    static let range = 180...360
    static let presets: [CGFloat] = [180, defaultValue, 260, 300, 360]

    static func parse(_ text: String) -> CGFloat? {
        guard let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), range.contains(value) else { return nil }
        return CGFloat(value)
    }
}

nonisolated struct CanvasOverviewPreparedModel: Sendable {
    let notes: [CanvasOverviewNote]
    let noteByID: [Int64: CanvasOverviewNote]
    let canvasGeometry: CanvasOverviewCanvasGeometry
    var waterfallGeometry: CanvasOverviewWaterfallGeometry
    let style: CanvasOverviewPaperStyle
    let waterfallStyle: CanvasOverviewPaperStyle
    let isRealData: Bool
    let richTextNoteCount: Int
    let previewRichNoteIDs: [Int64]
    let overviewImage: UIImage?
    var initialViewportImage: UIImage?
    var initialViewportRect: CGRect
    var isWaterfallPrepared = true
    var regionalBackdrops: [NoteReviewDirectoryGroupID: UIImage] = [:]

    /// 两种布局拥有各自有界窗口；跨模式查找只能按业务身份，不能共用数组下标。
    func note(for id: Int64) -> CanvasOverviewNote? {
        noteByID[id] ?? waterfallGeometry.indexByID[id].map { waterfallGeometry.notes[$0] }
    }

    /// 未准备某个模式的端点明确返回 nil，不能拿另一套排版补位。
    func content(for id: Int64, mode: NoteReviewCanvasOverviewController.Mode) -> CanvasOverviewPaperContentGeometry? {
        if mode == .desktop { return canvasGeometry.paper(for: id)?.contentGeometry }
        return waterfallGeometry.indexByID[id].map { waterfallGeometry.contentGeometries[$0] }
    }
}

/// 长期只保留身份和无障碍短摘要；完整富文本由页面有界缓存持有。
nonisolated struct CanvasOverviewNote: Sendable {
    let id: Int64
    let revision: CanvasOverviewSourceRevision
    private let immediate: CanvasOverviewPreviewPayload?
    let store: CanvasOverviewPreviewStore?
    let key: CanvasOverviewResourceKey?
    let summary: String
    let summaryBook: String
    let richFormatting: Bool
    var payload: CanvasOverviewPreviewPayload? { immediate ?? key.flatMap { store?.previews.lease(for: $0)?.value } }
    var quote: String { payload?.quote.text ?? summary }
    var thought: String { payload?.thought.text ?? "" }
    var bookTitle: String { payload?.book.text ?? summaryBook }
    var chapter: String { payload?.chapter.text ?? "" }
    var quoteAsset: CanvasOverviewTextAsset { payload?.quote ?? .empty }
    var thoughtAsset: CanvasOverviewTextAsset { payload?.thought ?? .empty }
    var bookAsset: CanvasOverviewTextAsset { payload?.book ?? .empty }
    var chapterAsset: CanvasOverviewTextAsset { payload?.chapter ?? .empty }
    var hasRichFormatting: Bool { richFormatting }

    init(id: Int64, quote: String, thought: String, bookTitle: String, chapter: String,
         quoteAsset: CanvasOverviewTextAsset, thoughtAsset: CanvasOverviewTextAsset,
         bookAsset: CanvasOverviewTextAsset, chapterAsset: CanvasOverviewTextAsset,
         revision: CanvasOverviewSourceRevision = .init()) {
        self.id = id
        self.revision = revision
        immediate = CanvasOverviewPreviewPayload(quote: quoteAsset, thought: thoughtAsset, book: bookAsset, chapter: chapterAsset)
        store = nil; key = nil
        summary = String(quote.prefix(80)); summaryBook = String(bookTitle.prefix(80))
        richFormatting = quoteAsset.hasRichFormatting || thoughtAsset.hasRichFormatting
    }

    private init(note: Self, store: CanvasOverviewPreviewStore, key: CanvasOverviewResourceKey) {
        id = note.id; revision = note.revision; immediate = nil; self.store = store; self.key = key
        summary = note.summary; summaryBook = note.summaryBook; richFormatting = note.richFormatting
    }

    /// 批次消费完成前移交有成本上限的缓存，不让完整清单强引用正文。
    func cached(in store: CanvasOverviewPreviewStore, generation: UUID) -> Self {
        let key = CanvasOverviewResourceKey(generation: generation, noteID: id, width: 0)
        if let payload { _ = store.previews.insert(payload, for: key, cost: payload.cost) }
        return Self(note: self, store: store, key: key)
    }

    /// 恢复缓存中的不可变预览用于后台字形准备，不再读仓储或解析同一段 HTML。
    func restoringPreview(_ payload: CanvasOverviewPreviewPayload) -> Self {
        Self(id: id, quote: payload.quote.text, thought: payload.thought.text,
             bookTitle: payload.book.text, chapter: payload.chapter.text,
             quoteAsset: payload.quote, thoughtAsset: payload.thought,
             bookAsset: payload.book, chapterAsset: payload.chapter, revision: revision)
    }
}

// NSAttributedString 在解析任务结束时复制为不可变值；该窄桥接不包含 CTFrame / CTLine。
nonisolated struct CanvasOverviewTextAsset: @unchecked Sendable {
    static var empty: Self { Self(text: "", attributedText: NSAttributedString(string: ""),
        attributeKeys: NoteReviewCanvasTextAttributes(quote: .init("blockquote"), bullet: .init("bulletList"), italic: .init("obliqueItalic"))) }
    let text: String
    let attributedText: NSAttributedString
    let attributeKeys: NoteReviewCanvasTextAttributes
    var hasRichFormatting: Bool = false

    static func containsFormatting(_ attributes: [NSAttributedString.Key: Any]) -> Bool {
        let traits = (attributes[.font] as? UIFont)?.fontDescriptor.symbolicTraits ?? []
        return traits.contains(.traitBold) || traits.contains(.traitItalic)
            || attributes[.obliqueItalic] != nil || attributes[.underlineStyle] != nil
            || attributes[.strikethroughStyle] != nil || attributes[.backgroundColor] != nil
            || attributes[.blockquote] != nil || attributes[.bulletList] != nil || attributes[.link] != nil
    }

    func measuredHeight(width: CGFloat) -> CGFloat {
        guard !text.isEmpty, width > 0 else { return 0 }
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            CTFramesetterCreateWithAttributedString(attributedText),
            CFRange(location: 0, length: 0),
            nil,
            CGSize(width: width, height: .greatestFiniteMagnitude),
            nil
        )
        return ceil(size.height)
    }
}

nonisolated struct CanvasOverviewPaperStyle: Sendable {
    let canvasBaseColor: CGColor
    let canvasTintColor: CGColor
    let paperColor: CGColor
    let borderColor: CGColor
    let primaryTextColor: UIColor
    let secondaryTextColor: UIColor
    let hintTextColor: UIColor
    let bodyFont: UIFont
    let annotationFont: UIFont
    let metadataFont: UIFont
    let metadataMediumFont: UIFont
    let paperSkin: UIImage
    let drawingSkin: NoteReviewCanvasPaperSkin
    let isFlat: Bool
    let cornerRadius: CGFloat
    let traits: UITraitCollection
    let textAttributes: NoteReviewCanvasTextAttributes
    let alignment: NSTextAlignment
    let metadataAlignment: NSTextAlignment
    let display: NoteReviewImmersiveDisplaySettings
    let paragraphIndent: CGFloat
    let bodyLineSpacing: CGFloat
    let annotationLineSpacing: CGFloat
    let quoteAccent: UIColor
    let linkColor: UIColor
    var backgroundImage: CGImage?
    let backgroundOverlay: CGColor

    @MainActor
    init(traits: UITraitCollection, isFlat: Bool = false, settings: NoteReviewSettings? = nil) {
        self.traits = traits
        textAttributes = .project
        alignment = settings?.textAlignment.nsTextAlignment ?? .natural
        metadataAlignment = settings?.textAlignment.auxiliaryNSTextAlignment ?? .natural
        display = settings?.immersiveDisplay ?? .defaultValue
        paragraphIndent = RichTextEditorView.defaultParagraphIndent
        bodyLineSpacing = ReadingContentTypography.bodyLineSpacing
        annotationLineSpacing = ReadingContentTypography.annotationLineSpacing
        quoteAccent = RichTextAppearance.quoteAccent.resolvedColor(with: traits)
        linkColor = UIColor.link.resolvedColor(with: traits)
        backgroundOverlay = (settings?.cardAppearance.uiOnSurface ?? NoteReviewCanvasAppearance.primary)
            .resolvedColor(with: traits).withAlphaComponent(0.03).cgColor
        self.isFlat = isFlat
        cornerRadius = isFlat ? CornerRadius.containerLarge : CornerRadius.blockLarge
        func resolved(_ color: UIColor) -> UIColor {
            color.resolvedColor(with: traits)
        }
        canvasBaseColor = resolved(NoteReviewCanvasAppearance.page).cgColor
        canvasTintColor = resolved(NoteReviewCanvasAppearance.accent).withAlphaComponent(0.025).cgColor
        paperColor = settings?.cardAppearance.uiSurface.resolvedColor(with: traits).cgColor ?? resolved(isFlat ? NoteReviewCanvasAppearance.sheet : NoteReviewCanvasAppearance.paper).cgColor
        borderColor = resolved(isFlat ? NoteReviewCanvasAppearance.border : NoteReviewCanvasAppearance.subtleBorder).cgColor
        primaryTextColor = settings?.cardAppearance.uiOnSurface.resolvedColor(with: traits) ?? resolved(NoteReviewCanvasAppearance.primary)
        secondaryTextColor = settings?.cardAppearance.uiOnSurface.resolvedColor(with: traits).withAlphaComponent(0.72) ?? resolved(NoteReviewCanvasAppearance.secondary)
        hintTextColor = resolved(NoteReviewCanvasAppearance.hint)
        bodyFont = settings?.fontSelection.uiFont(base: ReadingContentTypography.uiBody) ?? ReadingContentTypography.uiBody
        annotationFont = settings?.fontSelection.uiFont(base: ReadingContentTypography.uiAnnotation) ?? ReadingContentTypography.uiAnnotation
        metadataFont = ReadingContentTypography.uiMetadata
        metadataMediumFont = ReadingContentTypography.uiMetadataMedium
        paperSkin = CanvasOverviewPaperRenderer.makeSkin(paperColor: paperColor, borderColor: borderColor,
            scale: traits.displayScale, cornerRadius: cornerRadius, hasShadow: !isFlat)
        drawingSkin = NoteReviewCanvasPaperSkin(image: paperSkin.cgImage!, scale: paperSkin.scale,
            cap: CanvasOverviewPaperRenderer.shadowPadding + cornerRadius + 2)
    }
}

nonisolated struct CanvasOverviewPaperContentGeometry: Sendable {
    let quoteRect: CGRect
    let thoughtRect: CGRect?
    let bookRect: CGRect
    let chapterRect: CGRect
    let isQuoteTruncated: Bool
    let isThoughtTruncated: Bool
    private let immediateBlocks: [CanvasOverviewTextBlock]?
    let store: CanvasOverviewPreviewStore?
    let key: CanvasOverviewResourceKey?
    let fallback: CanvasOverviewFallbackRegion?
    private var protection: NoteReviewCanvasResourceLease<CanvasOverviewDrawingPayload>?
    var preparedBlocks: [CanvasOverviewTextBlock]? {
        immediateBlocks ?? protection?.value.blocks ?? key.flatMap { store?.drawings.lease(for: $0)?.value.blocks }
    }
    var blocks: [CanvasOverviewTextBlock] { preparedBlocks ?? [] }

    init(quoteRect: CGRect, thoughtRect: CGRect?, bookRect: CGRect, chapterRect: CGRect,
         isQuoteTruncated: Bool, isThoughtTruncated: Bool, blocks: [CanvasOverviewTextBlock],
         store: CanvasOverviewPreviewStore? = nil, key: CanvasOverviewResourceKey? = nil,
         fallback: CanvasOverviewFallbackRegion? = nil) {
        self.quoteRect = quoteRect; self.thoughtRect = thoughtRect; self.bookRect = bookRect; self.chapterRect = chapterRect
        self.isQuoteTruncated = isQuoteTruncated; self.isThoughtTruncated = isThoughtTruncated
        self.store = store; self.key = key; self.fallback = fallback
        protection = nil
        immediateBlocks = store == nil ? blocks : nil
        if let store, let key {
            let payload = CanvasOverviewDrawingPayload(blocks: blocks)
            _ = store.drawings.insert(payload, for: key, cost: payload.cost)
        }
    }

    /// 精确矩形留在轻量几何中，字形转入预算缓存；失配时使用同代次真实图集。
    func cached(in store: CanvasOverviewPreviewStore, key: CanvasOverviewResourceKey,
                fallback: CanvasOverviewFallbackRegion) -> Self {
        Self(quoteRect: quoteRect, thoughtRect: thoughtRect, bookRect: bookRect, chapterRect: chapterRect,
            isQuoteTruncated: isQuoteTruncated, isThoughtTruncated: isThoughtTruncated,
            blocks: blocks, store: store, key: key, fallback: fallback)
    }

    /// 转场或绘制期间固定字形端点，并将其实际强引用计入共享预算。
    func pinned() -> Self {
        var value = self
        if let key { value.protection = store?.drawings.lease(for: key) }
        return value
    }

    /// 调宽接管复用原有文本块边界；高清缓存未命中时从已解析属性重放字形，不退回低清图集。
    func replaying(_ note: CanvasOverviewNote) -> Self {
        var blocks = [CanvasOverviewTextBlock(asset: note.quoteAsset, rect: quoteRect, truncated: isQuoteTruncated)]
        blocks.append(CanvasOverviewTextBlock(asset: note.thoughtAsset, rect: thoughtRect ?? .zero, truncated: isThoughtTruncated))
        blocks.append(CanvasOverviewTextBlock(asset: note.bookAsset, rect: bookRect))
        blocks.append(CanvasOverviewTextBlock(asset: note.chapterAsset, rect: chapterRect))
        return Self(quoteRect: quoteRect, thoughtRect: thoughtRect, bookRect: bookRect, chapterRect: chapterRect,
            isQuoteTruncated: isQuoteTruncated, isThoughtTruncated: isThoughtTruncated, blocks: blocks)
    }
}

/// 桌面、瀑布流和代理均消费生产共享内核，不再跨队列持有 CTLine。
nonisolated struct CanvasOverviewTextBlock: Sendable {
    let rect: CGRect
    let layout: NoteReviewCanvasTextLayout
    let signature: String
    let truncated: Bool
    let hasVisibleFormatting: Bool

    init(asset: CanvasOverviewTextAsset, rect: CGRect, truncated: Bool = false) {
        self.rect = rect
        self.truncated = truncated
        layout = NoteReviewCanvasTextLayout(text: asset.attributedText, size: rect.size, attributes: asset.attributeKeys)
        var formatted = false
        if asset.hasRichFormatting, layout.visibleRange.length > 0 {
            asset.attributedText.enumerateAttributes(in: layout.visibleRange) { attributes, _, stop in
                if CanvasOverviewTextAsset.containsFormatting(attributes) { formatted = true; stop.pointee = true }
            }
        }
        hasVisibleFormatting = formatted
        signature = layout.metrics.map {
            "\($0.range.location):\($0.range.length):\(rect.height - $0.origin.y)"
        }.joined(separator: "|") + (truncated ? "fade" : "full") + ":\(asset.attributedText.hash)"
    }
}

nonisolated struct CanvasOverviewCanvasPaper: Sendable {
    let index: Int
    let noteID: Int64
    let frame: CGRect
    let visualFrame: CGRect
    let rotation: CGFloat
    let contentGeometry: CanvasOverviewPaperContentGeometry
}

nonisolated struct CanvasOverviewCanvasRow: Sendable {
    let indexRange: Range<Int>
    let minY: CGFloat
    let maxY: CGFloat
}

typealias CanvasOverviewDesktopPacking = NoteReviewCanvasDesktopPacking
typealias CanvasOverviewDesktopLayoutParameters = NoteReviewCanvasDesktopLayoutParameters
typealias CanvasOverviewPairPlacement = NoteReviewCanvasPairPlacement
typealias CanvasOverviewPairGeometry = NoteReviewCanvasPairGeometry

nonisolated struct CanvasOverviewCanvasGroup: Sendable {
    let rowRange: Range<Int>
    let indexRange: Range<Int>
    let minY: CGFloat
    let maxY: CGFloat
}

nonisolated struct CanvasOverviewCanvasGeometry: Sendable {
    let cardWidth: CGFloat
    let columnCount: Int
    let parameters: CanvasOverviewDesktopLayoutParameters
    let notes: [CanvasOverviewNote]
    let papers: [CanvasOverviewCanvasPaper]
    let rows: [CanvasOverviewCanvasRow]
    let groups: [CanvasOverviewCanvasGroup]
    let lifts: [CGFloat]
    let indexByID: [Int64: Int]
    let contentSize: CGSize
    let packingSummary: String
    let spatialIndex: NoteReviewCanvasGeometry
    var regionSlices: [CanvasOverviewRegionSlice] = []

    func paper(for noteID: Int64) -> CanvasOverviewCanvasPaper? {
        indexByID[noteID].flatMap { papers[safe: $0] }
    }

    func fitZoomScale(in viewport: CGSize) -> CGFloat {
        guard contentSize.width > 0, contentSize.height > 0 else { return 1 }
        return min(viewport.width / contentSize.width, viewport.height / contentSize.height) * 0.82
    }

    func readableZoomScale(in viewport: CGSize) -> CGFloat {
        max(fitZoomScale(in: viewport), min(1, viewport.width * 0.52 / cardWidth))
    }

    func indexes(in rect: CGRect) -> [Int] {
        let query = rect.insetBy(dx: -20, dy: -20)
        if !regionSlices.isEmpty {
            return regionSlices.flatMap { slice in
                guard slice.frame.intersects(query) else { return [Int]() }
                return slice.geometry.indexes(in: query.offsetBy(dx: -slice.origin.x, dy: -slice.origin.y))
                    .map { $0 + slice.indexRange.lowerBound }
            }
        }
        return spatialIndex.indexes(in: query)
    }

    func paper(at point: CGPoint) -> CanvasOverviewCanvasPaper? {
        if !regionSlices.isEmpty {
            for slice in regionSlices where slice.frame.contains(point) {
                if let id = slice.geometry.hitTest(CGPoint(x: point.x - slice.origin.x, y: point.y - slice.origin.y)) {
                    return paper(for: id)
                }
            }
            return nil
        }
        return spatialIndex.hitTest(point).flatMap { paper(for: $0) }
    }

    func nearestPaper(to point: CGPoint) -> CanvasOverviewCanvasPaper? {
        let searchRect = CGRect(x: point.x - 700, y: point.y - 700, width: 1_400, height: 1_400)
        let candidates = indexes(in: searchRect)
        let indexesToSearch = candidates.isEmpty ? Array(papers.indices.prefix(1)) : candidates
        return indexesToSearch.min { lhs, rhs in
            papers[lhs].frame.center.distanceSquared(to: point)
                < papers[rhs].frame.center.distanceSquared(to: point)
        }.map { papers[$0] }
    }
}

nonisolated struct CanvasOverviewWaterfallGeometry: Sendable {
    let notes: [CanvasOverviewNote]
    let frames: [CGRect]
    let contentGeometries: [CanvasOverviewPaperContentGeometry]
    let columnIndexes: [[Int]]
    let indexByID: [Int64: Int]
    let contentSize: CGSize

    let spatialIndex: NoteReviewCanvasWaterfallGeometry

    func indexes(in rect: CGRect) -> [Int] {
        spatialIndex.indexes(in: rect)
    }

    func nearestIndex(to point: CGPoint) -> Int? {
        let search = CGRect(x: 0, y: point.y - 700, width: contentSize.width, height: 1_400)
        return indexes(in: search).min {
            frames[$0].center.distanceSquared(to: point) < frames[$1].center.distanceSquared(to: point)
        }
    }
}

nonisolated struct CanvasOverviewPaperPose: Sendable {
    let center: CGPoint
    let size: CGSize
    let rotation: CGFloat

    func offset(dx: CGFloat, dy: CGFloat) -> CanvasOverviewPaperPose {
        CanvasOverviewPaperPose(center: CGPoint(x: center.x + dx, y: center.y + dy), size: size, rotation: rotation)
    }

    var boundingFrame: CGRect {
        let cosine = abs(cos(rotation))
        let sine = abs(sin(rotation))
        let width = size.width * cosine + size.height * sine
        let height = size.width * sine + size.height * cosine
        return CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
    }
}


nonisolated enum CanvasOverviewTransitionState: String {
    case idle, preparing, animating, settling
}

typealias CanvasOverviewViewportState = NoteReviewCanvasViewport

/// 逻辑排版和屏幕映射分离；转场始终消费当前 generation 的原始卡宽，不用投影宽度重新排版。
nonisolated struct CanvasOverviewRenderEndpoint: Sendable {
    let note: CanvasOverviewNote
    let paper: CanvasOverviewCanvasPaper
    let pose: CanvasOverviewPaperPose
    let style: CanvasOverviewPaperStyle

    var scale: CGFloat { pose.size.width / paper.frame.width }
}

nonisolated enum CanvasOverviewSceneCardKind {
    case migrate, exchange, exit, enter
}

nonisolated struct CanvasOverviewSceneCard: Sendable {
    let desktop: CanvasOverviewRenderEndpoint
    let waterfall: CanvasOverviewRenderEndpoint
    let kind: CanvasOverviewSceneCardKind
    let isAnchor: Bool
    let delay: CGFloat
}

nonisolated struct CanvasOverviewTransitionPlan: Sendable {
    let clip: CGRect
    let cards: [CanvasOverviewSceneCard]
    let desktopVisible: [CanvasOverviewRenderEndpoint]
    let waterfallVisible: [CanvasOverviewRenderEndpoint]
    let style: CanvasOverviewPaperStyle
    let isPanorama: Bool
    let focusRatio: CGFloat
    let desktopAnchor: CGPoint
    let focusAnchor: CGPoint
    let screenScale: CGFloat
    let generation: Int
    let desktopCanvasRect: CGRect
    let model: CanvasOverviewPreparedModel
}

nonisolated struct CanvasOverviewBlockTexture: Sendable {
    let source: UIImage?
    let target: UIImage?
    let isIdentical: Bool
    let sourceRect: CGRect
    let targetRect: CGRect
}

nonisolated struct CanvasOverviewSceneTextures: Sendable {
    let desktopBackground: UIImage
    let waterfallBackground: UIImage
    let desktopFull: UIImage
    let waterfallFull: UIImage?
    let desktopUnderlay: UIImage?
    let blocks: [[CanvasOverviewBlockTexture]]

    private var distinctBitmaps: [CGImage] {
        var seen = Set<ObjectIdentifier>()
        let images = [desktopBackground, waterfallBackground, desktopFull, waterfallFull, desktopUnderlay]
            .compactMap { $0 } + blocks.flatMap { $0.flatMap { [$0.source, $0.target].compactMap { $0 } } }
        return images.compactMap { image in
            guard let bitmap = image.cgImage, seen.insert(ObjectIdentifier(bitmap)).inserted else { return nil }
            return bitmap
        }
    }

    /// 按实际像素行成本统计，同一 CGImage 被不同 UIImage 或补底复用时只计费一次。
    var pixelBytes: Int {
        distinctBitmaps.reduce(0) { $0 + $1.bytesPerRow * $1.height }
    }

    /// 仅汇总像素存储格式，不含书摘身份与内容；由主线程在转场开始时记录一次。
    var pixelFormatSummary: String {
        var groups: [String: (count: Int, bytes: Int)] = [:]
        for bitmap in distinctBitmaps {
            let key = "\(bitmap.width)x\(bitmap.height):bpc\(bitmap.bitsPerComponent)/bpp\(bitmap.bitsPerPixel):row\(bitmap.bytesPerRow)"
            let previous = groups[key] ?? (0, 0)
            groups[key] = (previous.count + 1, previous.bytes + bitmap.bytesPerRow * bitmap.height)
        }
        return groups.keys.sorted().map { key in
            let group = groups[key]!
            return "\(key):count\(group.count):bytes\(group.bytes)"
        }.joined(separator: ";")
    }
}

/// 主线程撤销需求，准备队列在卡片边界停止；取消结果不得提交给新的场景。
nonisolated final class CanvasOverviewTransitionPreparation: @unchecked Sendable {
    let lock = NSLock()
    var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

final class CanvasOverviewTransitionContext {
    let fromMode: NoteReviewCanvasOverviewController.Mode
    let toMode: NoteReviewCanvasOverviewController.Mode
    var requestedMode: NoteReviewCanvasOverviewController.Mode
    let animator: UIViewPropertyAnimator
    let scene: CanvasOverviewTransitionSceneView
    let generation: Int

    init(from: NoteReviewCanvasOverviewController.Mode,
         to: NoteReviewCanvasOverviewController.Mode,
         animator: UIViewPropertyAnimator, scene: CanvasOverviewTransitionSceneView, generation: Int) {
        fromMode = from
        toMode = to
        requestedMode = to
        self.animator = animator
        self.scene = scene
        self.generation = generation
    }
}

/// 只在串行准备队列生成可见端点纹理，不在手势和显示时钟中测量或栅格化。
nonisolated enum CanvasOverviewTransitionRasterizer {
    static func prepare(_ plan: CanvasOverviewTransitionPlan,
                        preparation: CanvasOverviewTransitionPreparation,
                        reducedMotion: Bool = false) -> CanvasOverviewSceneTextures? {
        guard !preparation.isCancelled else { return nil }
        if reducedMotion {
            let desktop = surface(plan.desktopVisible, plan: plan, preparation: preparation)
            guard !preparation.isCancelled else { return nil }
            let waterfall = surface(plan.waterfallVisible, plan: plan, preparation: preparation)
            guard !preparation.isCancelled else { return nil }
            return CanvasOverviewSceneTextures(desktopBackground: desktop, waterfallBackground: waterfall,
                desktopFull: desktop, waterfallFull: waterfall, desktopUnderlay: desktop, blocks: [])
        }
        let ids = Set(plan.cards.map { $0.desktop.note.id })
        let desktopBackground = surface(plan.desktopVisible.filter { !ids.contains($0.note.id) },
                                        plan: plan, preparation: preparation)
        guard !preparation.isCancelled else { return nil }
        let waterfallBackground = surface(plan.waterfallVisible.filter { !ids.contains($0.note.id) },
                                          plan: plan, preparation: preparation)
        // 全景只绘制一次远景卡片；完整端点在同一底图上补回有界代理，高清补底直接共享它。
        let desktopFull = surface(plan.desktopVisible.filter { ids.contains($0.note.id) },
                                  plan: plan, preparation: preparation, background: desktopBackground)
        // Normal paper motion never displays waterfallFull; the actual waterfall owns its settled endpoint.
        var blocks: [[CanvasOverviewBlockTexture]] = []
        for card in plan.cards {
            guard !preparation.isCancelled else { return nil }
            let sourceContent = card.desktop.paper.contentGeometry
            let targetContent = card.waterfall.paper.contentGeometry
            let sourceBlocks = sourceContent.blocks
            let targetBlocks = targetContent.blocks
            // 退出和进入在可逆时间轴上分别固定使用一端，另一端永远不参与显示。
            let displayedSides: (source: Bool, target: Bool)
            switch card.kind {
            case .exit: displayedSides = (true, false)
            case .enter: displayedSides = (false, true)
            case .migrate, .exchange: displayedSides = (true, true)
            }
            // Four stable semantic slots: quote, thought, book and chapter. An offscreen
            // endpoint may have no cached drawing; it must not discard the ready visible side.
            blocks.append((0..<max(sourceBlocks.count, targetBlocks.count)).map { index in
                let source = sourceBlocks[safe: index]
                let target = targetBlocks[safe: index]
                let identical = displayedSides.source && displayedSides.target && source != nil && target != nil
                    && source?.signature == target?.signature && source?.truncated == false
                let rasterScale = plan.screenScale * max(1, card.desktop.scale * plan.focusRatio)
                return CanvasOverviewBlockTexture(
                    source: displayedSides.source ? source.flatMap { block($0, style: card.desktop.style, scale: rasterScale) } : nil,
                    target: displayedSides.target && !identical ? target.flatMap { block($0, style: card.waterfall.style, scale: rasterScale) } : nil,
                    isIdentical: identical,
                    sourceRect: source?.rect ?? contentRect(at: index, in: sourceContent),
                    targetRect: target?.rect ?? contentRect(at: index, in: targetContent)
                )
            })
        }
        guard !preparation.isCancelled else { return nil }
        return CanvasOverviewSceneTextures(
            desktopBackground: desktopBackground, waterfallBackground: waterfallBackground,
            desktopFull: desktopFull, waterfallFull: nil,
            desktopUnderlay: desktopFull,
            blocks: blocks
        )
    }

    /// 未缓存端点只使用不可变语义矩形；不为屏外文字额外解析或测量。
    static func contentRect(at index: Int, in content: CanvasOverviewPaperContentGeometry) -> CGRect {
        switch index {
        case 0: content.quoteRect
        case 1: content.thoughtRect ?? .zero
        case 2: content.bookRect
        case 3: content.chapterRect
        default: .zero
        }
    }

    static func surface(_ endpoints: [CanvasOverviewRenderEndpoint], plan: CanvasOverviewTransitionPlan,
                                preparation: CanvasOverviewTransitionPreparation, background: UIImage? = nil) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        // 纯色书摘使用既有 SDR 配色，避免自动上下文把普通正文提升为 16-bit 浮点纹理。
        // 图片背景及已有扩展范围底图仍由 UIKit 选择格式，不在这里改变其色域或动态范围。
        if plan.style.backgroundImage == nil,
           endpoints.allSatisfy({ $0.style.backgroundImage == nil }),
           (background?.cgImage?.bitsPerComponent ?? 8) <= 8 {
            format.preferredRange = .standard
        }
        let isSolidBackground = endpoints.isEmpty && background == nil
        let outputSize = isSolidBackground ? CGSize(width: 1, height: 1) : plan.clip.size
        format.scale = isSolidBackground ? 1 : plan.screenScale
        return UIGraphicsImageRenderer(size: outputSize, format: format).image { renderer in
            let context = renderer.cgContext
            if let background {
                background.draw(in: CGRect(origin: .zero, size: outputSize))
            } else {
                CanvasOverviewCanvasRasterizer.fillCanvas(CGRect(origin: .zero, size: outputSize), style: plan.style, in: context)
            }
            context.translateBy(x: -plan.clip.minX, y: -plan.clip.minY)
            for endpoint in endpoints {
                guard !preparation.isCancelled else { break }
                context.saveGState()
                context.translateBy(x: endpoint.pose.center.x, y: endpoint.pose.center.y)
                context.rotate(by: endpoint.pose.rotation)
                context.scaleBy(x: endpoint.scale, y: endpoint.scale)
                context.translateBy(x: -endpoint.paper.frame.midX, y: -endpoint.paper.frame.midY)
                CanvasOverviewPaperRenderer.draw(paper: endpoint.paper, note: endpoint.note, style: endpoint.style, in: context)
                context.restoreGState()
            }
        }
    }

    static func block(_ block: CanvasOverviewTextBlock, style: CanvasOverviewPaperStyle, scale: CGFloat) -> UIImage? {
        guard block.rect.width > 0, block.rect.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        if style.backgroundImage == nil { format.preferredRange = .standard }
        return UIGraphicsImageRenderer(size: block.rect.size, format: format).image { renderer in
            renderer.cgContext.translateBy(x: -block.rect.minX, y: -block.rect.minY)
            CanvasOverviewPaperRenderer.draw(block: block, paperColor: style.paperColor, in: renderer.cgContext)
        }
    }
}

/// 一个表面拥有转场期间的全部内容。真实滚动面没有打孔，也不叠加独立预览。
final class CanvasOverviewTransitionSceneView: NoteReviewCanvasTransitionSurface {
    let plan: CanvasOverviewTransitionPlan
    let textures: CanvasOverviewSceneTextures
    let clockView = UIView()
    let desktopBackground = UIImageView()
    let waterfallBackground = UIImageView()
    let desktopFull = UIImageView()
    let waterfallFull = UIImageView()
    var papers: [CanvasOverviewTransitionPaperView] = []
    let reducedMotion: Bool
    let fromDesktop: Bool
    private var renderedProgress: CGFloat = 0
    private var renderedPhysicalProgress: CGFloat?
    var duration: TimeInterval { reducedMotion ? 0.12 : (plan.isPanorama ? 0.64 : 0.48) }

    init(plan: CanvasOverviewTransitionPlan, textures: CanvasOverviewSceneTextures, fromDesktop: Bool, reducedMotion: Bool) {
        self.plan = plan
        self.textures = textures
        self.fromDesktop = fromDesktop
        self.reducedMotion = reducedMotion
        super.init(frame: plan.clip)
        clipsToBounds = true
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        backgroundColor = NoteReviewCanvasAppearance.resolvedPaper(plan.style.canvasBaseColor)
        for imageView in [desktopBackground, waterfallBackground, desktopFull, waterfallFull] {
            imageView.frame = bounds
            imageView.contentMode = .scaleToFill
            renderingContent.addSubview(imageView)
        }
        desktopBackground.image = textures.desktopBackground
        waterfallBackground.image = textures.waterfallBackground
        desktopFull.image = textures.desktopFull
        waterfallFull.image = textures.waterfallFull
        if !reducedMotion {
            desktopFull.isHidden = true
            waterfallFull.isHidden = true
            for (index, card) in plan.cards.enumerated() {
                let paper = CanvasOverviewTransitionPaperView(card: card, textures: textures.blocks[index], style: plan.style)
                renderingContent.addSubview(paper)
                papers.append(paper)
            }
            // Fixed ownership and z order; the anchor is never covered by a neighbor.
            for (index, paper) in papers.enumerated() {
                paper.layer.zPosition = plan.cards[index].isAnchor ? 100 : CGFloat(index + 1)
            }
        }
        clockView.bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        clockView.center = .zero
        clockView.isUserInteractionEnabled = false
        addSubview(clockView)
        render(progress: 0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 中断复用有界代理与原图，离屏绘制同一进度，不携带滚动容器的系统边缘结果。
    override func preparedContentImage() -> UIImage? {
        let copy = CanvasOverviewTransitionSceneView(plan: plan, textures: textures,
            fromDesktop: fromDesktop, reducedMotion: reducedMotion)
        copy.render(progress: renderedProgress, physicalProgress: renderedPhysicalProgress)
        return rasterizePreparedScene(copy)
    }

    func render(progress: CGFloat, physicalProgress: CGFloat? = nil) {
        renderedProgress = progress
        renderedPhysicalProgress = physicalProgress
        let u = fromDesktop ? progress : 1 - progress
        let physical = physicalProgress.map { fromDesktop ? $0 : 1 - $0 }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if reducedMotion {
            desktopFull.alpha = 1 - u
            waterfallFull.alpha = u
            desktopBackground.isHidden = true
            waterfallBackground.isHidden = true
            CATransaction.commit()
            return
        }
        let time = u * CGFloat(duration)
        let focus = plan.isPanorama ? CanvasOverviewMotion.ease(time / 0.28) : 1
        let morphStart: CGFloat = plan.isPanorama ? 0.18 : 0
        let morphDuration = CGFloat(duration) - morphStart
        let morphTime = max(0, time - morphStart)
        let morph = !plan.isPanorama ? (physical ?? CanvasOverviewMotion.spring(morphTime / morphDuration))
            : CanvasOverviewMotion.spring(morphTime / morphDuration)
        let cameraScale = 1 + (plan.focusRatio - 1) * focus
        let cameraAnchor = CanvasOverviewMotion.mix(plan.desktopAnchor, plan.focusAnchor, focus)
        let localAnchor = CGPoint(x: plan.desktopAnchor.x - plan.clip.minX, y: plan.desktopAnchor.y - plan.clip.minY)
        desktopBackground.layer.anchorPoint = CGPoint(x: localAnchor.x / bounds.width, y: localAnchor.y / bounds.height)
        desktopBackground.layer.position = CGPoint(x: cameraAnchor.x - plan.clip.minX, y: cameraAnchor.y - plan.clip.minY)
        desktopBackground.transform = CGAffineTransform(scaleX: cameraScale, y: cameraScale)
        let backgroundBlend = CanvasOverviewMotion.ease(morphTime / 0.16)
        desktopBackground.alpha = 1 - backgroundBlend
        waterfallBackground.alpha = backgroundBlend

        for (index, paper) in papers.enumerated() {
            let card = plan.cards[index]
            let cameraPose = CanvasOverviewPaperPose(
                center: CGPoint(x: cameraAnchor.x + (card.desktop.pose.center.x - plan.desktopAnchor.x) * cameraScale,
                                y: cameraAnchor.y + (card.desktop.pose.center.y - plan.desktopAnchor.y) * cameraScale),
                size: CGSize(width: card.desktop.pose.size.width * cameraScale, height: card.desktop.pose.size.height * cameraScale),
                rotation: card.desktop.pose.rotation)
            let localTime = max(0, morphTime - card.delay)
            let localMorph = !plan.isPanorama ? morph
                : (card.isAnchor ? morph : CanvasOverviewMotion.spring(localTime / max(0.01, morphDuration - card.delay)))
            let crossfade = CanvasOverviewMotion.ease((morphTime - 0.16) / 0.09)
            let delta = CGPoint(x: card.waterfall.pose.center.x - cameraPose.center.x,
                                y: card.waterfall.pose.center.y - cameraPose.center.y)
            let length = max(1, sqrt(delta.x * delta.x + delta.y * delta.y))
            let direction = CGPoint(x: delta.x / length * 24, y: delta.y / length * 24)
            let exitProgress = CanvasOverviewMotion.ease(localTime / 0.16)
            let enterProgress = CanvasOverviewMotion.ease((localTime - 0.15) / 0.16)
            switch card.kind {
            case .migrate:
                paper.apply(pose: CanvasOverviewMotion.mix(cameraPose, card.waterfall.pose, localMorph),
                            contentProgress: crossfade, blockPositionProgress: localMorph, opacity: 1, clipOrigin: plan.clip.origin)
            case .exit:
                paper.apply(pose: cameraPose.offset(dx: direction.x * exitProgress, dy: direction.y * exitProgress),
                            contentProgress: 0, blockPositionProgress: 0, opacity: 1 - exitProgress, clipOrigin: plan.clip.origin)
            case .enter:
                paper.apply(pose: card.waterfall.pose.offset(dx: -direction.x * (1 - enterProgress), dy: -direction.y * (1 - enterProgress)),
                            contentProgress: 1, blockPositionProgress: 1, opacity: enterProgress, clipOrigin: plan.clip.origin)
            case .exchange:
                if localTime < 0.16 {
                    paper.apply(pose: cameraPose.offset(dx: direction.x * exitProgress, dy: direction.y * exitProgress),
                                contentProgress: 0, blockPositionProgress: 0, opacity: 1 - exitProgress, clipOrigin: plan.clip.origin)
                } else {
                    paper.apply(pose: card.waterfall.pose.offset(dx: -direction.x * (1 - enterProgress), dy: -direction.y * (1 - enterProgress)),
                                contentProgress: 1, blockPositionProgress: 1, opacity: enterProgress, clipOrigin: plan.clip.origin)
                }
            }
        }
        CATransaction.commit()
    }
}

nonisolated enum CanvasOverviewMotion {
    static func pathsConflict(start: CGPoint, end: CGPoint, anchorStart: CGPoint, anchorEnd: CGPoint, clearance: CGFloat) -> Bool {
        let relative = CGPoint(x: start.x - anchorStart.x, y: start.y - anchorStart.y)
        let velocity = CGPoint(x: (end.x - anchorEnd.x) - relative.x, y: (end.y - anchorEnd.y) - relative.y)
        let denominator = velocity.x * velocity.x + velocity.y * velocity.y
        let t = denominator > 0.001 ? min(1, max(0, -(relative.x * velocity.x + relative.y * velocity.y) / denominator)) : 0
        let closest = CGPoint(x: relative.x + velocity.x * t, y: relative.y + velocity.y * t)
        return closest.x * closest.x + closest.y * closest.y < clearance * clearance
    }

    static func ease(_ input: CGFloat) -> CGFloat {
        let x = min(1, max(0, input))
        return x * x * (3 - 2 * x)
    }

    /// 单一归一化阻尼曲线，端点严格为 0/1；反向沿同一时间轴，不重新起动画。
    static func spring(_ input: CGFloat) -> CGFloat {
        let x = min(1, max(0, input))
        let damping: CGFloat = 0.96
        let omega: CGFloat = 7.2
        let damped = omega * sqrt(1 - damping * damping)
        func response(_ t: CGFloat) -> CGFloat {
            1 - exp(-damping * omega * t) * (cos(damped * t) + damping * omega / damped * sin(damped * t))
        }
        return response(x) / response(1)
    }

    static func mix(_ a: CGFloat, _ b: CGFloat, _ p: CGFloat) -> CGFloat { a + (b - a) * p }
    static func mix(_ a: CGPoint, _ b: CGPoint, _ p: CGFloat) -> CGPoint {
        CGPoint(x: mix(a.x, b.x, p), y: mix(a.y, b.y, p))
    }
    static func mix(_ a: CanvasOverviewPaperPose, _ b: CanvasOverviewPaperPose, _ p: CGFloat) -> CanvasOverviewPaperPose {
        CanvasOverviewPaperPose(center: mix(a.center, b.center, p),
            size: CGSize(width: mix(a.size.width, b.size.width, p), height: mix(a.size.height, b.size.height, p)),
            rotation: mix(a.rotation, b.rotation, p))
    }
}

// MARK: - Model preparation

nonisolated enum CanvasOverviewModelBuilder {
    static func build(notes: [CanvasOverviewNote], viewportSize: CGSize, screenScale: CGFloat,
                      style: CanvasOverviewPaperStyle, waterfallStyle: CanvasOverviewPaperStyle,
                      isRealData: Bool, desktopCardWidth: CGFloat, packing: CanvasOverviewDesktopPacking = .compactPairs,
                      cancellation: CanvasOverviewTransitionPreparation? = nil,
                      desktopContents: [Int: CanvasOverviewPaperContentGeometry] = [:],
                      waterfallContents: [CanvasOverviewPaperContentGeometry]? = nil,
                      fixedColumns: Int? = nil, anchorID: Int64? = nil,
                      preparesWaterfall: Bool = true, overviewLongEdge: CGFloat = 2_048) -> CanvasOverviewPreparedModel? {
        guard !notes.isEmpty, cancellation?.isCancelled != true else { return nil }
        guard let canvasGeometry = CanvasOverviewGeometryBuilder.makeCanvas(
            notes: notes,
            viewportSize: viewportSize,
            cardWidth: desktopCardWidth,
            fixedColumns: fixedColumns,
            cancellation: cancellation,
            preparedContents: desktopContents,
            isRTL: style.traits.layoutDirection == .rightToLeft,
            parameters: CanvasOverviewDesktopLayoutParameters(packing: packing,
                permitsLift: !style.traits.preferredContentSizeCategory.isAccessibilityCategory,
                usesAccessibleLayout: style.traits.preferredContentSizeCategory.isAccessibilityCategory)
        ) else { return nil }
        guard let waterfallGeometry = CanvasOverviewGeometryBuilder.makeWaterfall(
            notes: preparesWaterfall ? notes : [],
            viewportSize: viewportSize,
            traits: style.traits, cancellation: cancellation, preparedContents: waterfallContents
        ) else { return nil }
        let previewRichNoteIDs = canvasGeometry.papers.filter { $0.contentGeometry.blocks.contains(where: \.hasVisibleFormatting) }.map(\.noteID)
        let initialIndex = anchorID.flatMap { canvasGeometry.indexByID[$0] } ?? notes.count / 2
        let currentPaper = canvasGeometry.papers[initialIndex]
        let readableZoom = canvasGeometry.readableZoomScale(in: viewportSize)
        let visibleRect = CGRect(
            x: currentPaper.frame.midX - viewportSize.width / readableZoom / 2,
            y: currentPaper.frame.midY - viewportSize.height / readableZoom / 2,
            width: viewportSize.width / readableZoom,
            height: viewportSize.height / readableZoom
        )

        return CanvasOverviewPreparedModel(
            notes: notes,
            noteByID: Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) }),
            canvasGeometry: canvasGeometry,
            waterfallGeometry: waterfallGeometry,
            style: style,
            waterfallStyle: waterfallStyle,
            isRealData: isRealData,
            richTextNoteCount: notes.filter(\.hasRichFormatting).count,
            previewRichNoteIDs: previewRichNoteIDs,
            overviewImage: CanvasOverviewCanvasRasterizer.makeOverview(
                geometry: canvasGeometry,
                style: style,
                maximumLongEdge: overviewLongEdge, cancellation: cancellation
            ),
            // The caller warms the actual first neighborhood, then makes this one sharp surface.
            initialViewportImage: nil,
            initialViewportRect: visibleRect,
            isWaterfallPrepared: preparesWaterfall
        )
    }

    static func reflowDesktop(model: CanvasOverviewPreparedModel, width: CGFloat, viewportSize: CGSize,
                              screenScale: CGFloat, anchorID: Int64, anchorInViewport: CGPoint,
                              zoomScale: CGFloat, cancellation: CanvasOverviewTransitionPreparation? = nil,
                              preparedContents: [Int: CanvasOverviewPaperContentGeometry] = [:],
                              packing: CanvasOverviewDesktopPacking? = nil) -> CanvasOverviewPreparedModel {
        var parameters = model.canvasGeometry.parameters
        if let packing { parameters.packing = packing }
        let result: CanvasOverviewCanvasGeometry?
        if model.canvasGeometry.regionSlices.isEmpty {
            result = CanvasOverviewGeometryBuilder.makeCanvas(notes: model.notes, viewportSize: viewportSize, cardWidth: width,
                fixedColumns: model.canvasGeometry.columnCount, cancellation: cancellation, preparedContents: preparedContents,
                isRTL: model.canvasGeometry.spatialIndex.isRTL, parameters: parameters)
        } else {
            result = CanvasOverviewRegionalGeometry.reflow(model.canvasGeometry, width: width, viewport: viewportSize,
                contents: preparedContents, anchorID: anchorID, cancellation: cancellation)
        }
        guard let geometry = result else { return model }
        // A cancelled, partial generation is never exposed; avoid expensive raster work on its way out.
        if cancellation?.isCancelled == true { return model }
        let paper = geometry.paper(for: anchorID) ?? geometry.papers[0]
        let visibleRect = CGRect(x: paper.frame.midX - anchorInViewport.x / zoomScale,
                                 y: paper.frame.midY - anchorInViewport.y / zoomScale,
                                 width: viewportSize.width / zoomScale, height: viewportSize.height / zoomScale)
        return CanvasOverviewPreparedModel(notes: model.notes, noteByID: model.noteByID,
            canvasGeometry: geometry, waterfallGeometry: model.waterfallGeometry,
            style: model.style, waterfallStyle: model.waterfallStyle, isRealData: model.isRealData,
            richTextNoteCount: model.richTextNoteCount,
            previewRichNoteIDs: geometry.papers.filter { $0.contentGeometry.blocks.contains(where: \.hasVisibleFormatting) }.map(\.noteID),
            overviewImage: CanvasOverviewCanvasRasterizer.makeOverview(geometry: geometry, style: model.style, maximumLongEdge: 2_048, cancellation: cancellation),
            initialViewportImage: CanvasOverviewCanvasRasterizer.makeViewport(geometry: geometry, style: model.style,
                canvasRect: visibleRect, outputSize: viewportSize, outputScale: screenScale, cancellation: cancellation),
            initialViewportRect: visibleRect, isWaterfallPrepared: model.isWaterfallPrepared)
    }
}

nonisolated enum CanvasOverviewTextFactory {
    static func makeRealNotes(_ sources: [NoteReviewOverviewLayoutSource], style: CanvasOverviewPaperStyle,
                              cancellation: CanvasOverviewTransitionPreparation? = nil) -> [CanvasOverviewNote] {
        var notes: [CanvasOverviewNote] = []
        for source in sources {
            guard cancellation?.isCancelled != true else { return [] }
            let quote = richAsset(source.contentHTML, font: style.bodyFont, color: style.primaryTextColor,
                                  lineSpacing: style.bodyLineSpacing, style: style)
            let thought = richAsset(style.display.showsIdea ? source.ideaHTML : "", font: style.annotationFont, color: style.secondaryTextColor,
                                    lineSpacing: style.annotationLineSpacing, style: style)
            let visibleQuote = quote.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && thought.text.isEmpty
                ? makeTextAsset("点按查看完整书摘", font: style.bodyFont, color: style.primaryTextColor,
                    lineSpacing: style.bodyLineSpacing, keys: style.textAttributes, alignment: style.alignment)
                : quote
            let book = style.display.showsBookInfo ? source.bookTitle : ""
            let chapter = style.display.showsChapter ? source.chapterTitle : ""
            notes.append(CanvasOverviewNote(id: source.noteID, quote: quote.text, thought: thought.text,
                bookTitle: book, chapter: chapter, quoteAsset: visibleQuote, thoughtAsset: thought,
                bookAsset: makeTextAsset(book, font: style.metadataMediumFont, color: style.primaryTextColor, lineSpacing: 0, keys: style.textAttributes, alignment: style.metadataAlignment),
                chapterAsset: makeTextAsset(chapter, font: style.metadataFont, color: style.secondaryTextColor, lineSpacing: 0, keys: style.textAttributes, alignment: style.metadataAlignment),
                revision: CanvasOverviewSourceRevision(source)))
        }
        return notes
    }

    static func richAsset(_ html: String, font: UIFont, color: UIColor,
                                  lineSpacing: CGFloat, style: CanvasOverviewPaperStyle) -> CanvasOverviewTextAsset {
        let parsed = HTMLParser.parsePrepared(html, baseFont: font, traitCollection: style.traits,
            paragraphIndent: style.paragraphIndent)
        let range = NSRange(location: 0, length: parsed.length)
        var hasFormatting = false
        parsed.enumerateAttributes(in: range) { attributes, range, _ in
            let paragraph = (attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
                ?? NSMutableParagraphStyle()
            paragraph.lineSpacing = lineSpacing
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.alignment = style.alignment
            parsed.addAttribute(.paragraphStyle, value: paragraph, range: range)
            let isLink = attributes[.link] != nil
            parsed.addAttribute(.foregroundColor, value: isLink ? style.linkColor : color, range: range)
            if attributes[.blockquote] != nil {
                parsed.addAttribute(NSAttributedString.Key("prototypeQuoteColor"),
                    value: style.quoteAccent, range: range)
            }
            if isLink { parsed.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
            hasFormatting = hasFormatting || CanvasOverviewTextAsset.containsFormatting(attributes)
        }
        let immutable = NSAttributedString(attributedString: parsed)
        return CanvasOverviewTextAsset(text: immutable.string, attributedText: immutable, attributeKeys: style.textAttributes,
            hasRichFormatting: hasFormatting)
    }

    static func makeTextAsset(
        _ text: String,
        font: UIFont,
        color: UIColor,
        lineSpacing: CGFloat, keys: NoteReviewCanvasTextAttributes, alignment: NSTextAlignment = .natural
    ) -> CanvasOverviewTextAsset {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = alignment
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
        )
        return CanvasOverviewTextAsset(
            text: text,
            attributedText: attributed, attributeKeys: keys
        )
    }
}

nonisolated enum CanvasOverviewGeometryBuilder {
    // 未缩放纸面的业务几何常量；与卡内 18 / 12 / 4 pt 层级保持一致，后台不读取 UI actor。
    static let contentInset: CGFloat = 18
    static let blockGap: CGFloat = 12
    static let metadataGap: CGFloat = 4
    static let minimumHeight: CGFloat = 168
    static let maximumHeight: CGFloat = 300

    static func makeCanvas(notes: [CanvasOverviewNote], viewportSize: CGSize, cardWidth: CGFloat,
                           fixedColumns: Int? = nil, cancellation: CanvasOverviewTransitionPreparation? = nil,
                           preparedContents: [Int: CanvasOverviewPaperContentGeometry] = [:],
                           isRTL: Bool = false,
                           parameters: CanvasOverviewDesktopLayoutParameters = .init()) -> CanvasOverviewCanvasGeometry? {
        var contents: [CanvasOverviewPaperContentGeometry] = []
        for (index, note) in notes.enumerated() {
            guard cancellation?.isCancelled != true else { return nil }
            contents.append(preparedContents[index] ?? makeContentGeometry(note: note, width: cardWidth))
        }
        guard let spatial = try? NoteReviewCanvasGeometry(ids: notes.map(\.id),
            heights: contents.map { $0.chapterRect.maxY + contentInset }, cardWidth: cardWidth,
            viewport: viewportSize, generation: 0, fixedColumns: fixedColumns, parameters: parameters, isRTL: isRTL,
            isCancelled: { cancellation?.isCancelled == true }) else { return nil }
        let papers = spatial.papers.enumerated().map { index, paper in
            CanvasOverviewCanvasPaper(index: index, noteID: paper.noteID, frame: paper.frame,
                visualFrame: paper.visualFrame, rotation: paper.rotation, contentGeometry: contents[index])
        }
        let columns = spatial.columnCount
        var rows: [CanvasOverviewCanvasRow] = []
        for start in stride(from: 0, to: papers.count, by: columns) {
            let range = start..<min(papers.count, start + columns)
            rows.append(CanvasOverviewCanvasRow(indexRange: range,
                minY: range.map { papers[$0].visualFrame.minY }.min()!,
                maxY: range.map { papers[$0].visualFrame.maxY }.max()!))
        }
        let groups = spatial.groups.map {
            CanvasOverviewCanvasGroup(rowRange: ($0.indexes.lowerBound / columns)..<Int(ceil(Double($0.indexes.upperBound) / Double(columns))),
                indexRange: $0.indexes, minY: $0.minY, maxY: $0.maxY)
        }
        let lifts = spatial.papers.map(\.lift)
        let summary = packingSummary(papers: papers, columns: columns, groups: groups, lifts: lifts,
            parameters: parameters, size: spatial.contentSize)
        return CanvasOverviewCanvasGeometry(cardWidth: cardWidth, columnCount: columns, parameters: parameters,
            notes: notes, papers: papers, rows: rows, groups: groups, lifts: lifts,
            indexByID: spatial.indexByID, contentSize: spatial.contentSize, packingSummary: summary,
            spatialIndex: spatial)
    }

    /// Background-only geometry diagnostics; no content or IDs enter logs and no scan runs while panning.
    static func packingSummary(papers: [CanvasOverviewCanvasPaper], columns: Int, groups: [CanvasOverviewCanvasGroup],
                                        lifts: [CGFloat], parameters: CanvasOverviewDesktopLayoutParameters, size: CGSize) -> String {
        guard let first = papers.first else { return "empty" }
        var horizontal = CGFloat.greatestFiniteMagnitude
        var vertical = CGFloat.greatestFiniteMagnitude
        var margin: CGFloat = .greatestFiniteMagnitude
        var gaps: [CGFloat] = []
        var violations = 0
        for paper in papers {
            let index = paper.index
            let a = paper.visualFrame
            margin = min(margin, a.minX, a.minY, size.width - a.maxX, size.height - a.maxY)
            if index % columns + 1 < columns, index + 1 < papers.count {
                horizontal = min(horizontal, papers[index + 1].visualFrame.minX - a.maxX)
            }
            let nextRow = index / columns + 1
            for c in max(0, index % columns - 1)..<min(columns, index % columns + 2) {
                let next = nextRow * columns + c
                guard next < papers.count else { continue }
                let b = papers[next].visualFrame
                if max(a.minX - b.maxX, b.minX - a.maxX) < parameters.verticalGap {
                    vertical = min(vertical, b.minY - a.maxY)
                }
                if c == index % columns { gaps.append(b.minY - a.maxY) }
            }
        }
        if horizontal < 23.999 || vertical < parameters.verticalGap - 0.001 || margin < 47.999 { violations += 1 }
        if lifts.contains(where: { $0 < -0.001 || $0 > parameters.maximumLift + 0.001 }) { violations += 1 }
        var baselineHeight: CGFloat = 96 - 24
        for group in groups {
            let heights = group.indexRange.map { papers[$0].frame.height }
            baselineHeight += CanvasOverviewPairGeometry.place(firstRow: group.rowRange.lowerBound, columns: columns,
                width: first.frame.width, heights: heights, parameters: .init(packing: .originalRows),
                rotations: group.indexRange.map { papers[$0].rotation }).height + 24
        }
        if size.height > baselineHeight + 0.001 { violations += 1 }
        gaps.sort()
        let p50 = gaps.isEmpty ? 0 : gaps[gaps.count / 2]
        let p90 = gaps.isEmpty ? 0 : gaps[min(gaps.count - 1, Int(Double(gaps.count - 1) * 0.9))]
        let h = horizontal == .greatestFiniteMagnitude ? 0 : horizontal
        let v = vertical == .greatestFiniteMagnitude ? 0 : vertical
        let reduction = (1 - size.height / max(1, baselineHeight)) * 100
        let result = String(format: "%@ H%.2f V%.2f E%.2f\nlift %d/%.1f height −%.2f%%\ngap50/90 %.1f/%.1f violations %d",
            parameters.packing.rawValue, h, v, margin, lifts.filter { $0 > 0.01 }.count, lifts.max() ?? 0,
            reduction, p50, p90, violations)
        Logger(subsystem: "com.wangke.xmnote", category: "SingleCanvasPacking").info("geometry \(parameters.version, privacy: .public) \(result, privacy: .public)")
        return result
    }

    static func makeWaterfall(notes: [CanvasOverviewNote], viewportSize: CGSize,
                               traits: UITraitCollection,
                               cancellation: CanvasOverviewTransitionPreparation? = nil,
                               preparedContents: [CanvasOverviewPaperContentGeometry]? = nil,
                               retainingFrames: [Int64: CGRect] = [:]) -> CanvasOverviewWaterfallGeometry? {
        let accessible = traits.preferredContentSizeCategory.isAccessibilityCategory
        let metrics = NoteReviewCanvasWaterfallMetrics(viewport: viewportSize, accessibility: accessible,
            regularWidth: traits.horizontalSizeClass == .regular)
        var contents: [CanvasOverviewPaperContentGeometry] = []
        for (index, note) in notes.enumerated() {
            guard cancellation?.isCancelled != true else { return nil }
            contents.append(preparedContents?[index] ?? makeContentGeometry(note: note, width: metrics.cardWidth))
        }
        guard let spatial = try? NoteReviewCanvasWaterfallGeometry(ids: notes.map(\.id),
            heights: contents.map { $0.chapterRect.maxY + contentInset }, viewport: viewportSize,
            generation: 0, accessibility: accessible, regularWidth: traits.horizontalSizeClass == .regular,
            isRTL: traits.layoutDirection == .rightToLeft,
            retainingFrames: retainingFrames,
            isCancelled: { cancellation?.isCancelled == true }) else { return nil }
        return CanvasOverviewWaterfallGeometry(notes: notes, frames: spatial.frames, contentGeometries: contents,
            columnIndexes: spatial.columnIndexes, indexByID: spatial.indexByID,
            contentSize: spatial.contentSize, spatialIndex: spatial)
    }

    static func makeContentGeometry(note: CanvasOverviewNote, width: CGFloat) -> CanvasOverviewPaperContentGeometry {
        let inset = contentInset
        let contentWidth = max(1, width - inset * 2)
        let quoteMeasured = note.quoteAsset.measuredHeight(width: contentWidth)
        let thoughtMeasured = note.thoughtAsset.measuredHeight(width: contentWidth)
        let quoteHeight = note.quoteAsset.text.isEmpty ? 0 : min(116, max(24, quoteMeasured))
        let thoughtHeight = note.thought.isEmpty ? 0 : min(46, max(18, thoughtMeasured))
        let metadataHeight: CGFloat = note.chapterAsset.text.isEmpty ? 0 : 16
        let bookHeight: CGFloat = note.bookAsset.text.isEmpty ? 0 : 18

        var y = inset
        let quoteRect = CGRect(x: inset, y: y, width: contentWidth, height: quoteHeight)
        y = quoteRect.maxY
        var thoughtRect: CGRect?
        if thoughtHeight > 0 {
            y += blockGap
            thoughtRect = CGRect(x: inset, y: y, width: contentWidth, height: thoughtHeight)
            y += thoughtHeight
        }
        y += blockGap
        var bookRect = CGRect(x: inset, y: y, width: contentWidth, height: bookHeight)
        var chapterRect = CGRect(
            x: inset,
            y: bookRect.maxY + metadataGap,
            width: contentWidth,
            height: metadataHeight
        )

        let desiredHeight = min(maximumHeight, max(minimumHeight, chapterRect.maxY + inset))
        let bottom = desiredHeight - inset
        if chapterRect.maxY < bottom {
            let delta = bottom - chapterRect.maxY
            bookRect = bookRect.offsetBy(dx: 0, dy: delta)
            chapterRect = chapterRect.offsetBy(dx: 0, dy: delta)
        }

        return CanvasOverviewPaperContentGeometry(
            quoteRect: quoteRect,
            thoughtRect: thoughtRect,
            bookRect: bookRect,
            chapterRect: chapterRect,
            isQuoteTruncated: quoteMeasured > quoteHeight + 0.5,
            isThoughtTruncated: thoughtMeasured > thoughtHeight + 0.5,
            blocks: [
                CanvasOverviewTextBlock(asset: note.quoteAsset, rect: quoteRect, truncated: quoteMeasured > quoteHeight + 0.5),
                CanvasOverviewTextBlock(asset: note.thoughtAsset, rect: thoughtRect ?? .zero, truncated: thoughtMeasured > thoughtHeight + 0.5),
                CanvasOverviewTextBlock(asset: note.bookAsset, rect: bookRect),
                CanvasOverviewTextBlock(asset: note.chapterAsset, rect: chapterRect),
            ]
        )
    }

    static func rotatedBoundingBox(of frame: CGRect, angle: CGFloat) -> CGRect {
        let cosine = abs(cos(angle))
        let sine = abs(sin(angle))
        let width = frame.width * cosine + frame.height * sine
        let height = frame.width * sine + frame.height * cosine
        return CGRect(
            x: frame.midX - width / 2,
            y: frame.midY - height / 2,
            width: width,
            height: height
        )
    }
}

// MARK: - Single tiled canvas

final class CanvasOverviewTiledLayer: CATiledLayer {
    override class func fadeDuration() -> CFTimeInterval { 0 }
}

nonisolated struct CanvasOverviewCanvasDiagnostics: Sendable {
    let lastDrawMilliseconds: Double
    let candidateCount: Int
}

nonisolated final class CanvasOverviewCanvasRenderStore {
    let lock = NSLock()
    var geometry: CanvasOverviewCanvasGeometry?
    var style: CanvasOverviewPaperStyle?
    var lastDrawMilliseconds: Double = 0
    var candidateCount = 0

    func replace(geometry: CanvasOverviewCanvasGeometry, style: CanvasOverviewPaperStyle) {
        lock.lock()
        self.geometry = geometry
        self.style = style
        lock.unlock()
    }

    func snapshot() -> (CanvasOverviewCanvasGeometry, CanvasOverviewPaperStyle)? {
        lock.lock()
        defer { lock.unlock() }
        guard let geometry, let style else { return nil }
        return (geometry, style)
    }

    func record(milliseconds: Double, candidateCount: Int) {
        lock.lock()
        lastDrawMilliseconds = milliseconds
        self.candidateCount = candidateCount
        lock.unlock()
    }

    var diagnostics: CanvasOverviewCanvasDiagnostics {
        lock.lock()
        defer { lock.unlock() }
        return CanvasOverviewCanvasDiagnostics(
            lastDrawMilliseconds: lastDrawMilliseconds,
            candidateCount: candidateCount
        )
    }
}

final class NoteReviewCanvasSurfaceView: UIView {
    let renderStore = CanvasOverviewCanvasRenderStore()
    var onActivateNote: ((Int64) -> Bool)?
    var onNoteAccessibilityActions: ((Int64) -> [UIAccessibilityCustomAction])?
    var onOrderedScroll: ((UIAccessibilityScrollDirection) -> Bool)?

    override class var layerClass: AnyClass { CanvasOverviewTiledLayer.self }

    var diagnostics: CanvasOverviewCanvasDiagnostics { renderStore.diagnostics }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        if let tiledLayer = layer as? CATiledLayer {
            tiledLayer.tileSize = CGSize(width: 256, height: 256)
        }
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        geometry: CanvasOverviewCanvasGeometry,
        style: CanvasOverviewPaperStyle,
        viewportSize: CGSize
    ) {
        renderStore.replace(geometry: geometry, style: style)
        if let tiledLayer = layer as? CATiledLayer {
            let minimumScale = max(0.01, geometry.fitZoomScale(in: viewportSize) * 0.72)
            tiledLayer.levelsOfDetail = max(1, Int(ceil(log2(1 / minimumScale))) + 1)
            tiledLayer.levelsOfDetailBias = 2
            tiledLayer.setNeedsDisplay()
        }
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(),
              let (geometry, style) = renderStore.snapshot() else { return }
        let start = CACurrentMediaTime()
        CanvasOverviewCanvasRasterizer.fillCanvas(rect, style: style, in: context)
        let indexes = geometry.indexes(in: rect)
        for index in indexes {
            CanvasOverviewPaperRenderer.draw(
                paper: geometry.papers[index],
                note: geometry.notes[index],
                style: style,
                in: context
            )
        }
        renderStore.record(
            milliseconds: (CACurrentMediaTime() - start) * 1_000,
            candidateCount: indexes.count
        )
    }

    func updateAccessibilityElements(visibleIndexes: [Int], notes: [CanvasOverviewNote]) {
        accessibilityElements = visibleIndexes.sorted().compactMap { index in
            guard let geometry = renderStore.snapshot()?.0,
                  let paper = geometry.papers[safe: index],
                  let note = notes[safe: index] else { return nil }
            let element = CanvasOverviewAccessibilityElement(accessibilityContainer: self)
            element.accessibilityIdentifier = "canvas-note-\(note.id)"
            element.activate = { [weak self] in self?.onActivateNote?(note.id) ?? false }
            element.accessibilityLabel = "\(note.quote)，\(note.bookTitle)，\(note.chapter)"
            element.accessibilityHint = "轻点选择这条书摘"
            element.accessibilityTraits = .button
            element.accessibilityCustomActions = onNoteAccessibilityActions?(note.id)
            element.accessibilityFrameInContainerSpace = paper.visualFrame
            return element
        }
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        onOrderedScroll?(direction) ?? false
    }
}

/// 每个虚拟元素仅保存稳定身份动作，不创建额外纸张视图。
final class CanvasOverviewAccessibilityElement: UIAccessibilityElement {
    var activate: (() -> Bool)?
    override func accessibilityActivate() -> Bool { activate?() ?? false }
}

final class CanvasOverviewZoomContentView: UIView {
    let underlayView = UIImageView()
    let viewportUnderlayView = UIImageView()
    var underlayGeneration = -1
    var regionalUnderlays: [UIImageView] = []
    private(set) var canvasView = NoteReviewCanvasSurfaceView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        underlayView.contentMode = .scaleToFill
        underlayView.isUserInteractionEnabled = false
        addSubview(underlayView)
        viewportUnderlayView.contentMode = .scaleToFill
        viewportUnderlayView.isUserInteractionEnabled = false
        addSubview(viewportUnderlayView)
        addSubview(canvasView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        underlayView.frame = bounds
        canvasView.frame = bounds
    }

    func configure(
        geometry: CanvasOverviewCanvasGeometry,
        overviewImage: UIImage?,
        style: CanvasOverviewPaperStyle,
        viewportSize: CGSize
    ) {
        regionalUnderlays.forEach { $0.removeFromSuperview() }; regionalUnderlays.removeAll()
        underlayView.image = overviewImage
        viewportUnderlayView.image = nil
        underlayGeneration = -1
        // Each immutable geometry owns a fresh tiled layer; old async tile completions cannot paint a new generation.
        canvasView.removeFromSuperview()
        canvasView = NoteReviewCanvasSurfaceView(frame: bounds)
        addSubview(canvasView)
        canvasView.configure(geometry: geometry, style: style, viewportSize: viewportSize)
        setNeedsLayout()
    }
}

extension CanvasOverviewZoomContentView {
    func installViewportUnderlay(_ image: UIImage?, canvasRect: CGRect, generation: Int) {
        guard generation >= underlayGeneration, let image else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        underlayGeneration = generation
        viewportUnderlayView.frame = canvasRect
        viewportUnderlayView.image = image
        viewportUnderlayView.isHidden = false
        CATransaction.commit()
    }

    func discardUnderlayIfOutside(_ rect: CGRect) {
        guard !viewportUnderlayView.frame.intersects(rect) else { return }
        viewportUnderlayView.image = nil
    }
}

nonisolated enum CanvasOverviewPaperRenderer {

    static let shadowPadding: CGFloat = 24

    static func makeSkin(paperColor: CGColor, borderColor: CGColor, scale: CGFloat,
                         cornerRadius: CGFloat, hasShadow: Bool) -> UIImage {
        let padding = shadowPadding
        let paperSize: CGFloat = 64
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let size = CGSize(width: paperSize + padding * 2, height: paperSize + padding * 2)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext
            let rect = CGRect(x: padding, y: padding, width: paperSize, height: paperSize)
            let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius,
                              cornerHeight: cornerRadius, transform: nil)
            if hasShadow {
                context.setShadow(offset: CGSize(width: 0, height: 4), blur: 12,
                                  color: UIColor.black.withAlphaComponent(0.11).cgColor)
            }
            context.setFillColor(paperColor)
            context.addPath(path)
            context.fillPath()
            context.setShadow(offset: .zero, blur: 0, color: nil)
            context.setStrokeColor(borderColor)
            context.setLineWidth(StrokeWidth.hairline)
            context.addPath(path)
            context.strokePath()
        }
        let cap = padding + cornerRadius + 2
        return image.resizableImage(withCapInsets: UIEdgeInsets(top: cap, left: cap, bottom: cap, right: cap),
                                    resizingMode: .stretch)
    }
    static func draw(
        paper: CanvasOverviewCanvasPaper,
        note: CanvasOverviewNote,
        style: CanvasOverviewPaperStyle,
        in context: CGContext
    ) {
        let content = paper.contentGeometry.pinned()
        defer { withExtendedLifetime(content) {} }
        guard let blocks = content.preparedBlocks else {
            paper.contentGeometry.fallback?.draw(in: context, frame: paper.frame, rotation: paper.rotation)
            return
        }
        NoteReviewCanvasPaperRenderer.draw(frame: paper.frame, rotation: paper.rotation,
            cornerRadius: style.cornerRadius, skin: style.drawingSkin, paperColor: style.paperColor,
            backgroundImage: style.backgroundImage, backgroundOverlay: style.backgroundOverlay,
            blocks: blocks.map {
                NoteReviewCanvasPaperTextBlock(rect: $0.rect, layout: $0.layout, truncated: $0.truncated)
            }, in: context)
    }

    static func draw(block: CanvasOverviewTextBlock, paperColor: CGColor, in context: CGContext) {
        NoteReviewCanvasPaperRenderer.draw(block: NoteReviewCanvasPaperTextBlock(rect: block.rect,
            layout: block.layout, truncated: block.truncated), paperColor: paperColor, in: context)
    }
}

nonisolated enum CanvasOverviewCanvasRasterizer {
    static func fillCanvas(
        _ rect: CGRect,
        style: CanvasOverviewPaperStyle,
        in context: CGContext
    ) {
        context.setFillColor(style.canvasBaseColor)
        context.fill(rect)
        context.setFillColor(style.canvasTintColor)
        context.fill(rect)
    }

    static func makeOverview(
        geometry: CanvasOverviewCanvasGeometry,
        style: CanvasOverviewPaperStyle,
        maximumLongEdge: CGFloat,
        cancellation: CanvasOverviewTransitionPreparation? = nil
    ) -> UIImage? {
        let maximumDimension = max(geometry.contentSize.width, geometry.contentSize.height)
        guard maximumDimension > 0 else { return nil }
        let scale = min(1, maximumLongEdge / maximumDimension)
        let outputSize = CGSize(
            width: max(1, floor(geometry.contentSize.width * scale)),
            height: max(1, floor(geometry.contentSize.height * scale))
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: outputSize, format: format).image { rendererContext in
            let context = rendererContext.cgContext
            context.scaleBy(x: scale, y: scale)
            fillCanvas(
                CGRect(origin: .zero, size: geometry.contentSize),
                style: style,
                in: context
            )
            for paper in geometry.papers {
                if cancellation?.isCancelled == true { break }
                CanvasOverviewPaperRenderer.draw(
                    paper: paper,
                    note: geometry.notes[paper.index],
                    style: style,
                    in: context
                )
            }
        }
    }

    static func makeViewport(
        geometry: CanvasOverviewCanvasGeometry,
        style: CanvasOverviewPaperStyle,
        canvasRect: CGRect,
        outputSize: CGSize,
        outputScale: CGFloat,
        cancellation: CanvasOverviewTransitionPreparation? = nil
    ) -> UIImage? {
        guard outputSize.width > 0, outputSize.height > 0, canvasRect.width > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = outputScale
        format.opaque = false
        let scale = outputSize.width / canvasRect.width
        return UIGraphicsImageRenderer(size: outputSize, format: format).image { rendererContext in
            let context = rendererContext.cgContext
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -canvasRect.minX, y: -canvasRect.minY)
            fillCanvas(canvasRect, style: style, in: context)
            for index in geometry.indexes(in: canvasRect) {
                if cancellation?.isCancelled == true { break }
                CanvasOverviewPaperRenderer.draw(
                    paper: geometry.papers[index],
                    note: geometry.notes[index],
                    style: style,
                    in: context
                )
            }
        }
    }
}

// MARK: - Waterfall

final class CanvasOverviewWaterfallLayout: UICollectionViewLayout {
    var geometry: CanvasOverviewWaterfallGeometry? {
        didSet { invalidateLayout() }
    }

    override var collectionViewContentSize: CGSize {
        geometry?.contentSize ?? .zero
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard let geometry else { return [] }
        return geometry.indexes(in: rect.insetBy(dx: 0, dy: -120)).map { index in
            let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
            attributes.frame = geometry.frames[index]
            return attributes
        }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard let frame = geometry?.frames[safe: indexPath.item] else { return nil }
        let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        attributes.frame = frame
        return attributes
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { false }
}

final class CanvasOverviewWaterfallCell: UICollectionViewCell {
    static let reuseID = "CanvasOverviewWaterfallCell"
    let paperView = CanvasOverviewPaperContentView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        contentView.clipsToBounds = false
        clipsToBounds = false
        contentView.addSubview(paperView)
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        paperView.frame = contentView.bounds.insetBy(dx: -CanvasOverviewPaperRenderer.shadowPadding, dy: -CanvasOverviewPaperRenderer.shadowPadding)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        alpha = 1
        accessibilityCustomActions = nil
        paperView.clearContent()
    }

    func configure(note: CanvasOverviewNote, geometry: CanvasOverviewPaperContentGeometry, size: CGSize, style: CanvasOverviewPaperStyle) {
        paperView.configure(note: note, geometry: geometry, size: size, style: style)
        accessibilityLabel = "\(note.quote)，\(note.bookTitle)，\(note.chapter)"
        accessibilityTraits = .button
        accessibilityIdentifier = "canvas-note-\(note.id)"
    }
}

final class CanvasOverviewPaperContentView: UIView {
    var paper: CanvasOverviewCanvasPaper?
    var note: CanvasOverviewNote?
    var style: CanvasOverviewPaperStyle?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        clipsToBounds = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(note: CanvasOverviewNote, geometry: CanvasOverviewPaperContentGeometry, size: CGSize, style: CanvasOverviewPaperStyle) {
        self.note = note
        self.style = style
        paper = CanvasOverviewCanvasPaper(index: 0, noteID: note.id,
            frame: CGRect(origin: .zero, size: size), visualFrame: .zero,
            rotation: 0, contentGeometry: geometry.pinned())
        setNeedsDisplay()
    }

    /// 已复用的纸面必须释放上一个身份的保护，避免离屏 Cell 长期占用字形预算。
    func clearContent() {
        paper = nil
        note = nil
        style = nil
    }

    /// 高清缓存写回后更新真实绘制子视图，不只刷新 Cell 或 contentView 的空图层。
    func refreshPreparedContent() {
        guard let paper, let note, let style else { return }
        configure(note: note, geometry: paper.contentGeometry, size: paper.frame.size, style: style)
    }

    override func draw(_ rect: CGRect) {
        guard let paper, let note, let style, let context = UIGraphicsGetCurrentContext() else { return }
        context.translateBy(x: CanvasOverviewPaperRenderer.shadowPadding, y: CanvasOverviewPaperRenderer.shadowPadding)
        CanvasOverviewPaperRenderer.draw(paper: paper, note: note, style: style, in: context)
    }
}


final class CanvasOverviewTransitionPaperView: UIView {
    let card: CanvasOverviewSceneCard
    let skin = UIImageView()
    let targetSkin = UIImageView()
    let opaquePaper = UIView()
    let contentClip = UIView()
    let backgroundImage = UIImageView()
    let backgroundTint = UIView()
    var sourceBlocks: [UIImageView] = []
    var targetBlocks: [UIImageView] = []
    let textures: [CanvasOverviewBlockTexture]

    init(card: CanvasOverviewSceneCard, textures: [CanvasOverviewBlockTexture], style: CanvasOverviewPaperStyle) {
        self.card = card
        self.textures = textures
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        addSubview(opaquePaper)
        skin.image = card.desktop.style.paperSkin
        targetSkin.image = card.waterfall.style.paperSkin
        addSubview(skin)
        addSubview(targetSkin)
        contentClip.clipsToBounds = true
        contentClip.layer.cornerRadius = CornerRadius.blockLarge
        addSubview(contentClip)
        backgroundImage.image = style.backgroundImage.map { UIImage(cgImage: $0) }
        backgroundImage.contentMode = .scaleAspectFill
        backgroundImage.clipsToBounds = true
        backgroundTint.backgroundColor = NoteReviewCanvasAppearance.resolvedPaper(style.backgroundOverlay)
        backgroundTint.isHidden = style.backgroundImage == nil
        contentClip.addSubview(backgroundImage)
        contentClip.addSubview(backgroundTint)
        for texture in textures {
            let source = UIImageView(image: texture.source)
            let target = UIImageView(image: texture.target)
            source.contentMode = .scaleToFill
            target.contentMode = .scaleToFill
            contentClip.addSubview(source)
            contentClip.addSubview(target)
            sourceBlocks.append(source)
            targetBlocks.append(target)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(pose: CanvasOverviewPaperPose, contentProgress: CGFloat, blockPositionProgress: CGFloat,
               opacity: CGFloat, clipOrigin: CGPoint) {
        let p = blockPositionProgress
        let sourceSize = card.desktop.paper.frame.size
        let targetSize = card.waterfall.paper.frame.size
        let logicalWidth = CanvasOverviewMotion.mix(sourceSize.width, targetSize.width, p)
        let scale = pose.size.width / logicalWidth
        let logicalHeight = pose.size.height / scale
        bounds = CGRect(x: 0, y: 0, width: logicalWidth, height: logicalHeight)
        center = CGPoint(x: pose.center.x - clipOrigin.x, y: pose.center.y - clipOrigin.y)
        transform = CGAffineTransform(rotationAngle: pose.rotation).scaledBy(x: scale, y: scale)
        alpha = opacity
        skin.frame = bounds.insetBy(dx: -CanvasOverviewPaperRenderer.shadowPadding, dy: -CanvasOverviewPaperRenderer.shadowPadding)
        targetSkin.frame = skin.frame
        let radius = CanvasOverviewMotion.mix(card.desktop.style.cornerRadius, card.waterfall.style.cornerRadius, p)
        opaquePaper.frame = bounds
        opaquePaper.layer.cornerRadius = radius
        opaquePaper.backgroundColor = mixedPaperColor(progress: p)
        let changesStyle = card.desktop.style.isFlat != card.waterfall.style.isFlat
        skin.alpha = changesStyle ? 1 - p : 1
        targetSkin.alpha = changesStyle ? p : 0
        contentClip.frame = bounds
        contentClip.layer.cornerRadius = radius
        backgroundImage.frame = bounds
        backgroundTint.frame = bounds
        for index in textures.indices {
            let sourceRect = textures[index].sourceRect
            let targetRect = textures[index].targetRect
            let origin = CanvasOverviewMotion.mix(sourceRect.origin, targetRect.origin, p)
            sourceBlocks[index].frame = CGRect(origin: origin, size: sourceRect.size)
            targetBlocks[index].frame = CGRect(origin: origin, size: targetRect.size)
            sourceBlocks[index].alpha = textures[index].isIdentical ? 1 : 1 - contentProgress
            targetBlocks[index].alpha = textures[index].isIdentical ? 0 : contentProgress
        }
    }

    func mixedPaperColor(progress: CGFloat) -> UIColor {
        NoteReviewCanvasAppearance.interpolatePaper(from: card.desktop.style.paperColor,
            to: card.waterfall.style.paperColor, progress: progress)
    }
}

// MARK: - Live width coordination

extension NoteReviewCanvasOverviewController {
    var widthReduceMotion: Bool {
        reduceMotionSwitch.isOn || UIAccessibility.isReduceMotionEnabled || UIAccessibility.prefersCrossFadeTransitions
    }

    func configureWidthToolbar() {
        view.addSubview(widthToolbar)
        widthEdgeInteraction.edge = .bottom
        widthToolbar.addInteraction(widthEdgeInteraction)
        widthToolbar.isHidden = true
        NSLayoutConstraint.activate([
            widthToolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Spacing.screenEdge),
            widthToolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Spacing.screenEdge),
            widthToolbar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -Spacing.base),
        ])
        widthToolbar.slider.addTarget(self, action: #selector(widthTouchBegan), for: .touchDown)
        widthToolbar.slider.addTarget(self, action: #selector(widthValueChanged), for: .valueChanged)
        widthToolbar.slider.addTarget(self, action: #selector(widthTouchEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        widthToolbar.reset.addAction(UIAction { [weak self] _ in
            guard let self, let session = self.widthSession else { return }
            self.animateWidth(to: CanvasOverviewDesktopCardWidth.defaultValue, in: session)
        }, for: .touchUpInside)
        widthToolbar.cancel.addAction(UIAction { [weak self] _ in
            guard let self, let session = self.widthSession else { return }
            if session.scene == nil { self.abandonWidthSession(); return }
            if !session.needsCommit, session.committedWidth == session.openingModel.canvasGeometry.cardWidth {
                self.abandonWidthSession(); return
            }
            session.closeAfterCommit = true
            session.isCancelledAdjustment = true
            session.requestedMode = nil
            self.animateWidth(to: session.openingModel.canvasGeometry.cardWidth, in: session)
        }, for: .touchUpInside)
        widthToolbar.done.addAction(UIAction { [weak self] _ in
            guard let self, let session = self.widthSession else { return }
            session.closeAfterCommit = true
            self.settleWidth(session)
        }, for: .touchUpInside)
    }

    func beginWidthAdjustment(showToolbar: Bool) {
        guard widthSession == nil, currentMode == .desktop, transitionState == .idle,
              !isPreparingDesktopWidth, environmentCover == nil, let model = preparedModel,
              let id = currentNoteID, let index = model.canvasGeometry.indexByID[id] else { return }
        cancelRegionalPreparation()
        desktopScrollView.stopScrollingAndZooming()
        guard let pose = paperPose(in: .desktop, noteID: id) else { return }
        let clip = desktopScrollView.convert(desktopScrollView.bounds, to: view)
        let viewport = CanvasOverviewViewportState(noteID: id, offset: desktopScrollView.contentOffset,
                                             zoomScale: desktopScrollView.zoomScale, anchor: pose.center,
                                             viewportRect: clip)
        let seed = CanvasOverviewWidthSeed(model: model, clip: clip, anchor: pose.center, anchorIndex: index,
                                     scale: viewport.zoomScale, screenScale: traitCollection.displayScale)
        let session = CanvasOverviewWidthSession(seed: seed, viewport: viewport, showsToolbar: showToolbar, generation: generation)
        widthSession = session
        previewTask?.cancel(); previewTask = nil
        isPreparingDesktopWidth = true
        setSurfaceInteractionEnabled(false)
        widthToolbar.isHidden = !showToolbar
        bottomControlPanel.isHidden = showToolbar
        widthToolbar.slider.isEnabled = false
        widthToolbar.update(width: session.requestedWidth, status: "正在准备调整…")
        view.bringSubviewToFront(widthToolbar)
        updateCountMenu()
        let token = CanvasOverviewTransitionPreparation()
        session.previewTask = token
        session.initialTask = Task { [weak self, weak session] in
            guard let self, let session else { return }
            let renderSet = Set(seed.renderIndexes)
            let context = seed.groups.flatMap { model.canvasGeometry.groups[$0].indexRange }.filter { !renderSet.contains($0) }
            let preparationIndexes = seed.rasterMode
                ? Array(seed.renderIndexes.sorted { abs($0 - seed.anchorIndex) < abs($1 - seed.anchorIndex) }.prefix(48))
                : context + seed.renderIndexes
            let ids = preparationIndexes.map { model.notes[$0].id }
            do { try await warmPreviews(ids: ids, model: model, work: token) }
            catch { }
            guard !Task.isCancelled, widthSession === session, !token.isCancelled else { return }
            session.sourceProtection = seed.renderIndexes.prefix(48).compactMap { index in
                guard let key = model.notes[index].key else { return nil }
                return self.previewStore.previews.lease(for: key)
            }
            prepareWidthInitialSurface(session: session, seed: seed, model: model, token: token)
        }
        wakeWidthDisplayLink()
    }

    /// 图层接管前先准备好首帧；在此之前真实画布仍完整显示。
    func prepareWidthInitialSurface(session: CanvasOverviewWidthSession, seed: CanvasOverviewWidthSeed,
                                    model: CanvasOverviewPreparedModel, token: CanvasOverviewTransitionPreparation) {
        let interval = signposter.beginInterval("Width initial surface")
        widthQueue.async { [weak self, weak session] in
            let result = autoreleasepool { CanvasOverviewWidthBuilder.preview(seed: seed, width: model.canvasGeometry.cardWidth,
                                                                          original: true, cancellation: token) }
            let raster = result.flatMap { preview in
                seed.rasterMode ? CanvasOverviewWidthBuilder.raster(seed: seed, width: preview.width, source: preview,
                    target: preview, progress: 1, textProgress: 1) : nil
            }
            DispatchQueue.main.async {
                guard let self, let session else { return }
                self.signposter.endInterval("Width initial surface", interval)
                guard self.widthSession === session, self.generation == session.generation, !token.isCancelled,
                      let preview = result else { return }
                session.previewTask = nil
                session.current = preview
                session.previous = preview
                let scene = CanvasOverviewWidthSceneView(seed: seed)
                scene.bind(source: preview, target: preview)
                scene.render(width: preview.width, source: preview, target: preview, progress: 1, textProgress: 1)
                scene.rasterView.image = raster
                session.lastRenderedWidth = preview.width
                session.lastRenderedBlend = 1
                self.view.insertSubview(scene, belowSubview: self.topControlPanel)
                session.scene = scene
                self.widthEdgeInteraction.scrollView = scene
                self.widthToolbar.slider.isEnabled = true
                self.widthToolbar.update(width: session.requestedWidth, status: "字号与相机倍率不变")
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.desktopScrollView.alpha = 0
                CATransaction.commit()
                self.onControlsChanged?()
                if session.phase == .preparing { session.phase = session.needsCommit ? .settling : .idle }
                if let pending = session.pendingAnimation {
                    session.pendingAnimation = nil
                    self.animateWidth(to: pending, in: session)
                }
                self.wakeWidthDisplayLink()
            }
        }
        wakeWidthDisplayLink()
    }

    func wakeWidthDisplayLink() {
        guard !isCanvasPaused, !isDisposed else { return }
        if widthDisplayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(updateWidthPreview))
            link.add(to: .main, forMode: .common)
            widthDisplayLink = link
        }
        widthDisplayLink?.isPaused = false
    }

    @objc func widthTouchBegan() {
        guard let session = widthSession else { return }
        session.animator?.stopAnimation(true)
        session.animator = nil
        session.pendingAnimation = nil
        if let content = session.automaticSource {
            session.previewWidth = session.automaticSourceWidth
            session.previous = content
            session.current = content
            session.scene?.bind(source: content, target: content)
            session.scene?.render(width: session.previewWidth, source: content, target: content, progress: 1, textProgress: 1)
            if session.seed.rasterMode { session.scene?.rasterView.image = session.automaticRaster }
        }
        session.automaticCover?.removeFromSuperview()
        session.automaticCover = nil
        session.automaticSource = nil
        session.automaticRaster = nil
        session.requestedWidth = session.previewWidth
        widthToolbar.slider.value = Float(session.previewWidth)
        session.finalTask?.cancel()
        session.finalAsyncTask?.cancel()
        session.finalTask = nil
        session.finalModel = nil
        session.sharpOverlay?.removeFromSuperview()
        session.sharpOverlay = nil
        session.sharpStarted = nil
        session.needsCommit = false
        session.closeAfterCommit = false
        session.phase = .tracking
        session.startedAt = CACurrentMediaTime()
        session.responseStartedAt = session.startedAt
        session.firstResponseMilliseconds = nil
        wakeWidthDisplayLink()
    }

    @objc func widthValueChanged() {
        guard let session = widthSession else { return }
        let input = CGFloat(widthToolbar.slider.value)
        if session.phase != .tracking { widthTouchBegan() }
        session.requestedWidth = input
        session.previewWidth = session.requestedWidth
        widthToolbar.update(width: session.requestedWidth, status: "字号与相机倍率不变")
        if !widthToolbar.slider.isTracking { settleWidth(session) } // VoiceOver/keyboard adjustments have no touch-up.
        wakeWidthDisplayLink()
    }

    @objc func widthTouchEnded() {
        guard let session = widthSession else { return }
        settleWidth(session)
    }

    func settleWidth(_ session: CanvasOverviewWidthSession) {
        session.requestedWidth = session.requestedWidth.rounded()
        if session.phase == .idle, session.requestedWidth == session.committedWidth {
            if session.closeAfterCommit { closeWidthAdjustment(session) }
            return
        }
        if session.animator == nil { session.previewWidth = session.requestedWidth }
        session.phase = .settling
        session.needsCommit = true
        session.startedAt = CACurrentMediaTime()
        widthToolbar.update(width: session.requestedWidth, status: "字号与相机倍率不变")
        wakeWidthDisplayLink()
    }

    func animateWidth(to width: CGFloat, in session: CanvasOverviewWidthSession) {
        if session.phase == .idle, width.rounded() == session.committedWidth {
            if session.closeAfterCommit { closeWidthAdjustment(session) }
            return
        }
        guard let scene = session.scene else {
            session.pendingAnimation = width
            session.requestedWidth = width.rounded()
            widthToolbar.update(width: width, status: "正在准备调整…")
            return
        }
        session.animator?.stopAnimation(true)
        session.animator = nil
        session.finalTask?.cancel()
        session.finalTask = nil
        session.finalModel = nil
        session.sharpOverlay?.removeFromSuperview()
        session.sharpOverlay = nil
        session.sharpStarted = nil
        session.requestedWidth = width.rounded()
        if widthReduceMotion {
            if session.automaticCover == nil {
                session.automaticCover = scene.snapshotView(afterScreenUpdates: false)
                session.automaticSource = session.current
                session.automaticSourceWidth = session.previewWidth
                session.automaticRaster = scene.rasterView.image
                if let cover = session.automaticCover { cover.frame = scene.bounds; scene.addSubview(cover) }
            }
            session.previewWidth = session.requestedWidth
            settleWidth(session)
            return
        }
        session.animationFrom = session.previewWidth
        session.animationTo = session.requestedWidth
        session.clock.center = .zero
        if session.clock.superview == nil {
            session.clock.isHidden = true
            view.addSubview(session.clock)
        }
        let animator = UIViewPropertyAnimator(duration: 0.38, dampingRatio: 0.96)
        animator.addAnimations { session.clock.center = CGPoint(x: 1, y: 0) }
        session.animator = animator
        animator.addCompletion { [weak self, weak session, weak animator] _ in
            guard let self, let session, let animator, self.widthSession === session, session.animator === animator else { return }
            session.previewWidth = session.requestedWidth
            session.animator = nil
            self.settleWidth(session)
        }
        session.phase = .settling
        session.needsCommit = true
        session.startedAt = CACurrentMediaTime()
        widthToolbar.update(width: session.previewWidth, status: "字号与相机倍率不变")
        wakeWidthDisplayLink()
        animator.startAnimation()
    }

    @objc func updateWidthPreview() {
        guard let session = widthSession else { widthDisplayLink?.isPaused = true; return }
        let began = CACurrentMediaTime()
        if let animator = session.animator {
            let p = session.clock.layer.presentation()?.position.x ?? animator.fractionComplete
            session.previewWidth = CanvasOverviewMotion.mix(session.animationFrom, session.animationTo, p)
            widthToolbar.update(width: session.previewWidth, status: "字号与相机倍率不变")
        }
        guard let scene = session.scene, var target = session.current else { return }
        let wanted = session.needsCommit ? session.requestedWidth : min(360, max(180, (session.requestedWidth / 4).rounded() * 4))
        if session.queuedPreview?.width != wanted { session.queuedPreview = nil }
        if session.blend >= 1, let queued = session.queuedPreview {
            session.queuedPreview = nil
            installWidthPreview(queued, in: session)
            target = queued
        }
        let source = session.previous ?? target
        let blend = session.previous == nil ? 1 : CanvasOverviewMotion.ease(session.blend)
        let textBlend = min(1, max(0, CGFloat((began - session.blendStarted) / 0.09)))
        if session.seed.rasterMode {
            if !session.rasterBusy, began - session.lastRasterTime >= 1.0 / 30,
               abs(session.lastRenderedWidth - session.previewWidth) > 0.001 || session.lastRenderedBlend != blend {
                scheduleWidthRaster(session, source: source, target: target, blend: blend, textBlend: textBlend)
            }
        } else {
            scene.render(width: session.previewWidth, source: source, target: target, progress: blend, textProgress: textBlend)
            session.lastRenderedWidth = session.previewWidth
            session.lastRenderedBlend = blend
        }
        if session.firstResponseMilliseconds == nil, abs(session.lastRenderedWidth - session.committedWidth) > 0.1 {
            session.firstResponseMilliseconds = (began - session.responseStartedAt) * 1_000
        }
        if session.previewTask == nil, abs(target.width - wanted) > 0.001,
           session.queuedPreview?.width != wanted, began - session.lastPreviewRequest >= 0.05 {
            if session.blend >= 1, let cached = session.previous, cached.width == wanted {
                session.cacheHits += 1
                installWidthPreview(cached, in: session)
            } else { scheduleWidthPreview(session, width: wanted) }
        }
        if session.needsCommit, session.animator == nil, began - session.startedAt > 0.25 {
            widthToolbar.update(width: session.requestedWidth, status: "正在完成排版…")
        }
        if session.needsCommit, session.animator == nil, abs(target.width - session.requestedWidth) < 0.001,
           session.queuedPreview == nil, session.blend >= 1 {
            if session.finalTask == nil, session.finalModel == nil {
                scheduleWidthCommit(session, preview: target)
            }
            if let model = session.finalModel,
               abs(session.lastRenderedWidth - session.requestedWidth) < 0.001,
               session.lastRenderedBlend == 1, !session.rasterBusy {
                finishWidthCommit(session, model: model)
            }
        }
        session.maximumFrameSubmitMilliseconds = max(session.maximumFrameSubmitMilliseconds, (CACurrentMediaTime() - began) * 1_000)
        if session.phase == .idle, session.previewTask == nil, session.blend >= 1, !session.rasterBusy {
            widthDisplayLink?.isPaused = true
        }
    }

    func installWidthPreview(_ preview: CanvasOverviewWidthPreview, in session: CanvasOverviewWidthSession) {
        session.previous = session.automaticSource ?? session.current
        session.current = preview
        session.blendStarted = CACurrentMediaTime()
        session.scene?.bind(source: session.previous ?? preview, target: preview)
    }

    func scheduleWidthPreview(_ session: CanvasOverviewWidthSession, width: CGFloat) {
        let token = CanvasOverviewTransitionPreparation()
        session.previewTask = token
        session.lastPreviewRequest = CACurrentMediaTime()
        session.cacheMisses += 1
        let seed = session.seed
        let interval = signposter.beginInterval("Width visible text")
        widthQueue.async { [weak self, weak session] in
            let result = autoreleasepool { CanvasOverviewWidthBuilder.preview(seed: seed, width: width, cancellation: token) }
            DispatchQueue.main.async {
                guard let self, let session else { return }
                self.signposter.endInterval("Width visible text", interval)
                guard self.widthSession === session, session.previewTask === token, self.generation == session.generation else { return }
                session.previewTask = nil
                guard !token.isCancelled, let preview = result else { return }
                let latest = session.needsCommit ? session.requestedWidth : min(360, max(180, (session.requestedWidth / 4).rounded() * 4))
                // Never run through obsolete intermediate widths after a quick reversal.
                guard latest == width else { self.wakeWidthDisplayLink(); return }
                if session.blend < 1 { session.queuedPreview = preview }
                else { self.installWidthPreview(preview, in: session) }
                self.wakeWidthDisplayLink()
            }
        }
    }

    func scheduleWidthRaster(_ session: CanvasOverviewWidthSession, source: CanvasOverviewWidthPreview,
                             target: CanvasOverviewWidthPreview, blend: CGFloat, textBlend: CGFloat) {
        session.rasterBusy = true
        session.lastRasterTime = CACurrentMediaTime()
        let width = session.previewWidth
        let seed = session.seed
        session.rasterRevision += 1
        let revision = session.rasterRevision
        widthRasterQueue.async { [weak self, weak session] in
            let image = autoreleasepool { CanvasOverviewWidthBuilder.raster(seed: seed, width: width, source: source,
                target: target, progress: blend, textProgress: textBlend) }
            DispatchQueue.main.async {
                guard let self, let session, self.widthSession === session, self.generation == session.generation else { return }
                session.scene?.rasterView.image = image
                session.lastRenderedWidth = width
                session.lastRenderedBlend = blend
                session.displayedRasterRevision = revision
                session.rasterBusy = false
            }
        }
    }

    func scheduleWidthCommit(_ session: CanvasOverviewWidthSession, preview: CanvasOverviewWidthPreview) {
        let token = CanvasOverviewTransitionPreparation()
        session.finalTask = token
        let seed = session.seed
        let width = session.requestedWidth
        session.finalAsyncTask?.cancel()
        session.finalAsyncTask = Task { [weak self, weak session] in
            guard let self, let session else { return }
            do {
                guard var model = try await prepareModel(ids: seed.model.notes.map(\.id), style: seed.model.style,
                    waterfallStyle: seed.model.waterfallStyle, size: seed.clip.size, scale: seed.screenScale,
                    width: width, packing: seed.model.canvasGeometry.parameters.packing, work: token,
                    fixedColumns: seed.model.canvasGeometry.columnCount, preparesWaterfall: seed.model.canvasGeometry.regionSlices.isEmpty,
                    preparesInitialViewport: false),
                    !Task.isCancelled, !token.isCancelled else { return }
                if !seed.model.canvasGeometry.regionSlices.isEmpty {
                    let freshlyPrepared = model
                    let reflowAnchor = session.openingViewport.noteID
                    let rebuilt: (CanvasOverviewCanvasGeometry, [NoteReviewDirectoryGroupID: UIImage])? = await withCheckedContinuation { continuation in
                        self.preparationQueue.async {
                            guard let geometry = CanvasOverviewRegionalGeometry.reflow(seed.model.canvasGeometry,
                                width: width, viewport: seed.clip.size,
                                contents: Dictionary(uniqueKeysWithValues: freshlyPrepared.canvasGeometry.papers.map { ($0.index, $0.contentGeometry) }),
                                anchorID: reflowAnchor, cancellation: token, notes: freshlyPrepared.notes) else {
                                continuation.resume(returning: nil); return
                            }
                            var backdrops: [NoteReviewDirectoryGroupID: UIImage] = [:]
                            for slice in geometry.regionSlices {
                                guard !token.isCancelled else { continuation.resume(returning: nil); return }
                                let local = CanvasOverviewRegionalGeometry.local(geometry, slice: slice)
                                backdrops[slice.id] = CanvasOverviewCanvasRasterizer.makeOverview(geometry: local,
                                    style: freshlyPrepared.style, maximumLongEdge: 768, cancellation: token)
                            }
                            continuation.resume(returning: (geometry, backdrops))
                        }
                    }
                    guard let (geometry, backdrops) = rebuilt, !Task.isCancelled else { return }
                    model = replacingCanvas(in: seed.model, with: geometry)
                    model.regionalBackdrops = backdrops
                }
                guard let paper = model.canvasGeometry.paper(for: session.openingViewport.noteID) else { return }
                let rect = CGRect(x: paper.frame.midX - seed.anchor.x / seed.scale,
                    y: paper.frame.midY - seed.anchor.y / seed.scale, width: seed.clip.width / seed.scale,
                    height: seed.clip.height / seed.scale)
                let ready = model
                let exactSeed = CanvasOverviewWidthSeed(model: ready, clip: seed.clip,
                    anchor: CGPoint(x: seed.clip.minX + seed.anchor.x, y: seed.clip.minY + seed.anchor.y),
                    anchorIndex: seed.anchorIndex, scale: seed.scale, screenScale: seed.screenScale)
                let result: (UIImage?, CanvasOverviewWidthPreview?) = await withCheckedContinuation { continuation in
                    self.preparationQueue.async {
                        let image = CanvasOverviewCanvasRasterizer.makeViewport(geometry: ready.canvasGeometry,
                            style: ready.style, canvasRect: rect, outputSize: seed.clip.size,
                            outputScale: seed.screenScale, cancellation: token)
                        let exact = CanvasOverviewWidthBuilder.preview(seed: exactSeed, width: width, original: true, cancellation: token)
                        continuation.resume(returning: (image, exact))
                    }
                }
                guard widthSession === session, generation == session.generation, session.finalTask === token,
                      !Task.isCancelled, !token.isCancelled, session.requestedWidth == width else { return }
                model.initialViewportImage = result.0
                model.initialViewportRect = rect
                session.finalTask = nil
                session.finalModel = model
                if let exact = result.1 { installWidthPreview(exact, in: session) }
                session.endpointError = CanvasOverviewWidthBuilder.endpointError(seed: seed, preview: preview, model: model)
                wakeWidthDisplayLink()
            } catch {
                guard widthSession === session, !token.isCancelled else { return }
                session.finalTask = nil
                widthToolbar.update(width: session.requestedWidth, status: "排版未完成，请重试或取消")
            }
        }
    }

    func finishWidthCommit(_ session: CanvasOverviewWidthSession, model: CanvasOverviewPreparedModel) {
        guard let scene = session.scene else { return }
        if session.sharpStarted == nil {
            // Upgrade any budget-limited preview texture before handing over, never at the endpoint frame.
            let sharp = UIImageView(frame: scene.bounds)
            sharp.image = model.initialViewportImage
            sharp.alpha = 0
            scene.addSubview(sharp)
            if let cover = session.automaticCover { scene.bringSubviewToFront(cover) }
            session.sharpOverlay = sharp
            session.sharpStarted = CACurrentMediaTime()
        }
        let elapsed = CACurrentMediaTime() - (session.sharpStarted ?? CACurrentMediaTime())
        session.sharpOverlay?.alpha = min(1, elapsed / 0.09)
        session.automaticCover?.alpha = max(0, 1 - elapsed / 0.12)
        guard elapsed >= 0.17 else { return }
        session.automaticCover?.removeFromSuperview()
        session.automaticCover = nil
        session.automaticSource = nil
        session.automaticRaster = nil
        let interval = signposter.beginInterval("Width atomic handoff")
        isPositioningViewport = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preparedModel = model
        if !model.canvasGeometry.regionSlices.isEmpty { adoptRegionalWidthModel(model) }
        selectedDesktopCardWidth = model.canvasGeometry.cardWidth
        desktopScrollView.setZoomScale(1, animated: false)
        zoomContentView.transform = .identity
        zoomContentView.frame = CGRect(origin: .zero, size: model.canvasGeometry.contentSize)
        if model.canvasGeometry.regionSlices.isEmpty {
            zoomContentView.configure(geometry: model.canvasGeometry, overviewImage: model.overviewImage,
                                     style: model.style, viewportSize: session.clip.size)
        } else {
            zoomContentView.configureRegional(geometry: model.canvasGeometry, models: regionalModels,
                style: model.style, viewportSize: session.clip.size)
        }
        desktopScrollView.contentSize = model.canvasGeometry.contentSize
        desktopScrollView.minimumZoomScale = min(session.seed.scale, max(0.01, model.canvasGeometry.fitZoomScale(in: session.clip.size) * 0.72))
        desktopScrollView.maximumZoomScale = max(1.55, session.seed.scale)
        desktopScrollView.setZoomScale(session.seed.scale, animated: false)
        updateDesktopContentInset()
        zoomContentView.layoutIfNeeded()
        if let pose = paperPose(in: .desktop, noteID: session.openingViewport.noteID) {
            let offset = CGPoint(x: desktopScrollView.contentOffset.x + pose.center.x - session.openingViewport.anchor.x,
                                 y: desktopScrollView.contentOffset.y + pose.center.y - session.openingViewport.anchor.y)
            var inset = desktopScrollView.contentInset
            inset.left = max(inset.left, -offset.x)
            inset.top = max(inset.top, -offset.y)
            inset.right = max(inset.right, offset.x + session.clip.width - desktopScrollView.contentSize.width)
            inset.bottom = max(inset.bottom, offset.y + session.clip.height - desktopScrollView.contentSize.height)
            desktopScrollView.contentInset = inset
            desktopScrollView.setContentOffset(offset, animated: false)
        }
        zoomContentView.installViewportUnderlay(model.initialViewportImage, canvasRect: model.initialViewportRect, generation: generation)
        preparedModel?.initialViewportImage = nil
        saveViewport(for: .desktop, noteID: session.openingViewport.noteID)
        if let actual = paperPose(in: .desktop, noteID: session.openingViewport.noteID) {
            session.anchorError = sqrt(actual.center.distanceSquared(to: session.openingViewport.anchor))
        }
        isPositioningViewport = false
        session.committedWidth = model.canvasGeometry.cardWidth
        session.needsCommit = false
        session.finalModel = nil
        session.phase = .idle
        widthToolbar.update(width: session.committedWidth, status: "字号与相机倍率不变")
        updateCurrentPresentation()
        updateCanvasAccessibility()
        updateCountMenu()
        CATransaction.commit()
        signposter.endInterval("Width atomic handoff", interval)
        Logger(subsystem: "com.wangke.xmnote", category: "SingleCanvasWidth").info(
            "handoff width=\(session.committedWidth) columns=\(model.canvasGeometry.columnCount) zoom=\(session.seed.scale) endpoint=\(session.endpointError) anchor=\(session.anchorError) first_ms=\(session.firstResponseMilliseconds ?? -1) submit_ms=\(session.maximumFrameSubmitMilliseconds)")
        if session.closeAfterCommit {
            closeWidthAdjustment(session)
        } else {
            // Keep the exact endpoint visible while the tool remains open; the next touch reuses this scene.
            widthDisplayLink?.isPaused = true
        }
    }

    func closeWidthAdjustment(_ session: CanvasOverviewWidthSession) {
        if !session.isCancelledAdjustment { onConfirmedWidth?(Int(session.committedWidth)) }
        let target = session.requestedMode
        if let target, target != .desktop {
            environmentCover = session.scene
            session.scene = nil
        }
        abandonWidthSession()
        if let target, target != .desktop { requestMode(target) }
        onWidthEnded?()
    }

    func abandonWidthSession() {
        guard let session = widthSession else { return }
        session.cancelWork()
        session.clock.removeFromSuperview()
        session.scene?.removeFromSuperview()
        widthSession = nil
        widthDisplayLink?.invalidate()
        widthDisplayLink = nil
        widthToolbar.isHidden = true
        widthEdgeInteraction.scrollView = nil
        bottomControlPanel.isHidden = !showsDiagnosticControls
        isPreparingDesktopWidth = false
        modeControl.selectedSegmentIndex = currentMode.rawValue
        desktopScrollView.alpha = currentMode == .desktop && environmentCover == nil ? 1 : 0
        setSurfaceInteractionEnabled(true)
        updateCountMenu()
    }
}

// MARK: - Live width experiment (page-private)

nonisolated enum CanvasOverviewWidthPhase: String { case idle, preparing, tracking, settling }

/// A session keeps the opening endpoint for Cancel; preview jobs never mutate the installed canvas.
@MainActor
final class CanvasOverviewWidthSession {
    let seed: CanvasOverviewWidthSeed
    let openingModel: CanvasOverviewPreparedModel
    let openingViewport: CanvasOverviewViewportState
    let clip: CGRect
    let showsToolbar: Bool
    var isCancelledAdjustment = false
    let generation: Int
    var phase: CanvasOverviewWidthPhase = .preparing
    var requestedWidth: CGFloat
    var previewWidth: CGFloat
    var committedWidth: CGFloat
    var scene: CanvasOverviewWidthSceneView?
    var current: CanvasOverviewWidthPreview?
    var previous: CanvasOverviewWidthPreview?
    var queuedPreview: CanvasOverviewWidthPreview?
    var blendStarted: CFTimeInterval = 0
    var lastPreviewRequest: CFTimeInterval = 0
    var previewTask: CanvasOverviewTransitionPreparation?
    var initialTask: Task<Void, Never>?
    var sourceProtection: [NoteReviewCanvasResourceLease<CanvasOverviewPreviewPayload>] = []
    var finalAsyncTask: Task<Void, Never>?
    var finalTask: CanvasOverviewTransitionPreparation?
    var finalModel: CanvasOverviewPreparedModel?
    var sharpOverlay: UIImageView?
    var sharpStarted: CFTimeInterval?
    var needsCommit = false
    var closeAfterCommit = false
    var requestedMode: NoteReviewCanvasOverviewController.Mode?
    var animator: UIViewPropertyAnimator?
    var pendingAnimation: CGFloat?
    var automaticCover: UIView?
    var automaticSource: CanvasOverviewWidthPreview?
    var automaticSourceWidth: CGFloat = 0
    var automaticRaster: UIImage?
    let clock = UIView()
    var animationFrom: CGFloat = 0
    var animationTo: CGFloat = 0
    var rasterBusy = false
    var lastRasterTime: CFTimeInterval = 0
    var lastRenderedWidth: CGFloat = -1
    var lastRenderedBlend: CGFloat = -1
    var rasterRevision = 0
    var displayedRasterRevision = -1
    var startedAt = CACurrentMediaTime()
    var responseStartedAt = CACurrentMediaTime()
    var firstResponseMilliseconds: Double?
    var maximumFrameSubmitMilliseconds: Double = 0
    var endpointError: CGFloat = 0
    var anchorError: CGFloat = 0
    var cacheHits = 0
    var cacheMisses = 0

    init(seed: CanvasOverviewWidthSeed, viewport: CanvasOverviewViewportState, showsToolbar: Bool, generation: Int) {
        self.seed = seed
        openingModel = seed.model
        openingViewport = viewport
        clip = seed.clip
        self.showsToolbar = showsToolbar
        self.generation = generation
        requestedWidth = seed.model.canvasGeometry.cardWidth
        previewWidth = requestedWidth
        committedWidth = requestedWidth
    }

    var blend: CGFloat { min(1, max(0, CGFloat((CACurrentMediaTime() - blendStarted) / 0.20))) }
    var textureBytes: Int { [previous, current, queuedPreview].compactMap { $0 }.reduce(0) { $0 + $1.textureBytes } }

    func cancelWork() {
        previewTask?.cancel()
        finalTask?.cancel()
        finalAsyncTask?.cancel()
        initialTask?.cancel()
        animator?.stopAnimation(true)
        animator = nil
    }
}

/// Immutable inputs are shared with the preparation/raster queues. Only those queues build text layouts.
nonisolated struct CanvasOverviewWidthSeed: @unchecked Sendable {
    let model: CanvasOverviewPreparedModel
    let clip: CGRect
    let anchor: CGPoint
    let anchorIndex: Int
    let scale: CGFloat
    let screenScale: CGFloat
    let rows: Range<Int>
    let groups: Range<Int>
    let columns: Range<Int>
    let renderIndexes: [Int]
    let rasterMode: Bool

    init(model: CanvasOverviewPreparedModel, clip: CGRect, anchor: CGPoint, anchorIndex: Int,
         scale: CGFloat, screenScale: CGFloat) {
        self.model = model
        self.clip = clip
        self.anchor = CGPoint(x: anchor.x - clip.minX, y: anchor.y - clip.minY)
        self.anchorIndex = anchorIndex
        self.scale = scale
        self.screenScale = screenScale
        if !model.canvasGeometry.regionSlices.isEmpty {
            let geometry = model.canvasGeometry
            let paper = geometry.papers[anchorIndex]
            let rect = CGRect(x: paper.frame.midX - self.anchor.x / scale,
                y: paper.frame.midY - self.anchor.y / scale, width: clip.width / scale, height: clip.height / scale)
            let candidate = rect.insetBy(dx: -rect.width, dy: -rect.height)
            let slices = geometry.regionSlices.filter { $0.frame.intersects(candidate) || $0.indexRange.contains(anchorIndex) }
            // Complete regions protect cross-region height propagation. Raster/agents remain bounded.
            renderIndexes = slices.flatMap { Array($0.indexRange) }
            rows = 0..<geometry.rows.count
            groups = 0..<geometry.groups.count
            columns = 0..<geometry.columnCount
            rasterMode = renderIndexes.count > 48
            return
        }
        let count = model.canvasGeometry.columnCount
        let row = anchorIndex / count
        let column = anchorIndex % count
        let p = model.canvasGeometry.parameters
        let minimumGroupStride = 2 * CanvasOverviewDesktopLayoutParameters.minimumHeight + 2 * p.verticalGap - p.maximumLift
        let minimumHeight = CanvasOverviewDesktopLayoutParameters.minimumHeight
        let minimumAnchorOffset = row.isMultiple(of: 2) ? minimumHeight / 2
            : minimumHeight * 1.5 + p.verticalGap - p.maximumLift
        let minimumTrailingExtent = row.isMultiple(of: 2) ? minimumHeight * 1.5 + p.verticalGap - p.maximumLift
            : minimumHeight / 2
        // One minimum-height neighbour ring, plus the complete group containing it. Correlate
        // width with stride instead of combining the widest paper with the narrowest stride.
        let above = max(0, Int(floor((self.anchor.y / scale + minimumHeight - minimumAnchorOffset - p.verticalGap) / minimumGroupStride)) + 1)
        let below = max(0, Int(floor(((clip.height - self.anchor.y) / scale + minimumHeight - minimumTrailingExtent - p.verticalGap) / minimumGroupStride)) + 1)
        let groupRange = max(0, row / 2 - above)..<min(model.canvasGeometry.groups.count, row / 2 + below + 1)
        groups = groupRange
        let candidateRows = groupRange.lowerBound * 2..<min(model.canvasGeometry.rows.count, groupRange.upperBound * 2)
        rows = candidateRows
        let minimumStride = p.stride(width: CGFloat(CanvasOverviewDesktopCardWidth.range.lowerBound))
        let halfExtent = CGFloat(CanvasOverviewDesktopCardWidth.range.lowerBound) / 2 + 24 + p.horizontalReserve
        let left = Int(ceil(max(0, self.anchor.x / scale + halfExtent) / minimumStride))
        let right = Int(ceil(max(0, (clip.width - self.anchor.x) / scale + halfExtent) / minimumStride))
        let leading = model.canvasGeometry.spatialIndex.isRTL ? right : left
        let trailing = model.canvasGeometry.spatialIndex.isRTL ? left : right
        let candidateColumns = max(0, column - leading)..<min(count, column + trailing + 1)
        columns = candidateColumns
        renderIndexes = candidateRows.flatMap { r in candidateColumns.compactMap { c in
            let i = r * count + c
            return i < model.notes.count ? i : nil
        } }
        rasterMode = renderIndexes.count > 48
    }
}

nonisolated struct CanvasOverviewWidthBlock: Sendable {
    let rect: CGRect
    let signature: String
    let image: UIImage?
}

nonisolated struct CanvasOverviewWidthPreview: @unchecked Sendable {
    let width: CGFloat
    let contents: [Int: CanvasOverviewPaperContentGeometry]
    let groupHeights: [[CGFloat]]
    let layoutVersion: String
    let textures: [Int: [CanvasOverviewWidthBlock]]
    let textureBytes: Int
    var regionalGeometry: CanvasOverviewCanvasGeometry?
}

nonisolated struct CanvasOverviewWidthPaperPose: Sendable {
    let index: Int
    let pose: CanvasOverviewPaperPose
}

nonisolated enum CanvasOverviewWidthBuilder {
    static func endpointError(seed: CanvasOverviewWidthSeed, preview: CanvasOverviewWidthPreview, model: CanvasOverviewPreparedModel) -> CGFloat {
        let anchor = model.canvasGeometry.papers[seed.anchorIndex].frame.center
        return poses(seed: seed, width: preview.width, source: preview, target: preview, progress: 1).reduce(0) { error, item in
            let frame = model.canvasGeometry.papers[item.index].frame
            let center = CGPoint(x: seed.anchor.x + (frame.midX - anchor.x) * seed.scale,
                                 y: seed.anchor.y + (frame.midY - anchor.y) * seed.scale)
            return max(error, sqrt(item.pose.center.distanceSquared(to: center)))
        }
    }

    /// Measure complete candidate rows for their true maxima, but raster only candidate columns.
    static func preview(seed: CanvasOverviewWidthSeed, width: CGFloat, original: Bool = false,
                        cancellation: CanvasOverviewTransitionPreparation) -> CanvasOverviewWidthPreview? {
        var contents: [Int: CanvasOverviewPaperContentGeometry] = [:]
        var groupHeights: [[CGFloat]] = []
        let geometry = seed.model.canvasGeometry
        let renderIndexes = Set(seed.renderIndexes)
        for group in seed.groups {
            guard !cancellation.isCancelled else { return nil }
            var heights: [CGFloat] = []
            for index in geometry.groups[group].indexRange {
                guard !cancellation.isCancelled else { return nil }
                let paper = geometry.papers[index]
                let note = seed.model.notes[index]
                let content: CanvasOverviewPaperContentGeometry
                if original, renderIndexes.contains(index), note.payload != nil {
                    content = paper.contentGeometry.replaying(independentNote(note))
                } else if original || note.payload == nil {
                    content = paper.contentGeometry
                } else {
                    content = CanvasOverviewGeometryBuilder.makeContentGeometry(note: independentNote(note), width: width)
                }
                contents[index] = content
                let height = content.chapterRect.maxY + CanvasOverviewGeometryBuilder.contentInset
                heights.append(height)
            }
            groupHeights.append(heights)
        }
        let area = seed.renderIndexes.reduce(CGFloat.zero) { total, index in
            total + (contents[index]?.blocks.reduce(0) { $0 + max(0, $1.rect.width * $1.rect.height) } ?? 0)
        }
        // Leave headroom for bitmap row alignment and the single latest preparation task.
        let budgetScale = sqrt(CGFloat(7 * 1_024 * 1_024) / max(1, area * 4))
        let textureScale = max(0.01, min(seed.screenScale * seed.scale, budgetScale))
        var textures: [Int: [CanvasOverviewWidthBlock]] = [:]
        var bytes = 0
        for index in seed.renderIndexes {
            guard !cancellation.isCancelled, let content = contents[index] else { return nil }
            if content.preparedBlocks == nil, let fallback = content.fallback {
                let size = geometry.papers[index].frame.size
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: CanvasOverviewGeometryBuilder.contentInset, dy: CanvasOverviewGeometryBuilder.contentInset)
                let format = UIGraphicsImageRendererFormat()
                format.scale = max(0.1, textureScale)
                let image = UIGraphicsImageRenderer(size: rect.size, format: format).image { output in
                    output.cgContext.translateBy(x: -rect.minX, y: -rect.minY)
                    fallback.draw(in: output.cgContext, frame: CGRect(origin: .zero, size: size), rotation: 0)
                }
                if let cg = image.cgImage { bytes += cg.bytesPerRow * cg.height }
                textures[index] = [CanvasOverviewWidthBlock(rect: rect, signature: "fallback-\(index)-\(size)", image: image)]
                    + (0..<3).map { _ in CanvasOverviewWidthBlock(rect: .zero, signature: "empty", image: nil) }
                continue
            }
            textures[index] = content.blocks.map { block in
                let image = rasterBlock(block, style: seed.model.style, scale: textureScale)
                if let cg = image?.cgImage { bytes += cg.bytesPerRow * cg.height }
                // Compare ink layout, not the empty right-hand width of a text bitmap.
                let metrics = block.layout.metrics.map {
                    "\($0.origin.x):\($0.width)"
                }.joined(separator: "|")
                let signature = block.signature + metrics + (block.truncated ? ":\(block.rect.height)" : "")
                return CanvasOverviewWidthBlock(rect: block.rect, signature: signature, image: image)
            }
        }
        guard !cancellation.isCancelled else { return nil }
        var preview = CanvasOverviewWidthPreview(width: width, contents: contents, groupHeights: groupHeights,
                                     layoutVersion: geometry.parameters.version,
                                     textures: textures, textureBytes: bytes)
        if !geometry.regionSlices.isEmpty {
            preview.regionalGeometry = original ? geometry : CanvasOverviewRegionalGeometry.reflow(geometry,
                width: width, viewport: seed.clip.size, contents: contents,
                anchorID: geometry.papers[seed.anchorIndex].noteID, cancellation: cancellation)
            guard preview.regionalGeometry != nil else { return nil }
        }
        return preview
    }

    /// Each preparation task owns its framesetters; parsed immutable attributes and decorations are retained.
    static func independentNote(_ note: CanvasOverviewNote) -> CanvasOverviewNote {
        func asset(_ old: CanvasOverviewTextAsset) -> CanvasOverviewTextAsset {
            CanvasOverviewTextAsset(text: old.text, attributedText: old.attributedText, attributeKeys: old.attributeKeys,
                hasRichFormatting: old.hasRichFormatting)
        }
        return CanvasOverviewNote(id: note.id, quote: note.quote, thought: note.thought,
            bookTitle: note.bookTitle, chapter: note.chapter, quoteAsset: asset(note.quoteAsset),
            thoughtAsset: asset(note.thoughtAsset), bookAsset: asset(note.bookAsset), chapterAsset: asset(note.chapterAsset))
    }

    static func rasterBlock(_ block: CanvasOverviewTextBlock, style: CanvasOverviewPaperStyle, scale: CGFloat) -> UIImage? {
        guard block.rect.width > 0, block.rect.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: block.rect.size, format: format).image { renderer in
            renderer.cgContext.translateBy(x: -block.rect.minX, y: -block.rect.minY)
            CanvasOverviewPaperRenderer.draw(block: block, paperColor: style.paperColor, in: renderer.cgContext)
        }
    }

    /// Repositions only prepared candidate groups. Heights and safe lifts share one progress;
    /// the panorama calls this on its raster queue, never scanning the full ID list on main.
    static func poses(seed: CanvasOverviewWidthSeed, width: CGFloat, source: CanvasOverviewWidthPreview,
                      target: CanvasOverviewWidthPreview, progress: CGFloat) -> [CanvasOverviewWidthPaperPose] {
        let geometry = seed.model.canvasGeometry
        if let first = source.regionalGeometry, let second = target.regionalGeometry {
            let a = first.papers[seed.anchorIndex].frame.center
            let b = second.papers[seed.anchorIndex].frame.center
            let anchor = CanvasOverviewMotion.mix(a, b, progress)
            let preparedWidth = CanvasOverviewMotion.mix(first.cardWidth, second.cardWidth, progress)
            let strideRatio = geometry.parameters.stride(width: width) / geometry.parameters.stride(width: preparedWidth)
            return seed.renderIndexes.map { index in
                let f = first.papers[index].frame
                let t = second.papers[index].frame
                let center = CanvasOverviewMotion.mix(f.center, t.center, progress)
                return .init(index: index, pose: .init(center: CGPoint(
                    x: seed.anchor.x + (center.x - anchor.x) * seed.scale * strideRatio,
                    y: seed.anchor.y + (center.y - anchor.y) * seed.scale),
                    size: CGSize(width: width * seed.scale, height: CanvasOverviewMotion.mix(f.height, t.height, progress) * seed.scale),
                    rotation: geometry.papers[index].rotation))
            }
        }
        let count = geometry.columnCount
        guard source.layoutVersion == geometry.parameters.version, target.layoutVersion == source.layoutVersion else { return [] }
        let placements = source.groupHeights.indices.map { local -> CanvasOverviewPairPlacement in
            let heights = zip(source.groupHeights[local], target.groupHeights[local]).map { CanvasOverviewMotion.mix($0, $1, progress) }
            return CanvasOverviewPairGeometry.place(firstRow: (seed.groups.lowerBound + local) * 2,
                columns: count, width: width, heights: heights, parameters: geometry.parameters,
                rotations: geometry.groups[seed.groups.lowerBound + local].indexRange.map { geometry.papers[$0].rotation })
        }
        var origins = [CGFloat](repeating: 0, count: placements.count)
        for local in placements.indices.dropFirst() {
            origins[local] = origins[local - 1] + placements[local - 1].height + geometry.parameters.verticalGap
        }
        let localAnchorGroup = seed.anchorIndex / (count * 2) - seed.groups.lowerBound
        let anchorFrame = placements[localAnchorGroup].frames[seed.anchorIndex % (count * 2)]
        let anchor = CGPoint(x: anchorFrame.midX, y: anchorFrame.midY + origins[localAnchorGroup])
        return seed.renderIndexes.map { index in
            let group = index / (count * 2) - seed.groups.lowerBound
            let frame = placements[group].frames[index % (count * 2)].offsetBy(dx: 0, dy: origins[group])
            let direction: CGFloat = geometry.spatialIndex.isRTL ? -1 : 1
            let center = CGPoint(x: seed.anchor.x + (frame.midX - anchor.x) * seed.scale * direction,
                                 y: seed.anchor.y + (frame.midY - anchor.y) * seed.scale)
            return CanvasOverviewWidthPaperPose(index: index, pose: CanvasOverviewPaperPose(center: center,
                size: CGSize(width: width * seed.scale, height: frame.height * seed.scale), rotation: geometry.papers[index].rotation))
        }
    }

    /// Far-view composition draws prepared bitmap blocks only; it never calls CTLineDraw or creates shadows.
    static func raster(seed: CanvasOverviewWidthSeed, width: CGFloat, source: CanvasOverviewWidthPreview,
                       target: CanvasOverviewWidthPreview, progress: CGFloat, textProgress: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(seed.screenScale, 2_048 / max(seed.clip.width, seed.clip.height))
        format.opaque = true
        return UIGraphicsImageRenderer(size: seed.clip.size, format: format).image { renderer in
            let context = renderer.cgContext
            CanvasOverviewCanvasRasterizer.fillCanvas(CGRect(origin: .zero, size: seed.clip.size), style: seed.model.style, in: context)
            for item in poses(seed: seed, width: width, source: source, target: target, progress: progress) {
                guard item.pose.boundingFrame.insetBy(dx: -24, dy: -24).intersects(CGRect(origin: .zero, size: seed.clip.size)) else { continue }
                context.saveGState()
                context.translateBy(x: item.pose.center.x, y: item.pose.center.y)
                context.rotate(by: item.pose.rotation)
                context.scaleBy(x: seed.scale, y: seed.scale)
                let bounds = CGRect(x: -width / 2, y: -item.pose.size.height / seed.scale / 2,
                                    width: width, height: item.pose.size.height / seed.scale)
                seed.model.style.paperSkin.draw(in: bounds.insetBy(dx: -24, dy: -24))
                context.addPath(CGPath(roundedRect: bounds, cornerWidth: seed.model.style.cornerRadius,
                                      cornerHeight: seed.model.style.cornerRadius, transform: nil))
                context.clip()
                context.translateBy(x: bounds.minX, y: bounds.minY)
                NoteReviewCanvasPaperRenderer.drawBackground(seed.model.style.backgroundImage,
                    overlay: seed.model.style.backgroundOverlay, size: bounds.size, in: context)
                for (a, b) in zip(source.textures[item.index] ?? [], target.textures[item.index] ?? []) {
                    let origin = CanvasOverviewMotion.mix(a.rect.origin, b.rect.origin, progress)
                    let same = a.signature == b.signature
                    a.image?.draw(in: CGRect(origin: origin, size: a.rect.size), blendMode: .normal, alpha: same ? 1 : 1 - textProgress)
                    if !same { b.image?.draw(in: CGRect(origin: origin, size: b.rect.size), blendMode: .normal, alpha: textProgress) }
                }
                context.restoreGState()
            }
        }
    }
}

/// A bounded near-view paper pool, or one far-view bitmap. The hidden real canvas never competes with it.
@MainActor
final class CanvasOverviewWidthSceneView: NoteReviewCanvasTransitionSurface {
    let rasterView = UIImageView()
    var papers: [Int: CanvasOverviewWidthPaperView] = [:]
    var reusablePapers: [CanvasOverviewWidthPaperView] = []
    var boundTarget: CanvasOverviewWidthPreview?
    var boundSource: CanvasOverviewWidthPreview?
    let seed: CanvasOverviewWidthSeed
    var activePaperCount: Int { papers.count }

    init(seed: CanvasOverviewWidthSeed) {
        self.seed = seed
        super.init(frame: seed.clip)
        backgroundColor = NoteReviewCanvasAppearance.resolvedPaper(seed.model.style.canvasBaseColor)
        let tint = UIView(frame: bounds)
        tint.backgroundColor = NoteReviewCanvasAppearance.resolvedPaper(seed.model.style.canvasTintColor)
        addSubview(tint)
        clipsToBounds = true
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        rasterView.frame = bounds
        addSubview(rasterView)
        if !seed.rasterMode {
            // Allocate the bounded pool before enabling the slider, never on an edge-entry frame.
            reusablePapers = seed.renderIndexes.map { _ in CanvasOverviewWidthPaperView(style: seed.model.style) }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func bind(source: CanvasOverviewWidthPreview, target: CanvasOverviewWidthPreview) {
        boundSource = source
        boundTarget = target
        for (index, paper) in papers { paper.bind(source: source.textures[index] ?? [], target: target.textures[index] ?? []) }
    }

    func render(width: CGFloat, source: CanvasOverviewWidthPreview, target: CanvasOverviewWidthPreview,
                progress: CGFloat, textProgress: CGFloat) {
        guard !seed.rasterMode else { return }
        let visible = CanvasOverviewWidthBuilder.poses(seed: seed, width: width, source: source, target: target, progress: progress)
            .filter { $0.pose.boundingFrame.insetBy(dx: -24, dy: -24).intersects(bounds) }
        let ids = Set(visible.map(\.index))
        for index in Array(papers.keys) where !ids.contains(index) {
            if let paper = papers.removeValue(forKey: index) {
                paper.removeFromSuperview()
                paper.bind(source: [], target: [])
                reusablePapers.append(paper)
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for item in visible {
            let paper: CanvasOverviewWidthPaperView
            if let existing = papers[item.index] { paper = existing } else {
                guard let reusable = reusablePapers.popLast() else { assertionFailure("Width candidate budget exceeded"); continue }
                paper = reusable
                paper.bind(source: source.textures[item.index] ?? [], target: target.textures[item.index] ?? [])
                papers[item.index] = paper
                addSubview(paper)
            }
            paper.apply(pose: item.pose, width: width, scale: seed.scale, progress: progress, textProgress: textProgress)
        }
        CATransaction.commit()
    }
}

@MainActor
final class CanvasOverviewWidthPaperView: UIView {
    let skin = UIImageView()
    let clip = UIView()
    let backgroundImage = UIImageView()
    let backgroundTint = UIView()
    let sourceViews = (0..<4).map { _ in UIImageView() }
    let targetViews = (0..<4).map { _ in UIImageView() }
    var source: [CanvasOverviewWidthBlock] = []
    var target: [CanvasOverviewWidthBlock] = []

    init(style: CanvasOverviewPaperStyle) {
        super.init(frame: .zero)
        skin.image = style.paperSkin
        addSubview(skin)
        clip.clipsToBounds = true
        clip.layer.cornerRadius = style.cornerRadius
        addSubview(clip)
        backgroundImage.image = style.backgroundImage.map { UIImage(cgImage: $0) }
        backgroundImage.contentMode = .scaleAspectFill
        backgroundImage.clipsToBounds = true
        backgroundTint.backgroundColor = NoteReviewCanvasAppearance.resolvedPaper(style.backgroundOverlay)
        backgroundTint.isHidden = style.backgroundImage == nil
        clip.addSubview(backgroundImage)
        clip.addSubview(backgroundTint)
        for view in sourceViews + targetViews { clip.addSubview(view) }
        isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func bind(source: [CanvasOverviewWidthBlock], target: [CanvasOverviewWidthBlock]) {
        self.source = source
        self.target = target
        for i in 0..<4 {
            sourceViews[i].image = source[safe: i]?.image
            targetViews[i].image = target[safe: i]?.image
        }
    }

    func apply(pose: CanvasOverviewPaperPose, width: CGFloat, scale: CGFloat, progress: CGFloat, textProgress: CGFloat) {
        bounds = CGRect(x: 0, y: 0, width: width, height: pose.size.height / scale)
        center = pose.center
        transform = CGAffineTransform(rotationAngle: pose.rotation).scaledBy(x: scale, y: scale)
        skin.frame = bounds.insetBy(dx: -24, dy: -24)
        clip.frame = bounds
        backgroundImage.frame = bounds
        backgroundTint.frame = bounds
        for i in 0..<min(source.count, target.count) {
            let a = source[i], b = target[i]
            let origin = CanvasOverviewMotion.mix(a.rect.origin, b.rect.origin, progress)
            sourceViews[i].frame = CGRect(origin: origin, size: a.rect.size)
            targetViews[i].frame = CGRect(origin: origin, size: b.rect.size)
            let same = a.signature == b.signature
            sourceViews[i].alpha = same ? 1 : 1 - textProgress
            targetViews[i].alpha = same ? 0 : textProgress
        }
    }
}

@MainActor
final class CanvasOverviewWidthToolbar: UIView {
    let slider = UISlider()
    let valueLabel = UILabel()
    let statusLabel = UILabel()
    let reset = UIButton(type: .system)
    let cancel = UIButton(type: .system)
    let done = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = NoteReviewCanvasAppearance.paper
        layer.cornerRadius = CornerRadius.containerMedium
        layer.borderWidth = StrokeWidth.hairline
        layer.borderColor = NoteReviewCanvasAppearance.subtleBorder.cgColor
        valueLabel.font = UIFont.preferredFont(forTextStyle: .body)
        valueLabel.textColor = NoteReviewCanvasAppearance.primary
        statusLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = NoteReviewCanvasAppearance.secondary
        statusLabel.numberOfLines = 0
        slider.minimumValue = 180
        slider.maximumValue = 360
        slider.isContinuous = true
        slider.accessibilityLabel = "桌面卡宽"
        slider.accessibilityIdentifier = "singleCanvasWidthSlider"
        valueLabel.accessibilityIdentifier = "singleCanvasWidthValue"
        for (button, title, id) in [(reset, "恢复默认", "singleCanvasWidthReset"),
                                     (cancel, "取消", "singleCanvasWidthCancel"),
                                     (done, "完成", "singleCanvasWidthDone")] {
            button.setTitle(title, for: .normal)
            button.setTitleColor(NoteReviewCanvasAppearance.primary, for: .normal)
            button.accessibilityIdentifier = id
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: InteractionMetrics.minimumTouchTarget).isActive = true
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: InteractionMetrics.minimumTouchTarget).isActive = true
        }
        slider.heightAnchor.constraint(greaterThanOrEqualToConstant: InteractionMetrics.minimumTouchTarget).isActive = true
        let actions = UIStackView(arrangedSubviews: [reset, UIView(), cancel, done])
        actions.spacing = Spacing.base
        let stack = UIStackView(arrangedSubviews: [valueLabel, slider, statusLabel, actions])
        stack.axis = .vertical
        stack.spacing = Spacing.compact
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.screenEdge),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.screenEdge),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.base),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Spacing.cozy),
        ])
        update(width: 220, status: "字号与相机倍率不变")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(width: CGFloat, status: String) {
        valueLabel.text = "桌面卡宽  \(Int(width.rounded())) pt"
        slider.accessibilityValue = "\(Int(width.rounded())) pt"
        if !slider.isTracking { slider.value = Float(width) }
        if statusLabel.text != status { statusLabel.text = status }
    }
}

// MARK: - Helpers

private extension CGRect {
    nonisolated var center: CGPoint { CGPoint(x: midX, y: midY) }
}

private extension CGPoint {
    nonisolated func distanceSquared(to other: CGPoint) -> CGFloat {
        let dx = x - other.x
        let dy = y - other.y
        return dx * dx + dy * dy
    }
}

private extension Array {
    nonisolated subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
