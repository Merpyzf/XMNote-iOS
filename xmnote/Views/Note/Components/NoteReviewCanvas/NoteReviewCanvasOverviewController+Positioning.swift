/**
 * [INPUT]: 接收用户定位、系统滚动完成与同代次可见正文就绪状态
 * [OUTPUT]: 为程序缩放、平移和即时定位统一收敛高清需求与显示失效
 * [POS]: NoteReviewCanvas 定位闭环；不通过拖拽回调补救已经完成的程序操作
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import UIKit

extension NoteReviewCanvasOverviewController {
    /// UIScrollView 的像素对齐与坐标换算可能相差亚像素；不可为同一可见位置等待不存在的滚动动画。
    func isSameScreenOffset(_ current: CGPoint, as target: CGPoint) -> Bool {
        let tolerance = 1 / max(1, traitCollection.displayScale)
        return abs(current.x - target.x) <= tolerance && abs(current.y - target.y) <= tolerance
    }

    /// 预热与真实动画消费同一参与者计划；全景交换卡两端都受保护，进入／退出只准备可见的一端。
    func transitionPreviewDemand(for plan: CanvasOverviewTransitionPlan) -> (desktop: [Int64], waterfall: [Int64]) {
        let desktop = plan.cards.filter { $0.kind != .enter }.map { $0.desktop.note.id }
        let waterfall = plan.cards.filter { $0.kind != .exit }.map { $0.waterfall.note.id }
        return (desktop, waterfall)
    }

    /// 主 actor 在定位前固定目标身份并预热实际目标区域；取消令牌禁止旧目标继续申请后续批次。
    func beginProgrammaticPositioning(mode: Mode, noteID: Int64, canvasRect: CGRect? = nil,
                                     zoomScale: CGFloat? = nil, waterfallRect: CGRect? = nil) {
        let superseded = pendingProgrammaticPosition?.mode
        cancelProgrammaticPositioning()
        if let superseded {
            isPositioningViewport = true
            (superseded == .desktop ? desktopScrollView : waterfallView).stopScrollingAndZooming()
            isPositioningViewport = false
        }
        guard let model = preparedModel else { return }
        programmaticPositionGeneration += 1
        let token = programmaticPositionGeneration
        pendingProgrammaticPosition = (token, mode, noteID)
        isPositioningViewport = true
        let ids = readablePreviewIDs(model: model, mode: mode, noteID: noteID,
            canvasRect: canvasRect, zoomScale: zoomScale, waterfallRect: waterfallRect)
        positionPreviewTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await warmPreviews(ids: ids, model: model, work: nil, modes: [mode])
                guard !Task.isCancelled, programmaticPositionGeneration == token else { return }
                if pendingProgrammaticPosition == nil { invalidateVisiblePreparedPreviews() }
            } catch { /* A trusted same-generation surface remains while normal demand retries. */ }
        }
    }

    /// 动画完成与即时／同位定位走同一出口；先解除抑制再报告需求，不改变程序指定的当前身份。
    func finishProgrammaticPositioning(in scrollView: UIScrollView) {
        let resolvedMode: Mode = scrollView === desktopScrollView ? .desktop : .waterfall
        guard let pending = pendingProgrammaticPosition, pending.mode == resolvedMode,
              pending.generation == programmaticPositionGeneration else { return }
        pendingProgrammaticPosition = nil
        isPositioningViewport = false
        guard !isDisposed, !isCanvasPaused, transitionState == .idle else { return }
        saveViewport(for: resolvedMode, noteID: pending.noteID)
        if resolvedMode == .desktop { updateCanvasAccessibility() }
        updateCurrentPresentation()
        updateCountMenu()
        reportDemand()
        invalidateVisiblePreparedPreviews()
        commitDeferredModelIfPossible()
    }

    /// 用户直接操控立即取回视口；晚到的滚动结束回调不再提交旧程序目标。
    func cancelProgrammaticPositioning() {
        programmaticPositionGeneration += 1
        pendingProgrammaticPosition = nil
        positionPreviewTask?.cancel()
        positionPreviewTask = nil
        isPositioningViewport = false
    }

    /// 准备期间不锁住可信源内容；宿主在真实手势开始时取消待切换请求，动画期仍由转场持有显示权。
    func userInteractionBegan() {
        endMenuPrewarming(cancelUnrequestedPreparation: true)
        cancelProgrammaticPositioning()
        onUserInteractionBegan?()
        if transitionState == .preparing { cancelPendingPresentation() }
    }

    /// 只使当前视口里已有高清字形的纸张失效，缓存命中也必须驱逐曾绘制的低清 Tile 像素。
    func invalidateVisiblePreparedPreviews() {
        guard let model = preparedModel, let id = currentNoteID, !isDisposed, !isCanvasPaused else { return }
        let ids = readablePreviewIDs(model: model, mode: currentMode, noteID: id)
            .filter { previewsAreReady(for: $0, in: model, modes: [currentMode]) }
        refreshPreparedPreviews(ids: ids, model: model)
    }

    /// 普通尺度使用实际目标视口，全景仅准备最终可读邻域；不使用与卡宽及视口脱节的固定半径。
    func readablePreviewIDs(model: CanvasOverviewPreparedModel, mode: Mode, noteID: Int64,
                            canvasRect: CGRect? = nil, zoomScale: CGFloat? = nil,
                            waterfallRect: CGRect? = nil) -> [Int64] {
        let indexes: [Int]
        if mode == .desktop {
            let rect = desktopPreviewRect(model: model, noteID: noteID, canvasRect: canvasRect, zoomScale: zoomScale)
            indexes = model.canvasGeometry.indexes(in: rect)
        } else {
            indexes = model.waterfallGeometry.indexes(in: waterfallRect ?? waterfallView.bounds)
        }
        var seen = Set<Int64>()
        return ([noteID] + indexes.map { model.notes[$0].id }).filter { seen.insert($0).inserted }
    }

    /// 所有目标预热共享实际视口尺寸；缩略地图只映射到当前纸张的可读邻域，不读完整地图正文。
    func desktopPreviewRect(model: CanvasOverviewPreparedModel, noteID: Int64,
                            canvasRect: CGRect? = nil, zoomScale: CGFloat? = nil) -> CGRect {
        let rect = canvasRect ?? zoomContentView.canvasView.convert(desktopScrollView.bounds, from: desktopScrollView)
        let scale = zoomScale ?? desktopScrollView.zoomScale
        guard scale * model.canvasGeometry.cardWidth < 116,
              let paper = model.canvasGeometry.paper(for: noteID) else { return rect }
        let readable = model.canvasGeometry.readableZoomScale(in: desktopScrollView.bounds.size)
        let size = CGSize(width: desktopScrollView.bounds.width / readable,
                          height: desktopScrollView.bounds.height / readable)
        return CGRect(x: paper.frame.midX - size.width / 2, y: paper.frame.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
}
