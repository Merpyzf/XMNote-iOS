/**
 * [INPUT]: 依赖书摘画布纯几何、不可变绘制指令及隔离设置容器
 * [OUTPUT]: 限定验证基础组件的几何、文字端点和卡宽兼容边界
 * [POS]: NoteReviewCanvasTests；不驱动 UI，不读写用户数据
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import UIKit
import CoreText
import Testing
@testable import xmnote

@MainActor
struct NoteReviewCanvasTests {
    @Test
    func stackCapacityDecodesIndependentlyAndInvalidValueDoesNotResetCardWidth() throws {
        var settings = NoteReviewSettings.defaultValue
        settings.desktopGroupCapacity = 64
        settings.desktopCardWidth = 277
        let data = try JSONEncoder().encode(settings)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for bad: Any in [17, "broken"] {
            json["desktopGroupCapacity"] = bad
            let decoded = try JSONDecoder().decode(NoteReviewSettings.self, from: JSONSerialization.data(withJSONObject: json))
            #expect(decoded.desktopGroupCapacity == 96 && decoded.desktopCardWidth == 277)
        }
        json.removeValue(forKey: "desktopGroupCapacity")
        #expect(try JSONDecoder().decode(NoteReviewSettings.self,
            from: JSONSerialization.data(withJSONObject: json)).desktopGroupCapacity == 96)
        #expect(try JSONDecoder().decode(NoteReviewSettings.self, from: data).desktopGroupCapacity == 64)
    }

    @Test
    func stalePreviewIdentityTerminatesWorkerWithoutAnyRead() async throws {
        let controller = NoteReviewCanvasOverviewController()
        controller.automaticallyPreparesOverview = false
        controller.loadViewIfNeeded()
        defer { controller.disposeCanvas() }
        let model = try await previewFixture(controller: controller, count: 2)
        controller.preparedModel = model
        controller.previewDemand = [999]
        controller.previewVisibleDemand = [999]
        var reads = 0
        controller.sourceReader = { _, _ in reads += 1; return [] }
        controller.startPreviewWorker(model: model)
        await waitUntil { controller.previewTask == nil }
        #expect(reads == 0 && controller.previewAttemptedIDs.isEmpty)
    }

    @Test(arguments: [false, true])
    func realStackSceneDoesNotCommitReadingUntilExpansionFinishes(reverse: Bool) async throws {
        let controller = NoteReviewCanvasOverviewController(startStackAnimation: { $0.pauseAnimation() })
        controller.automaticallyPreparesOverview = false
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        controller.view.layoutIfNeeded()
        defer { controller.disposeCanvas() }
        controller.stackAllIDs = Array(1...192)
        controller.selectedCount = 192
        controller.sourceReader = { ids, _ in ids.map(Self.previewSource) }
        let model = try await previewFixture(controller: controller, count: 96)
        controller.activeDirectoryRegion = controller.fixtureStack(containing: 24)?.region
        controller.commit(model: model, preservingCurrentID: 24, animatesEnvironmentChange: false)
        var currentEvents: [Int64] = []
        controller.onCurrentChanged = { currentEvents.append($0) }
        let originalZoom = controller.desktopScrollView.zoomScale
        let originalOffset = controller.desktopScrollView.contentOffset
        controller.presentStackBrowser()
        await controller.stackTask?.value
        let session = try #require(controller.stackSession)
        let opening = try #require(session.animator)
        opening.stopAnimation(false); opening.finishAnimation(at: .end)
        await controller.stackNeighborTask?.value
        #expect(controller.currentNoteID == 24 && currentEvents.isEmpty)
        let browser = try #require(controller.stackBrowser)
        let controls = try #require(browser.scrollView.accessibilityElements as? [UIControl])
        #expect(!controls.isEmpty)
        #expect(controls.allSatisfy { browser.scrollView.touchesShouldCancel(in: $0) })
        #expect(controls.compactMap(\.accessibilityIdentifier) == browser.previews.map { "review-stack-\($0.group.id.bucket)" })
        // A late callback from the now hidden real scroll surface must not replace the reading anchor.
        controller.desktopScrollView.contentOffset = .zero
        controller.scrollViewDidEndDecelerating(controller.desktopScrollView)
        #expect(controller.currentNoteID == 24 && currentEvents.isEmpty)
        controller.desktopScrollView.contentOffset = originalOffset
        #expect(controller.preparedModel?.canvasGeometry.indexByID.count == 96)
        #expect(controller.stackPreviews.count <= 5)
        #expect(controller.stackPreviews.reduce(0, { $0 + $1.pixelBytes }) <= CanvasStackContentRenderer.previewBudget)
        let next = try #require(controller.stackPreviews.first(where: { $0.group.id != session.group.id }))
        let rtl = CanvasStackBrowserView(frame: browser.bounds, reduced: true)
        rtl.semanticContentAttribute = .forceRightToLeft
        rtl.apply(controller.stackPreviews, preserving: session.group.id)
        #expect(rtl.focusedID == session.group.id)
        let currentPose = try #require(rtl.poses(for: session.group.id, in: rtl).values.first)
        let nextPose = try #require(rtl.poses(for: next.group.id, in: rtl).values.first)
        #expect(nextPose.center.x < currentPose.center.x)
        rtl.focus(next.group.id) {}
        #expect(rtl.focusedID == next.group.id)
        controller.expandStack(next.group.id)
        await controller.stackTask?.value
        #expect(currentEvents.isEmpty)
        let closing = try #require(session.animator)
        closing.fractionComplete = 0.5
        closing.stopAnimation(false); closing.finishAnimation(at: reverse ? .start : .end)
        if reverse {
            #expect(controller.stackBrowser != nil && controller.currentNoteID == 24)
            #expect(currentEvents.isEmpty)
            #expect(abs(controller.desktopScrollView.zoomScale - originalZoom) < 0.001)
            #expect(abs(controller.desktopScrollView.contentOffset.x - originalOffset.x) < 2)
            #expect(abs(controller.desktopScrollView.contentOffset.y - originalOffset.y) < 2)
        } else {
            #expect(controller.stackBrowser == nil && controller.currentNoteID == next.group.noteIDs.first)
            #expect(currentEvents == [try #require(next.group.noteIDs.first)])
            #expect(controller.transitionPreviewPins.isEmpty && controller.stackSession == nil)
        }
    }

    @Test(arguments: [1, 24])
    func productionParentCapturesRealReadingInkWithoutBakingScrollEdges(repetitions: Int) throws {
        let repository = RepositoryContainer(sheetPreviewDatabaseManager: DatabaseManager(database: try AppDatabase.empty()),
            userDefaults: try #require(UserDefaults(suiteName: "handoff-tests-\(UUID().uuidString)")))
        let item = NoteReviewCardItem(id: 7, bookID: 1, bookTitle: "交接验证", bookAuthor: "", bookCoverURL: "",
            chapterTitle: "真实父页面", contentHTML: "<p>" + String(repeating: "纸张中的文字始终保持清晰，回到原处继续阅读。", count: repetitions) + "</p>",
            ideaHTML: "", position: "", positionUnit: 0, includeTime: false, createdDate: 1,
            imageURLs: [], tags: [], weReadOriginalURL: nil)
        let parent = NoteReviewViewController(payload: NoteReviewLaunchPayload(selectedNoteID: 7, currentIndex: 0,
            loadedNoteIDs: [7], seedItems: [item], settings: .defaultValue), repositories: repository,
            toastCenter: XMToastCenter(), onDismiss: {}, onOpenDetail: { _, _ in }, onError: { _ in })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = parent
        window.isHidden = false
        defer { parent.disposeReviewSession(); window.isHidden = true; window.rootViewController = nil }
        parent.view.layoutIfNeeded()
        func findCell(_ view: UIView) -> NoteReviewCollectionCell? {
            if let cell = view as? NoteReviewCollectionCell { return cell }
            return view.subviews.lazy.compactMap(findCell).first
        }
        let cell = try #require(findCell(parent.view))
        let scroll = cell.activeContentScrollView
        if repetitions > 1 { scroll.setContentOffset(CGPoint(x: 0, y: 100), animated: false) }
        let offset = scroll.contentOffset
        let endpoint = try #require(cell.immersiveTransitionEndpoint(in: parent.view,
            insets: UIEdgeInsets(top: 132, left: 0, bottom: 98, right: 0), surfaceColor: .white,
            requestGeneration: 3))
        #expect(endpoint.identity?.noteID == 7 && endpoint.identity?.requestGeneration == 3)
        #expect(scroll.contentOffset == offset)
        #expect(endpoint.viewportImage != nil && endpoint.viewportFrame == parent.view.bounds)
        let pixels = try raster(size: endpoint.logicalSize) { context in
            UIGraphicsPushContext(context)
            endpoint.image.draw(at: .zero)
            UIGraphicsPopContext()
        }
        let ink = stride(from: 0, to: pixels.count, by: 4).filter {
            pixels[$0 + 3] > 200 && pixels[$0] < 128 && pixels[$0 + 1] < 128 && pixels[$0 + 2] < 128
        }.count
        #expect(ink > 100, "The production parent with native scroll edges must supply real opaque reading pixels.")
    }

    @Test
    func readingIdentityRejectsAnotherNoteOrRequestButAllowsDifferentLayoutVersions() {
        let source = NoteReviewCanvasReadingEndpoint.Identity(noteID: 7, requestGeneration: 3, contentVersion: 10, appearanceVersion: 2)
        #expect(source.belongsToSameRequest(as: .init(noteID: 7, requestGeneration: 3, contentVersion: 11, appearanceVersion: 6)))
        #expect(!source.belongsToSameRequest(as: .init(noteID: 8, requestGeneration: 3, contentVersion: 10, appearanceVersion: 2)))
        #expect(!source.belongsToSameRequest(as: .init(noteID: 7, requestGeneration: 4, contentVersion: 10, appearanceVersion: 2)))
    }

    @Test
    func coordinatorRevealsLiveOwnerBeforeRemovingProxyAndNotifiesOnlyAfterHandoff() {
        let coordinator = NoteReviewCanvasModeCoordinator()
        var handedOff = false
        var notified = false
        coordinator.request(.desktop)
        coordinator.onSurfaceChanged = {
            #expect(handedOff && coordinator.settledMode == .desktop)
            #expect(coordinator.state == .settling)
            notified = true
        }
        coordinator.settle(.desktop) {
            #expect(coordinator.state == .settling)
            handedOff = true
        }
        #expect(notified && coordinator.state == .idle && coordinator.requestedMode == nil)
        coordinator.dispose()
    }

    @Test(arguments: [CGFloat(0.3), 0.5, 0.8])
    func interruptedSceneKeepsRawPixelsSeparateFromOneNativeEdgeOwner(progress: CGFloat) throws {
        let host = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 740))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        let (source, target) = readingEndpoints()
        let scene = NoteReviewCanvasReadingScene(source: source, target: target, clip: host.view.bounds,
            sourceBackground: nil, targetBackground: nil)
        host.view.addSubview(scene)
        scene.render(progress)
        host.view.layoutIfNeeded()
        let frozen = try #require(scene.frozenContentSurface(in: host.view))
        host.view.addSubview(frozen)
        #expect(scene.paper.superview === scene.renderingContent)
        #expect(frozen.frame == scene.frame && frozen.contentOffset == .zero)
        let paper = NoteReviewCanvasReadingEndpoint.capture(scene.paper, in: host.view,
            backdropColor: scene.backgroundColor ?? .clear, surfaceColor: scene.paperColor ?? .clear,
            cornerRadius: scene.paperCornerRadius)
        let raw = frozen.contentForHandoff()
        #expect(!descendants(of: raw).contains { $0 is UIScrollView })
        let image = try #require((raw.subviews.first as? UIImageView)?.image)
        let pixels = try raster(size: image.size) { context in
            UIGraphicsPushContext(context)
            image.draw(at: .zero)
            UIGraphicsPopContext()
        }
        #expect(stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] > 200 })
        let continuation = NoteReviewCanvasReadingScene(source: paper, target: target, clip: host.view.bounds,
            sourceBackground: raw, targetBackground: nil)
        host.view.addSubview(continuation)
        scene.removeFromSuperview()
        frozen.removeFromSuperview()
        continuation.render(0)
        expectColor(try #require(continuation.backgroundColor), matches: try #require(scene.backgroundColor))
        expectColor(try #require(continuation.paperColor), matches: try #require(scene.paperColor))
        #expect(continuation.paperCornerRadius == scene.paperCornerRadius)
        #expect(raw.superview === continuation.renderingContent)
        #expect(abs(continuation.paper.center.x - paper.frame.midX) < 0.001)
        #expect(abs(continuation.paper.center.y - paper.frame.midY) < 0.001)
    }

    @Test
    func explicitTaskViewerDoesNotRestoreOrReplaceAnOlderSceneSelection() {
        let source = ContentViewerSourceContext.noteReview(noteIDs: [7, 8, 9])
        let oldSelection = ContentViewerSceneSnapshot(source: source, selectedItemID: .note(8))
        let store = SceneStateStore()
        store.restore(from: nil, currentDataEpoch: 0)
        store.updateContentViewer(oldSelection)
        let persisted = store.persistedData
        let viewer = ContentViewerView(source: source, initialItemID: .note(9), keyword: "",
            restoresSelectionFromScene: false)
        #expect(viewer.restoredSelection(from: store.snapshot.contentViewer) == nil)
        #expect(viewer.initialItemID == .note(9))
        viewer.persistSelection(.note(9), in: store)
        #expect(store.snapshot.contentViewer == oldSelection && store.persistedData == persisted)
    }

    @Test
    func restorableViewerKeepsItsExistingMatchingScopeReadAndWritePolicy() {
        let source = ContentViewerSourceContext.noteReview(noteIDs: [7, 8, 9])
        let oldSelection = ContentViewerSceneSnapshot(source: source, selectedItemID: .note(8))
        let viewer = ContentViewerView(source: source, initialItemID: .note(9), keyword: "")
        #expect(viewer.restoresSelectionFromScene)
        #expect(viewer.restoredSelection(from: oldSelection) == .note(8))
        #expect(viewer.restoredSelection(from: nil) == nil)
        #expect(viewer.restoredSelection(from: ContentViewerSceneSnapshot(
            source: .noteReview(noteIDs: [7, 9]), selectedItemID: .note(7))) == nil)
        let store = SceneStateStore()
        store.restore(from: nil, currentDataEpoch: 0)
        store.updateContentViewer(oldSelection)
        viewer.persistSelection(.note(9), in: store)
        #expect(store.snapshot.contentViewer == ContentViewerSceneSnapshot(source: source, selectedItemID: .note(9)))
        viewer.persistSelection(nil, in: store)
        #expect(store.snapshot.contentViewer?.selectedItemID == .note(9))
    }

    @Test
    func immediateAndSamePositionDesktopRequestsFinishAndReportSharpDemand() async throws {
        let controller = try await positioningController()
        defer { controller.disposeCanvas() }
        var demands: [[Int64]] = []
        controller.onDemand = { visible, _ in demands.append(visible) }
        controller.positionDesktop(on: 10, zoomScale: 0.95, animated: false)
        #expect(controller.pendingProgrammaticPosition == nil && !controller.isPositioningViewport)
        #expect(demands.last?.contains(10) == true && controller.currentNoteID == 10)
        let offset = controller.desktopScrollView.contentOffset
        let scale = controller.desktopScrollView.zoomScale
        demands.removeAll()
        controller.positionDesktop(on: 10, zoomScale: scale, animated: true)
        #expect(controller.pendingProgrammaticPosition == nil && !controller.isPositioningViewport)
        #expect(controller.desktopScrollView.contentOffset == offset && controller.desktopScrollView.zoomScale == scale)
        #expect(demands.last?.contains(10) == true && controller.desktopViewport?.noteID == 10)
    }

    @Test
    func automaticZoomCompletionReportsDemandWithoutAUserDragOrChangingIdentity() async throws {
        let controller = try await positioningController()
        defer { controller.disposeCanvas() }
        controller.desktopScrollView.setContentOffset(.zero, animated: false)
        var demands: [[Int64]] = []
        controller.onDemand = { visible, _ in demands.append(visible) }
        controller.beginProgrammaticPositioning(mode: .desktop, noteID: 10)
        #expect(controller.isPositioningViewport)
        controller.scrollViewDidEndZooming(controller.desktopScrollView, with: controller.zoomContentView,
            atScale: controller.desktopScrollView.zoomScale)
        #expect(controller.pendingProgrammaticPosition == nil && !controller.isPositioningViewport)
        #expect(demands.last?.contains(10) == true && controller.currentNoteID == 10)
        #expect(controller.desktopViewport?.noteID == 10)
        let completedDemandCount = demands.count
        controller.finishProgrammaticPositioning(in: controller.desktopScrollView)
        #expect(demands.count == completedDemandCount)
    }

    @Test
    func cachedPreviewDemandInvalidatesPreviouslyRasterizedDesktopTilesWithoutReadingAgain() async throws {
        let controller = try await positioningController()
        defer { controller.disposeCanvas() }
        let model = try #require(controller.preparedModel)
        try await controller.warmPreviews(ids: [10], model: model, work: nil, modes: [.desktop], protectsTransition: true)
        controller.cancelPreviewWorker()
        controller.cancelProgrammaticPositioning()
        let layer = controller.zoomContentView.canvasView.layer
        layer.displayIfNeeded()
        #expect(!layer.needsDisplay())
        var reads = 0
        controller.sourceReader = { _, _ in reads += 1; return [] }
        try await controller.warmPreviews(ids: [10, 10], model: model, work: nil, modes: [.desktop])
        #expect(reads == 0)
        #expect(layer.needsDisplay())
        #expect(controller.previewsAreReady(for: 10, in: model, modes: [.desktop]))
    }

    @Test
    func panoramaTransitionPreparesExchangeBothSidesWithoutDemandingInvisibleCounterparts() async throws {
        let controller = try await positioningController()
        defer { controller.disposeCanvas() }
        let template = try #require(controller.makeTransitionPlan(anchorNoteID: 10))
        let kinds: [CanvasOverviewSceneCardKind] = [.migrate, .exchange, .exit, .enter]
        var cards: [CanvasOverviewSceneCard] = []
        for (index, kind) in kinds.enumerated() {
            let id = Int64(index + 1)
            cards.append(CanvasOverviewSceneCard(
                desktop: try #require(controller.endpoint(in: .desktop, noteID: id)),
                waterfall: try #require(controller.endpoint(in: .waterfall, noteID: id)),
                kind: kind, isAnchor: index == 0, delay: 0))
        }
        let plan = CanvasOverviewTransitionPlan(clip: template.clip, cards: cards,
            desktopVisible: [], waterfallVisible: [], style: template.style, isPanorama: true,
            focusRatio: template.focusRatio, desktopAnchor: template.desktopAnchor, focusAnchor: template.focusAnchor,
            screenScale: template.screenScale, generation: template.generation,
            desktopCanvasRect: template.desktopCanvasRect, model: template.model)
        let demand = controller.transitionPreviewDemand(for: plan)
        #expect(demand.desktop == [1, 2, 3])
        #expect(demand.waterfall == [1, 2, 4])
    }

    @Test
    func desktopObjectMenuCancelsPendingModePreparationWithoutChangingItsReadingIdentity() async throws {
        let controller = try await positioningController()
        let window = UIWindow(frame: controller.view.bounds)
        window.addSubview(controller.view)
        defer {
            controller.disposeCanvas()
            controller.view.removeFromSuperview()
        }
        let model = try #require(controller.preparedModel)
        let paper = try #require(model.canvasGeometry.paper(for: 10))
        let location = controller.desktopScrollView.convert(
            CGPoint(x: paper.frame.midX, y: paper.frame.midY), from: controller.zoomContentView.canvasView)
        let interaction = try #require(controller.desktopObjectMenuInteraction)
        var menuTargets: [Int64] = []
        var directManipulations = 0
        controller.onNoteActionMenu = { id in
            menuTargets.append(id)
            return UIMenu(children: [UIAction(title: "详情") { _ in }])
        }
        controller.onUserInteractionBegan = { directManipulations += 1 }
        controller.requestMode(.waterfall)
        #expect(controller.transitionState == .preparing && controller.pendingMode == .waterfall)
        let preparation = try #require(controller.transitionWarmTask)
        let configuration = try #require(controller.contextMenuInteraction(interaction,
            configurationForMenuAtLocation: location))
        #expect(configuration.identifier as? NSNumber == NSNumber(value: 10))
        #expect(menuTargets == [10] && directManipulations == 1)
        #expect(preparation.isCancelled && controller.transitionWarmTask == nil)
        #expect(controller.transitionState == .idle && controller.pendingMode == nil)
        #expect(controller.currentMode == .desktop && controller.currentNoteID == 10)
        #expect(controller.isObjectMenuPresented && controller.objectMenuConfiguration === configuration)
        #expect(controller.desktopScrollView.alpha == 1 && controller.waterfallView.alpha == 0)
        await preparation.value
        #expect(controller.transitionContext == nil && controller.currentMode == .desktop)
        #expect(controller.currentNoteID == 10)
        #expect(controller.preparedModel?.canvasGeometry.spatialIndex.generation == model.canvasGeometry.spatialIndex.generation)
        controller.endObjectMenu(configuration, animator: nil)
        #expect(!controller.isObjectMenuPresented)
    }

    @Test
    func identicalRasterRequestsShareWorkAndOneCancelledConsumerDoesNotCancelAnother() async {
        let cache = CanvasOverviewRasterPreparationCache()
        let queue = DispatchQueue(label: "canvas-test-shared-raster")
        let image = readingInk(size: CGSize(width: 80, height: 100))
        let key = CanvasOverviewRasterPreparationKey(generation: 1, modelGeneration: UUID(), kind: .reading(noteID: 7, mode: 0),
            rect: CGRect(x: 0, y: 0, width: 220, height: 180), outputSize: image.size, scale: 2)
        queue.suspend()
        let first = Task { await cache.image(for: key, queue: queue) { _ in image } }
        await waitUntil { cache.activeCount == 1 }
        let second = Task { await cache.image(for: key, queue: queue) { _ in image } }
        await waitUntil { cache.hitCount == 1 }
        #expect(cache.buildCount == 1 && cache.activeCount == 1)
        first.cancel()
        queue.resume()
        let firstImage = await first.value
        let secondImage = await second.value
        #expect(firstImage == nil && secondImage === image)
        let cached = await cache.image(for: key, queue: queue) { _ in nil }
        #expect(cached === image && cache.buildCount == 1 && cache.hitCount == 2)
        #expect(cache.activeCount == 0)
        cache.removeAll()
    }

    @Test
    func invalidatedRasterPreparationCannotReturnItsOldImageOrPopulateTheNewCache() async {
        let cache = CanvasOverviewRasterPreparationCache()
        let queue = DispatchQueue(label: "canvas-test-cancel-raster")
        let image = readingInk(size: CGSize(width: 80, height: 100))
        let modelGeneration = UUID()
        let rect = CGRect(x: 0, y: 0, width: 220, height: 180)
        let key = CanvasOverviewRasterPreparationKey(generation: 1, modelGeneration: modelGeneration, kind: .viewport,
            rect: rect, outputSize: image.size, scale: 2)
        queue.suspend()
        let first = Task { await cache.image(for: key, queue: queue) { _ in image } }
        await waitUntil { cache.activeCount == 1 }
        let second = Task { await cache.image(for: key, queue: queue) { _ in image } }
        await waitUntil { cache.hitCount == 1 }
        cache.removeAll()
        queue.resume()
        let firstImage = await first.value
        let secondImage = await second.value
        #expect(firstImage == nil && secondImage == nil && cache.activeCount == 0)
        let rebuilt = await cache.image(for: key, queue: queue) { _ in image }
        #expect(rebuilt === image && cache.buildCount == 2)
        let distinct = [key,
            CanvasOverviewRasterPreparationKey(generation: 2, modelGeneration: modelGeneration, kind: .viewport, rect: rect, outputSize: image.size, scale: 2),
            CanvasOverviewRasterPreparationKey(generation: 1, modelGeneration: UUID(), kind: .viewport, rect: rect, outputSize: image.size, scale: 2),
            CanvasOverviewRasterPreparationKey(generation: 1, modelGeneration: modelGeneration, kind: .reading(noteID: 7, mode: 0), rect: rect, outputSize: image.size, scale: 2),
            CanvasOverviewRasterPreparationKey(generation: 1, modelGeneration: modelGeneration, kind: .viewport, rect: rect.offsetBy(dx: 1, dy: 0), outputSize: image.size, scale: 2),
            CanvasOverviewRasterPreparationKey(generation: 1, modelGeneration: modelGeneration, kind: .viewport, rect: rect, outputSize: image.size, scale: 3),
            CanvasOverviewRasterPreparationKey(generation: 1, modelGeneration: modelGeneration, kind: .viewport, rect: rect, outputSize: image.size, scale: 2, contentState: 1)]
        #expect(Set(distinct).count == distinct.count)
        cache.removeAll()
    }

    @Test
    func aThirdRasterKeyWaitsForCapacityWithoutCancellingProtectedEndpoints() async {
        let cache = CanvasOverviewRasterPreparationCache()
        let queue = DispatchQueue(label: "canvas-test-raster-capacity")
        let image = readingInk(size: CGSize(width: 80, height: 100))
        let model = UUID()
        let keys = (1...3).map { CanvasOverviewRasterPreparationKey(generation: 1, modelGeneration: model,
            kind: .reading(noteID: Int64($0), mode: 0), rect: CGRect(origin: .zero, size: image.size),
            outputSize: image.size, scale: 2) }
        queue.suspend()
        let first = Task { await cache.image(for: keys[0], queue: queue) { _ in image } }
        let second = Task { await cache.image(for: keys[1], queue: queue) { _ in image } }
        await waitUntil { cache.activeCount == 2 }
        var thirdStarted = false
        let third = Task {
            thirdStarted = true
            return await cache.image(for: keys[2], queue: queue) { _ in image }
        }
        await waitUntil { thirdStarted }
        #expect(cache.activeCount == 2 && cache.buildCount == 2)
        queue.resume()
        let a = await first.value, b = await second.value, c = await third.value
        #expect(a === image && b === image && c === image)
        #expect(cache.activeCount == 0 && cache.buildCount == 3)
        #expect(cache.cachedBytes > 0 && cache.cachedBytes <= 16 * 1_024 * 1_024)
        cache.removeAll()
        #expect(cache.cachedBytes == 0)
    }

    private func positioningController() async throws -> NoteReviewCanvasOverviewController {
        let controller = NoteReviewCanvasOverviewController()
        controller.automaticallyPreparesOverview = false
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 700)
        controller.view.layoutIfNeeded()
        controller.sourceReader = { ids, _ in ids.map(Self.previewSource) }
        let model = try await previewFixture(controller: controller, count: 20)
        controller.commit(model: model, preservingCurrentID: 10, animatesEnvironmentChange: false)
        controller.cancelProgrammaticPositioning()
        controller.cancelPreviewWorker()
        return controller
    }

    @Test
    func actionItemUsesItsExplicitCachedIdentityAndRejectsAnOlderContentGeneration() async throws {
        let (session, repository) = deletionSession(ids: [7, 8, 9], current: 8)
        defer { session.dispose() }
        let first = try await session.fetchActionItem(noteID: 7)
        #expect(first.id == 7 && session.currentNoteID == 8 && repository.itemReads.isEmpty)
        session.updateVisibleIDs([7])
        let updated = first.replacingTags([NoteEditorTagOption(id: 33, title: "新版本")])
        repository.reviewItems = repository.reviewItems?.map { $0.id == 7 ? updated : $0 }
        #expect(await session.replaceTags([NoteEditorTagOption(id: 22, title: "当前项")], noteID: 8))
        session.handleMemoryWarning()
        let second = try await session.fetchActionItem(noteID: 7)
        #expect(second.id == 7 && second.tags.map(\.id) == [33])
        #expect(repository.itemReads == [[7]] && session.currentNoteID == 8)
    }

    @Test
    func concurrentActionReadsShareOneQueryAndOneCancelledMenuDoesNotCancelTheOther() async throws {
        let (session, repository) = deletionSession(ids: [7, 8, 9], current: 8, seedsOnlyCurrent: true)
        defer { session.dispose() }
        let gate = CanvasTestLatch()
        let items = try #require(repository.reviewItems)
        repository.itemReader = { ids in await gate.wait(); return items.filter { ids.contains($0.id) } }
        let first = Task { try await session.fetchActionItem(noteID: 7) }
        await waitUntil { repository.itemReads.count == 1 }
        var secondStarted = false
        let second = Task {
            secondStarted = true
            return try await session.fetchActionItem(noteID: 7)
        }
        await waitUntil { secondStarted }
        session.prefetch(noteIDs: [7])
        #expect(repository.itemReads == [[7]])
        first.cancel()
        gate.open()
        do {
            _ = try await first.value
            Issue.record("Cancelled action consumer must not receive the shared result")
        } catch is CancellationError { }
        let result = try await second.value
        #expect(result.id == 7 && session.currentNoteID == 8 && session.item(for: 7)?.id == 7)
        #expect(repository.itemReads == [[7]])
    }

    @Test
    func actionReadJoinsAnExistingPrefetchBatchAndKeepsItProtected() async throws {
        let (session, repository) = deletionSession(ids: [7, 8, 9], current: 8, seedsOnlyCurrent: true)
        defer { session.dispose() }
        let gate = CanvasTestLatch()
        let items = try #require(repository.reviewItems)
        repository.itemReader = { ids in await gate.wait(); return items.filter { ids.contains($0.id) } }
        session.prefetch(noteIDs: [7, 9])
        await waitUntil { repository.itemReads.count == 1 }
        var started = false
        let action = Task {
            started = true
            return try await session.fetchActionItem(noteID: 7)
        }
        await waitUntil { started }
        session.cancelAllPrefetch()
        gate.open()
        let result = try await action.value
        #expect(result.id == 7 && session.currentNoteID == 8)
        #expect(repository.itemReads == [[7, 9]])
    }

    @Test
    func actionResultsCannotPopulateCacheAfterManifestReplacementOrDisposal() async throws {
        for disposes in [false, true] {
            let (session, repository) = deletionSession(ids: [7, 8, 9], current: 8, seedsOnlyCurrent: true)
            defer { session.dispose() }
            let gate = CanvasTestLatch()
            let items = try #require(repository.reviewItems)
            repository.itemReader = { ids in await gate.wait(); return items.filter { ids.contains($0.id) } }
            let action = Task { try await session.fetchActionItem(noteID: 7) }
            await waitUntil { repository.itemReads.count == 1 }
            if disposes { session.dispose() } else { session.refreshCanvasSnapshot() }
            gate.open()
            do {
                _ = try await action.value
                Issue.record("An action from a retired generation must not be delivered")
            } catch is CancellationError { }
            #expect(session.item(for: 7) == nil)
            #expect(repository.itemReads == [[7]])
        }
    }

    @Test
    func deletingExplicitTargetDeduplicatesRequestsWithoutReplacingAnotherCurrentNote() async throws {
        let (session, repository) = deletionSession(ids: [7, 8, 9], current: 8)
        defer { session.dispose() }
        let gate = CanvasTestLatch()
        repository.deletion = { _ in await gate.wait() }
        await waitUntil { repository.dataChanges != nil }
        var invalidations = 0
        session.onOverviewInvalidated = { invalidations += 1 }
        let first = Task { try await session.deleteNote(noteID: 7) }
        await waitUntil { repository.deleteCalls.count == 1 }
        var duplicateStarted = false
        let duplicate = Task {
            duplicateStarted = true
            try await session.deleteNote(noteID: 7)
        }
        await waitUntil { duplicateStarted }
        #expect(repository.deleteCalls == [[7]])
        #expect(session.deletingNoteIDs == [7])
        #expect(session.currentNoteID == 8 && session.orderedIDs == [7, 8, 9])
        gate.open()
        try await first.value
        try await duplicate.value
        #expect(session.deletingNoteIDs.isEmpty)
        #expect(session.currentNoteID == 8 && session.orderedIDs == [7, 8, 9])
        repository.reviewIDs = [8, 9]
        repository.dataChanges?.yield(())
        await waitUntil { session.orderedIDs == [8, 9] }
        #expect(session.currentNoteID == 8 && session.currentIndex == 0)
        #expect(session.item(for: 8)?.id == 8 && invalidations == 0)
        #expect(repository.deleteCalls == [[7]])
    }

    @Test
    func failedDeletionKeepsTheOriginalListAndAllowsTheSameTargetToRetry() async throws {
        let (session, repository) = deletionSession(ids: [7, 8, 9], current: 8)
        defer { session.dispose() }
        repository.deletion = { _ in throw CanvasTestFailure.injected }
        do {
            try await session.deleteNote(noteID: 8)
            Issue.record("Injected deletion failure must propagate to the operation owner")
        } catch CanvasTestFailure.injected { }
        #expect(session.orderedIDs == [7, 8, 9] && session.currentNoteID == 8)
        #expect(session.deletingNoteIDs.isEmpty)
        repository.deletion = { _ in }
        try await session.deleteNote(noteID: 8)
        #expect(repository.deleteCalls == [[8], [8]])
        #expect(session.deletingNoteIDs.isEmpty)
        #expect(session.orderedIDs == [7, 8, 9] && session.currentNoteID == 8)
    }

    @Test
    func deletionObservationSelectsNextThenPreviousAndFinallyARealEmptyList() async throws {
        let (session, repository) = deletionSession(ids: [7, 8, 9], current: 8)
        defer { session.dispose() }
        repository.deletion = { _ in }
        await waitUntil { repository.dataChanges != nil }
        for (target, survivors, expectedCurrent) in [
            (Int64(8), [Int64(7), 9], Int64(9)), (Int64(9), [Int64(7)], Int64(7)), (Int64(7), [], Int64(0))
        ] {
            let original = session.orderedIDs
            try await session.deleteNote(noteID: target)
            #expect(session.orderedIDs == original && session.currentNoteID == target)
            repository.reviewIDs = survivors
            repository.dataChanges?.yield(())
            await waitUntil { session.orderedIDs == survivors }
            #expect(session.currentNoteID == expectedCurrent && session.count == survivors.count)
        }
        #expect(session.noteID(at: 0) == nil && session.index(of: 7) == nil)
        #expect(repository.deleteCalls == [[8], [9], [7]])
    }

    @Test
    func delayedDeletionManifestCannotUndoASelectionMadeWhileItsReadWasAwaiting() async throws {
        let (session, repository) = deletionSession(ids: [7, 8, 9], current: 8)
        let gate = CanvasTestLatch()
        defer { gate.open(); session.dispose() }
        repository.deletion = { _ in }
        repository.idReader = { await gate.wait(); return [8, 9] }
        var commits = 0
        session.onManifestChanged = { commits += 1 }
        await waitUntil { repository.dataChanges != nil }
        try await session.deleteNote(noteID: 7)
        repository.dataChanges?.yield(())
        await waitUntil { repository.idReads == 1 }
        #expect(session.currentNoteID == 8 && session.orderedIDs == [7, 8, 9])
        session.setCurrentNoteID(9)
        #expect(session.currentNoteID == 9)
        gate.open()
        await waitUntil { commits == 1 }
        #expect(session.orderedIDs == [8, 9] && session.currentNoteID == 9)
        #expect(session.index(of: 9) == 1 && session.index(of: 7) == nil)
        #expect(repository.idReads == 1 && repository.deleteCalls == [[7]])
    }

    @Test
    func deletionObservationRefreshesSurvivingFullContentAndTagsWithoutASecondOverviewInvalidation() async throws {
        let (session, repository) = deletionSession(ids: [7, 8, 9], current: 8)
        defer { session.dispose() }
        let original = try #require(session.item(for: 8))
        let updated = NoteReviewCardItem(id: original.id, bookID: original.bookID,
            bookTitle: original.bookTitle, bookAuthor: original.bookAuthor, bookCoverURL: original.bookCoverURL,
            chapterTitle: original.chapterTitle, contentHTML: "<p>与删除一同回流的新正文</p>",
            ideaHTML: "<p>同一次更新的新想法</p>", position: original.position, positionUnit: original.positionUnit,
            includeTime: original.includeTime, createdDate: original.createdDate, imageURLs: original.imageURLs,
            tags: [NoteEditorTagOption(id: 88, title: "更新后的标签")], weReadOriginalURL: original.weReadOriginalURL)
        var manifestCommits = 0
        var overviewInvalidations = 0
        session.onManifestChanged = { manifestCommits += 1 }
        session.onOverviewInvalidated = { overviewInvalidations += 1 }
        repository.deletion = { _ in }
        await waitUntil { repository.dataChanges != nil }
        try await session.deleteNote(noteID: 7)
        repository.reviewItems = repository.reviewItems?.map { $0.id == 8 ? updated : $0 }
        repository.reviewIDs = [8, 9]
        repository.dataChanges?.yield(())
        await waitUntil { manifestCommits == 1 }
        await waitUntil { session.item(for: 8)?.contentHTML == updated.contentHTML }
        let actionItem = try await session.fetchActionItem(noteID: 8)
        #expect(actionItem.contentHTML == updated.contentHTML && actionItem.ideaHTML == updated.ideaHTML)
        #expect(actionItem.tags.map(\.id) == [88] && original.tags.isEmpty)
        #expect(session.item(for: 8)?.contentHTML == updated.contentHTML)
        #expect(session.item(for: 8)?.tags.map(\.id) == [88])
        #expect(session.orderedIDs == [8, 9] && session.currentNoteID == 8)
        #expect(repository.itemReads.contains { $0.contains(8) })
        #expect(overviewInvalidations == 0 && repository.deleteCalls == [[7]])
    }

    private func deletionSession(ids: [Int64], current: Int64,
                                 seedsOnlyCurrent: Bool = false) -> (NoteReviewUIKitSession, CanvasTestNoteRepository) {
        let repository = CanvasTestNoteRepository()
        let items = ids.map { id in
            NoteReviewCardItem(id: id, bookID: 1, bookTitle: "书", bookAuthor: "", bookCoverURL: "",
                chapterTitle: "章节", contentHTML: "<p>正文 \(id)</p>", ideaHTML: "", position: "", positionUnit: 0,
                includeTime: false, createdDate: 1, imageURLs: [], tags: [], weReadOriginalURL: nil)
        }
        repository.reviewIDs = ids
        repository.reviewItems = items
        let payload = NoteReviewLaunchPayload(selectedNoteID: current, currentIndex: ids.firstIndex(of: current) ?? 0,
            loadedNoteIDs: ids, seedItems: seedsOnlyCurrent ? items.filter { $0.id == current } : items, settings: .defaultValue)
        let session = NoteReviewUIKitSession(payload: payload, repository: repository)
        session.automaticallyPreparesOverview = false
        return (session, repository)
    }

    @Test
    func deletionReusesExactContentAfterEvictionAndKeepsOriginalColumnsEvenForOneSurvivor() async throws {
        let controller = NoteReviewCanvasOverviewController()
        controller.automaticallyPreparesOverview = false
        defer { controller.disposeCanvas() }
        let original = try await previewFixture(controller: controller, count: 20, rich: true)
        controller.previewStore.removeUnprotected()
        #expect(original.notes.allSatisfy { $0.payload == nil })
        #expect(original.canvasGeometry.papers.allSatisfy { $0.contentGeometry.preparedBlocks == nil })
        #expect(original.canvasGeometry.columnCount > 1)
        let viewport = CGSize(width: 402, height: 700)
        let anchor = CGPoint(x: 181, y: 272)
        let zoom: CGFloat = 0.6
        for survivors: [Int64] in [[2, 4, 8, 11, 16, 20], [8]] {
            let prepared = await withCheckedContinuation { continuation in
                controller.preparationQueue.async {
                    continuation.resume(returning: CanvasOverviewDeletionModelBuilder.build(model: original,
                        survivingIDs: survivors, viewportSize: viewport, screenScale: 1,
                        anchorID: 8, anchor: anchor, zoomScale: zoom))
                }
            }
            let model = try #require(prepared)
            #expect(model.notes.map(\.id) == survivors)
            #expect(model.canvasGeometry.columnCount == original.canvasGeometry.columnCount)
            #expect(model.canvasGeometry.cardWidth == original.canvasGeometry.cardWidth)
            for (index, id) in survivors.enumerated() {
                let oldPaper = try #require(original.canvasGeometry.paper(for: id))
                let paper = try #require(model.canvasGeometry.paper(for: id))
                #expect(paper.index == index && model.canvasGeometry.indexByID[id] == index)
                #expect(paper.frame.size == oldPaper.frame.size && paper.rotation == oldPaper.rotation)
                #expect(paper.contentGeometry.key == oldPaper.contentGeometry.key)
                #expect(paper.contentGeometry.quoteRect == oldPaper.contentGeometry.quoteRect)
                #expect(paper.contentGeometry.chapterRect == oldPaper.contentGeometry.chapterRect)
                #expect(model.canvasGeometry.paper(at: CGPoint(x: paper.frame.midX, y: paper.frame.midY))?.noteID == id)
                let oldFlowIndex = try #require(original.waterfallGeometry.indexByID[id])
                #expect(model.waterfallGeometry.frames[index].size == original.waterfallGeometry.frames[oldFlowIndex].size)
                #expect(model.waterfallGeometry.contentGeometries[index].key == original.waterfallGeometry.contentGeometries[oldFlowIndex].key)
                let flowFrame = model.waterfallGeometry.frames[index]
                #expect(model.waterfallGeometry.spatialIndex.hitTest(CGPoint(x: flowFrame.midX, y: flowFrame.midY)) == id)
            }
            let paper = try #require(model.canvasGeometry.paper(for: 8))
            #expect(abs((paper.frame.midX - model.initialViewportRect.minX) * zoom - anchor.x) < 0.0001)
            #expect(abs((paper.frame.midY - model.initialViewportRect.minY) * zoom - anchor.y) < 0.0001)
            #expect(model.canvasGeometry.paper(for: 1) == nil && model.waterfallGeometry.indexByID[1] == nil)
            #expect(model.overviewImage != nil && model.initialViewportImage == nil)
        }
        #expect(original.notes.count == 20 && original.canvasGeometry.paper(for: 1) != nil)
    }

    @Test
    func deletionCommitInstallsPreparedViewportBeforeReturningDisplayOwnership() async throws {
        let controller = try await positioningController()
        defer { controller.disposeCanvas() }
        controller.renderingSettings = .defaultValue
        let original = try #require(controller.preparedModel)
        let sourceAnchor = try #require(controller.paperPose(in: .desktop, noteID: 10))
        let scale = controller.desktopScrollView.zoomScale
        let survivors = original.notes.map(\.id).filter { $0 != 10 }
        var settled = false
        controller.onReady = { settled = true }
        controller.isObjectMenuPresented = true
        #expect(controller.queueDeletionSnapshotIfPossible(ids: survivors, currentID: 11, settings: .defaultValue))
        #expect(controller.preparedModel?.notes.count == 20 && controller.deletionUpdate == nil)
        controller.isObjectMenuPresented = false
        let update = try #require(controller.deletionUpdate)
        let preparation = try #require(update.task)
        await preparation.value
        let committed = try #require(controller.preparedModel)
        let image = try #require(controller.zoomContentView.viewportUnderlayView.image)
        let bitmap = try #require(image.cgImage)
        #expect(committed.initialViewportImage == nil)
        #expect(image !== committed.overviewImage && image.size == controller.desktopScrollView.bounds.size)
        if controller.traitCollection.displayScale > 0 {
            #expect(image.scale == controller.traitCollection.displayScale)
        }
        #expect(abs(CGFloat(bitmap.width) - image.size.width * image.scale) < 1)
        #expect(abs(CGFloat(bitmap.height) - image.size.height * image.scale) < 1)
        #expect(controller.zoomContentView.underlayGeneration == controller.generation)
        let visibleIDs = committed.canvasGeometry.indexes(in: committed.initialViewportRect).map { committed.notes[$0].id }
        #expect(!visibleIDs.isEmpty && visibleIDs.allSatisfy {
            controller.previewsAreReady(for: $0, in: committed, modes: [.desktop])
        })
        #expect(committed.notes.map(\.id) == survivors)
        #expect(committed.canvasGeometry.columnCount == original.canvasGeometry.columnCount)
        #expect(controller.zoomContentView.viewportUnderlayView.image === image)
        #expect(controller.zoomContentView.viewportUnderlayView.frame == committed.initialViewportRect)
        #expect(!controller.zoomContentView.viewportUnderlayView.isHidden)
        #expect(update.scene?.superview === controller.view && !settled)
        #expect(controller.flushDeletionForModeRequest())
        #expect(controller.deletionUpdate == nil && update.scene?.superview == nil && settled)
        #expect(controller.transitionPreviewPins.isEmpty && controller.currentNoteID == 11)
        #expect(controller.desktopScrollView.zoomScale == scale)
        let finalAnchor = try #require(controller.paperPose(in: .desktop, noteID: 11))
        #expect(abs(finalAnchor.center.x - sourceAnchor.center.x) <= 2)
        #expect(abs(finalAnchor.center.y - sourceAnchor.center.y) <= 2)
        #expect(controller.zoomContentView.viewportUnderlayView.image === image)
    }

    @Test
    func deletionWithASurvivorEditRebuildsThatRevisionBeforeHandingBackTheCanvas() async throws {
        let controller = try await positioningController()
        defer { controller.disposeCanvas() }
        controller.renderingSettings = .defaultValue
        let original = try #require(controller.preparedModel)
        let oldNote = try #require(original.noteByID[10])
        #expect(original.isRealData)
        let oldPaper = try #require(original.canvasGeometry.paper(for: 10))
        let survivors = original.notes.map(\.id).filter { $0 != 1 }
        let revised = NoteReviewOverviewLayoutSource(noteID: 10,
            contentHTML: "<p>删除时同时编辑的正文。" + String(repeating: "新的段落必须重新测量，不能继续重放旧字形。", count: 30) + "</p>",
            ideaHTML: "<p>更新后的想法</p>", bookTitle: "更新后的书名", chapterTitle: "更新后的章节",
            noteUpdatedDate: 2, bookUpdatedDate: 3, chapterUpdatedDate: 4)
        var reads: [[Int64]] = []
        controller.sourceReader = { ids, _ in
            reads.append(ids)
            return ids.map { $0 == 10 ? revised : Self.previewSource($0) }
        }
        #expect(controller.queueDeletionSnapshotIfPossible(ids: survivors, currentID: 10, settings: .defaultValue))
        let update = try #require(controller.deletionUpdate)
        let preparation = try #require(update.task)
        await preparation.value
        let committed = try #require(controller.preparedModel)
        let note = try #require(committed.noteByID[10])
        let paper = try #require(committed.canvasGeometry.paper(for: 10))
        #expect(note.revision == CanvasOverviewSourceRevision(revised) && note.revision != oldNote.revision)
        #expect(paper.contentGeometry.key != oldPaper.contentGeometry.key)
        #expect(paper.frame.height > oldPaper.frame.height)
        #expect(note.quote.hasPrefix("删除时同时编辑的正文。") && note.bookTitle == revised.bookTitle)
        #expect(note.chapter == revised.chapterTitle)
        #expect(committed.notes.map(\.id) == survivors && committed.canvasGeometry.paper(for: 1) == nil)
        #expect(committed.canvasGeometry.columnCount == original.canvasGeometry.columnCount)
        #expect(committed.canvasGeometry.cardWidth == original.canvasGeometry.cardWidth)
        #expect(reads.first == survivors && reads.allSatisfy { $0.count <= 128 && !$0.contains(1) })
        #expect(controller.previewsAreReady(for: 10, in: committed, modes: [.desktop]))
        #expect(controller.zoomContentView.viewportUnderlayView.image != nil)
        #expect(controller.flushDeletionForModeRequest())
        #expect(controller.currentNoteID == 10 && controller.deletionUpdate == nil)
    }

    @Test
    func deletionRejectsCancelledMissingAndDuplicateSnapshotsWithoutChangingTrustedGeometry() async throws {
        let controller = NoteReviewCanvasOverviewController()
        controller.automaticallyPreparesOverview = false
        defer { controller.disposeCanvas() }
        let model = try await previewFixture(controller: controller, count: 20)
        let cancellation = CanvasOverviewTransitionPreparation()
        cancellation.cancel()
        let rejected = await withCheckedContinuation { continuation in
            controller.preparationQueue.async {
                let candidates: [([Int64], Int64, CanvasOverviewTransitionPreparation?)] = [
                    ([8], 8, cancellation), ([], 8, nil), ([8, 8], 8, nil), ([8, 99], 8, nil), ([8], 1, nil)
                ]
                continuation.resume(returning: candidates.map { ids, anchor, work in
                    CanvasOverviewDeletionModelBuilder.build(model: model, survivingIDs: ids,
                        viewportSize: CGSize(width: 402, height: 700), screenScale: 1,
                        anchorID: anchor, anchor: CGPoint(x: 201, y: 350), zoomScale: 0.95,
                        cancellation: work) == nil
                })
            }
        }
        #expect(rejected.allSatisfy { $0 })
        #expect(model.notes.map(\.id) == (1...20).map(Int64.init))
        #expect(model.canvasGeometry.papers.count == 20 && model.waterfallGeometry.frames.count == 20)
    }

    @Test
    func enteringOverviewPaperDoesNotLoseReadyTextWhenItsOffscreenSourceIsEvicted() async throws {
        let (scene, endpoint) = try await oneSidedOverviewScene(entering: true)
        let paper = try #require(scene.papers.first)
        #expect(paper.card.desktop.paper.contentGeometry.blocks.isEmpty)
        #expect(!paper.card.waterfall.paper.contentGeometry.blocks.isEmpty)
        scene.render(progress: 1)
        #expect(paper.alpha == 1)
        #expect(paper.sourceBlocks.allSatisfy { $0.image == nil })
        #expect(paper.targetBlocks.contains { $0.image != nil && $0.alpha == 1 })
        #expect(paper.targetBlocks.first?.frame == endpoint.paper.contentGeometry.quoteRect)
        #expect(abs(paper.bounds.width - endpoint.paper.frame.width) < 0.0001)
    }

    @Test
    func exitingOverviewPaperRetainsSourceTextWithoutPreparingAnOffscreenDestination() async throws {
        let (scene, endpoint) = try await oneSidedOverviewScene(entering: false)
        let paper = try #require(scene.papers.first)
        #expect(!paper.card.desktop.paper.contentGeometry.blocks.isEmpty)
        #expect(paper.card.waterfall.paper.contentGeometry.blocks.isEmpty)
        scene.render(progress: 0)
        #expect(paper.alpha == 1)
        #expect(paper.targetBlocks.allSatisfy { $0.image == nil })
        #expect(paper.sourceBlocks.contains { $0.image != nil && $0.alpha == 1 })
        #expect(paper.sourceBlocks.first?.frame == endpoint.paper.contentGeometry.quoteRect)
        #expect(abs(paper.bounds.width - endpoint.paper.frame.width) < 0.0001)
        scene.render(progress: 1)
        #expect(paper.alpha == 0)
    }

    @Test
    func solidTransitionBackgroundUsesOnePixelWithoutReducingPaperResolutionOrChangingItsColor() async throws {
        let (scene, original) = try await oneSidedOverviewScene(entering: false)
        let clip = CGRect(x: 0, y: 0, width: 320, height: 480)
        let endpoint = CanvasOverviewRenderEndpoint(note: original.note, paper: original.paper,
            pose: CanvasOverviewPaperPose(center: CGPoint(x: clip.midX, y: clip.midY), size: original.paper.frame.size,
                rotation: 0), style: original.style)
        let card = CanvasOverviewSceneCard(desktop: endpoint, waterfall: endpoint, kind: .migrate, isAnchor: true, delay: 0)
        let plan = CanvasOverviewTransitionPlan(clip: clip, cards: [card], desktopVisible: [endpoint],
            waterfallVisible: [endpoint], style: original.style, isPanorama: false, focusRatio: 1,
            desktopAnchor: endpoint.pose.center, focusAnchor: endpoint.pose.center, screenScale: 2,
            generation: scene.plan.generation, desktopCanvasRect: clip, model: scene.plan.model)
        let output: (CanvasOverviewSceneTextures?, CanvasOverviewSceneTextures?, UIImage, UIImage) =
            await withCheckedContinuation { continuation in
                DispatchQueue(label: "canvas-test-background-density").async {
                    let work = CanvasOverviewTransitionPreparation()
                    let solid = CanvasOverviewTransitionRasterizer.surface([], plan: plan, preparation: work)
                    let normal = CanvasOverviewTransitionRasterizer.prepare(plan, preparation: work)
                    let reduced = CanvasOverviewTransitionRasterizer.prepare(plan, preparation: work, reducedMotion: true)
                    let reference = CanvasOverviewTransitionRasterizer.surface([endpoint], plan: plan, preparation: work)
                    continuation.resume(returning: (normal, reduced, solid, reference))
                }
            }
        let normal = try #require(output.0), reduced = try #require(output.1)
        let pixel = try #require(output.2.cgImage)
        #expect(pixel.width == 1 && pixel.height == 1)
        let full = try #require(normal.desktopFull.cgImage)
        #expect(normal.desktopFull.size == clip.size && normal.desktopFull.scale == 2)
        #expect(full.width == 640 && full.height == 960)
        #expect(full.bitsPerComponent <= 8 && full.bitsPerPixel <= 32)
        let textBitmaps = normal.blocks.flatMap { $0.flatMap { [$0.source?.cgImage, $0.target?.cgImage].compactMap { $0 } } }
        #expect(!textBitmaps.isEmpty && textBitmaps.allSatisfy { $0.bitsPerComponent <= 8 && $0.bitsPerPixel <= 32 })
        #expect(normal.waterfallFull == nil && normal.desktopUnderlay === normal.desktopFull && !normal.blocks.isEmpty)
        let reference = try #require(output.3.cgImage)
        let actualPixels = try raster(size: clip.size) { $0.draw(full, in: CGRect(origin: .zero, size: clip.size)) }
        let referencePixels = try raster(size: clip.size) { $0.draw(reference, in: CGRect(origin: .zero, size: clip.size)) }
        let pixelWidth = Int(clip.width * 3)
        let corners = [0, (pixelWidth - 1) * 4, actualPixels.count - pixelWidth * 4, actualPixels.count - 4]
        for start in corners {
            for channel in 0..<4 { #expect(abs(Int(actualPixels[start + channel]) - Int(referencePixels[start + channel])) <= 2) }
        }
        #expect(reduced.blocks.isEmpty && reduced.desktopBackground === reduced.desktopFull)
        #expect(reduced.waterfallBackground === reduced.waterfallFull && reduced.desktopUnderlay === reduced.desktopFull)
        let reducedDesktop = try #require(reduced.desktopFull.cgImage)
        let reducedWaterfall = try #require(reduced.waterfallFull?.cgImage)
        #expect(reducedDesktop.width == 640 && reducedDesktop.height == 960)
        #expect(reducedWaterfall.width == 640 && reducedWaterfall.height == 960)
        #expect(reduced.pixelBytes == reducedDesktop.bytesPerRow * reducedDesktop.height
            + reducedWaterfall.bytesPerRow * reducedWaterfall.height)
    }

    /// Uses real prepared endpoints with only the visible side protected; no second-mode prefetch is allowed.
    private func oneSidedOverviewScene(entering: Bool) async throws -> (CanvasOverviewTransitionSceneView, CanvasOverviewRenderEndpoint) {
        let controller = NoteReviewCanvasOverviewController()
        controller.automaticallyPreparesOverview = false
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 700)
        controller.view.layoutIfNeeded()
        defer { controller.disposeCanvas() }
        let model = try await previewFixture(controller: controller, count: 1)
        controller.preparedModel = model
        controller.currentNoteID = 1
        controller.previewStore.removeUnprotected()
        controller.sourceReader = { ids, _ in ids.map(Self.previewSource) }
        try await controller.warmPreviews(ids: [1], model: model, work: nil,
            modes: entering ? [.waterfall] : [.desktop], protectsTransition: true)
        let desktop = try #require(controller.endpoint(in: .desktop, noteID: 1))
        let waterfall = try #require(controller.endpoint(in: .waterfall, noteID: 1))
        let clip = controller.view.bounds
        let card = CanvasOverviewSceneCard(desktop: desktop, waterfall: waterfall,
            kind: entering ? .enter : .exit, isAnchor: false, delay: 0)
        let plan = CanvasOverviewTransitionPlan(clip: clip, cards: [card],
            desktopVisible: entering ? [] : [desktop], waterfallVisible: entering ? [waterfall] : [],
            style: model.style, isPanorama: false, focusRatio: 1,
            desktopAnchor: desktop.pose.center, focusAnchor: desktop.pose.center,
            screenScale: 1, generation: controller.generation, desktopCanvasRect: clip, model: model)
        let prepared: CanvasOverviewSceneTextures? = await withCheckedContinuation { continuation in
            controller.preparationQueue.async {
                continuation.resume(returning: CanvasOverviewTransitionRasterizer.prepare(plan,
                    preparation: CanvasOverviewTransitionPreparation()))
            }
        }
        let textures = try #require(prepared)
        return (CanvasOverviewTransitionSceneView(plan: plan, textures: textures, fromDesktop: true, reducedMotion: false),
                entering ? waterfall : desktop)
    }

    @Test
    func realReadingCellKeepsVisibleInkWhenItsSceneTakesOwnership() async throws {
        let bounds = CGRect(x: 0, y: 0, width: 402, height: 874)
        let host = UIViewController()
        host.loadViewIfNeeded()
        host.view.frame = bounds
        host.view.backgroundColor = .white
        let window = UIWindow(frame: bounds)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        let cell = NoteReviewCollectionCell(frame: bounds)
        host.view.addSubview(cell)
        let paragraph = "界面中的纸张应当始终保留可读文字。书摘回顾让用户从一条内容返回同一处位置。"
        let item = NoteReviewCardItem(id: 7, bookID: 1, bookTitle: "排版验证", bookAuthor: "", bookCoverURL: "",
            chapterTitle: "真实阅读端点", contentHTML: "<p>" + String(repeating: paragraph, count: 5) + "</p>",
            ideaHTML: "", position: "", positionUnit: 0, includeTime: false, createdDate: 1,
            imageURLs: [], tags: [], weReadOriginalURL: nil)
        let insets = UIEdgeInsets(top: 132, left: 0, bottom: 98, right: 0)
        cell.configure(item: item, mode: .immersive, settings: .defaultValue, overviewSnapshot: nil,
            overviewMeasurement: nil, paperWidth: bounds.width, chromeInsets: insets)
        host.view.layoutIfNeeded()
        cell.layoutIfNeeded()
        CATransaction.flush()
        await Task.yield()
        let source = try #require(cell.immersiveTransitionEndpoint(in: host.view, insets: insets, surfaceColor: .white))
        let sourcePixels = try raster(size: source.logicalSize) { context in
            UIGraphicsPushContext(context)
            source.image.draw(in: CGRect(origin: .zero, size: source.logicalSize))
            UIGraphicsPopContext()
        }
        func inkCount(_ pixels: [UInt8]) -> Int {
            stride(from: 0, to: pixels.count, by: 4).reduce(0) { count, offset in
                count + (pixels[offset + 3] > 200 && pixels[offset] < 128
                    && pixels[offset + 1] < 128 && pixels[offset + 2] < 128 ? 1 : 0)
            }
        }
        #expect(inkCount(sourcePixels) > 100, "The actual reading capture must contain opaque text, not only a valid UIImage.")
        let targetSize = CGSize(width: 220, height: 168)
        let target = NoteReviewCanvasReadingEndpoint(image: readingInk(size: targetSize),
            frame: CGRect(x: 42, y: 158, width: 209, height: 159.6), rotation: 0,
            logicalSize: targetSize, surface: .init(color: .white, cornerRadius: 12), backdropColor: .white)
        let scene = NoteReviewCanvasReadingScene(source: source, target: target, clip: bounds,
            sourceBackground: nil, targetBackground: nil)
        host.view.addSubview(scene)
        cell.alpha = 0
        for progress in [CGFloat.zero, 0.15, 0.3] {
            scene.render(progress)
            scene.layoutIfNeeded()
            let pixels = try raster(size: scene.bounds.size) { context in scene.layer.render(in: context) }
            #expect(inkCount(pixels) > 100, "The source ink must survive ownership and clipping before target ink becomes visible.")
        }
    }

    @Test
    func readingSceneUsesOriginalLayoutAtBothPaperEndpoints() throws {
        let (source, target) = readingEndpoints()
        let clip = CGRect(x: 10, y: 30, width: 402, height: 740)
        let scene = NoteReviewCanvasReadingScene(source: source, target: target, clip: clip,
            sourceBackground: nil, targetBackground: nil)
        for (progress, endpoint) in [(CGFloat.zero, source), (CGFloat(1), target)] {
            scene.render(progress)
            let scale = hypot(scene.paper.transform.a, scene.paper.transform.b)
            #expect(abs(scale - endpoint.scale) < 0.0001)
            #expect(abs(scene.paper.bounds.width - endpoint.logicalSize.width) < 0.0001)
            #expect(abs(scene.paper.bounds.height * scale - endpoint.frame.height) < 0.0001)
            #expect(abs(scene.paper.center.x + clip.minX - endpoint.frame.midX) < 0.0001)
            #expect(abs(scene.paper.center.y + clip.minY - endpoint.frame.midY) < 0.0001)
            #expect(abs(atan2(scene.paper.transform.b, scene.paper.transform.a) - endpoint.rotation) < 0.0001)
            #expect(scene.paperCornerRadius == endpoint.surface.cornerRadius)
            let color = try #require(scene.paperColor)
            expectColor(color, matches: endpoint.surface.color)
        }
        #expect(source.logicalSize.width == 220 && source.frame.width == 132)
        #expect(scene.contentProjection.target.size == target.logicalSize)
    }

    @Test
    func readingSceneKeepsInkUniformComplementaryAndReusesTexturesWhenReversed() {
        let (source, target) = readingEndpoints()
        let scene = NoteReviewCanvasReadingScene(source: source, target: target,
            clip: CGRect(x: 0, y: 0, width: 402, height: 740), sourceBackground: nil, targetBackground: nil)
        let views = descendants(of: scene).map(ObjectIdentifier.init)
        let textures = descendants(of: scene).compactMap { ($0 as? UIImageView)?.image }.map(ObjectIdentifier.init)
        let samples = stride(from: 0.0, through: 1.0, by: 0.025).map { CGFloat($0) }
        for progress in samples + Array(samples.reversed()) {
            scene.render(progress)
            for (frame, endpoint) in [(scene.contentProjection.source, source), (scene.contentProjection.target, target)] {
                #expect(frame.origin == .zero)
                #expect(abs(frame.width / endpoint.logicalSize.width - frame.height / endpoint.logicalSize.height) < 0.0001)
            }
            #expect(abs(scene.contentOpacity.source + scene.contentOpacity.target - 1) < 0.0001)
            #expect((0...1).contains(scene.contentOpacity.source) && (0...1).contains(scene.contentOpacity.target))
            if progress >= 0.74 { #expect(scene.contentOpacity.source == 0 && scene.contentOpacity.target == 1) }
            #expect(descendants(of: scene).map(ObjectIdentifier.init) == views)
            #expect(descendants(of: scene).compactMap { ($0 as? UIImageView)?.image }.map(ObjectIdentifier.init) == textures)
        }
        #expect(scene.contentOpacity.source == 1 && scene.contentOpacity.target == 0)
    }

    @Test
    func reducedReadingMotionDissolvesStationaryCompleteBackdrops() {
        let (source, target) = readingEndpoints()
        let clip = CGRect(x: 0, y: 40, width: 402, height: 700)
        let sourceBackground = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 780))
        let targetBackground = UIView(frame: sourceBackground.frame)
        let scene = NoteReviewCanvasReadingScene(source: source, target: target, clip: clip,
            sourceBackground: sourceBackground, targetBackground: targetBackground)
        let sourceFrame = sourceBackground.frame, targetFrame = targetBackground.frame
        scene.reducedMotion = true
        for progress in [CGFloat(0), 0.3, 0.5, 0.8, 1, 0.5, 0] {
            scene.render(progress)
            #expect(scene.paper.isHidden)
            #expect(sourceBackground.layer.mask == nil && targetBackground.layer.mask == nil)
            #expect(sourceBackground.frame == sourceFrame && targetBackground.frame == targetFrame)
            #expect(abs(sourceBackground.alpha - (1 - progress)) < 0.0001)
            #expect(abs(targetBackground.alpha - progress) < 0.0001)
        }
        scene.reducedMotion = false
        #expect(!scene.paper.isHidden)
        #expect(sourceBackground.layer.mask != nil && targetBackground.layer.mask != nil)
    }

    @Test
    func interruptedReadingPaperKeepsItsProjectionWithoutAddingAnotherSkin() {
        let (source, target) = readingEndpoints()
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 740))
        let scene = NoteReviewCanvasReadingScene(source: source, target: target, clip: container.bounds,
            sourceBackground: nil, targetBackground: nil)
        container.addSubview(scene)
        scene.render(0.45)
        let captured = NoteReviewCanvasReadingEndpoint.capture(scene.paper, in: container)
        #expect(captured.imageIncludesSurface)
        #expect(captured.logicalSize == scene.paper.bounds.size)
        #expect(abs(captured.scale - hypot(scene.paper.transform.a, scene.paper.transform.b)) < 0.0001)
        #expect(abs(captured.frame.midX - scene.paper.center.x) < 0.0001)
        let skin = readingInk(size: CGSize(width: 48, height: 48))
        let completePaper = NoteReviewCanvasReadingEndpoint(image: captured.image, frame: captured.frame,
            rotation: captured.rotation, logicalSize: captured.logicalSize,
            surface: .init(color: .clear, skin: skin, backgroundImage: skin), imageIncludesSurface: true)
        let continuation = NoteReviewCanvasReadingScene(source: completePaper, target: target, clip: container.bounds,
            sourceBackground: nil, targetBackground: nil)
        continuation.render(0)
        let images = descendants(of: continuation).compactMap { ($0 as? UIImageView)?.image }
        #expect(images.filter { $0 === captured.image }.count == 1)
        #expect(!images.contains { $0 === skin })
        #expect(abs(continuation.paper.bounds.width - captured.logicalSize.width) < 0.0001)
        #expect(abs(continuation.paper.center.y - captured.frame.midY) < 0.0001)
    }

    @Test
    func overviewReadingEndpointKeepsTransparentInkAndOriginalWidthAcrossCameraScales() async throws {
        let controller = NoteReviewCanvasOverviewController()
        controller.automaticallyPreparesOverview = false
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 700)
        controller.view.layoutIfNeeded()
        defer { controller.disposeCanvas() }
        let model = try await previewFixture(controller: controller, count: 1)
        controller.preparedModel = model
        controller.currentNoteID = 1
        controller.sourceReader = { ids, _ in ids.map(Self.previewSource) }
        controller.desktopScrollView.minimumZoomScale = 0.1
        controller.desktopScrollView.maximumZoomScale = 2
        for scale in [CGFloat(0.6), 0.95, 1.3] {
            controller.desktopScrollView.setZoomScale(scale, animated: false)
            let prepared = await controller.readingEndpoint(noteID: 1, in: controller.view)
            let endpoint = try #require(prepared)
            #expect(endpoint.logicalSize == model.canvasGeometry.papers[0].frame.size)
            #expect(endpoint.logicalSize.width == 220 && !endpoint.imageIncludesSurface)
            #expect(abs(endpoint.frame.width / endpoint.logicalSize.width - controller.desktopScrollView.zoomScale) < 0.0001)
            let pixels = try raster(size: endpoint.logicalSize) { context in
                UIGraphicsPushContext(context)
                endpoint.image.draw(in: CGRect(origin: .zero, size: endpoint.logicalSize))
                UIGraphicsPopContext()
            }
            #expect(pixels[3] == 0 && pixels[pixels.count - 1] == 0)
            #expect(stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] > 0 })
            #expect(endpoint.surface.skin != nil && endpoint.surface.cornerRadius == model.style.cornerRadius)
        }
    }

    @Test
    func chromeMenuUpdatesWaitForDismissalAndIgnoreAnOlderCompletion() throws {
        let button = NoteReviewChromeMenuButton(frame: CGRect(x: 0, y: 0, width: 48, height: 48))
        let original = UIMenu(title: "original", children: [])
        let intermediate = UIMenu(title: "intermediate", children: [])
        let latest = UIMenu(title: "latest", children: [])
        button.setReviewMenu(original)
        button.isContextMenuInteractionEnabled = true
        let interaction = try #require(button.contextMenuInteraction)
        let configuration = UIContextMenuConfiguration(identifier: nil, previewProvider: nil, actionProvider: nil)
        button.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: nil)
        button.setReviewMenu(intermediate)
        button.setReviewMenu(latest)
        #expect(button.menu?.title == original.title)
        let completion = CanvasTestMenuAnimator()
        button.contextMenuInteraction(interaction, willEndFor: configuration, animator: completion)
        #expect(button.menu?.title == original.title)
        completion.complete()
        #expect(button.menu?.title == latest.title)
        button.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: nil)
        button.setReviewMenu(intermediate)
        let stale = CanvasTestMenuAnimator()
        button.contextMenuInteraction(interaction, willEndFor: configuration, animator: stale)
        button.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: nil)
        button.setReviewMenu(original)
        stale.complete()
        #expect(button.menu?.title == latest.title)
        button.contextMenuInteraction(interaction, willEndFor: configuration, animator: nil)
        #expect(button.menu?.title == original.title)
    }

    @Test
    func nativeMenuLoadingCoalescesUntilDismissalWithoutDisablingOrReshapingItsButton() throws {
        let button = NoteReviewChromeMenuButton(frame: CGRect(x: 0, y: 0, width: 48, height: 48))
        button.setReviewMenu(UIMenu(title: "模式", children: []))
        button.isContextMenuInteractionEnabled = true
        let interaction = try #require(button.contextMenuInteraction)
        let configuration = UIContextMenuConfiguration(identifier: nil, previewProvider: nil, actionProvider: nil)
        let originalBounds = button.bounds
        var ended = 0
        button.onMenuDidEnd = { ended += 1 }
        button.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: nil)
        button.setReviewLoading(true)
        button.setReviewLoading(false)
        button.setReviewLoading(true)
        #expect(button.configuration?.showsActivityIndicator == false && button.accessibilityValue == nil)
        let completion = CanvasTestMenuAnimator()
        button.contextMenuInteraction(interaction, willEndFor: configuration, animator: completion)
        #expect(button.configuration?.showsActivityIndicator == false && ended == 0)
        completion.complete()
        #expect(button.configuration?.showsActivityIndicator == true)
        #expect(button.accessibilityValue == "正在准备切换" && ended == 1)
        #expect(button.bounds == originalBounds && button.isEnabled && button.showsMenuAsPrimaryAction)
        #expect(button.configuration?.cornerStyle == .capsule)
        button.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: nil)
        button.setReviewLoading(false)
        let stale = CanvasTestMenuAnimator()
        button.contextMenuInteraction(interaction, willEndFor: configuration, animator: stale)
        button.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: nil)
        stale.complete()
        #expect(button.configuration?.showsActivityIndicator == true && ended == 1)
        button.contextMenuInteraction(interaction, willEndFor: configuration, animator: nil)
        #expect(button.configuration?.showsActivityIndicator == false && button.accessibilityValue == nil && ended == 2)
    }

    private func readingEndpoints() -> (NoteReviewCanvasReadingEndpoint, NoteReviewCanvasReadingEndpoint) {
        let sourceSize = CGSize(width: 220, height: 180), targetSize = CGSize(width: 390, height: 680)
        return (
            NoteReviewCanvasReadingEndpoint(image: readingInk(size: sourceSize),
                frame: CGRect(x: 40, y: 180, width: 132, height: 108), rotation: -0.01, logicalSize: sourceSize,
                surface: .init(color: .lightGray, cornerRadius: 12), backdropColor: .gray),
            NoteReviewCanvasReadingEndpoint(image: readingInk(size: targetSize),
                frame: CGRect(x: 10, y: 50, width: 390, height: 680), rotation: 0, logicalSize: targetSize,
                surface: .init(color: .white, cornerRadius: 0), backdropColor: .white)
        )
    }

    private func readingInk(size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { output in
            output.cgContext.setFillColor(UIColor.black.cgColor)
            output.cgContext.fill(CGRect(x: 18, y: 18, width: min(80, size.width - 36), height: 14))
        }
    }

    private func descendants(of view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func expectColor(_ actual: UIColor, matches expected: UIColor) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        var expectedRed: CGFloat = 0, expectedGreen: CGFloat = 0, expectedBlue: CGFloat = 0, expectedAlpha: CGFloat = 0
        #expect(actual.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        #expect(expected.getRed(&expectedRed, green: &expectedGreen, blue: &expectedBlue, alpha: &expectedAlpha))
        #expect(abs(red - expectedRed) < 0.0001 && abs(green - expectedGreen) < 0.0001)
        #expect(abs(blue - expectedBlue) < 0.0001 && abs(alpha - expectedAlpha) < 0.0001)
    }

    @Test
    func readingRecoveryEndsSpinnerWithoutInlineError() {
        let feedback = NoteReviewCanvasPageFeedback()
        feedback.setWaiting(true)
        feedback.showReadingRecovery()
        #expect(feedback.needsReadingRecovery)
        #expect(!feedback.isWaiting && !feedback.gate.isVisible)
        #expect(feedback.error == nil)
    }

    @Test
    func reversingOverviewPreparationDoesNotResurrectASettledRequest() {
        let coordinator = NoteReviewCanvasModeCoordinator()
        coordinator.settle(.desktop)
        coordinator.request(.waterfall)
        coordinator.isOverviewTransition = true
        coordinator.reverseOverview = { mode in coordinator.settle(mode); return true }
        #expect(coordinator.reverseIfPossible(to: .desktop))
        #expect(coordinator.requestedMode == nil && coordinator.state == .idle)
        #expect(coordinator.settledMode == .desktop)
        coordinator.dispose()
    }

    @Test
    func dissolveCanReverseWithoutSharedPaperEndpoints() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 700))
        let source = UIView(frame: container.bounds), target = UIView(frame: container.bounds), chrome = UIView()
        [source, target, chrome].forEach(container.addSubview)
        var result: Bool?
        let transition = NoteReviewCanvasSurfaceDissolve(source: source, target: target, frozenSource: nil,
            container: container, below: chrome) { result = $0 }
        transition.animator.startAnimation()
        transition.animator.pauseAnimation()
        transition.animator.fractionComplete = 0.5
        transition.reverse(true)
        #expect(transition.animator.isReversed)
        transition.animator.stopAnimation(false)
        transition.animator.finishAnimation(at: .start)
        #expect(result == false && source.alpha == 1 && target.alpha == 0)
        #expect(container.subviews.count == 3)
    }

    @Test
    func dissolveCancellationCannotCommitAStaleMode() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 700))
        let source = UIView(frame: container.bounds), target = UIView(frame: container.bounds), chrome = UIView()
        [source, target, chrome].forEach(container.addSubview)
        let coordinator = NoteReviewCanvasModeCoordinator()
        coordinator.request(.desktop)
        var commits = 0
        coordinator.animateDissolve(from: .immersive, to: .desktop, source: source, target: target,
            frozenSource: nil, container: container, below: chrome) { _ in commits += 1 }
        #expect(coordinator.reverseIfPossible(to: .immersive))
        coordinator.dispose()
        #expect(commits == 0 && coordinator.state == .idle)
        #expect(container.subviews.count == 3)
    }

    @Test
    func openingOneNoteDoesNotRequireUnrelatedNeighbors() async throws {
        let controller = NoteReviewCanvasOverviewController()
        controller.automaticallyPreparesOverview = false
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 700)
        controller.view.layoutIfNeeded()
        defer { controller.disposeCanvas() }
        let model = try await previewFixture(controller: controller, count: 20)
        controller.preparedModel = model
        controller.currentNoteID = 1
        controller.previewStore.removeUnprotected()
        var requested: [Int64] = []
        controller.sourceReader = { ids, _ in
            requested += ids
            return ids.filter { $0 == 1 }.map(Self.previewSource)
        }
        let endpoint = await controller.readingEndpoint(noteID: 1, in: controller.view)
        #expect(endpoint != nil && requested == [1])
        #expect(controller.transitionPreviewPins.count == 1)
    }

    @Test
    func readableRecoveryDoesNotRevealMissingTargetContent() async throws {
        let controller = NoteReviewCanvasOverviewController()
        controller.automaticallyPreparesOverview = false
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 700)
        controller.view.layoutIfNeeded()
        defer { controller.disposeCanvas() }
        controller.preparedModel = try await previewFixture(controller: controller, count: 1)
        controller.currentNoteID = 1
        controller.previewStore.removeUnprotected()
        controller.sourceReader = { _, _ in [] }
        do {
            try await controller.prepareReadableSurface(.waterfall, noteID: 1)
            Issue.record("A missing target must not be treated as a ready dissolve")
        } catch CanvasOverviewPreviewError.unavailable { }
        #expect(controller.currentMode == .desktop && controller.modeDissolve == nil)
    }

    @Test
    func overviewRecoverySettlesTheRequestedModeAndKeepsIdentity() async throws {
        let controller = NoteReviewCanvasOverviewController()
        controller.automaticallyPreparesOverview = false
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 700)
        controller.view.layoutIfNeeded()
        defer { controller.disposeCanvas() }
        let model = try await previewFixture(controller: controller, count: 20)
        controller.preparedModel = model
        controller.currentNoteID = 1
        controller.waterfallLayout.geometry = model.waterfallGeometry
        controller.waterfallView.reloadData()
        controller.waterfallView.layoutIfNeeded()
        controller.sourceReader = { ids, _ in ids.map(Self.previewSource) }
        var result: NoteReviewCanvasOverviewController.Mode?
        controller.onSettledMode = { result = $0 }
        controller.transitionState = .preparing
        controller.pendingMode = .waterfall
        controller.recoverModeTransition(target: .waterfall, from: .desktop, noteID: 1,
            token: controller.transitionGeneration, reason: "test-endpoint-unavailable")
        await waitUntil { controller.transitionState == .idle }
        #expect(result == .waterfall && controller.currentMode == .waterfall)
        #expect(controller.currentNoteID == 1 && controller.modeDissolve == nil)
        #expect(controller.waterfallView.alpha == 1 && controller.desktopScrollView.alpha == 0)
        #expect(controller.waterfallView.isUserInteractionEnabled)
    }

    @Test
    func singleReadingDoesNotPrepareOverviewUntilExplicitlyRequested() {
        let controller = NoteReviewCanvasOverviewController()
        controller.automaticallyPreparesOverview = false
        var reads = 0
        controller.sourceReader = { _, _ in reads += 1; return [] }
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        controller.view.layoutIfNeeded()
        controller.resumeCanvas()
        #expect(controller.generation == 0 && controller.modelPreparation == nil)
        #expect(reads == 0 && !controller.requestedInitialPreparation)
        #expect(NoteReviewCanvasModeCoordinator().settledMode == .immersive)
        controller.disposeCanvas()
    }

    @Test
    func waitingGateIsOnlyOwnedByAnOperationAndCancellationIsImmediate() {
        let feedback = NoteReviewCanvasPageFeedback()
        #expect(!feedback.isWaiting && feedback.gate.intent == .none)
        feedback.setWaiting(true)
        feedback.setWaiting(true)
        #expect(feedback.isWaiting && feedback.gate.intent == .read)
        feedback.setWaiting(false)
        #expect(!feedback.isWaiting && !feedback.gate.isVisible && feedback.gate.intent == .none)
    }

    @Test
    func sharpeningUsesCachedTextAndRefreshesTheRealWaterfallPaper() async throws {
        let controller = NoteReviewCanvasOverviewController()
        controller.automaticallyPreparesOverview = false
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 700)
        controller.view.layoutIfNeeded()
        defer { controller.disposeCanvas() }
        let model = try await previewFixture(controller: controller, count: 1)
        controller.preparedModel = model
        controller.currentMode = .waterfall
        controller.currentNoteID = 1
        controller.waterfallLayout.geometry = model.waterfallGeometry
        controller.waterfallView.reloadData()
        controller.waterfallView.layoutIfNeeded()
        let cell = try #require(controller.waterfallView.cellForItem(at: IndexPath(item: 0, section: 0)) as? CanvasOverviewWaterfallCell)
        cell.paperView.clearContent()
        controller.previewStore.drawings.removeUnprotected()
        cell.configure(note: model.notes[0], geometry: model.waterfallGeometry.contentGeometries[0],
            size: model.waterfallGeometry.frames[0].size, style: model.waterfallStyle)
        #expect(cell.paperView.paper?.contentGeometry.preparedBlocks == nil)
        var reads = 0
        controller.sourceReader = { _, _ in reads += 1; return [] }
        try await controller.warmPreviews(ids: [1], model: model, work: nil)
        #expect(reads == 0)
        // Removing unprotected entries must not erase the visible paper's freshly acquired lease.
        controller.previewStore.drawings.removeUnprotected()
        #expect(cell.paperView.paper?.contentGeometry.preparedBlocks != nil)
        #expect(cell.paperView.paper?.contentGeometry.chapterRect == model.waterfallGeometry.contentGeometries[0].chapterRect)
    }

    @Test
    func completedSharpBatchSurvivesLaterCancellationAndSameDemandRetries() async throws {
        let controller = NoteReviewCanvasOverviewController()
        controller.automaticallyPreparesOverview = false
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 700)
        controller.view.layoutIfNeeded()
        defer { controller.disposeCanvas() }
        let model = try await previewFixture(controller: controller, count: 40)
        controller.preparedModel = model
        controller.previewStore.removeUnprotected()
        controller.previewDemand = (1...40).map(Int64.init)
        controller.previewVisibleDemand = (1...20).map(Int64.init)
        var reads = 0
        controller.sourceReader = { ids, _ in
            reads += 1
            #expect(ids.count <= 20)
            if reads == 2 { throw CancellationError() }
            return ids.map(Self.previewSource)
        }
        do {
            try await controller.warmPreviews(ids: controller.previewDemand, model: model, work: nil, modes: [.desktop])
            Issue.record("Second batch should cancel")
        } catch is CancellationError { }
        controller.previewStore.removeUnprotected()
        #expect((1...20).allSatisfy { controller.previewsAreReady(for: Int64($0), in: model, modes: [.desktop]) })
        #expect(!controller.previewsAreReady(for: 21, in: model, modes: [.desktop]))
        controller.sourceReader = { ids, _ in ids.map(Self.previewSource) }
        // The ID array is intentionally unchanged; only readiness changed.
        controller.startPreviewWorker(model: model)
        await waitUntil { controller.previewTask == nil }
        #expect(controller.previewDemand.allSatisfy { controller.previewsAreReady(for: $0, in: model, modes: [.desktop]) })
        #expect(controller.previewDrawingPins.count <= 20)
        #expect(controller.previewStore.drawings.statistics.bytes <= 16 * 1_024 * 1_024)
    }

    @Test
    func onlyVisibleStyleAndTransitionEndpointsPreventEviction() async throws {
        let controller = NoteReviewCanvasOverviewController()
        controller.automaticallyPreparesOverview = false
        controller.loadViewIfNeeded()
        defer { controller.disposeCanvas() }
        let model = try await previewFixture(controller: controller, count: 40)
        controller.preparedModel = model
        controller.previewDemand = (1...40).map(Int64.init)
        controller.previewVisibleDemand = (1...8).map(Int64.init)
        controller.protectPreviewDemand(in: model)
        #expect(controller.previewDrawingPins.count == 8)
        #expect(controller.previewDrawingPins.keys.allSatisfy { $0.width > 0 })
        controller.previewStore.removeUnprotected()
        #expect(controller.previewsAreReady(for: 1, in: model, modes: [.desktop]))
        #expect(!controller.previewsAreReady(for: 1, in: model, modes: [.waterfall]))
        #expect(!controller.previewsAreReady(for: 9, in: model, modes: [.desktop]))
        controller.sourceReader = { ids, _ in ids.map(Self.previewSource) }
        try await controller.warmPreviews(ids: Array(21...28).map(Int64.init), model: model, work: nil,
                                         modes: [.waterfall], protectsTransition: true)
        controller.previewStore.removeUnprotected()
        #expect(controller.transitionPreviewPins.count == 8)
        #expect(controller.previewsAreReady(for: 21, in: model, modes: [.waterfall]))
        #expect(controller.previewStore.drawings.statistics.protectedCount == 16)
        controller.cancelPendingPresentation()
        #expect(controller.transitionPreviewPins.isEmpty)
    }

    @Test
    func richPredictionPressureCannotEvictVisibleCardsOrRetryInALoop() async throws {
        let controller = NoteReviewCanvasOverviewController()
        controller.automaticallyPreparesOverview = false
        controller.loadViewIfNeeded()
        defer { controller.disposeCanvas() }
        let model = try await previewFixture(controller: controller, count: 40, rich: true)
        controller.preparedModel = model
        controller.previewStore.removeUnprotected()
        controller.previewDemand = (1...40).map(Int64.init)
        controller.previewVisibleDemand = (1...4).map(Int64.init)
        var reads = 0
        controller.sourceReader = { ids, _ in
            #expect(ids.count <= 20)
            reads += 1
            return ids.map { Self.previewSource($0, rich: true) }
        }
        controller.startPreviewWorker(model: model)
        await waitUntil { controller.previewTask == nil }
        #expect(controller.previewVisibleDemand.allSatisfy { controller.previewsAreReady(for: $0, in: model, modes: [.desktop]) })
        #expect(controller.previewDrawingPins.count == 4)
        #expect(controller.previewStore.drawings.statistics.bytes <= 16 * 1_024 * 1_024)
        let completedReads = reads
        controller.startPreviewWorker(model: model)
        await waitUntil { controller.previewTask == nil }
        #expect(reads == completedReads)
    }

    /// Controlled finite input; preparation runs off the main actor and shares the production cache.
    private func previewFixture(controller: NoteReviewCanvasOverviewController, count: Int, rich: Bool = false) async throws -> CanvasOverviewPreparedModel {
        let style = CanvasOverviewPaperStyle(traits: UITraitCollection(preferredContentSizeCategory: .large))
        let builder = CanvasOverviewBatchPreparation(count: count, store: controller.previewStore, style: style,
            waterfallStyle: style, width: 220, size: CGSize(width: 402, height: 700), scale: 1,
            packing: .compactPairs, fixedColumns: nil, anchorID: 1)
        let sources = (1...count).map { Self.previewSource(Int64($0), rich: rich) }
        let model = await withCheckedContinuation { continuation in
            controller.preparationQueue.async {
                let cancellation = CanvasOverviewTransitionPreparation()
                builder.append(sources, cancellation: cancellation)
                continuation.resume(returning: builder.finish(cancellation: cancellation))
            }
        }
        return try #require(model)
    }

    private static func previewSource(_ id: Int64, rich: Bool) -> NoteReviewOverviewLayoutSource {
        NoteReviewOverviewLayoutSource(noteID: id,
            contentHTML: rich ? "<p><u>\(String(repeating: "带下划线的完整富文本与 Emoji 🎨 保留相同排版。", count: 20))</u></p>"
                : "<p>稳定的真实排版 <b>清晰正文</b>与相同阅读位置。</p>", ideaHTML: "想法",
            bookTitle: "书名", chapterTitle: "章节", noteUpdatedDate: 1, bookUpdatedDate: 1, chapterUpdatedDate: 1)
    }

    private static func previewSource(_ id: Int64) -> NoteReviewOverviewLayoutSource { previewSource(id, rich: false) }

    @Test
    func widthReplayPreservesPreparedTextRolesAndRects() {
        let style = CanvasOverviewPaperStyle(traits: UITraitCollection(preferredContentSizeCategory: .large))
        let source = NoteReviewOverviewLayoutSource(noteID: 1, contentHTML: "<p>真实文字 <b>粗体</b>与完整排版</p>",
            ideaHTML: "", bookTitle: "一本书", chapterTitle: "章节", noteUpdatedDate: 1, bookUpdatedDate: 1, chapterUpdatedDate: 1)
        let note = CanvasOverviewTextFactory.makeRealNotes([source], style: style)[0]
        let original = CanvasOverviewGeometryBuilder.makeContentGeometry(note: note, width: 220)
        let replay = original.replaying(note)
        #expect(replay.blocks.count == 4)
        #expect(replay.blocks.map(\.rect) == original.blocks.map(\.rect))
        #expect(replay.blocks.map(\.signature) == original.blocks.map(\.signature))
        #expect(replay.chapterRect == original.chapterRect)
        #expect(CanvasOverviewWaterfallCell(frame: .zero).isAccessibilityElement)
    }

    @Test
    func transitionSurfaceDoesNotOwnScrollGestures() {
        let surface = NoteReviewCanvasTransitionSurface(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        surface.layoutIfNeeded()
        #expect(!surface.isScrollEnabled && !surface.isUserInteractionEnabled)
        #expect(surface.accessibilityElementsHidden)
        #expect(surface.contentSize == surface.bounds.size)
        #expect(surface.topEdgeEffect.style == .soft && surface.bottomEdgeEffect.style == .soft)
    }

    @Test
    func immersiveOverviewUsesFullBoundsWithoutRebuildingGeometry() {
        let controller = NoteReviewCanvasOverviewController()
        controller.extendsUnderSafeArea = true
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        controller.additionalSafeAreaInsets = UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0)
        controller.view.layoutIfNeeded()
        let generation = controller.generation
        let zoom = controller.desktopScrollView.zoomScale
        controller.setContentOcclusionInsets(UIEdgeInsets(top: 132, left: 0, bottom: 104, right: 0))
        #expect(controller.desktopScrollView.frame == controller.view.bounds)
        #expect(controller.waterfallView.frame == controller.view.bounds)
        #expect(controller.waterfallView.contentInset.top == 132)
        #expect(controller.clampedWaterfallOffsetY(-999) == -132)
        #expect(controller.generation == generation && controller.desktopScrollView.zoomScale == zoom)
        controller.disposeCanvas()
    }

    @Test
    func canvasPauseAndDisposalKeepTheCommittedIdentity() {
        let controller = NoteReviewCanvasOverviewController()
        controller.loadViewIfNeeded()
        controller.currentNoteID = 7
        controller.pauseCanvas()
        #expect(controller.isCanvasPaused)
        #expect(controller.currentNoteID == 7)
        controller.resumeCanvas()
        #expect(!controller.isCanvasPaused)
        controller.disposeCanvas()
        #expect(controller.isDisposed && controller.sourceReader == nil)
        #expect(controller.widthDisplayLink == nil && controller.transitionDisplayLink == nil)
    }

    @Test
    func thirdModeRequestDoesNotCommitTheInterruptedTarget() {
        let coordinator = NoteReviewCanvasModeCoordinator()
        coordinator.request(.desktop)
        coordinator.markAnimating()
        _ = coordinator.interrupt(in: UIView())
        coordinator.request(.waterfall)
        #expect(coordinator.settledMode == .immersive)
        #expect(coordinator.requestedMode == .waterfall && coordinator.state == .preparing)
        coordinator.dispose()
        #expect(coordinator.requestedMode == nil)
    }

    @Test
    func canvasContentInsetsMatchProjectTokens() {
        #expect(CanvasOverviewGeometryBuilder.contentInset == Spacing.contentEdge)
        #expect(CanvasOverviewGeometryBuilder.blockGap == Spacing.base)
        #expect(CanvasOverviewGeometryBuilder.metadataGap == Spacing.compact)
    }

    @Test
    func protectedContentAdvancesWithCacheRevision() async {
        let repository = CanvasTestNoteRepository()
        let old = repository.item
        let payload = NoteReviewLaunchPayload(selectedNoteID: old.id, currentIndex: 0,
            loadedNoteIDs: [old.id], seedItems: [old], settings: .defaultValue)
        let session = NoteReviewUIKitSession(payload: payload, repository: repository)
        defer { session.dispose() }
        let changed = old.replacingTags([NoteEditorTagOption(id: 9, title: "更新")])
        let saved = await session.replaceTags(changed.tags, noteID: old.id)
        #expect(saved)
        #expect(session.item(for: old.id)?.tags.map(\.id) == [9])
        session.handleMemoryWarning()
        #expect(session.item(for: old.id)?.tags.map(\.id) == [9])
    }

    @Test
    func productionSessionDoesNotStartLegacyOverviewAndSavesWidthOnce() async {
        let repository = CanvasTestNoteRepository()
        let session = NoteReviewUIKitSession(payload: NoteReviewLaunchPayload(selectedNoteID: 7, currentIndex: 0,
            loadedNoteIDs: [7], seedItems: [repository.item], settings: .defaultValue), repository: repository)
        defer { session.dispose() }
        session.automaticallyPreparesOverview = false
        var ready = false
        session.onManifestChanged = { ready = true }
        session.start()
        await waitUntil { ready }
        #expect(repository.sourceReads == 0)
        session.updateDesktopCardWidth(247)
        session.updateDesktopCardWidth(247)
        #expect(repository.saves == 1)
        #expect(repository.settings.desktopCardWidth == 247)
    }

    @Test
    func widthSettingsFeedbackDoesNotStartAnotherGeneration() {
        let controller = NoteReviewCanvasOverviewController()
        var next = NoteReviewSettings.defaultValue
        next.desktopCardWidth = 247
        controller.selectedDesktopCardWidth = 247
        let generation = controller.generation
        controller.applySettings(next, previous: .defaultValue)
        #expect(controller.generation == generation)
        #expect(controller.renderingSettings?.desktopCardWidth == 247)
        controller.disposeCanvas()
    }

    @Test
    func productionModeRemainsSettledUntilOwnershipIsReturned() {
        let coordinator = NoteReviewCanvasModeCoordinator()
        coordinator.request(.desktop)
        #expect(coordinator.settledMode == .immersive && coordinator.state == .preparing)
        coordinator.markAnimating()
        #expect(coordinator.settledMode == .immersive)
        coordinator.settle(.desktop)
        #expect(coordinator.settledMode == .desktop && coordinator.requestedMode == nil)
        var reversed: NoteReviewPresentationMode?
        coordinator.isOverviewTransition = true
        coordinator.reverseOverview = { reversed = $0; return true }
        #expect(coordinator.reverseIfPossible(to: .waterfall))
        #expect(reversed == .waterfall)
        coordinator.dispose()
        #expect(coordinator.state == .idle)
    }

    @Test
    func boundedModelRetainsGeometryAndRealFallbackAfterPressure() async throws {
        let traits = UITraitCollection(preferredContentSizeCategory: .large)
        let style = CanvasOverviewPaperStyle(traits: traits)
        let store = CanvasOverviewPreviewStore()
        let size = CGSize(width: 402, height: 700)
        let builder = CanvasOverviewBatchPreparation(count: 374, store: store, style: style, waterfallStyle: style,
            width: 220, size: size, scale: 1, packing: .compactPairs, fixedColumns: nil, anchorID: 180)
        let token = CanvasOverviewTransitionPreparation()
        let model: CanvasOverviewPreparedModel? = await withCheckedContinuation { continuation in
            DispatchQueue(label: "canvas-tests.prepare").async {
                for first in stride(from: 1, through: 374, by: 128) {
                    let sources = (first..<min(first + 128, 375)).map { id in
                        NoteReviewOverviewLayoutSource(noteID: Int64(id), contentHTML: "<p>真实排版 <b>强调内容</b>，每条卡片保留稳定的位置。</p>",
                            ideaHTML: "<p>想法</p>", bookTitle: "一本书", chapterTitle: "章节",
                            noteUpdatedDate: 1, bookUpdatedDate: 1, chapterUpdatedDate: 1)
                    }
                    builder.append(sources, cancellation: token)
                }
                continuation.resume(returning: builder.finish(cancellation: token))
            }
        }
        let result = try #require(model)
        #expect(result.notes.count == 374)
        #expect(store.previews.statistics.count <= 240)
        #expect(store.previews.statistics.bytes <= 8 * 1_024 * 1_024)
        #expect(store.drawings.statistics.bytes <= 16 * 1_024 * 1_024)
        let frames = result.canvasGeometry.papers.map(\.frame)
        store.removeUnprotected()
        #expect(result.notes.allSatisfy { $0.payload == nil })
        #expect(result.canvasGeometry.papers.map(\.frame) == frames)
        #expect(result.canvasGeometry.papers.allSatisfy { $0.contentGeometry.fallback?.atlas.image != nil })
        #expect(result.overviewImage != nil)
    }

    @Test
    func explicitFirstNeighborhoodProtectionIsBoundedAndEndsWithItsPreparationOwner() async throws {
        let style = CanvasOverviewPaperStyle(traits: UITraitCollection(preferredContentSizeCategory: .large))
        let store = CanvasOverviewPreviewStore()
        let sources = (1...40).map { Self.previewSource(Int64($0)) }
        let result: (model: CanvasOverviewPreparedModel?, requested: Int, sourcePins: Int, drawingPins: Int, anchorReady: Bool) =
            await withCheckedContinuation { continuation in
                DispatchQueue(label: "canvas-test-initial-protection").async {
                    let output = autoreleasepool {
                        let builder = CanvasOverviewBatchPreparation(count: 40, store: store, style: style,
                            waterfallStyle: style, width: 220, size: CGSize(width: 402, height: 700), scale: 1,
                            packing: .compactPairs, fixedColumns: nil, anchorID: 35,
                            initialProtectedIDs: Set((1...40).map(Int64.init)))
                        let work = CanvasOverviewTransitionPreparation()
                        builder.append(sources, cancellation: work)
                        let model = builder.finish(cancellation: work)
                        return withExtendedLifetime(builder) {
                            (model, builder.initialProtectedIDs.count, store.previews.statistics.protectedCount,
                             store.drawings.statistics.protectedCount, model?.noteByID[35]?.payload != nil)
                        }
                    }
                    continuation.resume(returning: output)
                }
            }
        let model = try #require(result.model)
        #expect(result.requested == 20 && result.sourcePins == 20 && result.drawingPins == 40 && result.anchorReady)
        #expect(store.previews.statistics.protectedCount == 0 && store.drawings.statistics.protectedCount == 0)
        store.removeUnprotected()
        #expect(model.notes.allSatisfy { $0.payload == nil })
        #expect(model.canvasGeometry.papers.allSatisfy { $0.contentGeometry.preparedBlocks == nil })
        #expect(store.previews.statistics.bytes == 0 && store.drawings.statistics.bytes == 0)
        #expect(model.canvasGeometry.papers.count == 40 && model.overviewImage != nil)
    }

    @Test
    func logicalViewportKeepsScaleAndReadingAnchorAcrossEnvironmentChanges() {
        let original = CGRect(x: 0, y: 100, width: 402, height: 650)
        let viewport = NoteReviewCanvasViewport(noteID: 88, offset: CGPoint(x: 800, y: 2000),
            zoomScale: 0.95, anchor: CGPoint(x: 201, y: 327.5), viewportRect: original)
        for target in [original, CGRect(x: 40, y: 24, width: 740, height: 330)] {
            let expected = CGPoint(x: target.midX, y: target.minY + target.height * 0.35)
            #expect(viewport.anchor(in: target) == expected)
            for card in [CGRect(x: 48, y: 48, width: 180, height: 168),
                         CGRect(x: 3000, y: 2000, width: 360, height: 300)] {
                let offset = viewport.offset(for: card, in: target)
                #expect(abs(card.midX * viewport.zoomScale - offset.x + target.minX - expected.x) < 0.001)
                #expect(abs(card.midY * viewport.zoomScale - offset.y + target.minY - expected.y) < 0.001)
            }
            #expect(viewport.noteID == 88 && viewport.zoomScale == 0.95)
        }
    }

    @Test
    func waterfallUsesAdaptiveColumnsAndOrderedSpatialQueries() throws {
        for count in [0, 1, 2, 20, 374, 2000] {
            let ids = (0..<count).map { Int64($0 + 1) }
            let heights = ids.map { CGFloat(168 + ($0 * 31) % 133) }
            for (size, accessibility, regular, expected) in [
                (CGSize(width: 320, height: 600), false, false, 1),
                (CGSize(width: 402, height: 740), false, false, 2),
                (CGSize(width: 740, height: 402), false, false, 3),
                (CGSize(width: 1024, height: 768), false, true, 4),
                (CGSize(width: 1024, height: 768), true, true, 1)
            ] {
                let ltr = try NoteReviewCanvasWaterfallGeometry(ids: ids, heights: heights, viewport: size,
                    generation: 1, accessibility: accessibility, regularWidth: regular)
                let rtl = try NoteReviewCanvasWaterfallGeometry(ids: ids, heights: heights, viewport: size,
                    generation: 2, accessibility: accessibility, regularWidth: regular, isRTL: true)
                #expect(ltr.metrics.columns == expected)
                for index in ids.indices {
                    let frame = ltr.frames[index]
                    #expect(abs(frame.minX + rtl.frames[index].maxX - size.width) < 0.001)
                    #expect(frame.minY == rtl.frames[index].minY)
                    #expect(ltr.hitTest(CGPoint(x: frame.midX, y: frame.midY)) == ids[index])
                    let query = frame.insetBy(dx: -10, dy: -10)
                    #expect(ltr.indexes(in: query) == ltr.frames.indices.filter { ltr.frames[$0].intersects(query) })
                }
                for column in ltr.columnIndexes {
                    for pair in zip(column, column.dropFirst()) {
                        #expect(abs(ltr.frames[pair.1].minY - ltr.frames[pair.0].maxY - 16) < 0.001)
                    }
                }
            }
        }
        #expect(throws: NoteReviewCanvasGeometryError.self) {
            try NoteReviewCanvasWaterfallGeometry(ids: [1, 1], heights: [180, 220],
                viewport: CGSize(width: 402, height: 740), generation: 1)
        }
        #expect(throws: NoteReviewCanvasGeometryError.self) {
            try NoteReviewCanvasWaterfallGeometry(ids: [1], heights: [180],
                viewport: CGSize(width: 402, height: 740), generation: 1, isCancelled: { true })
        }
    }

    @Test
    func coreGraphicsPaperSkinMatchesOriginalResizableEndpoint() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let image = UIGraphicsImageRenderer(size: CGSize(width: 112, height: 112), format: format).image { output in
            let context = output.cgContext
            context.setShadow(offset: CGSize(width: 0, height: 4), blur: 12,
                color: UIColor.black.withAlphaComponent(0.11).cgColor)
            context.setFillColor(UIColor.white.cgColor)
            context.addPath(CGPath(roundedRect: CGRect(x: 24, y: 24, width: 64, height: 64),
                cornerWidth: 12, cornerHeight: 12, transform: nil))
            context.fillPath()
        }.resizableImage(withCapInsets: UIEdgeInsets(top: 38, left: 38, bottom: 38, right: 38), resizingMode: .stretch)
        let skin = NoteReviewCanvasPaperSkin(image: try #require(image.cgImage), scale: image.scale, cap: 38)
        for size in [CGSize(width: 228, height: 216), CGSize(width: 408, height: 348)] {
            let prepared = try raster(size: size) { skin.draw(in: $0, rect: CGRect(origin: .zero, size: size)) }
            let reference = try raster(size: size) { context in
                UIGraphicsPushContext(context)
                image.draw(in: CGRect(origin: .zero, size: size))
                UIGraphicsPopContext()
            }
            let difference = zip(prepared, reference).reduce(0.0) { $0 + Double(abs(Int($1.0) - Int($1.1))) }
                / Double(prepared.count * 255)
            #expect(difference < 0.003, "Paper endpoint pixel difference: \(difference)")
        }
    }

    @Test
    func protectedResourcesStayInsideBudgetAndSurvivePressure() {
        let cache = NoteReviewCanvasResourceCache<Int, String>(limit: 100, countLimit: 2)
        #expect(cache.insert("anchor", for: 1, cost: 60))
        var anchor = cache.lease(for: 1)
        #expect(anchor?.value == "anchor")
        #expect(!cache.insert("too large", for: 2, cost: 70))
        #expect(cache.insert("neighbour", for: 2, cost: 40))
        #expect(cache.statistics.bytes == 100)
        cache.removeUnprotected()
        #expect(cache.statistics.bytes == 60 && cache.statistics.protectedCount == 1)
        #expect(!cache.insert("new anchor", for: 1, cost: 20))
        anchor = nil
        #expect(cache.insert("replacement", for: 3, cost: 80))
        #expect(cache.statistics.bytes == 80)
        #expect(cache.lease(for: 1) == nil)
        cache.removeUnprotected()
        #expect(cache.statistics.bytes == 0 && cache.statistics.count == 0)
    }
    @Test
    func sourceBatchesWaitForConsumerAndHandleMissingIDs() async throws {
        var queries: [[Int64]] = []
        var delivered: [Int64] = []
        var missing = Set<Int64>()
        let latch = CanvasTestLatch()
        let adapter = NoteReviewCanvasSourceAdapter { ids, _ in
            queries.append(ids)
            return ids.reversed().filter { $0 != 19 }.map { id in
                NoteReviewOverviewLayoutSource(noteID: id, contentHTML: "", ideaHTML: "",
                    bookTitle: "", chapterTitle: "", noteUpdatedDate: 1, bookUpdatedDate: 2, chapterUpdatedDate: 3)
            }
        }
        var isLast = false
        let work = Task {
            try await adapter.consume(ids: (1...300).map(Int64.init) + [1, 19]) { batch in
                delivered += batch.sources.map(\.noteID)
                missing.formUnion(batch.missingIDs)
                isLast = batch.isLast
                if batch.completedCount == 128 { await latch.wait() }
            }
        }
        await waitUntil { delivered.count == 127 }
        #expect(queries.count == 1)
        latch.open()
        try await work.value
        #expect(queries.map(\.count) == [128, 128, 44])
        #expect(delivered == (1...300).map(Int64.init).filter { $0 != 19 })
        #expect(missing == [19] && isLast)
    }

    @Test
    func cancellationDuringSourceConsumptionNeverStartsNextBatch() async throws {
        let latch = CanvasTestLatch()
        var queries = 0
        var consumed = false
        let adapter = NoteReviewCanvasSourceAdapter { _, _ in queries += 1; return [] }
        let work = Task {
            try await adapter.consume(ids: (1...300).map(Int64.init)) { _ in
                consumed = true
                await latch.wait()
            }
        }
        await waitUntil { consumed }
        work.cancel()
        latch.open()
        do { try await work.value; Issue.record("Cancelled source stream completed") }
        catch is CancellationError {} catch { throw error }
        #expect(queries == 1)
    }

    @Test
    func deletedCurrentSelectsNextThenPreviousWithoutReordering() {
        #expect(NoteReviewCanvasSelection.replacement(for: 8, previousOrder: [4, 8, 12, 16], nextOrder: [4, 16]) == 16)
        #expect(NoteReviewCanvasSelection.replacement(for: 16, previousOrder: [4, 8, 12, 16], nextOrder: [4, 8]) == 8)
        #expect(NoteReviewCanvasSelection.replacement(for: 8, previousOrder: [4, 8], nextOrder: []) == nil)
        #expect(NoteReviewCanvasSelection.replacement(for: 8, previousOrder: [4, 8], nextOrder: [8, 4]) == 8)
    }

    @Test
    func readPermitsRemainBoundedAndCancellationDoesNotReleaseRunningWork() async throws {
        let gate = NoteReviewCanvasReadScheduler(limit: 1)
        let latch = CanvasTestLatch()
        var sequence: [Int] = []
        let first = Task {
            try await gate.perform {
                sequence.append(1)
                await latch.wait()
                return 1
            }
        }
        await waitUntil { gate.activeCount == 1 && sequence == [1] }
        let background = Task { try await gate.perform(priority: .utility) { sequence.append(2); return 2 } }
        let foreground = Task { try await gate.perform(priority: .userInitiated) { sequence.append(3); return 3 } }
        let cancelled = Task { try await gate.perform { sequence.append(4); return 4 } }
        await waitUntil { gate.waitingCount == 3 }
        cancelled.cancel()
        await waitUntil { gate.waitingCount == 2 }
        first.cancel()
        #expect(gate.activeCount == 1)
        #expect(sequence == [1])
        latch.open()
        do { _ = try await first.value; Issue.record("Cancelled running result escaped") }
        catch is CancellationError {} catch { throw error }
        _ = try await foreground.value
        _ = try await background.value
        do { _ = try await cancelled.value; Issue.record("Cancelled queued work ran") }
        catch is CancellationError {} catch { throw error }
        #expect(sequence == [1, 3, 2])
        #expect(gate.maximumObservedCount == 1 && gate.activeCount == 0)
    }

    @Test
    func disposalCancelsQueuedAndRejectsLateResults() async throws {
        let gate = NoteReviewCanvasReadScheduler()
        let latch = CanvasTestLatch()
        let running = (0..<2).map { value in Task { try await gate.perform { await latch.wait(); return value } } }
        await waitUntil { gate.activeCount == 2 }
        var ran = false
        let queued = Task { try await gate.perform { ran = true } }
        await waitUntil { gate.waitingCount == 1 }
        gate.dispose()
        latch.open()
        for task in running {
            do { _ = try await task.value; Issue.record("Disposed result escaped") }
            catch is CancellationError {} catch { throw error }
        }
        do { try await queued.value; Issue.record("Disposed queued work ran") }
        catch is CancellationError {} catch { throw error }
        #expect(!ran && gate.activeCount == 0 && gate.waitingCount == 0)
        #expect(gate.maximumObservedCount == 2)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("Deterministic scheduler failed to reach the expected state")
    }
    @Test
    func geometryPreservesIdentityGapsAndSpatialIndex() throws {
        for count in [0, 1, 2, 20, 374, 2000] {
            let ids = (0..<count).map { Int64($0 + 1) }
            let heights = (0..<count).map { CGFloat(168 + ($0 * 71) % 133) }
            for width: CGFloat in [180, 220, 247, 360] {
                for rtl in [false, true] {
                    let geometry = try NoteReviewCanvasGeometry(ids: ids, heights: heights, cardWidth: width,
                        viewport: CGSize(width: 402, height: 720), generation: 1, isRTL: rtl)
                    #expect(geometry.papers.map(\.noteID) == ids)
                    for (index, paper) in geometry.papers.enumerated() {
                        #expect(geometry.hitTest(CGPoint(x: paper.frame.midX, y: paper.frame.midY)) == paper.noteID)
                        #expect(paper.visualFrame.minX >= 47.999)
                        #expect(paper.visualFrame.minY >= 47.999)
                        #expect(geometry.contentSize.width - paper.visualFrame.maxX >= 47.999)
                        #expect(geometry.contentSize.height - paper.visualFrame.maxY >= 47.999)
                        #expect((0...48).contains(paper.lift))
                        let next = index + 1
                        if next < count, next / geometry.columnCount == index / geometry.columnCount {
                            let neighbour = geometry.papers[next].visualFrame
                            let gap = max(neighbour.minX - paper.visualFrame.maxX, paper.visualFrame.minX - neighbour.maxX)
                            #expect(gap >= 23.999)
                        }
                        let query = paper.visualFrame.insetBy(dx: -30, dy: -30)
                        let linear = geometry.papers.indices.filter { geometry.papers[$0].visualFrame.intersects(query) }
                        #expect(geometry.indexes(in: query) == linear)
                        for otherIndex in geometry.indexes(in: paper.visualFrame.insetBy(dx: -19.999, dy: -19.999))
                            where otherIndex != index {
                            let other = geometry.papers[otherIndex].visualFrame
                            #expect(!paper.visualFrame.intersects(other))
                            let horizontal = max(paper.visualFrame.minX - other.maxX, other.minX - paper.visualFrame.maxX)
                            if horizontal < 19.999 {
                                #expect(max(paper.visualFrame.minY - other.maxY, other.minY - paper.visualFrame.maxY) >= 19.999)
                            }
                        }
                    }
                }
            }
        }
    }

    @Test
    func geometryRejectsPartialGenerationAndDuplicateIDs() throws {
        #expect(throws: NoteReviewCanvasGeometryError.self) {
            try NoteReviewCanvasGeometry(ids: [7, 7], heights: [168, 200], cardWidth: 220,
                viewport: CGSize(width: 400, height: 700), generation: 1)
        }
        #expect(throws: NoteReviewCanvasGeometryError.self) {
            try NoteReviewCanvasGeometry(ids: [7], heights: [168], cardWidth: 220,
                viewport: CGSize(width: 400, height: 700), generation: 2, isCancelled: { true })
        }
        let accessible = try NoteReviewCanvasGeometry(ids: [7, 8, 9, 10], heights: [168, 300, 200, 168],
            cardWidth: 220, viewport: CGSize(width: 400, height: 700), generation: 3, fixedColumns: 2,
            parameters: .init(usesAccessibleLayout: true))
        #expect(accessible.papers.allSatisfy { $0.rotation == 0 && $0.lift == 0 })
        #expect(accessible.papers[0].frame.minY == accessible.papers[1].frame.minY)
    }

    @Test
    func widthInterpolationRemainsCollisionSafe() {
        let parameters = NoteReviewCanvasDesktopLayoutParameters()
        let first: [CGFloat] = [168, 300, 220, 300, 168, 180, 190, 290]
        let last: [CGFloat] = [300, 180, 168, 200, 300, 280, 168, 210]
        for tick in 0...100 {
            let progress = CGFloat(tick) / 100
            let heights = zip(first, last).map { $0 + ($1 - $0) * progress }
            let result = NoteReviewCanvasPairGeometry.place(firstRow: 0, columns: 4,
                width: 180 + 180 * progress, heights: heights, parameters: parameters)
            let boxes = result.frames.enumerated().map {
                NoteReviewCanvasGeometry.rotatedBounds($0.element,
                    angle: NoteReviewCanvasDesktopLayoutParameters.angles[$0.offset % 6])
            }
            for i in boxes.indices {
                for j in boxes.indices where j > i {
                    #expect(!boxes[i].intersects(boxes[j]))
                    let dx = max(boxes[i].minX - boxes[j].maxX, boxes[j].minX - boxes[i].maxX)
                    if i / 4 != j / 4, dx < 20 {
                        #expect(boxes[j].minY - boxes[i].maxY >= 19.999)
                    }
                }
            }
        }
    }

    @Test
    func cardWidthDecodingOnlyFallsBackTheDamagedField() throws {
        var original = NoteReviewSettings.defaultValue
        original.selectedBookIDs = [19, 23]
        original.textAlignment = .center
        original.desktopCardWidth = 247
        let encoded = try JSONEncoder().encode(original)
        var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for invalid: Any in ["wide", 0, 179, 361, 220.5, NSNull()] {
            json["desktopCardWidth"] = invalid
            let decoded = try JSONDecoder().decode(NoteReviewSettings.self,
                from: JSONSerialization.data(withJSONObject: json))
            #expect(decoded.desktopCardWidth == 220)
            #expect(decoded.selectedBookIDs == [19, 23])
            #expect(decoded.textAlignment == .center)
        }
        json.removeValue(forKey: "desktopCardWidth")
        #expect(try JSONDecoder().decode(NoteReviewSettings.self,
            from: JSONSerialization.data(withJSONObject: json)).desktopCardWidth == 220)
        #expect(try JSONDecoder().decode(NoteReviewSettings.self, from: encoded) == original)
    }

    @Test
    func settingStoreSanitizesWidthWithoutResettingPreferences() throws {
        let name = "NoteReviewCanvasTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = NoteReviewSettingStore(defaults: defaults)
        var settings = store.fetchSettings()
        settings.selectedTagIDs = [91]
        settings.desktopCardWidth = 300
        store.save(settings)
        #expect(store.fetchSettings().desktopCardWidth == 300)
        settings.desktopCardWidth = Int.max
        store.save(settings)
        #expect(store.fetchSettings().desktopCardWidth == 220)
        #expect(store.fetchSettings().selectedTagIDs == [91])
    }

    @Test
    func immutableGlyphsKeepCoreTextLineMetricsAndPixels() throws {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        let values: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 17),
            .foregroundColor: UIColor(red: 0.18, green: 0.42, blue: 0.66, alpha: 0.76),
            .paragraphStyle: paragraph
        ]
        for sample in ["稳定的书摘地图 English baseline\n下一行保留位置。",
                       "Bold italic 样式 underline & emoji 👩🏽‍💻 🎨",
                       "灰色元数据和辅助文字必须与原来的 Core Text 端点保持一致。"] {
            let text = NSMutableAttributedString(string: sample, attributes: values)
            if sample.hasPrefix("Bold") {
                text.addAttributes([.font: UIFont.boldSystemFont(ofSize: 17)], range: NSRange(location: 0, length: 4))
                text.addAttributes([.underlineStyle: 1], range: NSRange(location: 5, length: 6))
            }
            let size = CGSize(width: 184, height: 120)
            let output = NoteReviewCanvasTextLayout(text: text, size: size, attributes: .project, rasterScale: 3)
            let framesetter = CTFramesetterCreateWithAttributedString(text)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0),
                CGPath(rect: CGRect(origin: .zero, size: size), transform: nil), nil)
            let lines = CTFrameGetLines(frame) as! [CTLine]
            var origins = Array(repeating: CGPoint.zero, count: lines.count)
            CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
            #expect(output.metrics.count == lines.count)
            for (index, line) in lines.enumerated() {
                #expect(output.metrics[index].origin == origins[index])
                #expect(abs(output.metrics[index].width - CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))) < 0.001)
            }
            let prepared = try raster(size: size) { output.draw(in: $0) }
            let reference = try raster(size: size) { context in
                context.translateBy(x: 0, y: size.height); context.scaleBy(x: 1, y: -1)
                context.textMatrix = .identity
                for (index, line) in lines.enumerated() {
                    context.textPosition = origins[index]; CTLineDraw(line, context)
                }
            }
            let difference = zip(prepared, reference).reduce(0.0) { $0 + Double(abs(Int($1.0) - Int($1.1))) }
                / Double(prepared.count * 255)
            #expect(difference < 0.006, "Core Text endpoint pixel difference: \(difference)")
            #expect(output.cost > 0)
        }
    }

    private func raster(size: CGSize, draw: (CGContext) -> Void) throws -> [UInt8] {
        let width = Int(size.width * 3), height = Int(size.height * 3)
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 3, y: -3)
        draw(context)
        let data = try #require(context.data)
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
    }
}

/// Controlled suspension point; no wall-clock sleeps or repository dependencies.

/// Only the review surface is implemented; unexpected business access fails the scoped test immediately.
@MainActor
final class CanvasTestNoteRepository: NoteRepositoryProtocol {
    var settings = NoteReviewSettings.defaultValue
    var saves = 0
    var sourceReads = 0
    var reviewIDs: [Int64]?
    var idReads = 0
    var idReader: (() async throws -> [Int64])?
    var directory: (any NoteReviewDirectory)?
    var directoryOpens = 0
    var reviewItems: [NoteReviewCardItem]?
    var itemReads: [[Int64]] = []
    var itemReader: (([Int64]) async throws -> [NoteReviewCardItem])?
    var dataChanges: AsyncThrowingStream<Void, Error>.Continuation?
    var deleteCalls: [[Int64]] = []
    var deletion: (([Int64]) async throws -> Void)?
    let item = NoteReviewCardItem(id: 7, bookID: 1, bookTitle: "书", bookAuthor: "", bookCoverURL: "",
        chapterTitle: "章节", contentHTML: "<p>正文</p>", ideaHTML: "", position: "", positionUnit: 0,
        includeTime: false, createdDate: 1, imageURLs: [], tags: [], weReadOriginalURL: nil)
    func observeTagSections() -> AsyncThrowingStream<[TagSection], Error> { fatalError("Unexpected repository access") }
    func observeNoteHomeSnapshot() -> AsyncThrowingStream<NoteHomeSnapshot, Error> { fatalError("Unexpected repository access") }
    func observeNoteExcerptList(request: NoteExcerptPageRequest) -> AsyncThrowingStream<NoteExcerptListSnapshot, Error> { fatalError("Unexpected repository access") }
    func observeChapterNoteList(request: ChapterNotePageRequest) -> AsyncThrowingStream<NoteExcerptListSnapshot, Error> { fatalError("Unexpected repository access") }
    func observeStarredChapterGroups(request: StarredChapterRequest) -> AsyncThrowingStream<[StarredChapterGroup], Error> { fatalError("Unexpected repository access") }
    func setChapterStarred(chapterID: Int64, isStarred: Bool) async throws { fatalError("Unexpected repository access") }
    func observeRelatedCategories(request: RelatedCategoryRequest) -> AsyncThrowingStream<RelatedCategorySnapshot, Error> { fatalError("Unexpected repository access") }
    func observeRelatedContentList(request: RelatedContentPageRequest) -> AsyncThrowingStream<RelatedContentListSnapshot, Error> { fatalError("Unexpected repository access") }
    func deleteRelatedCategory(scope: RelatedCategoryScope) async throws { fatalError("Unexpected repository access") }
    func observeBookReviewList(request: BookReviewPageRequest) -> AsyncThrowingStream<BookReviewListSnapshot, Error> { fatalError("Unexpected repository access") }
    func fetchNoteReviewSettings() -> NoteReviewSettings { return settings }
    func saveNoteReviewSettings(_ settings: NoteReviewSettings) { self.settings = settings; saves += 1 }
    func observeNoteReviewSettingChanges() -> AsyncStream<Void> { return AsyncStream { _ in } }
    func observeNoteReviewDataChanges() -> AsyncThrowingStream<Void, Error> { AsyncThrowingStream { dataChanges = $0 } }
    func uploadNoteReviewBackground(localURL: URL) async throws -> S3UploadResult { fatalError("Unexpected repository access") }
    func fetchNoteReviewBackgroundData(remoteURL: URL) async throws -> Data { fatalError("Unexpected repository access") }
    func fetchNoteReviewPage(request: NoteReviewPageRequest) async throws -> [NoteReviewCardItem] { fatalError("Unexpected repository access") }
    func fetchNoteReviewIDs(settings: NoteReviewSettings) async throws -> [Int64] {
        idReads += 1
        if let idReader { return try await idReader() }
        return reviewIDs ?? [item.id]
    }
    func openNoteReviewDirectory(request: NoteReviewDirectoryRequest, cacheID: UUID,
                                 schedule: @escaping NoteReviewDirectoryReadScheduling,
                                 progress: @escaping @Sendable (NoteReviewDirectoryPreparation) async -> Void) async throws -> any NoteReviewDirectory {
        directoryOpens += 1
        guard let directory else { throw NoteReviewDirectoryError.unavailable }
        return directory
    }
    func fetchNoteReviewOverviewLayoutSources(noteIDs: [Int64]) async throws -> [NoteReviewOverviewLayoutSource] { sourceReads += 1; return [] }
    func fetchNoteReviewItem(noteID: Int64) async throws -> NoteReviewCardItem? { fatalError("Unexpected repository access") }
    func fetchNoteReviewItems(noteIDs: [Int64]) async throws -> [NoteReviewCardItem] {
        itemReads.append(noteIDs)
        if let itemReader { return try await itemReader(noteIDs) }
        return (reviewItems ?? [item]).filter { noteIDs.contains($0.id) }
    }
    func fetchNoteReviewTagOptions() async throws -> [NoteReviewTagOption] { fatalError("Unexpected repository access") }
    func fetchNoteReviewTagEditSnapshot(noteID: Int64) async throws -> NoteReviewTagEditSnapshot { fatalError("Unexpected repository access") }
    func replaceNoteReviewTags(noteID: Int64, tags: [NoteEditorTagOption]) async throws -> [NoteEditorTagOption] { tags }
    func setNoteTagMembership(noteID: Int64, tagID: Int64, isPresent: Bool) async throws { fatalError("Unexpected repository access") }
    func fetchNoteReviewSelectedBooks(bookIDs: [Int64]) async throws -> [BookPickerBook] { fatalError("Unexpected repository access") }
    func fetchNoteDetail(noteId: Int64) async throws -> NoteDetailPayload? { fatalError("Unexpected repository access") }
    func saveNoteDetail(noteId: Int64, contentHTML: String, ideaHTML: String) async throws { fatalError("Unexpected repository access") }
    func fetchNoteEditorBootstrap(mode: NoteEditorMode, seed: NoteEditorSeed?) async throws -> NoteEditorBootstrap { fatalError("Unexpected repository access") }
    func fetchNoteEditorChapters(bookId: Int64) async throws -> [NoteEditorChapterOption] { fatalError("Unexpected repository access") }
    func createNoteTag(named name: String) async throws -> NoteEditorTagOption { fatalError("Unexpected repository access") }
    func stageNoteEditorImage(data: Data, preferredFileExtension: String) async throws -> NoteEditorImageItem { fatalError("Unexpected repository access") }
    func uploadStagedNoteEditorImage(_ item: NoteEditorImageItem) async throws -> NoteEditorImageItem { fatalError("Unexpected repository access") }
    func removeStagedNoteEditorImage(_ item: NoteEditorImageItem) async { fatalError("Unexpected repository access") }
    func saveNoteEditorDraft(_ draft: NoteEditorDraft) { fatalError("Unexpected repository access") }
    func fetchNoteEditorDraft(bookId: Int64, noteId: Int64) -> NoteEditorDraft? { fatalError("Unexpected repository access") }
    func deleteNoteEditorDraft(bookId: Int64, noteId: Int64) { fatalError("Unexpected repository access") }
    func saveNoteEditor(_ draft: NoteEditorDraft) async throws -> Int64 { fatalError("Unexpected repository access") }
    func fetchNoteBatchEditBootstrap(noteIDs: [Int64]) async throws -> NoteBatchEditBootstrap { fatalError("Unexpected repository access") }
    func deleteNotes(noteIDs: [Int64]) async throws {
        guard let deletion else { fatalError("Unexpected repository access") }
        deleteCalls.append(noteIDs)
        try await deletion(noteIDs)
    }
    func moveNotes(noteIDs: [Int64], toBookID bookID: Int64) async throws { fatalError("Unexpected repository access") }
    func moveNotes(noteIDs: [Int64], toChapterID chapterID: Int64) async throws { fatalError("Unexpected repository access") }
    func createChapter(bookID: Int64, parentID: Int64, title: String) async throws -> NoteEditorChapterOption { fatalError("Unexpected repository access") }
    func replaceTagsForNotes(noteIDs: [Int64], tagIDs: [Int64]) async throws { fatalError("Unexpected repository access") }
    func fetchNoteMergeDraft(request: NoteMergePreviewRequest) async throws -> NoteMergeDraft { fatalError("Unexpected repository access") }
    func mergeNotes(_ draft: NoteMergeDraft) async throws -> Int64 { fatalError("Unexpected repository access") }
}

@MainActor
private final class CanvasTestLatch {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuations.append($0) }
    }
    func open() {
        isOpen = true
        let waiting = continuations
        continuations.removeAll()
        waiting.forEach { $0.resume() }
    }
}

private enum CanvasTestFailure: Error { case injected }

/// Supplies only the public menu animation completion contract; never presents a menu or adds an interaction.
@MainActor
private final class CanvasTestMenuAnimator: NSObject, UIContextMenuInteractionAnimating {
    var previewViewController: UIViewController? { nil }
    private var completions: [() -> Void] = []
    func addAnimations(_ animations: @escaping () -> Void) { }
    func addCompletion(_ completion: @escaping () -> Void) { completions.append(completion) }
    func complete() {
        let callbacks = completions
        completions.removeAll()
        callbacks.forEach { $0() }
    }
}
