/**
 * [INPUT]: 接收 Session 的有界组目录、真实预览源和用户浏览意图
 * [OUTPUT]: 提供稳定组内桌面、真实卡片堆、组切换及统一取消/显示权交接
 * [POS]: 生产与测试中心共用的总览控制器扩展；不读取 Repository 或 UserDefaults
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import UIKit
import os

extension NoteReviewCanvasOverviewController {
    var hasMultipleStacks: Bool { selectedCount > (activeDirectoryRegion?.members.count ?? selectedGroupCapacity) }
    var isStackHandoffPending: Bool { stackTask != nil || stackSession?.animator != nil }
    var desktopOverviewIcon: String {
        if stackBrowser != nil { return "arrow.uturn.backward" }
        return hasMultipleStacks ? "square.stack.3d.up" : (isShowingFullDesktop ? "scope" : "arrow.down.right.and.arrow.up.left")
    }
    var desktopOverviewLabel: String {
        if stackBrowser != nil { return "返回当前桌面" }
        return hasMultipleStacks ? "浏览卡片堆" : (isShowingFullDesktop ? "回到当前书摘" : "查看完整桌面")
    }

    /// 只有桌面菜单提供组容量；设置回流由现有生产入口统一保存和失效。
    func desktopGroupMenu() -> UIMenu {
        UIMenu(title: "每堆书摘", image: UIImage(systemName: "square.stack.3d.up"), children: [32, 64, 96, 128].map { capacity in
            UIAction(title: "\(capacity) 条", state: selectedGroupCapacity == capacity ? .on : .off) { [weak self] _ in
                guard let self, capacity != selectedGroupCapacity else { return }
                cancelStackBrowsingImmediately()
                selectedGroupCapacity = capacity
                if let onGroupCapacityChanged { onGroupCapacityChanged(capacity) }
                else { requestPreparation(count: selectedCount, preservingCurrentID: currentNoteID) }
            }
        })
    }

    /// 模拟数据仅提供身份目录，与生产使用相同组模型及交互；不为所有 ID 构造纸面。
    func fixtureStack(containing id: Int64) -> NoteReviewCanvasStackGroup? {
        guard let index = stackAllIDs.firstIndex(of: id) else { return nil }
        let start = index / selectedGroupCapacity * selectedGroupCapacity
        let ids = stackAllIDs[start..<min(stackAllIDs.count, start + selectedGroupCapacity)]
        return .init(id: .init(snapshotID: stackFixtureSnapshot, bucket: Int64(start / selectedGroupCapacity), capacity: selectedGroupCapacity),
            members: ids.enumerated().map { index, id in .init(slot: Int64(start + index),
                record: .init(noteID: id, bookID: 0, chapterID: 0, noteRevision: 0, bookRevision: 0, chapterRevision: 0)) },
            firstOrdinal: Int64(start), totalCount: Int64(stackAllIDs.count))
    }

    /// 接口返回元数据，不读取整组正文；取消由调用者与目录代次双重保护。
    func readStack(_ request: NoteReviewCanvasStackRequest) async throws -> NoteReviewCanvasStackGroup? {
        if let stackGroupReader { return try await stackGroupReader(request) }
        switch request {
        case let .containing(id, _): return fixtureStack(containing: id)
        case let .adjacent(id, direction):
            let index = direction > 0 ? Int(id.upperSlot) : Int(id.lowerSlot) - 1
            guard stackAllIDs.indices.contains(index) else { return nil }
            return fixtureStack(containing: stackAllIDs[index])
        }
    }

    /// 首帧仍是真实桌面；准备只覆盖当前堆前三条和当前书摘，不等待左右邻堆。
    func presentStackBrowser() {
        guard currentMode == .desktop, stackBrowser == nil, stackTask == nil,
              transitionState == .idle, widthSession == nil, modelPreparation == nil,
              let model = preparedModel, let id = currentNoteID, !isDisposed, !isCanvasPaused else { return }
        cancelProgrammaticPositioning()
        desktopScrollView.stopScrollingAndZooming()
        saveViewport(for: .desktop, noteID: id)
        cancelPreviewWorker()
        rasterPreparationCache.removeAll()
        stackRequestGeneration += 1
        let token = stackRequestGeneration
        let input = generation
        let work = CanvasOverviewTransitionPreparation()
        stackWork = work
        onPreparationChanged?(true, nil)
        stackTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let group = try await readStack(.containing(id, capacity: selectedGroupCapacity)) else { throw NoteReviewDirectoryError.staleSource }
                let preview = try await prepareStackPreview(group, currentID: id, work: work)
                try Task.checkCancellation()
                guard token == stackRequestGeneration, input == generation, !work.isCancelled else { return }
                let browser = CanvasStackBrowserView(frame: view.bounds, reduced: UIAccessibility.isReduceMotionEnabled || reduceMotionSwitch.isOn)
                browser.contentInsets = contentOcclusionInsets
                browser.apply([preview], preserving: group.id)
                browser.layoutIfNeeded()
                browser.setChromeVisible(false)
                let session = CanvasStackBrowsingSession(group: group, model: model, viewport: desktopViewport,
                    noteID: id, fullDesktop: isShowingFullDesktop)
                let scene = try await makeStackTransition(model: model, preview: preview,
                    poses: browser.poses(for: group.id, in: browser), anchorID: id, work: work, reduced: browser.reduced)
                try Task.checkCancellation()
                guard input == generation, token == stackRequestGeneration, !isDisposed, !isCanvasPaused else { return }
                stackSession = session; stackBrowser = browser; stackPreviews = [preview]
                bindStackBrowser(browser)
                view.addSubview(browser)
                view.addSubview(scene)
                if showsDiagnosticControls { view.bringSubviewToFront(topControlPanel); view.bringSubviewToFront(bottomControlPanel) }
                browser.setPileHidden(group.id, hidden: true)
                browser.backdrop.image = scene.desktopUnderlay
                browser.backdrop.alpha = 0
                desktopScrollView.alpha = 0
                desktopScrollView.isUserInteractionEnabled = false
                desktopScrollView.accessibilityElementsHidden = true
                stackTask = nil; stackWork = nil
                onPreparationChanged?(false, nil)
                animateStackScene(scene, session: session, opening: true, targetGroup: group)
            } catch {
                guard token == stackRequestGeneration else { return }
                stackTask = nil; stackWork = nil
                onPreparationChanged?(false, nil)
                reportDemand()
            }
        }
    }

    /// 纸张内容准备最多四条；真实桌面中的原始矩形优先，背纸只保存实际露出的前两行区域。
    func prepareStackPreview(_ group: NoteReviewCanvasStackGroup, currentID: Int64?,
                             work: CanvasOverviewTransitionPreparation) async throws -> CanvasStackPreview {
        let interval = CanvasOverviewPreparationMetrics.signposter.beginInterval("Prepare stack preview")
        defer { CanvasOverviewPreparationMetrics.signposter.endInterval("Prepare stack preview", interval) }
        guard let sourceReader, let model = preparedModel else { throw CancellationError() }
        let ids = group.previewIDs(currentID: currentID)
        let pins = Dictionary(uniqueKeysWithValues: ids.compactMap { id -> (Int64, CanvasOverviewNote)? in
            guard let note = model.note(for: id), let payload = note.payload else { return nil }
            return (id, note.restoringPreview(payload))
        })
        let missing = ids.filter { pins[$0] == nil }
        let sources = missing.isEmpty ? [] : try await sourceReader(missing, .userInitiated)
        try Task.checkCancellation()
        let width = selectedDesktopCardWidth
        let displayWidth = min(320, view.bounds.width * 0.72)
        let backExposure = ceil(64 * width / displayWidth)
        let scale = traitCollection.displayScale * displayWidth / width
        let queue = preparationQueue
        let result: CanvasStackPreview? = await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: autoreleasepool {
                    let restored = CanvasOverviewTextFactory.makeRealNotes(sources, style: model.style, cancellation: work)
                    let byID = pins.merging(Dictionary(uniqueKeysWithValues: restored.map { ($0.id, $0) })) { first, _ in first }
                    var contents: [CanvasStackPaperContent] = []
                    for (index, id) in ids.enumerated() {
                        guard !work.isCancelled, let note = byID[id] else { return nil }
                        let geometry = model.canvasGeometry.paper(for: id)?.contentGeometry.replaying(note)
                            ?? CanvasOverviewGeometryBuilder.makeContentGeometry(note: note, width: width)
                        let size = CGSize(width: width, height: geometry.chapterRect.maxY + geometry.quoteRect.minX)
                        let endpoint = CanvasOverviewRenderEndpoint(note: note,
                            paper: .init(index: index, noteID: id, frame: CGRect(origin: .zero, size: size), visualFrame: .zero, rotation: 0, contentGeometry: geometry),
                            pose: .init(center: .zero, size: size, rotation: 0), style: model.style)
                        let density = min(scale, CanvasStackContentRenderer.maximumPreviewLongEdge / max(size.width, size.height))
                        guard let content = CanvasStackContentRenderer.paper(endpoint, pixelScale: density,
                            exposedHeight: index == 0 ? nil : backExposure, cancellation: work) else { return nil }
                        contents.append(content)
                    }
                    return CanvasStackPreview(group: group, papers: contents)
                })
            }
        }
        try Task.checkCancellation()
        guard !work.isCancelled, let result, result.papers.count == ids.count,
              result.pixelBytes <= CanvasStackContentRenderer.previewBudget else { throw NoteReviewDirectoryError.unavailable }
        return result
    }

    /// 背景和独立代理不重复拥有纸张；远景余纸合为单图，独立运动纸张最多 48 张。
    func makeStackTransition(model: CanvasOverviewPreparedModel, preview: CanvasStackPreview,
        poses: [Int64: CanvasOverviewPaperPose], anchorID: Int64,
        work: CanvasOverviewTransitionPreparation, reduced: Bool) async throws -> CanvasStackTransitionView {
        let bounds = view.bounds
        let rect = zoomContentView.canvasView.convert(desktopScrollView.bounds, from: desktopScrollView)
        let visible = model.canvasGeometry.indexes(in: rect).map { model.notes[$0].id }
        var seen = Set<Int64>()
        let representatives = preview.papers.map(\.noteID)
        let ids = Array(([anchorID] + representatives + visible).filter { seen.insert($0).inserted }.prefix(48))
        try await warmPreviews(ids: ids, model: model, work: work, modes: [.desktop], protectsTransition: true)
        try Task.checkCancellation()
        let underlay = await preparedViewportImage(model: model, canvasRect: rect,
            size: bounds.size, scale: traitCollection.displayScale)
        try Task.checkCancellation()
        let endpoints = ids.compactMap { endpoint(in: .desktop, noteID: $0) }
        let remaining = visible.filter { !ids.contains($0) }.compactMap { endpoint(in: .desktop, noteID: $0) }
        let center = poses[representatives.first ?? anchorID]?.center ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let stackWidth = poses.values.first?.size.width ?? min(320, bounds.width * 0.72)
        let scale = traitCollection.displayScale
        let queue = preparationQueue
        let result: ([CanvasStackFlight], UIImage)? = await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: autoreleasepool {
                    var flights: [CanvasStackFlight] = []
                    var bytes = 0
                    for endpoint in endpoints {
                        guard !work.isCancelled else { return nil }
                        let isRepresentative = representatives.contains(endpoint.note.id)
                        let target = poses[endpoint.note.id] ?? .init(center: center,
                            size: CGSize(width: stackWidth * 0.96, height: endpoint.paper.frame.height * stackWidth * 0.96 / endpoint.paper.frame.width), rotation: 0)
                        let density = max(endpoint.scale, isRepresentative ? target.size.width / endpoint.paper.frame.width : endpoint.scale) * scale
                        guard let content = CanvasStackContentRenderer.paper(endpoint, pixelScale: density, cancellation: work) else { return nil }
                        bytes += content.pixelBytes
                        guard bytes <= CanvasStackContentRenderer.transitionBudget - 24 * 1_024 * 1_024 else { return nil }
                        flights.append(.init(content: content, desktopPose: endpoint.pose, stackPose: target,
                            remainsInStack: isRepresentative, isAnchor: endpoint.note.id == representatives.first,
                            appearsOnDesktop: endpoint.pose.boundingFrame.intersects(bounds)))
                    }
                    let image = CanvasStackContentRenderer.remainder(remaining, bounds: bounds, scale: scale, cancellation: work)
                    return (flights, image)
                })
            }
        }
        try Task.checkCancellation()
        guard !work.isCancelled, let result else { throw NoteReviewDirectoryError.unavailable }
        let scene = CanvasStackTransitionView(frame: bounds, flights: result.0, remainderImage: result.1, pileCenter: center, reduced: reduced)
        scene.desktopUnderlay = underlay
        scene.desktopUnderlayRect = rect
        return scene
    }

    /// 一个局部时间轴借用总览的转场状态；模式改选先反向收回，再交给父页面协调器。
    func animateStackScene(_ scene: CanvasStackTransitionView, session: CanvasStackBrowsingSession,
                           opening: Bool, targetGroup: NoteReviewCanvasStackGroup) {
        guard let browser = stackBrowser else { return }
        session.scene = scene; session.directionIsOpening = opening
        transitionState = .animating
        browser.scrollView.isScrollEnabled = false
        if browser.reduced {
            scene.apply(stacked: false)
            scene.alpha = opening ? 1 : 0
            browser.setPileHidden(targetGroup.id, hidden: false)
            browser.scrollView.alpha = opening ? 0 : 1
        } else {
            scene.apply(stacked: !opening)
            browser.scrollView.alpha = opening ? 0 : 1
        }
        let animator = UIViewPropertyAnimator(duration: browser.reduced ? 0.12 : 0.40, dampingRatio: 0.96)
        let interval = CanvasOverviewPreparationMetrics.signposter.beginInterval("Stack paper handoff")
        session.finishMetrics = { CanvasOverviewPreparationMetrics.signposter.endInterval("Stack paper handoff", interval) }
        session.animator = animator
        animator.addAnimations {
            if browser.reduced { scene.alpha = opening ? 0 : 1 }
            else { scene.apply(stacked: opening) }
            browser.scrollView.alpha = opening ? 1 : 0
            browser.material.effect = opening ? UIBlurEffect(style: .systemThinMaterial) : nil
            browser.backdrop.alpha = opening ? 0.28 : 0
            browser.setChromeVisible(opening)
        }
        animator.addCompletion { [weak self, weak session] position in
            session?.finishMetrics?(); session?.finishMetrics = nil
            guard let self, let session, self.stackSession === session, !isDisposed else { return }
            let finishesStacked = opening ? position == .end : position == .start
            session.animator = nil
            CATransaction.begin(); CATransaction.setDisableActions(true)
            if finishesStacked {
                browser.scrollView.alpha = 1
                browser.setPileHidden(targetGroup.id, hidden: false)
                browser.scrollView.isScrollEnabled = true
                desktopScrollView.alpha = 0
                if session.hasCommittedTarget { restoreStackHomeModel(session) }
                scene.removeFromSuperview(); session.scene = nil
                transitionState = .idle
            } else {
                desktopScrollView.alpha = 1
                desktopScrollView.accessibilityElementsHidden = false
                scene.removeFromSuperview(); session.scene = nil
                browser.removeFromSuperview(); stackBrowser = nil
                stackSession = nil; stackPreviews = []
                transitionState = .idle
                setSurfaceInteractionEnabled(true)
                if let id = currentNoteID { onCurrentChanged?(id) }
            }
            CATransaction.commit()
            transitionPreviewPins.removeAll()
            updateFullDesktopButton(); onControlsChanged?()
            if finishesStacked { onReady?(); prepareStackNeighbors() }
            else {
                updateCanvasAccessibility(); reportDemand(); invalidateVisiblePreparedPreviews(); onReady?()
                if showsDiagnosticControls, let target = pendingMode {
                    pendingMode = nil
                    requestMode(target)
                }
            }
        }
        updateFullDesktopButton(); onControlsChanged?()
        startStackAnimation(animator)
    }

    /// 横滑改变的是浏览焦点，不能调用 setCurrentNoteID；停下后才滚动有界准备窗口。
    func bindStackBrowser(_ browser: CanvasStackBrowserView) {
        browser.onActivate = { [weak self] id in self?.expandStack(id) }
        browser.onReturn = { [weak self] in self?.dismissStackBrowser() }
        browser.onFocus = { [weak self] _ in self?.cancelStackTargetPreparation() }
        browser.onStable = { [weak self] in self?.prepareStackNeighbors() }
        browser.onInteraction = { [weak self] in self?.cancelStackTargetPreparation() }
    }

    /// 只准备相邻两堆的前三条；一次仅一个任务，全部纹理包含在同一个窗口预算中。
    func prepareStackNeighbors() {
        guard let browser = stackBrowser, !browser.isMoving, transitionState == .idle,
              stackTask == nil, stackNeighborTask == nil, let focus = browser.focusedID else { return }
        let token = stackRequestGeneration
        let work = CanvasOverviewTransitionPreparation()
        stackNeighborTask = Task { [weak self] in
            guard let self else { return }
            defer { if token == stackRequestGeneration { stackNeighborTask = nil } }
            for direction in [1, -1] {
                var cursor = focus
                for _ in 0..<2 {
                    do {
                        try Task.checkCancellation()
                        guard token == stackRequestGeneration, stackBrowser === browser, !browser.isMoving else { return }
                        guard let group = try await readStack(.adjacent(cursor, direction: direction)) else { break }
                        cursor = group.id
                        if stackPreviews.contains(where: { $0.group.id == group.id }) { continue }
                        let next = try await prepareStackPreview(group, currentID: nil, work: work)
                        try Task.checkCancellation()
                        guard token == stackRequestGeneration, stackBrowser === browser, !browser.isMoving,
                              stackTask == nil, transitionState == .idle else { return }
                        var values = (stackPreviews + [next]).sorted { $0.group.id.bucket < $1.group.id.bucket }
                        // Retain the focused stack and only its nearest ready neighbors. Never evict
                        // a moving surface, and never extend scroll range with placeholders.
                        while values.count > 5 || values.reduce(0, { $0 + $1.pixelBytes }) > CanvasStackContentRenderer.previewBudget {
                            guard let victim = [values.startIndex, values.index(before: values.endIndex)]
                                .filter({ values[$0].group.id != focus })
                                .max(by: { abs(values[$0].group.id.bucket - focus.bucket) < abs(values[$1].group.id.bucket - focus.bucket) }) else { break }
                            values.remove(at: victim)
                        }
                        guard values.reduce(0, { $0 + $1.pixelBytes }) <= CanvasStackContentRenderer.previewBudget else { break }
                        guard values.contains(where: { $0.group.id == next.group.id }) else { break }
                        stackPreviews = values
                        browser.apply(values, preserving: focus)
                    } catch { break }
                }
            }
        }
    }

    /// 只有点按才准备整组；源堆保持可滑动，新的拖动立即取消待展开目标。
    func expandStack(_ id: NoteReviewCanvasStackID) {
        guard let browser = stackBrowser, let session = stackSession, session.animator == nil,
              transitionState == .idle, let preview = stackPreviews.first(where: { $0.group.id == id }),
              let target = stackViewports[id]?.noteID ?? preview.group.noteIDs.first else { return }
        cancelStackTargetPreparation()
        stackNeighborTask?.cancel(); stackNeighborTask = nil
        browser.scrollView.stopScrollingAndZooming()
        let token = stackRequestGeneration
        let work = CanvasOverviewTransitionPreparation(); stackWork = work
        onPreparationChanged?(true, nil)
        stackTask = Task { [weak self] in
            guard let self else { return }
            do {
                let sameGroup = id == session.group.id
                if let directoryRegionReader {
                    let verified = try await directoryRegionReader(target)
                    guard verified.stackID == id, verified.members.map(\.record.noteID) == preview.group.noteIDs else {
                        throw NoteReviewDirectoryError.staleSource
                    }
                }
                let model: CanvasOverviewPreparedModel
                if sameGroup { model = session.model }
                else {
                    guard let next = try await prepareModel(ids: preview.group.noteIDs, style: session.model.style,
                        waterfallStyle: session.model.waterfallStyle, size: desktopScrollView.bounds.size,
                        scale: traitCollection.displayScale, width: selectedDesktopCardWidth, packing: desktopPacking,
                        work: work, preparesWaterfall: false, requestedAnchor: target) else { throw NoteReviewDirectoryError.unavailable }
                    model = next
                }
                try Task.checkCancellation()
                guard token == stackRequestGeneration, stackSession === session, !isDisposed, !isCanvasPaused else { return }
                let chosen = sameGroup ? session.noteID : target
                let viewport = sameGroup ? session.viewport : stackViewports[id]
                transitionState = .idle
                cancelPreviewWorker()
                desktopViewport = viewport
                activeDirectoryRegion = preview.group.region
                dataIDs = preview.group.noteIDs
                generation += 1
                CATransaction.begin(); CATransaction.setDisableActions(true)
                commit(model: model, preservingCurrentID: chosen, restoringWidthViewport: viewport, animatesEnvironmentChange: false)
                if !sameGroup, viewport == nil { positionDesktop(on: chosen, zoomScale: desktopScrollView.zoomScale, animated: false) }
                desktopScrollView.alpha = 0; desktopScrollView.isUserInteractionEnabled = false
                CATransaction.commit()
                session.hasCommittedTarget = !sameGroup
                let scene = try await makeStackTransition(model: model, preview: preview,
                    poses: browser.poses(for: id, in: view), anchorID: chosen, work: work, reduced: browser.reduced)
                try Task.checkCancellation()
                guard token == stackRequestGeneration, stackSession === session else { return }
                stackTask = nil; stackWork = nil
                onPreparationChanged?(false, nil)
                zoomContentView.installViewportUnderlay(scene.desktopUnderlay, canvasRect: scene.desktopUnderlayRect, generation: generation)
                rasterPreparationCache.removeAll()
                scene.apply(stacked: true)
                browser.setPileHidden(id, hidden: true)
                view.addSubview(scene)
                if showsDiagnosticControls { view.bringSubviewToFront(topControlPanel); view.bringSubviewToFront(bottomControlPanel) }
                onResidentRegionIDs?(Set(preview.group.noteIDs))
                if let saved = session.viewport { stackViewports[session.group.id] = saved }
                animateStackScene(scene, session: session, opening: false, targetGroup: preview.group)
            } catch {
                guard token == stackRequestGeneration else { return }
                stackTask = nil; stackWork = nil
                if session.hasCommittedTarget { restoreStackHomeModel(session) }
                onPreparationChanged?(false, nil)
            }
        }
    }

    /// 动画中沿原时间轴反向；浏览态回到原堆再展开，不以新浏览焦点覆盖用户阅读进度。
    func dismissStackBrowser() {
        guard let session = stackSession, let browser = stackBrowser else { cancelStackPreparation(); onReady?(); return }
        if let animator = session.animator {
            animator.isReversed = session.directionIsOpening
            if animator.state == .active, !animator.isRunning { animator.startAnimation() }
            return
        }
        cancelStackTargetPreparation()
        stackNeighborTask?.cancel(); stackNeighborTask = nil
        browser.scrollView.stopScrollingAndZooming()
        if stackPreviews.contains(where: { $0.group.id == session.group.id }) {
            browser.focus(session.group.id) { [weak self] in self?.expandStack(session.group.id) }
        } else {
            let token = stackRequestGeneration
            let work = CanvasOverviewTransitionPreparation(); stackWork = work
            onPreparationChanged?(true, nil)
            stackTask = Task { [weak self] in
                guard let self else { return }
                let preview = try? await prepareStackPreview(session.group, currentID: session.noteID, work: work)
                guard token == stackRequestGeneration, stackSession === session else { return }
                stackTask = nil; stackWork = nil; onPreparationChanged?(false, nil)
                guard let preview else { return }
                guard let focus = browser.focusedID,
                      let index = stackPreviews.firstIndex(where: { $0.group.id == focus }) else { return }
                let retained = Array(stackPreviews[max(0, index - 1)...min(stackPreviews.count - 1, index + 1)])
                let values = (retained + [preview]).sorted { $0.group.id.bucket < $1.group.id.bucket }
                guard values.reduce(0, { $0 + $1.pixelBytes }) <= CanvasStackContentRenderer.previewBudget else { return }
                stackPreviews = values
                browser.apply(values, preserving: focus)
                browser.focus(preview.group.id) { [weak self] in self?.expandStack(preview.group.id) }
            }
        }
    }

    /// 拖动只取消待展开任务，已准备的小预览可继续使用；不会留下迟到的模式提交。
    func cancelStackTargetPreparation() {
        guard stackSession?.animator == nil else { return }
        stackRequestGeneration += 1
        stackTask?.cancel(); stackTask = nil
        stackNeighborTask?.cancel(); stackNeighborTask = nil
        stackWork?.cancel(); stackWork = nil
        transitionPreviewPins.removeAll()
        if let session = stackSession, session.hasCommittedTarget { restoreStackHomeModel(session) }
        onPreparationChanged?(false, nil)
    }

    func cancelStackPreparation() {
        guard stackBrowser == nil else { return }
        cancelStackTargetPreparation()
    }

    /// 隐藏目标准备失败或反向时恢复原桌面；两幅表面都由不透明卡片堆覆盖，禁止提前显露。
    func restoreStackHomeModel(_ session: CanvasStackBrowsingSession) {
        transitionState = .idle
        desktopViewport = session.viewport
        activeDirectoryRegion = session.group.region
        dataIDs = session.group.noteIDs
        commit(model: session.model, preservingCurrentID: session.noteID,
            restoringWidthViewport: session.viewport, animatesEnvironmentChange: false)
        desktopScrollView.alpha = 0
        desktopScrollView.isUserInteractionEnabled = false
        currentNoteID = session.noteID
        isShowingFullDesktop = session.fullDesktop
        session.hasCommittedTarget = false
    }

    /// 生命周期和环境变化立即撤销全部资格；不等待排版、不让旧动画回调再次显示纸张。
    func cancelStackBrowsingImmediately() {
        stackRequestGeneration += 1
        stackTask?.cancel(); stackTask = nil; stackNeighborTask?.cancel(); stackNeighborTask = nil
        stackWork?.cancel(); stackWork = nil
        guard let session = stackSession else { return }
        session.animator?.stopAnimation(true); session.animator = nil
        session.finishMetrics?(); session.finishMetrics = nil
        if session.hasCommittedTarget, !isDisposed { restoreStackHomeModel(session) }
        session.scene?.removeFromSuperview()
        stackBrowser?.removeFromSuperview(); stackBrowser = nil; stackSession = nil
        stackPreviews = []; transitionPreviewPins.removeAll()
        transitionState = .idle
        desktopScrollView.alpha = currentMode == .desktop ? 1 : 0
        desktopScrollView.accessibilityElementsHidden = currentMode != .desktop
        setSurfaceInteractionEnabled(true)
        onPreparationChanged?(false, nil)
    }
}
