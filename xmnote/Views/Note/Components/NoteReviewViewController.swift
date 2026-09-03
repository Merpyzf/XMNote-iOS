/**
 * [INPUT]: 依赖 NoteReviewUIKitSession、单一 UICollectionView、两种自定义布局、UIKit Sheet 与图片浏览宿主
 * [OUTPUT]: 对外提供 NoteReviewViewController（沉浸纵向分页、双向平铺、收藏标签、显示设置与连续布局转场）
 * [POS]: Views/Note/Components 的全屏回顾 UIKit owner，统一持有分页手势、布局锚点、控件显隐与可见范围生命周期
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 全屏回顾唯一控制器；集合视图、Cell、布局、菜单和 Sheet 均不回退到 SwiftUI 实现。
@MainActor
final class NoteReviewViewController: UIViewController {
    private let session: NoteReviewUIKitSession
    private let onDismiss: () -> Void
    private let onOpenDetail: (Int64, [Int64]) -> Void
    private let onError: (String) -> Void
    private let onInfo: (String) -> Void

    private let immersiveLayout = ImmersiveReviewFlowLayout()
    private let flatLayout = FlatReviewCanvasLayout()
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: immersiveLayout)
    private let closeButton = UIButton(type: .system)
    private let modeButton = UIButton(type: .system)
    private let favoriteButton = UIButton(type: .system)
    private let moreButton = UIButton(type: .system)
    private let progressLabel = UILabel()
    private let emptyLabel = UILabel()
    private var topControls: [UIView] = []
    private var bottomControls: [UIView] = []
    private var mode: NoteReviewPresentationMode = .immersive
    private var areControlsHidden = false
    private var isChangingLayout = false
    private var transitionAnimator: UIViewPropertyAnimator?
    private var pinchInitialScale: CGFloat = 1
    private var semanticScaleBand = 4
    private var galleryHost: XMJXPhotoBrowserHost?
    private var hasRestoredInitialAnchor = false
    private var contentSizeCategoryObserver: NSObjectProtocol?
    private var reduceMotionObserver: NSObjectProtocol?
    private var appearanceTraitRegistration: UITraitChangeRegistration?

    /// 建立页面私有会话，并把关闭、详情与轻量反馈交回应用导航层。
    init(
        payload: NoteReviewLaunchPayload,
        repository: any NoteRepositoryProtocol,
        onDismiss: @escaping () -> Void,
        onOpenDetail: @escaping (Int64, [Int64]) -> Void,
        onError: @escaping (String) -> Void,
        onInfo: @escaping (String) -> Void
    ) {
        self.session = NoteReviewUIKitSession(payload: payload, repository: repository)
        self.onDismiss = onDismiss
        self.onOpenDetail = onOpenDetail
        self.onError = onError
        self.onInfo = onInfo
        super.init(nibName: nil, bundle: nil)
        modalPresentationCapturesStatusBarAppearance = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let contentSizeCategoryObserver {
            NotificationCenter.default.removeObserver(contentSizeCategoryObserver)
        }
        if let reduceMotionObserver {
            NotificationCenter.default.removeObserver(reduceMotionObserver)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildCollectionView()
        buildChrome()
        bindSession()
        observeAccessibilityChanges()
        appearanceTraitRegistration = registerForTraitChanges(
            [UITraitUserInterfaceStyle.self]
        ) { (controller: NoteReviewViewController, _) in
            controller.collectionView.reloadData()
            controller.updateChromeColors()
        }
        updateModeButton()
        updateProgress()
        session.start()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !hasRestoredInitialAnchor, session.count > 0 else { return }
        hasRestoredInitialAnchor = true
        restoreAnchor(animated: false)
    }

    override func viewWillTransition(
        to size: CGSize,
        with coordinator: any UIViewControllerTransitionCoordinator
    ) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate { [weak self] _ in
            self?.collectionView.collectionViewLayout.invalidateLayout()
            self?.collectionView.layoutIfNeeded()
        } completion: { [weak self] _ in
            self?.restoreAnchor(animated: false)
        }
    }

}

private extension NoteReviewViewController {
    func buildCollectionView() {
        view.backgroundColor = .systemGroupedBackground
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .systemGroupedBackground
        collectionView.alwaysBounceVertical = true
        collectionView.showsVerticalScrollIndicator = false
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.keyboardDismissMode = .interactive
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.register(
            NoteReviewCollectionCell.self,
            forCellWithReuseIdentifier: NoteReviewCollectionCell.reuseIdentifier
        )
        updateScrollAxes()
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        flatLayout.noteIDProvider = { [weak session] index in
            session?.noteID(at: index)
        }
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        collectionView.addGestureRecognizer(pinch)
    }

    func buildChrome() {
        configureChromeButton(closeButton, systemName: "xmark", accessibilityLabel: "关闭全屏回顾")
        configureChromeButton(modeButton, systemName: "square.grid.2x2", accessibilityLabel: "切换到平铺回顾")
        configureChromeButton(favoriteButton, systemName: "heart", accessibilityLabel: "收藏")
        configureChromeButton(moreButton, systemName: "ellipsis", accessibilityLabel: "更多操作")
        closeButton.addTarget(self, action: #selector(handleClose), for: .touchUpInside)
        modeButton.addTarget(self, action: #selector(handleModeSwitch), for: .touchUpInside)
        favoriteButton.addTarget(self, action: #selector(handleFavorite), for: .touchUpInside)
        moreButton.showsMenuAsPrimaryAction = true

        let closeGlass = glassHost(containing: closeButton)
        let modeGlass = glassHost(containing: modeButton)
        let favoriteGlass = glassHost(containing: favoriteButton)
        let moreGlass = glassHost(containing: moreButton)
        topControls = [closeGlass, modeGlass]
        bottomControls = [favoriteGlass, moreGlass]

        progressLabel.translatesAutoresizingMaskIntoConstraints = false
        progressLabel.font = ReadingContentTypography.uiMetadataMedium
        progressLabel.textColor = .secondaryLabel
        progressLabel.textAlignment = .center
        progressLabel.adjustsFontForContentSizeCategory = true
        progressLabel.accessibilityLabel = "回顾进度"

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.text = "当前筛选下没有书摘"
        emptyLabel.font = ReadingContentTypography.uiBody
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.textAlignment = .center
        emptyLabel.isHidden = true

        [closeGlass, modeGlass, favoriteGlass, moreGlass, progressLabel, emptyLabel].forEach(view.addSubview)
        NSLayoutConstraint.activate([
            closeGlass.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            closeGlass.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            closeGlass.widthAnchor.constraint(equalToConstant: 48),
            closeGlass.heightAnchor.constraint(equalToConstant: 48),
            modeGlass.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            modeGlass.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            modeGlass.widthAnchor.constraint(equalToConstant: 48),
            modeGlass.heightAnchor.constraint(equalToConstant: 48),

            favoriteGlass.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            favoriteGlass.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10),
            favoriteGlass.widthAnchor.constraint(equalToConstant: 48),
            favoriteGlass.heightAnchor.constraint(equalToConstant: 48),
            moreGlass.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            moreGlass.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10),
            moreGlass.widthAnchor.constraint(equalToConstant: 48),
            moreGlass.heightAnchor.constraint(equalToConstant: 48),
            progressLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            progressLabel.centerYAnchor.constraint(equalTo: favoriteGlass.centerYAnchor),
            progressLabel.leadingAnchor.constraint(greaterThanOrEqualTo: favoriteGlass.trailingAnchor, constant: 12),
            progressLabel.trailingAnchor.constraint(lessThanOrEqualTo: moreGlass.leadingAnchor, constant: -12),

            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32)
        ])
        updateChromeColors()
    }

    func configureChromeButton(_ button: UIButton, systemName: String, accessibilityLabel: String) {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: systemName)
        configuration.baseForegroundColor = .label
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        button.configuration = configuration
        button.accessibilityLabel = accessibilityLabel
    }

    func glassHost(containing button: UIButton) -> UIVisualEffectView {
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = true
        let host = UIVisualEffectView(effect: effect)
        host.translatesAutoresizingMaskIntoConstraints = false
        host.clipsToBounds = true
        host.layer.cornerRadius = 24
        host.layer.cornerCurve = .continuous
        button.translatesAutoresizingMaskIntoConstraints = false
        host.contentView.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: host.contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: host.contentView.trailingAnchor),
            button.topAnchor.constraint(equalTo: host.contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: host.contentView.bottomAnchor)
        ])
        return host
    }

    func bindSession() {
        session.onManifestChanged = { [weak self] in
            guard let self else { return }
            let anchorID = session.currentNoteID
            collectionView.reloadData()
            collectionView.layoutIfNeeded()
            emptyLabel.isHidden = session.count != 0
            if session.orderedIDs.contains(anchorID) {
                restoreAnchor(animated: false)
            }
            updateProgress()
            refreshVisibleRange()
        }
        session.onItemsChanged = { [weak self] changedIDs in
            guard let self else { return }
            refreshVisibleCells(changedIDs: changedIDs)
            updateFavoriteButton()
            updateMoreMenu()
        }
        session.onSettingsChanged = { [weak self] in
            guard let self else { return }
            collectionView.collectionViewLayout.invalidateLayout()
            refreshVisibleCells(
                changedIDs: Set(
                    collectionView.indexPathsForVisibleItems.compactMap {
                        self.session.noteID(at: $0.item)
                    }
                )
            )
            updateFavoriteButton()
        }
        session.onError = { [weak self] message in
            self?.onError(message)
        }
    }

    func observeAccessibilityChanges() {
        contentSizeCategoryObserver = NotificationCenter.default.addObserver(
            forName: UIContentSizeCategory.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.collectionView.collectionViewLayout.invalidateLayout()
                self?.collectionView.reloadData()
            }
        }
        reduceMotionObserver = NotificationCenter.default.addObserver(
            forName: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.transitionAnimator?.stopAnimation(true)
            }
        }
    }

    func updateChromeColors() {
        view.backgroundColor = .systemGroupedBackground
        collectionView.backgroundColor = .systemGroupedBackground
        [closeButton, modeButton, favoriteButton, moreButton].forEach { button in
            button.configuration?.baseForegroundColor = .label
        }
    }
}

extension NoteReviewViewController: UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        session.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: NoteReviewCollectionCell.reuseIdentifier,
            for: indexPath
        ) as! NoteReviewCollectionCell
        if let noteID = session.noteID(at: indexPath.item) {
            cell.configurePlaceholder(noteID: noteID, mode: mode)
        }
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView,
        willDisplay cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        guard let cell = cell as? NoteReviewCollectionCell,
              let noteID = session.noteID(at: indexPath.item) else { return }
        configure(cell: cell, noteID: noteID)
        refreshVisibleRange()
    }

    func collectionView(
        _ collectionView: UICollectionView,
        didEndDisplaying cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        (cell as? NoteReviewCollectionCell)?.didEndDisplaying()
        refreshVisibleRange()
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let noteID = session.noteID(at: indexPath.item) else { return }
        if mode == .flat {
            session.setCurrentNoteID(noteID)
            switchMode(to: .immersive)
        } else {
            setControlsHidden(!areControlsHidden)
        }
    }

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        session.prefetch(noteIDs: indexPaths.compactMap { session.noteID(at: $0.item) })
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        session.cancelPrefetch(noteIDs: indexPaths.compactMap { session.noteID(at: $0.item) })
    }
}

extension NoteReviewViewController: UIGestureRecognizerDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if mode == .flat, !isChangingLayout {
            updateCurrentReadingAnchor()
        }
        refreshVisibleRange()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        commitCurrentImmersivePage()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard !decelerate else { return }
        commitCurrentImmersivePage()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        commitCurrentImmersivePage()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer is UIPinchGestureRecognizer || otherGestureRecognizer is UIPinchGestureRecognizer
    }
}

private extension NoteReviewViewController {
    func configure(cell: NoteReviewCollectionCell, noteID: Int64) {
        cell.onFavorite = { [weak self] noteID in self?.toggleFavorite(noteID: noteID) }
        cell.onOpenImages = { [weak self] item, index in self?.openImages(item: item, index: index) }
        guard let item = session.item(for: noteID) else {
            session.updateVisibleIDs(Set(collectionView.indexPathsForVisibleItems.compactMap { session.noteID(at: $0.item) }))
            return
        }
        cell.configure(
            item: item,
            mode: mode,
            settings: session.settings,
            flatScale: flatLayout.scale,
            isFavorite: session.isFavorite(noteID: noteID)
        )
    }

    func refreshVisibleCells(changedIDs: Set<Int64>) {
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard let noteID = session.noteID(at: indexPath.item), changedIDs.contains(noteID),
                  let cell = collectionView.cellForItem(at: indexPath) as? NoteReviewCollectionCell else { continue }
            configure(cell: cell, noteID: noteID)
        }
        collectionView.collectionViewLayout.invalidateLayout()
    }

    func refreshVisibleRange() {
        let ids = Set(collectionView.indexPathsForVisibleItems.compactMap { session.noteID(at: $0.item) })
        session.updateVisibleIDs(ids)
    }

    func updateCurrentReadingAnchor() {
        guard !collectionView.indexPathsForVisibleItems.isEmpty else { return }
        let visualAnchor = CGPoint(
            x: collectionView.contentOffset.x + collectionView.bounds.width / 2,
            y: collectionView.contentOffset.y + collectionView.bounds.height * (mode == .immersive ? 0.42 : 0.5)
        )
        let nearest = collectionView.indexPathsForVisibleItems.compactMap { indexPath -> (IndexPath, CGFloat)? in
            guard let attributes = collectionView.layoutAttributesForItem(at: indexPath) else { return nil }
            let distance = hypot(attributes.center.x - visualAnchor.x, attributes.center.y - visualAnchor.y)
            return (indexPath, distance)
        }.min(by: { $0.1 < $1.1 })
        guard let indexPath = nearest?.0,
              let noteID = session.noteID(at: indexPath.item),
              noteID != session.currentNoteID else { return }
        session.setCurrentNoteID(noteID)
        updateProgress()
        updateFavoriteButton()
    }

    func commitCurrentImmersivePage() {
        guard mode == .immersive, session.count > 0 else { return }
        let pageHeight = max(1, collectionView.bounds.height)
        let rawPage = (collectionView.contentOffset.y + collectionView.adjustedContentInset.top) / pageHeight
        let index = max(0, min(session.count - 1, Int(rawPage.rounded())))
        guard let noteID = session.noteID(at: index), noteID != session.currentNoteID else { return }
        session.setCurrentNoteID(noteID)
        updateProgress()
    }

    func updateProgress() {
        let displayIndex = session.count == 0 ? 0 : session.currentIndex + 1
        progressLabel.text = "\(displayIndex) / \(session.count)"
        progressLabel.accessibilityValue = "第 \(displayIndex) 条，共 \(session.count) 条"
        emptyLabel.isHidden = session.count != 0
        favoriteButton.isEnabled = session.count > 0
        moreButton.isEnabled = session.count > 0
        updateFavoriteButton()
        updateMoreMenu()
    }

    func updateFavoriteButton() {
        let isFavorite = session.isFavorite(noteID: session.currentNoteID)
        favoriteButton.configuration?.image = UIImage(systemName: isFavorite ? "heart.fill" : "heart")
        favoriteButton.configuration?.baseForegroundColor = isFavorite
            ? .systemRed
            : .label
        favoriteButton.accessibilityLabel = isFavorite ? "取消收藏" : "收藏"
    }

    func updateModeButton() {
        switch mode {
        case .immersive:
            modeButton.configuration?.image = UIImage(systemName: "square.grid.2x2")
            modeButton.accessibilityLabel = "切换到平铺回顾"
        case .flat:
            modeButton.configuration?.image = UIImage(systemName: "rectangle.portrait")
            modeButton.accessibilityLabel = "切换到沉浸回顾"
        }
    }

    func updateMoreMenu() {
        let noteID = session.currentNoteID
        var actions: [UIMenuElement] = [
            UIAction(title: "查看书摘详情", image: UIImage(systemName: "doc.text.magnifyingglass")) { [weak self] _ in
                guard let self else { return }
                onOpenDetail(noteID, session.orderedIDs)
            },
            UIAction(title: "显示内容", image: UIImage(systemName: "textformat.size")) { [weak self] _ in
                self?.presentDisplaySettings()
            },
            UIAction(title: "设置收藏标签", image: UIImage(systemName: "tag")) { [weak self] _ in
                self?.presentFavoriteTagPicker(favoriteNoteID: nil)
            }
        ]
        if session.settings.sortRule == .random {
            actions.append(
                UIAction(title: "换一组", image: UIImage(systemName: "shuffle")) { [weak self] _ in
                    self?.session.reshuffle()
                }
            )
        }
        if let item = session.item(for: noteID), let rawURL = item.weReadOriginalURL,
           let url = URL(string: rawURL) {
            actions.append(
                UIAction(title: "查看微信读书原文", image: UIImage(systemName: "arrow.up.right.square")) { _ in
                    UIApplication.shared.open(url)
                }
            )
        }
        moreButton.menu = UIMenu(children: actions)
    }

    func setControlsHidden(_ hidden: Bool) {
        areControlsHidden = hidden
        let targets = topControls + bottomControls
        guard !UIAccessibility.isReduceMotionEnabled else {
            targets.forEach { $0.alpha = hidden ? 0 : 1; $0.isUserInteractionEnabled = !hidden }
            return
        }
        UIView.animate(
            withDuration: 0.2,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut]
        ) {
            targets.forEach { $0.alpha = hidden ? 0 : 1 }
        } completion: { _ in
            targets.forEach { $0.isUserInteractionEnabled = !hidden }
        }
    }

    func switchMode(to nextMode: NoteReviewPresentationMode) {
        guard mode != nextMode else { return }
        transitionAnimator?.stopAnimation(false)
        transitionAnimator?.finishAnimation(at: .current)
        let anchorNoteID = session.currentNoteID
        isChangingLayout = true
        mode = nextMode
        updateModeButton()
        updateScrollAxes()
        let targetLayout: UICollectionViewLayout = nextMode == .immersive ? immersiveLayout : flatLayout

        if UIAccessibility.isReduceMotionEnabled {
            UIView.transition(with: collectionView, duration: 0.12, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                self.collectionView.setCollectionViewLayout(targetLayout, animated: false)
                self.collectionView.reloadData()
                self.collectionView.layoutIfNeeded()
                self.restoreAnchor(noteID: anchorNoteID, animated: false)
            } completion: { [weak self] _ in
                self?.isChangingLayout = false
            }
            return
        }

        let transition = collectionView.startInteractiveTransition(to: targetLayout) { [weak self] _, _ in
            guard let self else { return }
            collectionView.reloadData()
            collectionView.layoutIfNeeded()
            restoreAnchor(noteID: anchorNoteID, animated: false)
            updateScrollAxes()
            isChangingLayout = false
        }
        let animator = UIViewPropertyAnimator(duration: 0.3, curve: .easeInOut) {
            transition.transitionProgress = 1
            self.collectionView.layoutIfNeeded()
        }
        animator.addCompletion { [weak self] position in
            guard let self else { return }
            if position == .end {
                collectionView.finishInteractiveTransition()
            } else {
                collectionView.cancelInteractiveTransition()
            }
            transitionAnimator = nil
        }
        transitionAnimator = animator
        animator.startAnimation()
    }

    func updateScrollAxes() {
        collectionView.isPagingEnabled = mode == .immersive
        collectionView.decelerationRate = mode == .immersive ? .fast : .normal
        collectionView.isDirectionalLockEnabled = mode == .immersive
        collectionView.alwaysBounceVertical = true
        collectionView.alwaysBounceHorizontal = mode == .flat
        collectionView.showsHorizontalScrollIndicator = false
    }

    func restoreAnchor(noteID: Int64? = nil, animated: Bool) {
        let anchorNoteID = noteID ?? session.currentNoteID
        guard let index = session.orderedIDs.firstIndex(of: anchorNoteID), session.count > index else { return }
        let indexPath = IndexPath(item: index, section: 0)
        switch mode {
        case .immersive:
            collectionView.scrollToItem(at: indexPath, at: .top, animated: animated)
        case .flat:
            collectionView.layoutIfNeeded()
            guard let center = flatLayout.center(forItemAt: index) else { return }
            let proposed = CGPoint(
                x: center.x - collectionView.bounds.width / 2,
                y: center.y - collectionView.bounds.height / 2
            )
            collectionView.setContentOffset(clampedContentOffset(proposed), animated: animated)
        }
    }

    func clampedContentOffset(_ proposed: CGPoint) -> CGPoint {
        let maximumX = max(0, collectionView.contentSize.width - collectionView.bounds.width)
        let maximumY = max(0, collectionView.contentSize.height - collectionView.bounds.height)
        return CGPoint(x: max(0, min(maximumX, proposed.x)), y: max(0, min(maximumY, proposed.y)))
    }

    @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard mode == .flat else { return }
        let focalPoint = gesture.location(in: collectionView)
        switch gesture.state {
        case .began:
            pinchInitialScale = flatLayout.scale
        case .changed:
            let nextScale = pinchInitialScale * gesture.scale
            let focalContentPoint = CGPoint(
                x: collectionView.contentOffset.x + focalPoint.x,
                y: collectionView.contentOffset.y + focalPoint.y
            )
            let anchor = collectionView.indexPathsForVisibleItems.compactMap { indexPath in
                collectionView.layoutAttributesForItem(at: indexPath).map { attributes in
                    (indexPath, attributes)
                }
            }.min {
                hypot($0.1.center.x - focalContentPoint.x, $0.1.center.y - focalContentPoint.y)
                    < hypot($1.1.center.x - focalContentPoint.x, $1.1.center.y - focalContentPoint.y)
            }
            let localPoint: CGPoint? = anchor.map { _, attributes in
                CGPoint(
                    x: (focalContentPoint.x - attributes.frame.minX) / max(1, attributes.frame.width),
                    y: (focalContentPoint.y - attributes.frame.minY) / max(1, attributes.frame.height)
                )
            }
            flatLayout.setScale(nextScale)
            collectionView.layoutIfNeeded()
            let nextBand = semanticBand(for: flatLayout.scale)
            if nextBand != semanticScaleBand {
                semanticScaleBand = nextBand
                refreshVisibleCells(
                    changedIDs: Set(
                        collectionView.indexPathsForVisibleItems.compactMap {
                            session.noteID(at: $0.item)
                        }
                    )
                )
            }
            if let anchor, let localPoint,
               let updatedAttributes = collectionView.layoutAttributesForItem(at: anchor.0) {
                let updatedContentPoint = CGPoint(
                    x: updatedAttributes.frame.minX + updatedAttributes.frame.width * localPoint.x,
                    y: updatedAttributes.frame.minY + updatedAttributes.frame.height * localPoint.y
                )
                collectionView.contentOffset = clampedContentOffset(
                    CGPoint(
                        x: updatedContentPoint.x - focalPoint.x,
                        y: updatedContentPoint.y - focalPoint.y
                    )
                )
            }
        default:
            break
        }
    }

    func semanticBand(for scale: CGFloat) -> Int {
        [CGFloat(0.72), 0.75, 0.82, 0.95, 1.15].reduce(0) { count, threshold in
            count + (scale >= threshold ? 1 : 0)
        }
    }

    @objc func handleClose() {
        onDismiss()
    }

    @objc func handleModeSwitch() {
        switchMode(to: mode == .immersive ? .flat : .immersive)
    }

    @objc func handleFavorite() {
        toggleFavorite(noteID: session.currentNoteID)
    }

    func toggleFavorite(noteID: Int64) {
        guard session.toggleFavorite(noteID: noteID) else {
            presentFavoriteTagPicker(favoriteNoteID: noteID)
            return
        }
    }

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
        host.open(at: max(0, min(index, galleryItems.count - 1)), wallID: "note-review-\(item.id)", tapSequence: 1)
    }

    func presentFavoriteTagPicker(favoriteNoteID: Int64?) {
        let picker = NoteReviewFavoriteTagViewController(
            selectedTagID: session.settings.favoriteTagID,
            loadOptions: { [weak session] in
                guard let session else { return [] }
                return try await session.fetchTagOptions()
            },
            createTag: { [weak session] name in
                guard let session else { throw CancellationError() }
                return try await session.createTag(named: name)
            },
            onSelect: { [weak self] tag in
                guard let self else { return }
                session.bindFavoriteTag(tag.id, favoriteNoteID: favoriteNoteID)
                onInfo(favoriteNoteID == nil ? "已将“\(tag.title)”设为收藏标签" : "已收藏到“\(tag.title)”")
            },
            onError: onError
        )
        let navigation = UINavigationController(rootViewController: picker)
        navigation.modalPresentationStyle = .pageSheet
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(navigation, animated: true)
    }

    func presentDisplaySettings() {
        let controller = NoteReviewDisplaySettingsViewController(
            settings: session.settings.immersiveDisplay,
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

/// 收藏标签 UIKit 单选/创建 Sheet；选定标签后由会话决定是否同时收藏当前书摘。
@MainActor
private final class NoteReviewFavoriteTagViewController: UITableViewController {
    private let selectedTagID: Int64?
    private let loadOptions: () async throws -> [NoteReviewTagOption]
    private let createTag: (String) async throws -> NoteReviewTagOption
    private let onSelect: (NoteReviewTagOption) -> Void
    private let onError: (String) -> Void
    private var options: [NoteReviewTagOption] = []
    private var loadingTask: Task<Void, Never>?

    init(
        selectedTagID: Int64?,
        loadOptions: @escaping () async throws -> [NoteReviewTagOption],
        createTag: @escaping (String) async throws -> NoteReviewTagOption,
        onSelect: @escaping (NoteReviewTagOption) -> Void,
        onError: @escaping (String) -> Void
    ) {
        self.selectedTagID = selectedTagID
        self.loadOptions = loadOptions
        self.createTag = createTag
        self.onSelect = onSelect
        self.onError = onError
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit { loadingTask?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "选择收藏标签"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .close,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .add,
            primaryAction: UIAction { [weak self] _ in self?.presentCreateAlert() }
        )
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "tag")
        load()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        options.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "tag", for: indexPath)
        let option = options[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = option.title
        content.secondaryText = option.noteCount > 0 ? "\(option.noteCount) 条书摘" : nil
        cell.contentConfiguration = content
        cell.accessoryType = option.id == selectedTagID ? .checkmark : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let option = options[indexPath.row]
        onSelect(option)
        dismiss(animated: true)
    }

    private func load() {
        loadingTask?.cancel()
        loadingTask = Task { [weak self] in
            guard let self else { return }
            do {
                options = try await loadOptions()
                tableView.reloadData()
            } catch is CancellationError {
                return
            } catch {
                onError("读取标签失败：\(error.localizedDescription)")
            }
        }
    }

    private func presentCreateAlert() {
        var tagName = ""
        let createActionID = "create-tag"
        XMSystemAlertController.present(
            on: self,
            descriptor: XMSystemAlertDescriptor(
                title: "新建收藏标签",
                actions: [
                    XMSystemAlertAction(title: "取消", role: .cancel) {},
                    XMSystemAlertAction(id: createActionID, title: "创建并选择") { [weak self] in
                        guard let self else { return }
                        loadingTask = Task { [weak self] in
                            guard let self else { return }
                            do {
                                let tag = try await self.createTag(tagName)
                                self.onSelect(tag)
                                self.dismiss(animated: true)
                            } catch is CancellationError {
                                return
                            } catch {
                                self.onError("创建标签失败：\(error.localizedDescription)")
                            }
                        }
                    }
                ],
                textFields: [
                    XMSystemAlertTextField(
                        text: { tagName },
                        setText: { tagName = $0 },
                        placeholder: "标签名称"
                    )
                ],
                preferredActionID: createActionID
            )
        )
    }
}

/// 两种模式共享的 UIKit 显示设置 Sheet；正文固定显示，其余内容即时写入 Codable 偏好。
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

    init(
        settings: NoteReviewImmersiveDisplaySettings,
        onChange: @escaping (NoteReviewImmersiveDisplaySettings) -> Void
    ) {
        self.settings = settings
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
        Row.allCases.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = Row(rawValue: indexPath.row)!
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

    @objc private func handleToggle(_ sender: UISwitch) {
        guard let row = Row(rawValue: sender.tag) else { return }
        setValue(sender.isOn, for: row)
        onChange(settings)
    }

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
