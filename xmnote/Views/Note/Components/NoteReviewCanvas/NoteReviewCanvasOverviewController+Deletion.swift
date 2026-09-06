/**
 * [INPUT]: 接收数据观察交付的有序删除减集、存活卡片版本源、已测描述与会话视口
 * [OUTPUT]: 提供固定列数的删除补位、唯一显示权交接和可取消生命周期
 * [POS]: NoteReviewCanvas 页面私有删除投影；不直接访问仓储或执行删除，版本变化复用既有排版准备
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import UIKit

/// 校验只比较版本；首个变化即停止后续读取，缺失身份交回宿主重新核对清单。
private enum CanvasOverviewDeletionValidationError: Error {
    case changedRevision
    case missingIDs(Set<Int64>)
}

/// 只记录最新删除减集；菜单、手势和其他转场结束后才接管可信画面。
nonisolated struct CanvasOverviewDeletionSnapshot: Sendable {
    let ids: [Int64]
    let currentID: Int64?
    let sourceAnchorID: Int64?
}

/// 主 actor 持有一次补位的工作和显示资源，永久关闭可以同步撤销其交付资格。
@MainActor
final class CanvasOverviewDeletionUpdate {
    let snapshot: CanvasOverviewDeletionSnapshot
    let cancellation = CanvasOverviewTransitionPreparation()
    var task: Task<Void, Never>?
    var scene: CanvasOverviewDeletionScene?
    var animator: UIViewPropertyAnimator?
    /// 固定本次观察快照，后到的删除请求会替换整个工作单元。
    init(snapshot: CanvasOverviewDeletionSnapshot) { self.snapshot = snapshot }
}

/// 准备队列仅重排现有高度和绘制引用；所有剩余 ID 必须来自旧代次，不能退回全文测量。
nonisolated enum CanvasOverviewDeletionModelBuilder {
    /// 重测分支仍回到删除前的相机和锚点，不使用准备器的首次阅读倍率或居中位置。
    static func reanchored(_ model: CanvasOverviewPreparedModel, anchorID: Int64,
                          anchor: CGPoint, zoomScale: CGFloat, viewportSize: CGSize) -> CanvasOverviewPreparedModel? {
        guard let paper = model.canvasGeometry.paper(for: anchorID) else { return nil }
        let zoom = max(0.01, zoomScale)
        let rect = CGRect(x: paper.frame.midX - anchor.x / zoom, y: paper.frame.midY - anchor.y / zoom,
                          width: viewportSize.width / zoom, height: viewportSize.height / zoom)
        return CanvasOverviewPreparedModel(notes: model.notes, noteByID: model.noteByID,
            canvasGeometry: model.canvasGeometry, waterfallGeometry: model.waterfallGeometry,
            style: model.style, waterfallStyle: model.waterfallStyle, isRealData: model.isRealData,
            richTextNoteCount: model.richTextNoteCount, previewRichNoteIDs: model.previewRichNoteIDs,
            overviewImage: model.overviewImage, initialViewportImage: nil, initialViewportRect: rect)
    }

    /// 存活卡片重用原测量与缓存键，取消、重复或缺失身份不会交付半份模型。
    static func build(model: CanvasOverviewPreparedModel, survivingIDs: [Int64], viewportSize: CGSize,
                      screenScale: CGFloat, anchorID: Int64, anchor: CGPoint, zoomScale: CGFloat,
                      cancellation: CanvasOverviewTransitionPreparation? = nil) -> CanvasOverviewPreparedModel? {
        guard !survivingIDs.isEmpty, cancellation?.isCancelled != true else { return nil }
        var notes: [CanvasOverviewNote] = []
        var desktop: [Int: CanvasOverviewPaperContentGeometry] = [:]
        var waterfall: [CanvasOverviewPaperContentGeometry] = []
        for id in survivingIDs {
            guard cancellation?.isCancelled != true,
                  let index = model.canvasGeometry.indexByID[id],
                  let note = model.noteByID[id],
                  let waterfallIndex = model.waterfallGeometry.indexByID[id] else { return nil }
            desktop[notes.count] = model.canvasGeometry.papers[index].contentGeometry
            waterfall.append(model.waterfallGeometry.contentGeometries[waterfallIndex])
            notes.append(note)
        }
        guard Set(survivingIDs).count == notes.count,
              let canvas = CanvasOverviewGeometryBuilder.makeCanvas(notes: notes, viewportSize: viewportSize,
                cardWidth: model.canvasGeometry.cardWidth, fixedColumns: model.canvasGeometry.columnCount,
                cancellation: cancellation, preparedContents: desktop,
                isRTL: model.canvasGeometry.spatialIndex.isRTL, parameters: model.canvasGeometry.parameters),
              let flow = CanvasOverviewGeometryBuilder.makeWaterfall(notes: notes, viewportSize: viewportSize,
                traits: model.style.traits, cancellation: cancellation, preparedContents: waterfall),
              let paper = canvas.paper(for: anchorID) else { return nil }
        let zoom = max(0.01, zoomScale)
        let rect = CGRect(x: paper.frame.midX - anchor.x / zoom, y: paper.frame.midY - anchor.y / zoom,
                          width: viewportSize.width / zoom, height: viewportSize.height / zoom)
        let ids = Set(survivingIDs)
        return CanvasOverviewPreparedModel(notes: notes, noteByID: Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) }),
            canvasGeometry: canvas, waterfallGeometry: flow, style: model.style, waterfallStyle: model.waterfallStyle,
            isRealData: model.isRealData, richTextNoteCount: notes.filter(\.hasRichFormatting).count,
            previewRichNoteIDs: model.previewRichNoteIDs.filter(ids.contains),
            overviewImage: CanvasOverviewCanvasRasterizer.makeOverview(geometry: canvas, style: model.style,
                maximumLongEdge: 2_048, cancellation: cancellation),
            initialViewportImage: nil,
            initialViewportRect: rect)
    }
}

extension NoteReviewCanvasOverviewController {
    var isApplyingDeletion: Bool { deletionUpdate != nil || pendingDeletionSnapshot != nil }

    /// 主 actor 背压读取最多128条源，仅比较三项更新时间；每批释放HTML，取消后不再查询下一批。
    private func deletionRevisionsMatch(model: CanvasOverviewPreparedModel, ids: [Int64],
                                        work: CanvasOverviewTransitionPreparation) async throws -> Bool {
        guard model.isRealData, !ids.isEmpty else { return true }
        guard let sourceReader else { throw CancellationError() }
        let expectedGeneration = generation
        let adapter = NoteReviewCanvasSourceAdapter { [weak self] ids, priority in
            try Task.checkCancellation()
            guard let self, !isDisposed, !isCanvasPaused, !work.isCancelled,
                  generation == expectedGeneration else { throw CancellationError() }
            return try await sourceReader(ids, priority)
        }
        do {
            try await adapter.consume(ids: ids, priority: .userInitiated) { [weak self] batch in
                try Task.checkCancellation()
                guard let self, !isDisposed, !isCanvasPaused, !work.isCancelled,
                      generation == expectedGeneration else { throw CancellationError() }
                if !batch.missingIDs.isEmpty { throw CanvasOverviewDeletionValidationError.missingIDs(batch.missingIDs) }
                if batch.sources.contains(where: { model.noteByID[$0.noteID]?.revision != CanvasOverviewSourceRevision($0) }) {
                    throw CanvasOverviewDeletionValidationError.changedRevision
                }
            }
            return true
        } catch CanvasOverviewDeletionValidationError.changedRevision { return false }
    }

    /// 只认保序减集；筛选、重新随机、新增或配置变化仍交给原有整代准备路径。
    func queueDeletionSnapshotIfPossible(ids: [Int64], currentID: Int64, settings: NoteReviewSettings) -> Bool {
        guard let model = preparedModel, renderingSettings == settings else { return false }
        let previous = model.notes.map(\.id)
        let remaining = Set(ids)
        guard ids.count < previous.count, remaining.count == ids.count,
              previous.filter(remaining.contains) == ids else { return false }
        let oldAnchor = pendingDeletionSnapshot?.sourceAnchorID ?? deletionUpdate?.snapshot.sourceAnchorID ?? currentNoteID
        cancelDeletionUpdate()
        dataIDs = ids
        selectedCount = ids.count
        currentNoteID = ids.contains(currentID) ? currentID : ids.first
        pendingDeletionSnapshot = CanvasOverviewDeletionSnapshot(ids: ids, currentID: currentNoteID, sourceAnchorID: oldAnchor)
        commitPendingDeletionIfPossible()
        return true
    }

    /// 主 actor 仅在可信静止端点开始补位；版本一致复用旧测量，合并编辑则复用既有准备管线。
    func commitPendingDeletionIfPossible() {
        guard !isDisposed, !isCanvasPaused, !isObjectMenuPresented, deletionUpdate == nil,
              let snapshot = pendingDeletionSnapshot, let source = preparedModel,
              transitionState == .idle, widthSession == nil,
              !desktopScrollView.isDragging, !desktopScrollView.isDecelerating, !desktopScrollView.isZooming,
              !waterfallView.isDragging, !waterfallView.isDecelerating else { return }
        pendingDeletionSnapshot = nil
        cancelProgrammaticPositioning()
        rasterPreparationCache.removeAll()
        previewBatchCoordinator.cancelAll()
        cancelPreviewWorker()
        transitionWarmTask?.cancel(); transitionWarmTask = nil
        modelPreparation?.cancel(); modelPreparation = nil
        realDataTask?.cancel(); realDataTask = nil
        deferredModel = nil
        generation += 1
        let token = generation
        let update = CanvasOverviewDeletionUpdate(snapshot: snapshot)
        let work = update.cancellation
        deletionUpdate = update
        modelPreparation = work
        preparationIsPending = true
        setSurfaceInteractionEnabled(false)
        let size = desktopScrollView.bounds.size
        let scale = traitCollection.displayScale
        let zoom = desktopScrollView.zoomScale
        let oldID = snapshot.sourceAnchorID ?? snapshot.currentID
        let localBounds = desktopScrollView.convert(desktopScrollView.bounds, to: view)
        let desktopAnchor = oldID.flatMap { paperPose(in: .desktop, noteID: $0)?.center }
            ?? CGPoint(x: localBounds.midX, y: localBounds.midY)
        let flowBounds = waterfallView.convert(waterfallView.bounds, to: view)
        let waterfallAnchor = oldID.flatMap { paperPose(in: .waterfall, noteID: $0)?.center }
            ?? CGPoint(x: flowBounds.midX, y: flowBounds.midY)
        let sourceOrigin = zoomContentView.canvasView.convert(CGPoint.zero, to: view)
        let sourceWaterfallOffset = waterfallView.contentOffset
        let isFull = isShowingFullDesktop
        let queue = preparationQueue
        update.task = Task { [weak self, weak update] in
            guard let self, let update else { return }
            let target: CanvasOverviewPreparedModel?
            let replacesContent: Bool
            let relativeAnchor = CGPoint(x: desktopAnchor.x - localBounds.minX, y: desktopAnchor.y - localBounds.minY)
            do {
                if try await deletionRevisionsMatch(model: source, ids: snapshot.ids, work: work) {
                    replacesContent = false
                    target = await withCheckedContinuation { continuation in
                        queue.async {
                            let result = autoreleasepool {
                                snapshot.currentID.flatMap { id in CanvasOverviewDeletionModelBuilder.build(model: source,
                                    survivingIDs: snapshot.ids, viewportSize: size, screenScale: scale, anchorID: id,
                                    anchor: relativeAnchor, zoomScale: zoom, cancellation: work) }
                            }
                            continuation.resume(returning: result)
                        }
                    }
                } else {
                    replacesContent = true
                    // A coalesced edit invalidates old heights and fallback pixels; reuse the existing
                    // preparation pipeline with fixed tracks, then hand over through this same scene.
                    let rebuilt = try await prepareModel(ids: snapshot.ids, style: source.style,
                        waterfallStyle: source.waterfallStyle, size: size, scale: scale,
                        width: source.canvasGeometry.cardWidth, packing: desktopPacking, work: work,
                        fixedColumns: source.canvasGeometry.columnCount)
                    target = snapshot.currentID.flatMap { id in rebuilt.flatMap {
                        CanvasOverviewDeletionModelBuilder.reanchored($0, anchorID: id, anchor: relativeAnchor,
                            zoomScale: zoom, viewportSize: size)
                    } }
                }
            } catch {
                guard generation == token, deletionUpdate === update, !isDisposed, !isCanvasPaused else { return }
                cancelDeletionUpdate()
                if let validation = error as? CanvasOverviewDeletionValidationError,
                   case .missingIDs(let missing) = validation {
                    onMissingIDs?(missing)
                } else if !(error is CancellationError) {
                    onPreparationChanged?(false, "暂时无法更新回顾内容")
                }
                return
            }
            guard !Task.isCancelled, generation == token, deletionUpdate === update, !isDisposed, !isCanvasPaused else { return }
            guard snapshot.ids.isEmpty || target != nil else {
                if modelPreparation === work { modelPreparation = nil }
                deletionUpdate = nil
                preparationIsPending = false
                setSurfaceInteractionEnabled(true)
                onPreparationChanged?(false, "暂时无法更新回顾内容")
                return
            }
            let activeMode = currentMode
            let isDesktop = activeMode == .desktop
            let targetOrigin = target.flatMap { model in snapshot.currentID.flatMap { model.canvasGeometry.paper(for: $0) } }
                .map { CGPoint(x: desktopAnchor.x - $0.frame.midX * zoom, y: desktopAnchor.y - $0.frame.midY * zoom) } ?? sourceOrigin
            let targetFlowY = target.flatMap { model in snapshot.currentID.flatMap { model.waterfallGeometry.indexByID[$0] }
                .map { model.waterfallGeometry.frames[$0].midY - (waterfallAnchor.y - flowBounds.minY) } } ?? 0
            if let target, let id = snapshot.currentID {
                let visible = activeMode == .desktop
                    ? target.canvasGeometry.indexes(in: CGRect(x: -targetOrigin.x / zoom, y: -targetOrigin.y / zoom,
                        width: size.width / zoom, height: size.height / zoom))
                    : target.waterfallGeometry.indexes(in: CGRect(x: 0, y: targetFlowY, width: size.width, height: size.height))
                // Only the incoming viewport may need a bounded high-resolution cache refill.
                try? await warmPreviews(ids: [id] + visible.prefix(19).map { target.notes[$0].id }, model: target,
                    work: update.cancellation, modes: [activeMode], protectsTransition: true)
            }
            guard !Task.isCancelled, generation == token, deletionUpdate === update, !isDisposed, !isCanvasPaused else { return }
            let sceneSize = view.bounds.size
            let reduced = UIAccessibility.isReduceMotionEnabled || UIAccessibility.prefersCrossFadeTransitions || reduceMotionSwitch.isOn
            let rendered: (CanvasOverviewPreparedModel?, CanvasOverviewDeletionPresentation) = await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume(returning: autoreleasepool {
                        var final = target
                        if let prepared = target {
                            final?.initialViewportImage = CanvasOverviewCanvasRasterizer.makeViewport(
                                geometry: prepared.canvasGeometry, style: prepared.style,
                                canvasRect: prepared.initialViewportRect, outputSize: size, outputScale: scale,
                                cancellation: work)
                        }
                        let presentation = CanvasOverviewDeletionPresentation.make(
                        source: source, target: target, desktop: isDesktop, size: sceneSize,
                        screenScale: scale, zoom: zoom, sourceOrigin: sourceOrigin, targetOrigin: targetOrigin,
                        flowOrigin: flowBounds.origin, sourceFlowOffset: sourceWaterfallOffset.y,
                        targetFlowOffset: targetFlowY, prefersDissolve: reduced || isFull || replacesContent,
                        cancellation: work)
                        return (final, presentation)
                    })
                }
            }
            guard !Task.isCancelled, generation == token, deletionUpdate === update, !isDisposed, !isCanvasPaused else { return }
            let presentation = rendered.1
            let scene = CanvasOverviewDeletionScene(presentation: presentation, size: sceneSize)
            update.scene = scene
            view.insertSubview(scene, belowSubview: topControlPanel)
            if let id = snapshot.currentID {
                desktopViewport = CanvasOverviewViewportState(noteID: id, offset: desktopScrollView.contentOffset,
                    zoomScale: zoom, anchor: desktopAnchor, viewportRect: localBounds)
                waterfallViewport = CanvasOverviewViewportState(noteID: id, offset: CGPoint(x: 0, y: targetFlowY),
                    zoomScale: 1, anchor: waterfallAnchor, viewportRect: flowBounds)
            }
            if let target = rendered.0 {
                // A final snapshot owns the pixels while real geometry and native zoom are replaced once underneath it.
                commit(model: target, preservingCurrentID: snapshot.currentID, restoringWidthViewport: desktopViewport,
                       animatesEnvironmentChange: false)
                waterfallLayout.geometry = target.waterfallGeometry
                waterfallView.reloadData()
                let bottom = max(waterfallView.contentInset.bottom,
                    targetFlowY + waterfallView.bounds.height - target.waterfallGeometry.contentSize.height)
                var insets = waterfallView.contentInset
                insets.top = max(insets.top, -targetFlowY); insets.bottom = bottom
                waterfallView.contentInset = insets
                waterfallView.setContentOffset(CGPoint(x: 0, y: targetFlowY), animated: false)
                waterfallView.layoutIfNeeded()
                if let id = snapshot.currentID {
                    saveViewport(for: .desktop, noteID: id)
                    saveViewport(for: .waterfall, noteID: id)
                }
                isShowingFullDesktop = isFull
            } else {
                preparedModel = nil
                currentNoteID = nil
                waterfallLayout.geometry = nil
                waterfallView.reloadData()
                zoomContentView.isHidden = true
                desktopViewport = nil; waterfallViewport = nil
            }
            update.task = nil
            if modelPreparation === work { modelPreparation = nil }
            preparationIsPending = false
            setSurfaceInteractionEnabled(false)
            let animator = presentation.isDissolve
                ? UIViewPropertyAnimator(duration: 0.12, curve: .easeInOut)
                : UIViewPropertyAnimator(duration: 0.28, dampingRatio: 0.96)
            update.animator = animator
            animator.addAnimations { scene.showTarget() }
            animator.addCompletion { [weak self, weak update] _ in
                guard let self, let update, self.deletionUpdate === update else { return }
                self.finishDeletionUpdate(update)
            }
            animator.startAnimation()
        }
    }

    /// 模式请求可以立即结束已提交的短补位；后台准备未完时由 onReady 接回原有模式调度。
    func flushDeletionForModeRequest() -> Bool {
        if let update = deletionUpdate, let animator = update.animator, animator.state == .active {
            animator.stopAnimation(false)
            animator.finishAnimation(at: .end)
        }
        return !isApplyingDeletion
    }

    /// 唯一完成入口先交还真实表面，再释放临时纹理，最后恢复需求和宿主准备状态。
    func finishDeletionUpdate(_ update: CanvasOverviewDeletionUpdate) {
        guard deletionUpdate === update else { return }
        update.scene?.removeFromSuperview()
        if modelPreparation === update.cancellation { modelPreparation = nil }
        deletionUpdate = nil
        transitionPreviewPins.removeAll()
        setSurfaceInteractionEnabled(true)
        updateCurrentPresentation(); updateCanvasAccessibility(); reportDemand()
        onPreparationChanged?(false, nil)
        onReady?()
        commitPendingDeletionIfPossible()
    }

    /// 暂停时已提交的补位直接落稳；尚在计算的请求保留身份，恢复后重新按当时视口准备。
    func pauseDeletionUpdate() {
        guard let update = deletionUpdate else { return }
        if update.animator != nil { _ = flushDeletionForModeRequest() }
        else {
            pendingDeletionSnapshot = update.snapshot
            cancelDeletionUpdate()
        }
    }

    /// 环境变化或关闭撤销代次并同步回收代理；不会执行或撤销已完成的数据库事务。
    func cancelDeletionUpdate() {
        guard let update = deletionUpdate else { return }
        update.cancellation.cancel()
        update.task?.cancel()
        update.animator?.stopAnimation(true)
        update.scene?.removeFromSuperview()
        if modelPreparation === update.cancellation { modelPreparation = nil }
        deletionUpdate = nil
        transitionPreviewPins.removeAll()
        preparationIsPending = false
        setSurfaceInteractionEnabled(true)
    }
}

/// 一次准备出的有限纸张纹理；相同文字从旧位置移动到新位置，不产生另一份排版。
nonisolated struct CanvasOverviewDeletionPresentation: @unchecked Sendable {
    /// 同一纸张在源、目标至少一端可见，唯一纹理随空间关系迁移。
    struct Paper {
        let image: UIImage
        let source: CanvasOverviewPaperPose?
        let target: CanvasOverviewPaperPose?
    }
    let papers: [Paper]
    let sourceImage: UIImage?
    let targetImage: UIImage?
    let background: CGColor
    let backgroundTint: CGColor
    var isDissolve: Bool { sourceImage != nil || papers.isEmpty }

    /// 后台只绘制两端可见集合；超过代理或 64 MB 像素预算时整体短淡变，不降低文字分辨率。
    static func make(source: CanvasOverviewPreparedModel, target: CanvasOverviewPreparedModel?, desktop: Bool,
                     size: CGSize, screenScale: CGFloat, zoom: CGFloat, sourceOrigin: CGPoint, targetOrigin: CGPoint,
                     flowOrigin: CGPoint, sourceFlowOffset: CGFloat, targetFlowOffset: CGFloat,
                     prefersDissolve: Bool, cancellation: CanvasOverviewTransitionPreparation) -> Self {
        let bounds = CGRect(origin: .zero, size: size)
        let style = desktop ? source.style : source.waterfallStyle
        /// 两种空间索引只返回视口候选，不在动画时间轴扫描完整清单。
        func visible(_ model: CanvasOverviewPreparedModel, origin: CGPoint, flow: CGFloat) -> [Int64] {
            let indexes = desktop ? model.canvasGeometry.indexes(in: CGRect(
                x: -origin.x / zoom, y: -origin.y / zoom, width: size.width / zoom, height: size.height / zoom))
                : model.waterfallGeometry.indexes(in: bounds.offsetBy(dx: -flowOrigin.x, dy: flow - flowOrigin.y))
            return indexes.map { model.notes[$0].id }
        }
        /// 把逻辑纸面映射到相同内容容器，缩放仅影响桌面空间变换。
        func pose(_ model: CanvasOverviewPreparedModel, id: Int64, origin: CGPoint, flow: CGFloat) -> CanvasOverviewPaperPose? {
            if desktop, let paper = model.canvasGeometry.paper(for: id) {
                return CanvasOverviewPaperPose(center: CGPoint(x: paper.frame.midX * zoom + origin.x,
                    y: paper.frame.midY * zoom + origin.y), size: CGSize(width: paper.frame.width * zoom,
                    height: paper.frame.height * zoom), rotation: paper.rotation)
            }
            guard let index = model.waterfallGeometry.indexByID[id] else { return nil }
            let frame = model.waterfallGeometry.frames[index]
            return CanvasOverviewPaperPose(center: CGPoint(x: frame.midX + flowOrigin.x,
                y: frame.midY + flowOrigin.y - flow), size: frame.size, rotation: 0)
        }
        let sourceIDs = visible(source, origin: sourceOrigin, flow: sourceFlowOffset)
        let targetIDs = target.map { visible($0, origin: targetOrigin, flow: targetFlowOffset) } ?? []
        var seen = Set<Int64>()
        let ids = (sourceIDs + targetIDs).filter { seen.insert($0).inserted }
        let factor: CGFloat = desktop ? zoom : 1
        /// 两种布局均消费已提交的内容描述，不重新创建行布局。
        func paper(_ model: CanvasOverviewPreparedModel, id: Int64) -> CanvasOverviewCanvasPaper? {
            guard let index = model.canvasGeometry.indexByID[id] else { return nil }
            if desktop { return model.canvasGeometry.papers[index] }
            guard let flowIndex = model.waterfallGeometry.indexByID[id] else { return nil }
            let frame = model.waterfallGeometry.frames[flowIndex]
            return CanvasOverviewCanvasPaper(index: index, noteID: id, frame: frame, visualFrame: frame,
                rotation: 0, contentGeometry: model.waterfallGeometry.contentGeometries[flowIndex])
        }
        let pixels = ids.reduce(CGFloat(0)) { total, id in
            guard let value = paper(source, id: id) else { return total }
            return total + (value.frame.width + 48) * (value.frame.height + 48) * pow(factor * screenScale, 2) * 4
        }
        let dissolve = prefersDissolve || ids.count > 48 || pixels > 64 * 1_024 * 1_024
        /// 全景按视口绘制同一内容，两张有界图承接准备期间的可信表面。
        func fullImage(_ model: CanvasOverviewPreparedModel?, origin: CGPoint, flow: CGFloat) -> UIImage? {
            let format = UIGraphicsImageRendererFormat(); format.scale = min(screenScale, 2_048 / max(size.width, size.height))
            return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
                CanvasOverviewCanvasRasterizer.fillCanvas(bounds, style: style, in: ctx.cgContext)
                guard let model else { return }
                for id in visible(model, origin: origin, flow: flow) {
                    guard !cancellation.isCancelled, let value = paper(model, id: id),
                          let note = model.noteByID[id], let position = pose(model, id: id, origin: origin, flow: flow) else { continue }
                    ctx.cgContext.saveGState()
                    ctx.cgContext.translateBy(x: position.center.x, y: position.center.y)
                    ctx.cgContext.scaleBy(x: factor, y: factor)
                    CanvasOverviewPaperRenderer.draw(paper: CanvasOverviewCanvasPaper(index: value.index, noteID: id,
                        frame: CGRect(x: -value.frame.width / 2, y: -value.frame.height / 2, width: value.frame.width,
                            height: value.frame.height), visualFrame: .zero, rotation: value.rotation,
                        contentGeometry: value.contentGeometry), note: note, style: style, in: ctx.cgContext)
                    ctx.cgContext.restoreGState()
                }
            }
        }
        if dissolve {
            return Self(papers: [], sourceImage: fullImage(source, origin: sourceOrigin, flow: sourceFlowOffset),
                targetImage: fullImage(target, origin: targetOrigin, flow: targetFlowOffset), background: style.canvasBaseColor,
                backgroundTint: style.canvasTintColor)
        }
        var papers: [Paper] = []
        let sourceSet = Set(sourceIDs), targetSet = Set(targetIDs)
        for id in ids {
            guard !cancellation.isCancelled, let value = paper(source, id: id), let note = source.noteByID[id] else { break }
            let format = UIGraphicsImageRendererFormat(); format.scale = max(0.1, factor * screenScale); format.opaque = false
            let textureSize = CGSize(width: value.frame.width + 48, height: value.frame.height + 48)
            let image = UIGraphicsImageRenderer(size: textureSize, format: format).image { ctx in
                CanvasOverviewPaperRenderer.draw(paper: CanvasOverviewCanvasPaper(index: value.index, noteID: id,
                    frame: CGRect(origin: CGPoint(x: 24, y: 24), size: value.frame.size), visualFrame: .zero,
                    rotation: 0, contentGeometry: value.contentGeometry), note: note, style: style, in: ctx.cgContext)
            }
            papers.append(Paper(image: image,
                source: sourceSet.contains(id) ? pose(source, id: id, origin: sourceOrigin, flow: sourceFlowOffset) : nil,
                target: targetSet.contains(id) ? target.flatMap { pose($0, id: id, origin: targetOrigin, flow: targetFlowOffset) } : nil))
        }
        return Self(papers: papers, sourceImage: nil, targetImage: nil, background: style.canvasBaseColor,
            backgroundTint: style.canvasTintColor)
    }
}

/// 只持有有界纹理和显示属性；动画热路径不访问模型、缓存或文字排版。
@MainActor
final class CanvasOverviewDeletionScene: UIView {
    let presentation: CanvasOverviewDeletionPresentation
    private let sourceImage = UIImageView()
    private let targetImage = UIImageView()
    private var papers: [UIImageView] = []
    /// 全部纹理已在后台准备完成；首帧完整接管后才允许真实几何在下面改变。
    init(presentation: CanvasOverviewDeletionPresentation, size: CGSize) {
        self.presentation = presentation
        super.init(frame: CGRect(origin: .zero, size: size))
        clipsToBounds = true; isUserInteractionEnabled = false; accessibilityElementsHidden = true
        backgroundColor = NoteReviewCanvasAppearance.resolvedPaper(presentation.background)
        let tint = UIView(frame: bounds)
        tint.backgroundColor = NoteReviewCanvasAppearance.resolvedPaper(presentation.backgroundTint)
        addSubview(tint)
        if presentation.isDissolve {
            for image in [targetImage, sourceImage] { image.frame = bounds; addSubview(image) }
            sourceImage.image = presentation.sourceImage; targetImage.image = presentation.targetImage
        } else {
            for paper in presentation.papers {
                let image = UIImageView(image: paper.image)
                image.bounds.size = paper.image.size
                addSubview(image); papers.append(image)
                apply(paper.source ?? paper.target!, to: image)
                image.alpha = paper.source == nil ? 0 : 1
            }
        }
    }
    /// 仅支持程序化宿主创建。
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    /// 原始文字纹理只做等比映射；删除淡出，存活纸张到其唯一目标位置。
    func showTarget() {
        if presentation.isDissolve { sourceImage.alpha = 0; return }
        for (index, value) in presentation.papers.enumerated() {
            if let target = value.target { apply(target, to: papers[index]) }
            papers[index].alpha = value.target == nil ? 0 : 1
        }
    }
    /// 旋转与统一比例保持字形，不改变纸张的原始排版尺寸。
    private func apply(_ pose: CanvasOverviewPaperPose, to image: UIImageView) {
        let scale = pose.size.width / max(1, image.bounds.width - 48)
        image.center = pose.center
        image.transform = CGAffineTransform(rotationAngle: pose.rotation).scaledBy(x: scale, y: scale)
    }
}
