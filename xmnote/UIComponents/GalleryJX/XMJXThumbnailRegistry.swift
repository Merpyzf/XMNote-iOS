import UIKit

/**
 * [INPUT]: 依赖 UIKit UIView/UIImageView 生命周期与主线程 UI 语义
 * [OUTPUT]: 对外提供 XMJXThumbnailRegistry（缩略图 UIView 注册表）
 * [POS]: UIComponents/GalleryJX 的转场桥接基础设施，为 JXPhotoBrowser Zoom 动画提供 itemID -> UIView 映射与显隐状态回放
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

@MainActor
final class XMJXThumbnailRegistry {
    private final class WeakImageViewBox {
        weak var view: UIImageView?

        init(_ view: UIImageView) {
            self.view = view
        }
    }

    private var viewStore: [String: WeakImageViewBox] = [:]
    private var hiddenStateStore: [String: Bool] = [:]

    /// 注册 item 对应的缩略图视图，供 Zoom 转场查询起止位置。
    func register(itemID: String, view: UIImageView) {
        viewStore[itemID] = WeakImageViewBox(view)
        applyHiddenStateIfNeeded(for: itemID, to: view)
        cleanupStaleViews()
        XMJXGalleryLogger.verbose(
            "registry.register itemID=\(itemID) sourceCount=\(viewStore.count) hidden=\(hiddenStateStore[itemID] ?? false)"
        )
    }

    /// 注销 item 对应的缩略图视图，避免保留无效引用。
    func unregister(itemID: String, view: UIImageView) {
        guard let registered = viewStore[itemID]?.view, registered === view else {
            return
        }
        viewStore[itemID] = nil
        XMJXGalleryLogger.verbose("registry.unregister itemID=\(itemID) sourceCount=\(viewStore.count)")
    }

    /// 返回 item 对应的缩略图视图（Zoom 转场使用）。
    func thumbnailView(for itemID: String) -> UIView? {
        cleanupStaleViews()
        let view = viewStore[itemID]?.view
        XMJXGalleryLogger.verbose("registry.lookup itemID=\(itemID) hit=\(view != nil) sourceCount=\(viewStore.count)")
        return view
    }

    /// 返回 item 当前缩略图图像，用于浏览器大图加载前占位。
    func snapshotImage(for itemID: String) -> UIImage? {
        cleanupStaleViews()
        return viewStore[itemID]?.view?.image
    }

    /// 设置 item 缩略图显隐状态；当视图尚未挂载时会回放到后续注册。
    func setHidden(_ hidden: Bool, for itemID: String) {
        hiddenStateStore[itemID] = hidden
        cleanupStaleViews()
        viewStore[itemID]?.view?.isHidden = hidden
    }

    /// 强制恢复全部缩略图可见，用于浏览器异常退出的兜底恢复。
    func setAllVisible() {
        cleanupStaleViews()
        for key in hiddenStateStore.keys {
            hiddenStateStore[key] = false
        }
        for box in viewStore.values {
            box.view?.isHidden = false
        }
    }

    private func applyHiddenStateIfNeeded(for itemID: String, to view: UIImageView) {
        view.isHidden = hiddenStateStore[itemID] ?? false
    }

    private func cleanupStaleViews() {
        viewStore = viewStore.filter { $0.value.view != nil }
    }
}
