import UIKit
import Nuke
import JXPhotoBrowser

/**
 * [INPUT]: 依赖 JXPhotoBrowser Delegate 契约、Nuke ImagePipeline 与 XMJXThumbnailRegistry 缩略图映射
 * [OUTPUT]: 对外提供 XMJXPhotoBrowserPresenter（浏览器呈现与数据桥接器）
 * [POS]: UIComponents/GalleryJX 的 UIKit 核心桥接层，负责构建 JXPhotoBrowser、提供 cell 数据、维护 Zoom 转场缩略图显隐与图片加载
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

@MainActor
final class XMJXPhotoBrowserPresenter: NSObject, UIAdaptivePresentationControllerDelegate {
    private var items: [XMJXGalleryItem]
    private let registry: XMJXThumbnailRegistry
    private let pipeline: ImagePipeline
    private var loadingTasks: [String: Task<Void, Never>] = [:]
    private weak var browser: JXPhotoBrowserViewController?

    /// 初始化浏览器桥接器，注入数据源与缩略图注册表。
    init(
        items: [XMJXGalleryItem],
        registry: XMJXThumbnailRegistry,
        pipeline: ImagePipeline = .shared
    ) {
        self.items = items
        self.registry = registry
        self.pipeline = pipeline
    }

    /// 更新浏览器数据源，供 SwiftUI 墙面数据变更后同步。
    func updateItems(_ items: [XMJXGalleryItem]) {
        XMJXGalleryLogger.verbose("presenter.updateItems itemsCount=\(items.count)")
        self.items = items
    }

    /// 从当前前台最上层 ViewController 呈现图片浏览器。
    func present(initialIndex: Int, wallID: String? = nil, tapSequence: Int? = nil) {
        XMJXGalleryLogger.essential(
            "present.begin wallID=\(wallID ?? "nil") tapSeq=\(tapSequence.map(String.init) ?? "nil") index=\(initialIndex) itemsCount=\(items.count) isMain=\(Thread.isMainThread)"
        )
        guard !items.isEmpty else {
            XMJXGalleryLogger.essential("present.guard.fail reason=emptyData")
            return
        }

        guard let viewController = Self.topViewController() else {
            XMJXGalleryLogger.error(
                "present.guard.fail reason=topViewControllerNotFound wallID=\(wallID ?? "nil") tapSeq=\(tapSequence.map(String.init) ?? "nil")"
            )
            return
        }

        let safeIndex = max(0, min(initialIndex, items.count - 1))
        XMJXGalleryLogger.essential(
            "present.topVC.resolved type=\(String(describing: type(of: viewController))) safeIndex=\(safeIndex)"
        )
        let browser = JXPhotoBrowserViewController()
        browser.delegate = self
        browser.initialIndex = safeIndex
        browser.scrollDirection = .horizontal
        browser.transitionType = .zoom
        browser.itemSpacing = 0
        browser.isLoopingEnabled = false
        browser.addOverlay(JXPageIndicatorOverlay())

        self.browser = browser

        XMJXGalleryLogger.verbose(
            "present.browser.configured transition=zoom direction=horizontal loop=false itemSpacing=0"
        )

        browser.present(from: viewController)
        XMJXGalleryLogger.essential("present.called")
        DispatchQueue.main.async { [weak browser, weak self] in
            browser?.presentationController?.delegate = self
        }
    }

    /// 统一清理浏览器资源并恢复缩略图可见状态。
    func cleanupAfterDismiss() {
        XMJXGalleryLogger.essential("dismiss.cleanup.begin")
        cancelAllLoadingTasks()
        registry.setAllVisible()
        browser = nil

        XMJXGalleryLogger.essential("dismiss.cleanup.end")
    }
}

extension XMJXPhotoBrowserPresenter: JXPhotoBrowserDelegate {
    /// 返回浏览器总条目数，驱动 JXPhotoBrowser 分页。
    func numberOfItems(in browser: JXPhotoBrowserViewController) -> Int {
        XMJXGalleryLogger.verbose("delegate.numberOfItems count=\(items.count)")
        return items.count
    }

    /// 为指定索引提供 JX 浏览单元。
    func photoBrowser(
        _ browser: JXPhotoBrowserViewController,
        cellForItemAt index: Int,
        at indexPath: IndexPath
    ) -> JXPhotoBrowserAnyCell {
        XMJXGalleryLogger.verbose("delegate.cellForItemAt index=\(index) indexPath=\(indexPath)")
        let cell = browser.dequeueReusableCell(
            withReuseIdentifier: JXZoomImageCell.reuseIdentifier,
            for: indexPath
        ) as! JXZoomImageCell
        return cell
    }

    /// 在单元即将显示时加载原图，并优先使用缩略图占位避免黑帧。
    func photoBrowser(_ browser: JXPhotoBrowserViewController, willDisplay cell: JXPhotoBrowserAnyCell, at index: Int) {
        guard items.indices.contains(index), let zoomCell = cell as? JXZoomImageCell else {
            XMJXGalleryLogger.verbose("delegate.willDisplay.skip index=\(index) reason=invalidIndexOrCell")
            return
        }

        let item = items[index]
        XMJXGalleryLogger.verbose("delegate.willDisplay index=\(index) itemID=\(item.id)")
        zoomCell.imageView.image = registry.snapshotImage(for: item.id)

        loadingTasks[item.id]?.cancel()

        guard let url = normalizedOriginalURL(for: item) else {
            XMJXGalleryLogger.error("delegate.willDisplay.skip itemID=\(item.id) reason=invalidOriginalURL")
            return
        }

        let request = XMImageLoadRequest(url: url, priority: .high)
        loadingTasks[item.id] = Task { [weak zoomCell, weak self] in
            guard let self else { return }
            do {
                let image = try await self.pipeline.image(for: request.imageRequest)
                guard !Task.isCancelled else { return }
                guard let zoomCell else { return }
                zoomCell.imageView.image = image
                zoomCell.setNeedsLayout()
            } catch {
                guard !Task.isCancelled else { return }
                XMJXGalleryLogger.error("delegate.willDisplay.failed itemID=\(item.id) error=\(error.localizedDescription)")
            }
            self.loadingTasks[item.id] = nil
        }
    }

    /// 在单元结束显示时终止对应加载任务，避免复用串图。
    func photoBrowser(_ browser: JXPhotoBrowserViewController, didEndDisplaying cell: JXPhotoBrowserAnyCell, at index: Int) {
        guard items.indices.contains(index) else { return }
        let itemID = items[index].id
        XMJXGalleryLogger.verbose("delegate.didEndDisplaying index=\(index) itemID=\(itemID)")
        loadingTasks[itemID]?.cancel()
        loadingTasks[itemID] = nil
    }

    /// 返回指定索引的缩略图 UIView，供 Zoom 转场计算起止几何。
    func photoBrowser(_ browser: JXPhotoBrowserViewController, thumbnailViewAt index: Int) -> UIView? {
        guard items.indices.contains(index) else { return nil }
        let itemID = items[index].id
        let view = registry.thumbnailView(for: itemID)

        XMJXGalleryLogger.verbose("delegate.thumbnailViewAt index=\(index) itemID=\(itemID) hit=\(view != nil)")

        return view
    }

    /// 控制缩略图显隐，避免浏览器图层与墙面图层重叠。
    func photoBrowser(_ browser: JXPhotoBrowserViewController, setThumbnailHidden hidden: Bool, at index: Int) {
        guard items.indices.contains(index) else { return }
        let itemID = items[index].id
        registry.setHidden(hidden, for: itemID)

        XMJXGalleryLogger.verbose("delegate.setThumbnailHidden index=\(index) itemID=\(itemID) hidden=\(hidden)")

    }
}

extension XMJXPhotoBrowserPresenter {
    /// 系统关闭回调兜底，确保异常路径下也能恢复缩略图可见状态。
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        XMJXGalleryLogger.essential("dismiss.callback presentationControllerDidDismiss")
        cleanupAfterDismiss()
    }
}

private extension XMJXPhotoBrowserPresenter {
    /// 解析原图地址，不合法时回退缩略图地址。
    func normalizedOriginalURL(for item: XMJXGalleryItem) -> URL? {
        if let originalURL = XMImageRequestBuilder.normalizedURL(from: item.originalURL) {
            return originalURL
        }
        return XMImageRequestBuilder.normalizedURL(from: item.thumbnailURL)
    }

    /// 统一取消所有异步加载任务。
    func cancelAllLoadingTasks() {
        for task in loadingTasks.values {
            task.cancel()
        }
        loadingTasks.removeAll()
    }

    /// 返回当前前台场景的最上层视图控制器。
    static func topViewController() -> UIViewController? {
        XMJXGalleryLogger.verbose("topVC.scan.begin")
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
            let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            XMJXGalleryLogger.verbose("topVC.scan.end found=false")
            return nil
        }

        var top = root
        while let presented = top.presentedViewController {
            top = presented
        }
        XMJXGalleryLogger.verbose("topVC.scan.end found=true type=\(String(describing: type(of: top)))")
        return top
    }
}
