/**
 * [INPUT]: 接收目录集合、缩放层级与当前书摘身份
 * [OUTPUT]: 提供不读取正文的全景，以及当前集合就绪后的语义展开
 * [POS]: 总览控制器远景交接；复用同一个原生滚动缩放容器，不改变业务当前项
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import UIKit

extension NoteReviewCanvasOverviewController {
    /// 撤销后续目录交付，已经显示的集合仍然可信；取消不能恢复过时的层级。
    func cancelCatalogPreparation() {
        let wasPending = directoryCatalogTask != nil
        directoryCatalogGeneration += 1
        directoryCatalogTask?.cancel(); directoryCatalogTask = nil
        if wasPending, modelPreparation == nil { onPreparationChanged?(false, nil) }
    }

    /// 显示最多二十四个集合；屏幕较小时减少数量以保证计数可读，而非缩成不可辨识的纸点。
    func showDirectoryCatalog(scope: NoteReviewDirectoryGroupID? = nil) {
        guard let read = directoryCatalogReader, let model = preparedModel, currentMode == .desktop,
              transitionState == .idle, widthSession == nil, !isDisposed, !isCanvasPaused else { return }
        cancelCatalogPreparation()
        cancelRegionalPreparation()
        cancelProgrammaticPositioning()
        let token = directoryCatalogGeneration
        let input = generation
        let available = CGSize(width: desktopScrollView.bounds.width,
            height: max(160, desktopScrollView.bounds.height - contentOcclusionInsets.top - contentOcclusionInsets.bottom))
        let maximum = min(24, max(4, Int(available.width / 160) * Int(available.height / 150)))
        onPreparationChanged?(true, nil)
        directoryCatalogTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if token == directoryCatalogGeneration {
                    directoryCatalogTask = nil
                    onPreparationChanged?(false, nil)
                }
            }
            do {
                let catalog = try await read(scope, maximum)
                try Task.checkCancellation()
                guard token == directoryCatalogGeneration, generation == input, !isDisposed,
                      !isCanvasPaused, transitionState == .idle, !desktopScrollView.isDragging,
                      !desktopScrollView.isZooming else { return }
                if directoryCatalog == nil, let id = currentNoteID { saveViewport(for: .desktop, noteID: id) }
                let cover = desktopScrollView.snapshotView(afterScreenUpdates: false)
                if let cover { cover.frame = desktopScrollView.frame; view.addSubview(cover) }
                desktopScrollView.stopScrollingAndZooming()
                isPositioningViewport = true
                directoryCatalog = catalog
                directoryCatalogView.configure(catalog, style: model.style, viewport: available)
                directoryCatalogView.onActivate = { [weak self] group in self?.expandDirectoryGroup(group) }
                desktopScrollView.setZoomScale(1, animated: false)
                zoomContentView.transform = .identity
                zoomContentView.frame = CGRect(origin: .zero, size: directoryCatalogView.preferredSize)
                directoryCatalogView.frame = zoomContentView.bounds
                zoomContentView.addSubview(directoryCatalogView)
                directoryCatalogView.isHidden = false
                zoomContentView.canvasView.isHidden = true
                zoomContentView.underlayView.isHidden = true
                zoomContentView.viewportUnderlayView.isHidden = true
                zoomContentView.regionalUnderlays.forEach { $0.isHidden = true }
                desktopScrollView.contentSize = directoryCatalogView.preferredSize
                desktopScrollView.minimumZoomScale = directoryCatalogView.fitScale * 0.65
                desktopScrollView.maximumZoomScale = max(1.2, directoryCatalogView.fitScale * 4)
                desktopScrollView.setZoomScale(directoryCatalogView.fitScale, animated: false)
                updateDesktopContentInset()
                let size = desktopScrollView.contentSize
                let offset = CGPoint(x: (size.width - desktopScrollView.bounds.width) / 2,
                    y: (size.height - desktopScrollView.bounds.height) / 2)
                desktopScrollView.setContentOffset(offset, animated: false)
                isShowingFullDesktop = true
                isPositioningViewport = false
                updateFullDesktopButton(); onControlsChanged?()
                UIView.animate(withDuration: 0.12, animations: { cover?.alpha = 0 }) { _ in cover?.removeFromSuperview() }
            } catch { /* The previous layer stays interactive; the next explicit request can retry. */ }
        }
    }

    /// 子集合只需统计即可展开；叶子到真实纸张则保留源集合直到精确内容就绪。
    func expandDirectoryGroup(_ group: NoteReviewDirectoryGroup) {
        guard directoryCatalog != nil, modelPreparation == nil else { return }
        if !group.isLeaf { showDirectoryCatalog(scope: group.id); return }
        guard let read = directoryNeighborReader else { return }
        cancelCatalogPreparation()
        let token = directoryCatalogGeneration
        onPreparationChanged?(true, nil)
        directoryCatalogTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if token == directoryCatalogGeneration, directoryCatalogTask != nil {
                    directoryCatalogTask = nil
                    onPreparationChanged?(false, nil)
                }
            }
            do {
                guard let region = try await read(group.id) else { return }
                try Task.checkCancellation()
                guard token == directoryCatalogGeneration, !isDisposed, !isCanvasPaused else { return }
                let chosen = region.members.first { $0.record.noteID == currentNoteID }?.record.noteID
                    ?? region.members.first?.record.noteID
                guard let chosen else { return }
                directoryCatalogTask = nil
                // Selecting a group does not move progress until its real paper surface is ready.
                requestPreparation(count: selectedCount, preservingCurrentID: chosen)
            } catch {
                guard token == directoryCatalogGeneration else { return }
                directoryCatalogTask = nil; onPreparationChanged?(false, nil)
            }
        }
    }

    /// 离开集合层只恢复已保存的真实邻域；不把集合缩放写入用户的桌面相机。
    func restoreDirectoryDesktop() {
        guard directoryCatalog != nil, let model = preparedModel else { return }
        cancelCatalogPreparation()
        commit(model: model, preservingCurrentID: currentNoteID, restoringWidthViewport: desktopViewport)
        reportDemand()
    }

    /// 提交新真实区域前解除集合显示权；调用方已经保留源快照并持有全部目标资源。
    func clearDirectoryCatalogSurface() {
        directoryCatalog = nil
        directoryCatalogView.isHidden = true
        directoryCatalogView.removeFromSuperview()
        zoomContentView.canvasView.isHidden = false
        zoomContentView.underlayView.isHidden = false
        zoomContentView.regionalUnderlays.forEach { $0.isHidden = false }
    }

    /// 稳定后按同一滞回阈值改变语义层级；缩放期间不修改当前书摘身份。
    func settleDirectoryScaleIfNeeded() -> Bool {
        guard directoryCatalogReader != nil, !isPositioningViewport else { return false }
        if let catalog = directoryCatalog {
            if desktopScrollView.zoomScale * 220 >= 148 {
                let point = desktopScrollView.pinchGestureRecognizer?.location(in: directoryCatalogView)
                    ?? directoryCatalogView.convert(CGPoint(x: desktopScrollView.bounds.midX, y: desktopScrollView.bounds.midY), from: desktopScrollView)
                if let group = directoryCatalogView.nearestGroup(to: point) { expandDirectoryGroup(group) }
            } else if desktopScrollView.zoomScale < directoryCatalogView.fitScale * 0.8, catalog.scope.id != catalog.root.id {
                let parent = NoteReviewDirectoryGroupID(snapshotID: catalog.scope.id.snapshotID,
                    level: catalog.scope.id.level + 1, bucket: catalog.scope.id.bucket / 4)
                showDirectoryCatalog(scope: parent)
            }
            return true
        }
        if let model = preparedModel, model.canvasGeometry.cardWidth * desktopScrollView.zoomScale <= 116 {
            showDirectoryCatalog()
            return true
        }
        return false
    }
}
