/**
 * [INPUT]: 接收同一代几何、目标模式与当前书摘的可取消准备请求
 * [OUTPUT]: 提供目标首屏就绪检查和共享纸张不可用时的可靠淡变
 * [POS]: NoteReviewCanvas 总览交互恢复边界；动画降级不改变数据、相机或排版
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import UIKit
import OSLog

extension NoteReviewCanvasOverviewController {
    /// 准备不含系统边缘效果的整幅背景；桌面复用高清补底，瀑布流只绘制已准备的可见纸张。
    /// 主 actor 固定视口与代次，准备队列绘制；取消或几何变化不交付旧背景。
    func readingTransitionBackground(in container: UIView) async -> UIImageView? {
        guard let model = preparedModel else { return nil }
        let token = generation
        let mode = currentMode
        let scroll = mode == .desktop ? desktopScrollView : waterfallView
        let frame = scroll.convert(scroll.bounds, to: container)
        let image: UIImage?
        if mode == .desktop {
            let rect = zoomContentView.canvasView.convert(scroll.bounds, from: scroll)
            image = await preparedViewportImage(model: model, canvasRect: rect,
                size: scroll.bounds.size, scale: traitCollection.displayScale)
        } else {
            let clip = scroll.convert(scroll.bounds, to: view)
            let visible = model.waterfallGeometry.indexes(in: waterfallView.bounds).compactMap {
                endpoint(in: .waterfall, noteID: model.waterfallGeometry.notes[$0].id)
            }
            guard visible.allSatisfy({ $0.paper.contentGeometry.preparedBlocks != nil }) else { return nil }
            let plan = CanvasOverviewTransitionPlan(clip: clip, cards: [], desktopVisible: [],
                waterfallVisible: visible, style: model.style, isPanorama: false, focusRatio: 1,
                desktopAnchor: .zero, focusAnchor: .zero, screenScale: traitCollection.displayScale,
                generation: token, desktopCanvasRect: .zero, model: model)
            let key = CanvasOverviewRasterPreparationKey(generation: token,
                modelGeneration: model.notes.first?.key?.generation, kind: .readingBackdrop(mode: mode.rawValue),
                rect: scroll.bounds, outputSize: frame.size, scale: traitCollection.displayScale)
            image = await rasterPreparationCache.image(for: key, queue: preparationQueue) { work in
                guard !work.isCancelled else { return nil }
                return CanvasOverviewTransitionRasterizer.surface(visible, plan: plan, preparation: work)
            }
        }
        guard let image, token == generation, currentMode == mode, !Task.isCancelled, !isDisposed else { return nil }
        let background = UIImageView(image: image)
        background.frame = frame
        return background
    }

    /// 只准备真实目标首屏；当前可信内容继续受保护，未显示的共享邻卡不再占用恢复预算。
    /// 主 actor 捕获几何，绘制在准备队列完成；取消或 generation 改变后不交付补底。
    func prepareReadableSurface(_ target: Mode, noteID: Int64) async throws {
        guard let model = preparedModel, model.content(for: noteID, mode: target) != nil else {
            throw CanvasOverviewPreviewError.unavailable
        }
        let token = generation
        transitionPreviewPins.removeAll()
        let rect = zoomContentView.canvasView.convert(desktopScrollView.bounds, from: desktopScrollView)
        let ids = readablePreviewIDs(model: model, mode: target, noteID: noteID)
        try await warmPreviews(ids: ids, model: model,
                               work: nil, modes: [target], protectsTransition: true)
        try Task.checkCancellation()
        guard generation == token, !isDisposed, !isCanvasPaused else { throw CancellationError() }
        if target == .desktop {
            let size = desktopScrollView.bounds.size
            let scale = traitCollection.displayScale
            let image = await preparedViewportImage(model: model, canvasRect: rect, size: size, scale: scale)
            try Task.checkCancellation()
            guard generation == token, !isDisposed, !isCanvasPaused else { throw CancellationError() }
            guard let image else { throw CanvasOverviewPreviewError.unavailable }
            zoomContentView.installViewportUnderlay(image, canvasRect: rect, generation: token)
        } else {
            for case let cell as CanvasOverviewWaterfallCell in waterfallView.visibleCells {
                cell.paperView.refreshPreparedContent()
            }
        }
    }

    /// 同代次同视口的进入、恢复和共享端点复用一份高清准备；主 actor 合并请求，后台只绘制一次。
    func preparedViewportImage(model: CanvasOverviewPreparedModel, canvasRect: CGRect,
                               size: CGSize, scale: CGFloat) async -> UIImage? {
        var readiness = Hasher()
        for index in model.canvasGeometry.indexes(in: canvasRect) {
            readiness.combine(model.notes[index].id)
            readiness.combine(model.canvasGeometry.papers[index].contentGeometry.preparedBlocks != nil)
        }
        let key = CanvasOverviewRasterPreparationKey(generation: generation,
            modelGeneration: model.notes.first?.key?.generation, kind: .viewport,
            rect: canvasRect, outputSize: size, scale: scale, contentState: readiness.finalize())
        return await rasterPreparationCache.image(for: key, queue: preparationQueue) { work in
            CanvasOverviewCanvasRasterizer.makeViewport(geometry: model.canvasGeometry,
                style: model.style, canvasRect: canvasRect, outputSize: size, outputScale: scale, cancellation: work)
        }
    }

    /// 一次有界恢复：目标可读即淡变完成，数据不可用才上报宿主；不无限重试或显示低清目标。
    func recoverModeTransition(target: Mode, from: Mode, noteID: Int64, token: Int, reason: String) {
        Logger(subsystem: "com.wangke.xmnote", category: "CanvasTransition").notice(
            "Use readable-surface recovery: \(reason, privacy: .public)")
        transitionPreparation?.cancel(); transitionPreparation = nil
        transitionWarmTask = Task { [weak self] in
            guard let self else { return }
            do { try await prepareReadableSurface(target, noteID: noteID) }
            catch {
                guard !Task.isCancelled, transitionGeneration == token, !isDisposed, !isCanvasPaused else { return }
                Logger(subsystem: "com.wangke.xmnote", category: "CanvasTransition").error("Target content remains unavailable")
                cancelPendingPresentation()
                onPreparationChanged?(false, "当前回顾内容暂未就绪")
                return
            }
            guard !Task.isCancelled, transitionGeneration == token, transitionState == .preparing else { return }
            transitionState = .animating
            setLoadingVisible(false)
            let transition = NoteReviewCanvasSurfaceDissolve(source: surface(for: from), target: surface(for: target),
                frozenSource: nil, container: view, below: topControlPanel) { [weak self] reachedTarget in
                    guard let self, transitionGeneration == token else { return }
                    modeDissolve = nil
                    cleanUpTransition(settledMode: reachedTarget ? target : from)
                }
            modeDissolve = transition
            onPreparationChanged?(false, nil)
            transition.animator.startAnimation()
        }
    }
}
