/**
 * [INPUT]: 接收 Session 注入的叶子读取、真实可见范围和已准备的区域模型
 * [OUTPUT]: 将有界区域窗口合成为同一个桌面画布，保持存活纸张的屏幕位置
 * [POS]: 总览控制器的分区准备 owner；不持有仓储，不在手势回调测量正文
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import UIKit

extension NoteReviewCanvasOverviewController {
    /// 大范围失效或离场只撤销后续准备；区域模型仍由可信显示表面持有，迟到任务不能提交。
    func cancelRegionalPreparation() {
        regionalRequestGeneration += 1
        regionalTask?.cancel(); regionalTask = nil
        regionalWork?.cancel(); regionalWork = nil
    }

    /// 首叶独立就绪即可进入；其余八区不能加入首屏等待链。
    func seedRegionalWindow(_ local: CanvasOverviewPreparedModel) -> CanvasOverviewPreparedModel {
        if activeDirectoryRegion?.stackID != nil {
            cancelRegionalPreparation()
            regionalModels.removeAll(); regionalMetadata.removeAll(); regionalWindow = nil
            onResidentRegionIDs?(Set(local.notes.map(\.id)))
            return local
        }
        guard let region = activeDirectoryRegion, directoryNeighborReader != nil else { return local }
        cancelRegionalPreparation()
        regionalUnavailableIDs.removeAll()
        var retained = local
        retained.initialViewportImage = nil
        regionalModels = [region.group.id: retained]
        regionalMetadata = [region.group.id: region]
        var window = NoteReviewCanvasRegionWindow(regionWidth: CanvasOverviewRegionalGeometry.trackWidth(for: local.canvasGeometry),
            isRTL: local.canvasGeometry.spatialIndex.isRTL)
        guard window.admit(id: region.group.id, size: local.canvasGeometry.contentSize),
              let geometry = CanvasOverviewRegionalGeometry.compose([(region.group.id, local.canvasGeometry)], window: window),
              let slice = geometry.regionSlices.first else { return local }
        regionalWindow = window
        onResidentRegionIDs?(Set(local.notes.map(\.id)))
        var result = replacingCanvas(in: local, with: geometry)
        result.initialViewportImage = local.initialViewportImage
        result.initialViewportRect = local.initialViewportRect.offsetBy(dx: slice.origin.x, dy: slice.origin.y)
        return result
    }

    /// 相机热路径至多查询九个索引；只替换下一项需求，不取消仍受可见范围保护的读取。
    func requestRegionalNeighborsIfNeeded() {
        guard directoryNeighborReader != nil, regionalWindow != nil, currentMode == .desktop,
              canCommitBackgroundGeometry?() != false,
              view.alpha > 0.5, !isCanvasPaused, !isDisposed, transitionState == .idle,
              widthSession == nil, modelPreparation == nil, !isPositioningViewport,
              let model = preparedModel, let currentNoteID else { return }
        let rect = zoomContentView.canvasView.convert(desktopScrollView.bounds, from: desktopScrollView)
        let centerID = model.canvasGeometry.nearestPaper(to: CGPoint(x: rect.midX, y: rect.midY))?.noteID ?? currentNoteID
        guard let index = model.canvasGeometry.indexByID[centerID],
              let slice = model.canvasGeometry.regionSlices.first(where: { $0.indexRange.contains(index) }),
              let region = regionalMetadata[slice.id] else { return }
        let forward = desktopScrollView.panGestureRecognizer.velocity(in: desktopScrollView).y <= 0
        regionalDesiredIDs = NoteReviewCanvasRegionWindow.demand(around: region.group.id, forward: forward)
        guard regionalTask == nil else { return }
        regionalRequestGeneration += 1
        let token = regionalRequestGeneration
        let inputGeneration = generation
        let work = CanvasOverviewTransitionPreparation()
        regionalWork = work
        regionalTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if regionalRequestGeneration == token { regionalTask = nil; regionalWork = nil }
            }
            do {
                while !Task.isCancelled, !work.isCancelled, generation == inputGeneration,
                      regionalRequestGeneration == token, !isCanvasPaused, !isDisposed, widthSession == nil {
                    guard let requested = regionalDesiredIDs.first(where: { regionalModels[$0] == nil && !regionalUnavailableIDs.contains($0) }),
                          let read = directoryNeighborReader, let model = preparedModel else { break }
                    guard let region = try await read(requested) else {
                        regionalUnavailableIDs.insert(requested); continue
                    }
                    try Task.checkCancellation()
                    guard regionalDesiredIDs.contains(requested) else { continue }
                    // No more than nine live regions including the one being built.
                    guard await reclaimRegionalWindowIfNeeded(inputGeneration: inputGeneration, work: work),
                          regionalModels.count < 9 else { break }
                    let local = try await prepareModel(ids: region.members.map(\.record.noteID), style: model.style,
                        waterfallStyle: model.waterfallStyle, size: desktopScrollView.bounds.size,
                        scale: traitCollection.displayScale, width: model.canvasGeometry.cardWidth,
                        packing: model.canvasGeometry.parameters.packing, work: work,
                        fixedColumns: model.canvasGeometry.columnCount, preparesWaterfall: false,
                        preparesInitialViewport: false)
                    try Task.checkCancellation()
                    guard generation == inputGeneration, regionalRequestGeneration == token,
                          !isCanvasPaused, !work.isCancelled, regionalDesiredIDs.contains(requested), let local,
                          var window = regionalWindow else { continue }
                    guard window.admit(id: requested, size: local.canvasGeometry.contentSize) else { break }
                    let next = regionalModels.merging([requested: local]) { _, value in value }
                    guard await publishRegionalWindow(window, models: next, inputGeneration: inputGeneration, work: work) else { break }
                    regionalMetadata[requested] = region
                    regionalModels = next
                    regionalWindow = window
                    onResidentRegionIDs?(Set(next.values.flatMap { $0.notes.map(\.id) }))
                }
            } catch { /* Existing regions remain readable; the next demand retries only missing work. */ }
        }
    }

    /// 惯性中的当前与预测区域受保护；空间不足时等待，而不是强制回收仍在屏幕上的区域。
    func reclaimRegionalWindowIfNeeded(inputGeneration: Int, work: CanvasOverviewTransitionPreparation) async -> Bool {
        guard var window = regionalWindow, let model = preparedModel else { return false }
        guard window.placements.count >= 9 else { return true }
        let rect = zoomContentView.canvasView.convert(desktopScrollView.bounds, from: desktopScrollView)
            .insetBy(dx: -desktopScrollView.bounds.width / desktopScrollView.zoomScale,
                     dy: -desktopScrollView.bounds.height / desktopScrollView.zoomScale)
        let protected = Set(model.canvasGeometry.regionSlices.filter { $0.frame.intersects(rect) }.map(\.id))
        window.retain(wanted: Set(regionalDesiredIDs), protected: protected)
        guard window.placements.count < 9 else { return false }
        let next = regionalModels.filter { window.placements[$0.key] != nil }
        guard await publishRegionalWindow(window, models: next, inputGeneration: inputGeneration, work: work) else { return false }
        regionalWindow = window; regionalModels = next
        regionalMetadata = regionalMetadata.filter { window.placements[$0.key] != nil }
        return true
    }

    /// 准备队列合成精确几何及运动邻域补底；主 actor 一次替换显示权并等量补偿 offset。
    /// 等待期间允许原生拖拽；缩放、转场或调宽开始则丢弃提交，不同步等待后台任务。
    func publishRegionalWindow(_ window: NoteReviewCanvasRegionWindow,
        models: [NoteReviewDirectoryGroupID: CanvasOverviewPreparedModel],
        inputGeneration: Int, work: CanvasOverviewTransitionPreparation) async -> Bool {
        guard let old = preparedModel, let oldWindow = regionalWindow,
              !desktopScrollView.isZooming, !isPositioningViewport else { return false }
        let shift = CGPoint(x: window.canvasTranslation.x - oldWindow.canvasTranslation.x,
                            y: window.canvasTranslation.y - oldWindow.canvasTranslation.y)
        let originalRect = zoomContentView.canvasView.convert(desktopScrollView.bounds, from: desktopScrollView)
        let rect = originalRect.offsetBy(dx: shift.x, dy: shift.y).insetBy(dx: -originalRect.width * 0.5, dy: -originalRect.height * 0.5)
        let zoom = desktopScrollView.zoomScale
        let scale = traitCollection.displayScale
        let size = CGSize(width: rect.width * zoom, height: rect.height * zoom)
        let queue = preparationQueue
        let built: (CanvasOverviewCanvasGeometry, UIImage?)? = await withCheckedContinuation { continuation in
            queue.async {
                let result = autoreleasepool { () -> (CanvasOverviewCanvasGeometry, UIImage?)? in
                    guard !work.isCancelled,
                          let geometry = CanvasOverviewRegionalGeometry.compose(models.map { ($0.key, $0.value.canvasGeometry) }, window: window) else { return nil }
                    let image = CanvasOverviewCanvasRasterizer.makeViewport(geometry: geometry, style: old.style,
                        canvasRect: rect, outputSize: size, outputScale: min(scale, 2_048 / max(size.width, size.height)), cancellation: work)
                    return (geometry, image)
                }
                continuation.resume(returning: result)
            }
        }
        guard !Task.isCancelled, !work.isCancelled, generation == inputGeneration, !isCanvasPaused, !isDisposed,
              canCommitBackgroundGeometry?() != false,
              widthSession == nil, transitionState == .idle, !desktopScrollView.isZooming, !isPositioningViewport,
              abs(desktopScrollView.zoomScale - zoom) < 0.0001, let (geometry, image) = built, let image else { return false }
        let now = zoomContentView.canvasView.convert(desktopScrollView.bounds, from: desktopScrollView)
            .offsetBy(dx: shift.x, dy: shift.y)
        guard rect.contains(now) else { return false }
        let offset = desktopScrollView.contentOffset
        let insets = desktopScrollView.contentInset
        isPositioningViewport = true
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // Keep the native scroll view and zoom transform. Never reset zoom to 1 while extending.
        zoomContentView.bounds = CGRect(origin: .zero, size: geometry.contentSize)
        zoomContentView.center = CGPoint(x: geometry.contentSize.width * zoom / 2, y: geometry.contentSize.height * zoom / 2)
        zoomContentView.configureRegional(geometry: geometry, models: models, style: old.style,
            viewportSize: desktopScrollView.bounds.size)
        desktopScrollView.contentSize = CGSize(width: geometry.contentSize.width * zoom, height: geometry.contentSize.height * zoom)
        desktopScrollView.contentInset = insets
        desktopScrollView.setContentOffset(CGPoint(x: offset.x + shift.x * zoom, y: offset.y + shift.y * zoom), animated: false)
        zoomContentView.installViewportUnderlay(image, canvasRect: rect, generation: inputGeneration)
        preparedModel = replacingCanvas(in: old, with: geometry)
        CATransaction.commit()
        isPositioningViewport = false
        cancelPreviewWorker()
        updateCanvasAccessibility()
        // Geometry identity participates in raster reuse; old viewport pixels cannot satisfy a new region.
        rasterPreparationCache.removeAll()
        if let displayed = preparedModel {
            protectPreviewDemand(in: displayed)
            startPreviewWorker(model: displayed)
            invalidateVisiblePreparedPreviews()
        }
        return true
    }

    /// 两种总览的窗口互不覆盖；替换桌面仅更新桌面身份和空间索引，保留已就绪的瀑布流端点。
    func replacingCanvas(in old: CanvasOverviewPreparedModel, with geometry: CanvasOverviewCanvasGeometry) -> CanvasOverviewPreparedModel {
        .init(notes: geometry.notes, noteByID: Dictionary(uniqueKeysWithValues: geometry.notes.map { ($0.id, $0) }),
            canvasGeometry: geometry, waterfallGeometry: old.waterfallGeometry, style: old.style,
            waterfallStyle: old.waterfallStyle, isRealData: old.isRealData,
            richTextNoteCount: geometry.notes.filter(\.richFormatting).count,
            previewRichNoteIDs: old.previewRichNoteIDs.filter { geometry.indexByID[$0] != nil },
            overviewImage: old.overviewImage, initialViewportImage: nil, initialViewportRect: old.initialViewportRect,
            isWaterfallPrepared: old.isWaterfallPrepared)
    }

    /// 调宽落稳后替换各区域的轻量几何与同排版补底；后续跨区不允许重新读回旧卡宽的模型。
    func adoptRegionalWidthModel(_ model: CanvasOverviewPreparedModel) {
        let geometry = model.canvasGeometry
        let placements = geometry.regionSlices.map { NoteReviewCanvasRegionPlacement(id: $0.id, frame: $0.frame) }
        guard let window = NoteReviewCanvasRegionWindow(regionWidth: CanvasOverviewRegionalGeometry.trackWidth(for: geometry),
            isRTL: geometry.spatialIndex.isRTL, restoring: placements) else { return }
        var locals: [NoteReviewDirectoryGroupID: CanvasOverviewPreparedModel] = [:]
        for slice in geometry.regionSlices {
            let local = CanvasOverviewRegionalGeometry.local(geometry, slice: slice)
            locals[slice.id] = .init(notes: local.notes, noteByID: Dictionary(uniqueKeysWithValues: local.notes.map { ($0.id, $0) }),
                canvasGeometry: local, waterfallGeometry: model.waterfallGeometry, style: model.style,
                waterfallStyle: model.waterfallStyle, isRealData: model.isRealData,
                richTextNoteCount: local.notes.filter(\.richFormatting).count, previewRichNoteIDs: [],
                overviewImage: model.regionalBackdrops[slice.id], initialViewportImage: nil,
                initialViewportRect: .zero, isWaterfallPrepared: false)
        }
        regionalModels = locals; regionalWindow = window
    }
}

extension CanvasOverviewZoomContentView {
    /// 至多九个低清区域补底共用一个 Tile 画布；不会为区域里的每张纸创建 UIView。
    func configureRegional(geometry: CanvasOverviewCanvasGeometry,
        models: [NoteReviewDirectoryGroupID: CanvasOverviewPreparedModel], style: CanvasOverviewPaperStyle, viewportSize: CGSize) {
        configure(geometry: geometry, overviewImage: nil, style: style, viewportSize: viewportSize)
        regionalUnderlays.forEach { $0.removeFromSuperview() }; regionalUnderlays.removeAll()
        for slice in geometry.regionSlices {
            guard let image = models[slice.id]?.overviewImage else { continue }
            let view = UIImageView(image: image)
            view.frame = slice.frame
            view.isUserInteractionEnabled = false
            insertSubview(view, belowSubview: viewportUnderlayView)
            regionalUnderlays.append(view)
        }
    }
}
