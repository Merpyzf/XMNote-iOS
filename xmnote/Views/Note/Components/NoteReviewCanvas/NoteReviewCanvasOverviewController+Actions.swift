/**
 * [INPUT]: 接收触点命中的稳定书摘身份、现有纸面端点与父页面提供的业务动作
 * [OUTPUT]: 提供桌面和瀑布流对象菜单、单纸预览以及同身份的无障碍动作
 * [POS]: NoteReviewCanvas 页面私有对象交互接线；不读取仓储、不改变当前回顾项
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import UIKit

extension NoteReviewCanvasOverviewController {
    /// 桌面没有独立卡片 UIView，因此把系统对象菜单挂到滚动表面并用几何做精确命中。
    func configureObjectActions() {
        guard desktopObjectMenuInteraction == nil else { return }
        let interaction = UIContextMenuInteraction(delegate: self)
        desktopObjectMenuInteraction = interaction
        desktopScrollView.addInteraction(interaction)
    }

    /// 捕获菜单的目标而非当前项；只复用已准备端点，冷缓存沿用同代次真实补底。
    func objectMenuConfiguration(noteID: Int64, mode: Mode) -> UIContextMenuConfiguration? {
        guard !isDisposed, !isCanvasPaused, !isObjectMenuPresented,
              !isApplyingDeletion, transitionState == .idle || transitionState == .preparing,
              widthSession == nil, !isPreparingDesktopWidth, view.window != nil else { return nil }

        // 长按与拖动一样优先于尚未开始的模式准备；不得借此更新当前 ID 或进度。
        userInteractionBegan()
        guard !isDisposed, !isCanvasPaused, !isObjectMenuPresented, !isApplyingDeletion,
              transitionState == .idle, currentMode == mode,
              let menu = onNoteActionMenu?(noteID), !menu.children.isEmpty,
              let endpoint = endpoint(in: mode, noteID: noteID) else { return nil }
        let configuration = UIContextMenuConfiguration(identifier: NSNumber(value: noteID),
            previewProvider: nil, actionProvider: { _ in menu })
        objectMenuConfiguration = configuration
        isObjectMenuPresented = true
        cancelProgrammaticPositioning()
        let scrollView = mode == .desktop ? desktopScrollView : waterfallView
        scrollView.setContentOffset(scrollView.contentOffset, animated: false)
        objectMenuPreview = makeObjectMenuPreview(endpoint)
        return configuration
    }

    /// 系统预览只拥有一张纸，使用原始排版宽度与屏幕变换，不放大整个单画布。
    func makeObjectMenuPreview(_ endpoint: CanvasOverviewRenderEndpoint) -> UITargetedPreview {
        let paperView = CanvasOverviewObjectMenuPaperView(endpoint: endpoint)
        paperView.contentScaleFactor = traitCollection.displayScale * max(1, endpoint.scale)
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        let path = UIBezierPath(roundedRect: paperView.bounds, cornerRadius: endpoint.style.cornerRadius)
        parameters.visiblePath = path
        parameters.shadowPath = path
        let transform = CGAffineTransform(rotationAngle: endpoint.pose.rotation)
            .scaledBy(x: endpoint.scale, y: endpoint.scale)
        return UITargetedPreview(view: paperView, parameters: parameters,
            target: UIPreviewTarget(container: view, center: endpoint.pose.center, transform: transform))
    }

    /// 保留配置对象的身份，旧菜单的迟到结束回调不能释放新菜单或确认框的保护。
    func endObjectMenu(_ configuration: UIContextMenuConfiguration,
                       animator: (any UIContextMenuInteractionAnimating)?) {
        guard objectMenuConfiguration === configuration else { return }
        let completion = { [weak self] in
            guard let self, self.objectMenuConfiguration === configuration else { return }
            self.objectMenuConfiguration = nil
            self.objectMenuPreview = nil
            self.isObjectMenuPresented = false
            self.onObjectMenuDidEnd?()
            self.commitDeferredModelIfPossible()
        }
        if let animator { animator.addCompletion(completion) }
        else { completion() }
    }

    /// 离场即撤销预览保护；系统后续结束回调因配置身份失效而不能触发业务动作。
    func dismissObjectMenu() {
        guard objectMenuConfiguration != nil else { return }
        objectMenuConfiguration = nil
        objectMenuPreview = nil
        desktopObjectMenuInteraction?.dismissMenu()
        waterfallView.contextMenuInteraction?.dismissMenu()
        isObjectMenuPresented = false
    }

    /// 旋转纸张的包围框只用于索引；圆角以外的空白也不触发对象菜单。
    func desktopActionNoteID(at point: CGPoint) -> Int64? {
        guard directoryCatalog == nil else { return nil }
        guard let model = preparedModel, let paper = model.canvasGeometry.paper(at: point) else { return nil }
        let delta = CGPoint(x: point.x - paper.frame.midX, y: point.y - paper.frame.midY)
        let local = CGPoint(x: delta.x * cos(paper.rotation) + delta.y * sin(paper.rotation) + paper.frame.width / 2,
                            y: -delta.x * sin(paper.rotation) + delta.y * cos(paper.rotation) + paper.frame.height / 2)
        let path = UIBezierPath(roundedRect: CGRect(origin: .zero, size: paper.frame.size),
                                cornerRadius: model.style.cornerRadius)
        return path.contains(local) ? paper.noteID : nil
    }
}

extension NoteReviewCanvasOverviewController: UIContextMenuInteractionDelegate {
    /// 用 UIScrollView 的实际变换还原桌面坐标，不把阴影或画布留白当成目标。
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard interaction === desktopObjectMenuInteraction, currentMode == .desktop,
              !desktopScrollView.isDragging, !desktopScrollView.isZooming else { return nil }
        let point = desktopScrollView.convert(location, to: zoomContentView.canvasView)
        guard let id = desktopActionNoteID(at: point) else { return nil }
        return objectMenuConfiguration(noteID: id, mode: .desktop)
    }

    /// 高亮和收回共用一个固定端点，系统不再对整张桌面生成矩形预览。
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configuration: UIContextMenuConfiguration,
                                highlightPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        objectMenuConfiguration === configuration ? objectMenuPreview : nil
    }

    /// 菜单期间几何提交被延迟，因此收回端点仍与原纸面一致。
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configuration: UIContextMenuConfiguration,
                                dismissalPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        objectMenuConfiguration === configuration ? objectMenuPreview : nil
    }

    /// UIKit 开始展示后继续保持对象保护，不用触点身份替换回顾进度。
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                willDisplayMenuFor configuration: UIContextMenuConfiguration,
                                animator: (any UIContextMenuInteractionAnimating)?) {
        if objectMenuConfiguration === configuration { isObjectMenuPresented = true }
    }

    /// 等待 UIKit 的真实收回完成，再让父页面显示详情、标签或删除确认。
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                willEndFor configuration: UIContextMenuConfiguration,
                                animator: (any UIContextMenuInteractionAnimating)?) {
        endObjectMenu(configuration, animator: animator)
    }
}

extension NoteReviewCanvasOverviewController {
    /// 瀑布流由 Collection View 发起系统菜单，只在这一刻把 IndexPath 解析为固定 ID。
    func collectionView(_ collectionView: UICollectionView,
                        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard collectionView === waterfallView, currentMode == .waterfall,
              indexPaths.count == 1, let index = indexPaths.first?.item,
              let model = preparedModel, model.waterfallGeometry.notes.indices.contains(index),
              model.waterfallGeometry.frames.indices.contains(index) else { return nil }
        let note = model.waterfallGeometry.notes[index]
        let frame = model.waterfallGeometry.frames[index]
        let paperPath = UIBezierPath(roundedRect: frame, cornerRadius: model.waterfallStyle.cornerRadius)
        guard paperPath.contains(point) else { return nil }
        return objectMenuConfiguration(noteID: note.id, mode: .waterfall)
    }

    /// 可复用 Cell 与桌面消费相同端点，异步高清刷新不会改变菜单中的字形。
    func collectionView(_ collectionView: UICollectionView,
                        contextMenuConfiguration configuration: UIContextMenuConfiguration,
                        highlightPreviewForItemAt indexPath: IndexPath) -> UITargetedPreview? {
        objectMenuConfiguration === configuration ? objectMenuPreview : nil
    }

    /// 使用固定预览而非重查 IndexPath，避免观察回流后预览收回到另一条书摘。
    func collectionView(_ collectionView: UICollectionView,
                        contextMenuConfiguration configuration: UIContextMenuConfiguration,
                        dismissalPreviewForItemAt indexPath: IndexPath) -> UITargetedPreview? {
        objectMenuConfiguration === configuration ? objectMenuPreview : nil
    }

    /// 原生菜单展示期间保留同一对象保护，与桌面共享结束时机。
    func collectionView(_ collectionView: UICollectionView,
                        willDisplayContextMenu configuration: UIContextMenuConfiguration,
                        animator: (any UIContextMenuInteractionAnimating)?) {
        if objectMenuConfiguration === configuration { isObjectMenuPresented = true }
    }

    /// 所有业务动作在系统菜单真实收回后再呈现，不与菜单动画叠加。
    func collectionView(_ collectionView: UICollectionView,
                        willEndContextMenuInteraction configuration: UIContextMenuConfiguration,
                        animator: (any UIContextMenuInteractionAnimating)?) {
        endObjectMenu(configuration, animator: animator)
    }
}

/// 对象菜单最多保留一份已准备纸面，绘制只重放字形或同代次补底，不解析或测量正文。
@MainActor
private final class CanvasOverviewObjectMenuPaperView: UIView {
    private let endpoint: CanvasOverviewRenderEndpoint

    /// 保留原始排版及预算缓存租约，系统可以在不挂接卡片 UIView 的桌面上显示预览。
    init(endpoint: CanvasOverviewRenderEndpoint) {
        self.endpoint = endpoint
        super.init(frame: CGRect(origin: .zero, size: endpoint.paper.frame.size))
        isOpaque = false
        backgroundColor = .clear
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 绘制入口与真实纸面完全一致，菜单回交不会替换字体、行数或换行。
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        CanvasOverviewPaperRenderer.draw(paper: endpoint.paper, note: endpoint.note,
                                         style: endpoint.style, in: context)
    }
}
