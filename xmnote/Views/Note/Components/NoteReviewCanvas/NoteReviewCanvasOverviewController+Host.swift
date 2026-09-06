/**
 * [INPUT]: 接收父页面的身份、设置、生命周期及模式端点请求
 * [OUTPUT]: 提供生产和测试入口共用的窄范围宿主协议
 * [POS]: NoteReviewCanvas 总览控制器的业务无关接线层
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import UIKit
import OSLog

extension NoteReviewCanvasOverviewController {
    /// 遮挡范围只作为滚动的首尾留白；不触发排版、修改倍率或移动已建立的视口。
    func setContentOcclusionInsets(_ insets: UIEdgeInsets) {
        guard contentOcclusionInsets != insets else { return }
        contentOcclusionInsets = insets
        guard isViewLoaded else { return }
        let offset = waterfallView.contentOffset
        waterfallView.contentInset = insets
        if preparedModel != nil { waterfallView.setContentOffset(offset, animated: false) }
        updateDesktopContentInset()
    }

    /// 上下留白允许第一张和最后一张移出控件遮挡区，坐标仍属于同一不可变几何。
    func clampedWaterfallOffsetY(_ proposed: CGFloat) -> CGFloat {
        let minimum = -waterfallView.contentInset.top
        let maximum = max(minimum, waterfallLayout.collectionViewContentSize.height
            - waterfallView.bounds.height + waterfallView.contentInset.bottom)
        return min(maximum, max(minimum, proposed))
    }

    /// 父页面切到第三种模式时先捕获代理的当前端点；旧总览的异步准备不再有提交资格。
    func interruptModeTransition(in container: UIView) -> NoteReviewCanvasReadingEndpoint? {
        updateTransitionContent()
        let paper = transitionContext?.scene.papers.first { $0.card.isAnchor }
        let endpoint = paper.map { NoteReviewCanvasReadingEndpoint.capture($0, in: container) }
        transitionWarmTask?.cancel(); transitionWarmTask = nil
        transitionPreparation?.cancel(); transitionPreparation = nil
        transitionGeneration += 1
        modeDissolve?.cancel(); modeDissolve = nil
        transitionContext?.animator.stopAnimation(true)
        cleanUpTransition(settledMode: currentMode)
        return endpoint
    }
    /// 手势稳定后才应用完整代次；后到的新请求会清除上一份待提交结果。
    func commitDeferredModelIfPossible() {
        commitPendingDeletionIfPossible()
        guard !isApplyingDeletion else { return }
        guard !isCanvasPaused, !isDisposed, !isObjectMenuPresented,
              let pending = deferredModel, pending.generation == generation, transitionState == .idle,
              widthSession == nil, !activeScrollView.isDragging, !activeScrollView.isDecelerating,
              !desktopScrollView.isZooming else { return }
        deferredModel = nil
        commit(model: pending.model, preservingCurrentID: pending.anchor)
        onReady?()
    }
    var activeScrollView: UIScrollView { currentMode == .desktop ? desktopScrollView : waterfallView }
    var presentationScrollView: UIScrollView { transitionContext?.scene ?? widthSession?.scene ?? activeScrollView }
    var focusedAccessibilityElement: Any? {
        guard let id = currentNoteID else { return nil }
        if currentMode == .waterfall, let index = preparedModel?.waterfallGeometry.indexByID[id] {
            return waterfallView.cellForItem(at: IndexPath(item: index, section: 0))
        }
        return (zoomContentView.canvasView.accessibilityElements as? [UIAccessibilityElement])?
            .first { $0.accessibilityIdentifier == "canvas-note-\(id)" }
    }

    /// 输入只在身份顺序变化时失效；当前项变化不重建总览。
    func applySnapshot(ids: [Int64], currentID: Int64, settings: NoteReviewSettings) {
        guard !isDisposed else { return }
        if queueDeletionSnapshotIfPossible(ids: ids, currentID: currentID, settings: settings) { return }
        cancelDeletionUpdate()
        pendingDeletionSnapshot = nil
        let changed = ids != dataIDs
        dataIDs = ids
        renderingSettings = settings
        selectedDesktopCardWidth = CGFloat(settings.desktopCardWidth)
        currentNoteID = ids.contains(currentID) ? currentID : ids.first
        selectedCount = ids.count
        if changed || (!requestedInitialPreparation && modelPreparation == nil) {
            requestedInitialPreparation = true
            requestPreparation(count: ids.count, preservingCurrentID: currentNoteID)
        }
    }

    /// 确认卡宽的设置回流不重复重排；其余排版或外观变化准备新端点后才交接。
    func applySettings(_ settings: NoteReviewSettings, previous: NoteReviewSettings) {
        renderingSettings = settings
        var old = previous
        old.desktopCardWidth = settings.desktopCardWidth
        let widthAlreadyApplied = abs(selectedDesktopCardWidth - CGFloat(settings.desktopCardWidth)) < 0.5
        guard old != settings || !widthAlreadyApplied else { return }
        selectedDesktopCardWidth = CGFloat(settings.desktopCardWidth)
        if let id = currentNoteID { saveViewport(for: currentMode, noteID: id) }
        requestPreparation(count: dataIDs.count, preservingCurrentID: currentNoteID)
    }

    /// 离场保留可信表面及视口，只取消尚未提交的准备；主 actor 串行阻止迟到提交。
    func pauseCanvas() {
        guard !isCanvasPaused else { return }
        isCanvasPaused = true
        dismissObjectMenu()
        endMenuPrewarming(cancelUnrequestedPreparation: true)
        cancelProgrammaticPositioning()
        rasterPreparationCache.removeAll()
        previewBatchCoordinator.cancelAll()
        pausedAt = CACurrentMediaTime()
        pauseDeletionUpdate()
        if let id = currentNoteID, transitionState == .idle { saveViewport(for: currentMode, noteID: id) }
        diagnosticsTimer?.invalidate(); diagnosticsTimer = nil
        cancelPreviewWorker()
        transitionWarmTask?.cancel(); transitionWarmTask = nil
        if transitionState == .preparing {
            transitionPreparation?.cancel(); transitionPreparation = nil
            transitionGeneration += 1
            transitionState = .idle
            setLoadingVisible(false)
        }
        modelPreparation?.cancel(); modelPreparation = nil
        realDataTask?.cancel(); realDataTask = nil
        previewDemand = []
        transitionDisplayLink?.isPaused = true
        if modeDissolve?.animator.state == .active { modeDissolve?.animator.pauseAnimation() }
        transitionContext?.animator.pauseAnimation()
        widthDisplayLink?.isPaused = true
        widthSession?.animator?.pauseAnimation()
        if let session = widthSession {
            session.previewTask?.cancel(); session.previewTask = nil
            session.finalTask?.cancel(); session.finalTask = nil
            session.finalAsyncTask?.cancel(); session.finalAsyncTask = nil
        }
    }

    /// 不依赖一次初始化标记；被暂停的工作重新准备，同一表面继续显示。
    func resumeCanvas() {
        guard !isDisposed, isViewLoaded else { return }
        let duration = pausedAt.map { CACurrentMediaTime() - $0 } ?? 0
        isCanvasPaused = false
        pausedAt = nil
        commitPendingDeletionIfPossible()
        transitionDisplayLink?.isPaused = false
        if modeDissolve?.animator.state == .active { modeDissolve?.animator.startAnimation() }
        if transitionContext?.animator.state == .active { transitionContext?.animator.startAnimation() }
        if let session = widthSession {
            session.blendStarted += duration
            if let started = session.sharpStarted { session.sharpStarted = started + duration }
            if session.animator?.state == .active { session.animator?.startAnimation() }
            wakeWidthDisplayLink()
        }
        if showsDiagnosticControls { startDiagnosticsTimer() }
        if widthSession == nil, preparationIsPending || !requestedInitialPreparation { requestPreparationIfNeeded() }
        commitDeferredModelIfPossible()
        if let target = pendingMode, transitionContext == nil, !preparationIsPending {
            pendingMode = nil
            requestMode(target)
        }
        reportDemand()
    }

    /// 永久退出同步解除所有时钟、回调和取消令牌；不等待后台系统调用。
    func disposeCanvas() {
        guard !isDisposed else { return }
        isDisposed = true
        cancelDeletionUpdate()
        pendingDeletionSnapshot = nil
        pauseCanvas()
        abandonWidthSession()
        transitionPreparation?.cancel(); transitionPreparation = nil
        transitionGeneration += 1
        modeDissolve?.cancel(); modeDissolve = nil
        transitionContext?.animator.stopAnimation(true)
        transitionContext?.scene.removeFromSuperview(); transitionContext = nil
        transitionDisplayLink?.invalidate(); transitionDisplayLink = nil
        onReady = nil; onDemand = nil; onCurrentChanged = nil; onActivate = nil
        onUserInteractionBegan = nil
        onNoteActionMenu = nil; onNoteAccessibilityActions = nil; onObjectMenuDidEnd = nil
        zoomContentView.canvasView.onNoteAccessibilityActions = nil
        onSettledMode = nil; onConfirmedWidth = nil; onControlsChanged = nil
        onPreparationChanged = nil; onWidthEnded = nil; onBlankTap = nil; onMissingIDs = nil
        sourceReader = nil; resolveDataIDs = nil
        backgroundReader = nil; preparedBackgroundImage = nil
        previewDrawingPins.removeAll(); previewSourcePins.removeAll(); transitionPreviewPins.removeAll()
    }

    /// 单条返回时恢复已保存的目标视口；书摘变化只补偿逻辑锚点，不改变倍率。
    func showModeImmediately(_ target: Mode, noteID: Int64) {
        guard preparedModel != nil else { return }
        currentNoteID = noteID
        prepareTargetSurface(target)
        currentMode = target
        desktopScrollView.alpha = target == .desktop ? 1 : 0
        waterfallView.alpha = target == .waterfall ? 1 : 0
        setSurfaceInteractionEnabled(true)
        updateCanvasAccessibility()
        releaseHiddenWaterfallProtection()
        reportDemand()
    }

    /// 定位由稳定身份完成，不跨布局保存 IndexPath。
    func locate(noteID: Int64) {
        guard preparedModel?.canvasGeometry.indexByID[noteID] != nil else { return }
        cancelProgrammaticPositioning()
        currentNoteID = noteID
        let saved = currentMode == .desktop ? desktopViewport : waterfallViewport
        align(noteID: noteID, in: currentMode, to: saved?.anchor ?? CGPoint(x: view.bounds.midX, y: view.bounds.midY))
        updateCurrentPresentation()
        reportDemand()
        invalidateVisiblePreparedPreviews()
    }

    /// 只查询可见和邻接区域；全景正文需求仍局限于当前焦点邻域。
    func reportDemand() {
        guard !isCanvasPaused, !isDisposed, !isApplyingDeletion, widthSession == nil, let model = preparedModel, let id = currentNoteID else { return }
        let visible: [Int]
        let predicted: [Int]
        if currentMode == .desktop {
            let rect = desktopPreviewRect(model: model, noteID: id)
            visible = model.canvasGeometry.indexes(in: rect)
            predicted = model.canvasGeometry.indexes(in: rect.insetBy(dx: -rect.width * 0.5, dy: -rect.height * 0.5))
        } else {
            visible = model.waterfallGeometry.indexes(in: waterfallView.bounds)
            predicted = model.waterfallGeometry.indexes(in: waterfallView.bounds.insetBy(dx: 0, dy: -waterfallView.bounds.height))
        }
        var seen = Set<Int64>()
        let visibleIDs = Array(([id] + visible.map { model.notes[$0].id }).filter { seen.insert($0).inserted }.prefix(20))
        let active = Set(visibleIDs)
        let future = Array(predicted.map { model.notes[$0].id }.filter { !active.contains($0) }.prefix(20))
        onDemand?(visibleIDs, future)
        lastPreviewRequestTime = CACurrentMediaTime()
        if previewVisibleDemand != visibleIDs { previewRetryAfter = 0 }
        previewVisibleDemand = visibleIDs
        previewDemand = Array((visibleIDs + future).prefix(40))
        previewAttemptedIDs.formIntersection(previewDemand)
        protectPreviewDemand(in: model)
        startPreviewWorker(model: model)
    }

    /// 主 actor 串行消费最新需求；移动只替换下一批，不取消仍可能完成的当前二十条。
    /// 就绪判断基于缓存而非 ID 数组是否变化，避免相同视口永远卡在低清状态。
    func startPreviewWorker(model: CanvasOverviewPreparedModel) {
        let modes = [currentMode]
        guard previewTask == nil, transitionState == .idle, CACurrentMediaTime() >= previewRetryAfter,
              !previewDemand.allSatisfy({ previewsAreReady(for: $0, in: model, modes: modes) }) else { return }
        previewWorkerGeneration += 1
        let worker = previewWorkerGeneration
        let modelGeneration = generation
        previewTask = Task { [weak self] in
            guard let self else { return }
            defer { if previewWorkerGeneration == worker { previewTask = nil } }
            do {
                while !Task.isCancelled, generation == modelGeneration, !isCanvasPaused, !isDisposed,
                      transitionState == .idle, currentMode == modes.first {
                    let missingVisible = previewVisibleDemand.filter { !self.previewsAreReady(for: $0, in: model, modes: modes) }
                    let requiresAll = !missingVisible.isEmpty
                    let candidates = requiresAll ? missingVisible : previewDemand.filter { !self.previewAttemptedIDs.contains($0) }
                    let batch = Array(candidates.filter { !self.previewsAreReady(for: $0, in: model, modes: modes) }.prefix(20))
                    guard !batch.isEmpty else { break }
                    previewAttemptedIDs.formUnion(batch)
                    try await warmPreviews(ids: batch, model: model, work: nil, modes: modes, requiresAll: requiresAll)
                }
            } catch {
                // Retain the trusted surface. A subsequent demand retries from actual readiness.
                if !Task.isCancelled { previewRetryAfter = CACurrentMediaTime() + 0.75 }
            }
        }
    }

    /// 准备、暂停或销毁使旧 worker 失去交付权；取消不抹去已经写回的高清内容。
    func cancelPreviewWorker() {
        previewWorkerGeneration += 1
        previewTask?.cancel(); previewTask = nil
        previewAttemptedIDs.removeAll()
    }

    /// 父页面取消等待只撤销未显示的准备；旧桌面、已落稳模式和相机位置继续有效。
    func cancelPendingPresentation() {
        let discardsModelPreparation = modelPreparation != nil || deferredModel != nil
        if discardsModelPreparation { generation += 1 }
        modelPreparation?.cancel(); modelPreparation = nil
        realDataTask?.cancel(); realDataTask = nil
        preparationIsPending = false
        deferredModel = nil
        if discardsModelPreparation { cancelPreviewWorker() }
        transitionPreviewPins.removeAll()
        transitionWarmTask?.cancel(); transitionWarmTask = nil
        transitionPreparation?.cancel(); transitionPreparation = nil
        transitionGeneration += 1
        pendingMode = nil
        if let modeDissolve {
            modeDissolve.cancel()
            self.modeDissolve = nil
            transitionState = .preparing
            desktopScrollView.alpha = currentMode == .desktop ? 1 : 0
            waterfallView.alpha = currentMode == .waterfall ? 1 : 0
        }
        if transitionState == .preparing {
            transitionState = .idle
            environmentCover?.removeFromSuperview(); environmentCover = nil
            setSurfaceInteractionEnabled(true)
        }
        setLoadingVisible(false)
    }

    /// 两种端点均清晰才算就绪；预览源可以正常淘汰，不影响已准备字形显示。
    func previewsAreReady(for id: Int64, in model: CanvasOverviewPreparedModel,
                          modes: [Mode] = [.desktop, .waterfall]) -> Bool {
        guard let index = model.canvasGeometry.indexByID[id] else { return true }
        return modes.allSatisfy {
            previewContent(at: index, in: model, mode: $0).preparedBlocks != nil
        }
    }

    /// 单一布局的字形身份，预取不得为了隐藏模式额外绘制另一套排版。
    func previewContent(at index: Int, in model: CanvasOverviewPreparedModel, mode: Mode) -> CanvasOverviewPaperContentGeometry {
        mode == .desktop ? model.canvasGeometry.papers[index].contentGeometry : model.waterfallGeometry.contentGeometries[index]
    }

    /// 仅保护当前布局的可见字形；预测范围只预取源，可回收的未来纸张不能挤占当前高清预算。
    func protectPreviewDemand(in model: CanvasOverviewPreparedModel) {
        var drawingKeys = Set<CanvasOverviewResourceKey>()
        var sourceKeys = Set<CanvasOverviewResourceKey>()
        for id in previewDemand.prefix(40) {
            guard let index = model.canvasGeometry.indexByID[id] else { continue }
            if let key = model.notes[index].key { sourceKeys.insert(key) }
        }
        for id in previewVisibleDemand.prefix(20) {
            guard let index = model.canvasGeometry.indexByID[id],
                  let key = previewContent(at: index, in: model, mode: currentMode).key else { continue }
            drawingKeys.insert(key)
        }
        previewDrawingPins = previewDrawingPins.filter { drawingKeys.contains($0.key) }
        previewSourcePins = previewSourcePins.filter { sourceKeys.contains($0.key) }
        for key in drawingKeys where previewDrawingPins[key] == nil {
            previewDrawingPins[key] = previewStore.drawings.lease(for: key)
        }
        for key in sourceKeys where previewSourcePins[key] == nil {
            previewSourcePins[key] = previewStore.previews.lease(for: key)
        }
    }

    /// 隐藏的瀑布流保留视口与几何，不再以 Cell 的租约保护另一套首屏字形。
    func releaseHiddenWaterfallProtection() {
        guard currentMode == .desktop, let model = preparedModel else { return }
        for case let cell as CanvasOverviewWaterfallCell in waterfallView.visibleCells {
            guard let id = cell.paperView.note?.id, let index = model.waterfallGeometry.indexByID[id],
                  let paper = cell.paperView.paper else { continue }
            cell.paperView.paper = CanvasOverviewCanvasPaper(index: index, noteID: id,
                frame: paper.frame, visualFrame: paper.visualFrame, rotation: paper.rotation,
                contentGeometry: model.waterfallGeometry.contentGeometries[index])
        }
    }

    /// 每批转换立即使对应区域失效；后续批次取消不会吞掉已完成的显示更新。
    func refreshPreparedPreviews(ids: [Int64], model: CanvasOverviewPreparedModel) {
        guard !isDisposed, preparedModel?.notes.first?.key?.generation == model.notes.first?.key?.generation else { return }
        protectPreviewDemand(in: model)
        for id in ids {
            if let paper = model.canvasGeometry.paper(for: id) {
                zoomContentView.canvasView.layer.setNeedsDisplay(paper.visualFrame.insetBy(
                    dx: -CanvasOverviewPaperRenderer.shadowPadding, dy: -CanvasOverviewPaperRenderer.shadowPadding))
            }
            if (currentMode == .waterfall || pendingMode == .waterfall), let index = model.waterfallGeometry.indexByID[id],
               let cell = waterfallView.cellForItem(at: IndexPath(item: index, section: 0)) as? CanvasOverviewWaterfallCell {
                cell.paperView.refreshPreparedContent()
            }
        }
    }

    /// 快照在独占准备队列绘制，同一原始排版只按屏幕倍率投影；取消不提交迟到像素。
    func readingEndpoint(noteID: Int64, in container: UIView) async -> NoteReviewCanvasReadingEndpoint? {
        if let model = preparedModel {
            // Only this paper participates in a reading transition. Unrelated neighbors
            // must not make opening a fully loaded note fail.
            do { try await warmPreviews(ids: [noteID], model: model,
                                       work: nil, modes: [currentMode], protectsTransition: true) }
            catch { return nil }
        }
        guard let endpoint = endpoint(in: currentMode, noteID: noteID) else { return nil }
        let token = generation
        let screenScale = traitCollection.displayScale
        let rasterScale = max(0.1, screenScale * endpoint.scale)
        let key = CanvasOverviewRasterPreparationKey(generation: token,
            modelGeneration: preparedModel?.notes.first?.key?.generation,
            kind: .reading(noteID: noteID, mode: currentMode.rawValue),
            rect: CGRect(origin: .zero, size: endpoint.paper.frame.size),
            outputSize: endpoint.paper.frame.size, scale: rasterScale)
        let image = await rasterPreparationCache.image(for: key, queue: preparationQueue) { work in
            guard !work.isCancelled else { return nil }
            let format = UIGraphicsImageRendererFormat()
            // Keep the original layout width. Only density follows the camera projection.
            format.scale = rasterScale
            format.opaque = false
            return UIGraphicsImageRenderer(size: endpoint.paper.frame.size, format: format).image { renderer in
                for block in endpoint.paper.contentGeometry.blocks {
                    guard !work.isCancelled else { return }
                    CanvasOverviewPaperRenderer.draw(block: block, paperColor: endpoint.style.paperColor,
                                                    in: renderer.cgContext)
                }
            }
        }
        guard let image, !Task.isCancelled, token == generation, !isDisposed else { return nil }
        let center = view.convert(endpoint.pose.center, to: container)
        return NoteReviewCanvasReadingEndpoint(image: image,
            frame: CGRect(x: center.x - endpoint.pose.size.width / 2, y: center.y - endpoint.pose.size.height / 2,
                width: endpoint.pose.size.width, height: endpoint.pose.size.height), rotation: endpoint.pose.rotation,
            logicalSize: endpoint.paper.frame.size,
            surface: NoteReviewCanvasReadingSurface(color: NoteReviewCanvasAppearance.resolvedPaper(endpoint.style.paperColor),
                cornerRadius: endpoint.style.cornerRadius, skin: endpoint.style.paperSkin,
                backgroundImage: endpoint.style.backgroundImage.map { UIImage(cgImage: $0) },
                backgroundOverlay: NoteReviewCanvasAppearance.resolvedPaper(endpoint.style.backgroundOverlay)),
            backdropColor: NoteReviewCanvasAppearance.interpolatePaper(from: endpoint.style.canvasBaseColor,
                to: endpoint.style.canvasTintColor.copy(alpha: 1) ?? endpoint.style.canvasTintColor,
                progress: endpoint.style.canvasTintColor.alpha))
    }

    /// 高清需求最多按二十条读取；转换在独占准备队列执行，每批结束释放源并响应取消。
    func warmPreviews(ids: [Int64], model: CanvasOverviewPreparedModel,
                      work: CanvasOverviewTransitionPreparation?, modes: [Mode] = [.desktop, .waterfall],
                      protectsTransition: Bool = false, requiresAll: Bool = true) async throws {
        let token = work ?? CanvasOverviewTransitionPreparation()
        try await withTaskCancellationHandler {
            try await prepareProtectedPreviews(ids: ids, model: model, work: token,
                                               modes: modes, protectsTransition: protectsTransition, requiresAll: requiresAll)
        } onCancel: { token.cancel() }
    }

    /// 取消令牌跨读取与准备队列传递；每条解析前检查，反向移动不再继续处理旧批剩余项。
    private func prepareProtectedPreviews(ids: [Int64], model: CanvasOverviewPreparedModel,
                                          work: CanvasOverviewTransitionPreparation?, modes: [Mode],
                                          protectsTransition: Bool, requiresAll: Bool) async throws {
        guard let sourceReader else { throw CancellationError() }
        let modelGeneration = generation
        var seen = Set<Int64>()
        let valid = ids.filter { seen.insert($0).inserted && model.noteByID[$0] != nil }
        if protectsTransition { pinTransitionPreviews(ids: valid, model: model, modes: modes) }
        let wanted = valid.filter { !previewsAreReady(for: $0, in: model, modes: modes) }
        // A ready drawing may still sit behind a Tile rasterized earlier from the fallback atlas.
        // Cache hits therefore carry the same display invalidation as a newly completed batch.
        let wantedSet = Set(wanted)
        refreshPreparedPreviews(ids: valid.filter { !wantedSet.contains($0) }, model: model)
        for start in stride(from: 0, to: wanted.count, by: 20) {
            try Task.checkCancellation()
            guard work?.isCancelled != true else { throw CancellationError() }
            let requested = Array(wanted[start..<min(start + 20, wanted.count)])
            try await previewBatchCoordinator.perform { [self] batchWork in
                guard generation == modelGeneration, !isDisposed, !isCanvasPaused, !batchWork.isCancelled else {
                    throw CancellationError()
                }
                let batch = requested.filter { !previewsAreReady(for: $0, in: model, modes: modes) }
                guard !batch.isEmpty else { return }
                let cached = Dictionary(uniqueKeysWithValues: batch.compactMap { id -> (Int64, NoteReviewCanvasResourceLease<CanvasOverviewPreviewPayload>)? in
                    guard let note = model.noteByID[id], let key = note.key,
                          let lease = note.store?.previews.lease(for: key) else { return nil }
                    return (id, lease)
                })
                let uncached = batch.filter { cached[$0] == nil }
                let sources = try await readPreviewSources(uncached, reader: sourceReader)
                try Task.checkCancellation()
                guard generation == modelGeneration, !batchWork.isCancelled else { throw CancellationError() }
                let queueInterval = CanvasOverviewPreparationMetrics.signposter.beginInterval("Restore queue wait")
                let result: (ready: [Int64], missing: Int, stale: Int, rejected: Int) = await withCheckedContinuation { continuation in
                    preparationQueue.async {
                        CanvasOverviewPreparationMetrics.signposter.endInterval("Restore queue wait", queueInterval)
                        let completed = autoreleasepool { () -> (ready: [Int64], missing: Int, stale: Int, rejected: Int) in
                            let byID = Dictionary(sources.map { ($0.noteID, $0) }, uniquingKeysWith: { _, last in last })
                            var completed: [Int64] = []
                            var missing = 0, stale = 0, rejected = 0
                            for id in batch {
                                guard !batchWork.isCancelled,
                                      let index = model.canvasGeometry.indexByID[id],
                                      let key = model.notes[index].key,
                                      let store = model.notes[index].store else { continue }
                                let note: CanvasOverviewNote
                                if let cached = cached[id] {
                                    note = model.notes[index].restoringPreview(cached.value)
                                } else if let source = byID[id],
                                          model.notes[index].revision == CanvasOverviewSourceRevision(source),
                                          let fresh = CanvasOverviewPreparationMetrics.measure("Parse preview", {
                                              CanvasOverviewTextFactory.makeRealNotes([source], style: model.style,
                                                  cancellation: batchWork).first
                                          }) {
                                    note = fresh
                                } else {
                                    if byID[id] == nil { missing += 1 } else { stale += 1 }
                                    continue
                                }
                                _ = note.cached(in: store, generation: key.generation)
                                for mode in modes {
                                    let content = mode == .desktop ? model.canvasGeometry.papers[index].contentGeometry
                                        : model.waterfallGeometry.contentGeometries[index]
                                    guard !batchWork.isCancelled, let drawingKey = content.key,
                                          content.preparedBlocks == nil else { continue }
                                    // Reuse committed rectangles and truncation; sharpening never measures a new height.
                                    let payload = CanvasOverviewPreparationMetrics.measure("Restore drawing") {
                                        CanvasOverviewDrawingPayload(blocks: content.replaying(note).blocks)
                                    }
                                    if !store.drawings.insert(payload, for: drawingKey, cost: payload.cost) { rejected += 1 }
                                }
                                completed.append(id)
                            }
                            return (completed, missing, stale, rejected)
                        }
                        continuation.resume(returning: completed)
                    }
                }
                guard generation == modelGeneration else { throw CancellationError() }
                refreshPreparedPreviews(ids: result.ready, model: model)
                try Task.checkCancellation()
                guard !batchWork.isCancelled else { throw CancellationError() }
                if protectsTransition { pinTransitionPreviews(ids: batch, model: model, modes: modes) }
                guard !requiresAll || batch.allSatisfy({ previewsAreReady(for: $0, in: model, modes: modes) }) else {
                    let cache = previewStore.drawings.statistics
                    Logger(subsystem: "com.wangke.xmnote", category: "CanvasPreview").error(
                        "preview batch unavailable: requested=\(batch.count) converted=\(result.ready.count) missing=\(result.missing) stale=\(result.stale) rejected=\(result.rejected) bytes=\(cache.bytes) protected=\(cache.protectedCount)")
                    throw CanvasOverviewPreviewError.unavailable
                }
            }
            try Task.checkCancellation()
            guard work?.isCancelled != true, generation == modelGeneration else { throw CancellationError() }
            if protectsTransition { pinTransitionPreviews(ids: requested, model: model, modes: modes) }
        }
    }

    /// 读取经宿主调度，计时包含许可排队与仓储响应；取消前不再为后一批申请读取。
    private func readPreviewSources(_ ids: [Int64], reader: SourceReader) async throws -> [NoteReviewOverviewLayoutSource] {
        guard !ids.isEmpty else { return [] }
        try Task.checkCancellation()
        let interval = CanvasOverviewPreparationMetrics.signposter.beginInterval("Read preview batch")
        defer { CanvasOverviewPreparationMetrics.signposter.endInterval("Read preview batch", interval) }
        return try await reader(ids, isMenuPrewarming ? .utility : .userInitiated)
    }

    /// 转场仅保护会出现在对应端点的排版；所有租约在交还显示权或取消时释放。
    private func pinTransitionPreviews(ids: [Int64], model: CanvasOverviewPreparedModel, modes: [Mode]) {
        for id in ids {
            guard let index = model.canvasGeometry.indexByID[id] else { continue }
            for mode in modes {
                guard let key = previewContent(at: index, in: model, mode: mode).key,
                      transitionPreviewPins[key] == nil else { continue }
                transitionPreviewPins[key] = previewStore.drawings.lease(for: key)
            }
        }
    }
}

/// 高清未能进入预算缓存或源版本已失效时，禁止假装准备成功并进入转场。
enum CanvasOverviewPreviewError: Error { case unavailable }
