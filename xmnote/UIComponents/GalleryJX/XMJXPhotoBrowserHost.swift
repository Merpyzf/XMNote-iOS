import Foundation

/**
 * [INPUT]: 依赖 XMJXPhotoBrowserPresenter 浏览器桥接器与 XMJXThumbnailRegistry 缩略图注册表
 * [OUTPUT]: 对外提供 XMJXPhotoBrowserHost（图片浏览器宿主）
 * [POS]: UIComponents/GalleryJX 共享宿主层，统一维护浏览器 presenter 生命周期与 item 数据同步
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

@MainActor
/// 图片浏览器宿主，负责持有缩略图注册表与 presenter，供不同缩略图容器复用。
final class XMJXPhotoBrowserHost {
    let registry = XMJXThumbnailRegistry()

    private var presenter: XMJXPhotoBrowserPresenter?
    private var currentItems: [XMJXGalleryItem]

    /// 使用首帧数据初始化宿主；当存在数据时立即创建 presenter。
    init(initialItems: [XMJXGalleryItem]) {
        self.currentItems = initialItems
        if !initialItems.isEmpty {
            self.presenter = XMJXPhotoBrowserPresenter(items: initialItems, registry: registry)
        }
        XMJXGalleryLogger.verbose(
            "host.init itemsCount=\(initialItems.count) presenterReady=\(presenter != nil)"
        )
    }

    /// 同步外部数据源到浏览器桥接器。
    func updateItems(_ items: [XMJXGalleryItem]) {
        XMJXGalleryLogger.verbose("host.updateItems.begin itemsCount=\(items.count) presenterReady=\(presenter != nil)")
        currentItems = items
        if let presenter {
            presenter.updateItems(items)
        } else if !items.isEmpty {
            presenter = XMJXPhotoBrowserPresenter(items: items, registry: registry)
        }
        XMJXGalleryLogger.verbose("host.updateItems.end itemsCount=\(items.count) presenterReady=\(presenter != nil)")
    }

    /// 打开指定索引的全屏浏览器。
    func open(at index: Int, wallID: String, tapSequence: Int) {
        XMJXGalleryLogger.essential(
            "host.open.begin wallID=\(wallID) tapSeq=\(tapSequence) index=\(index) itemsCount=\(currentItems.count) presenterReady=\(presenter != nil)"
        )

        guard !currentItems.isEmpty else {
            XMJXGalleryLogger.essential("host.open.abort wallID=\(wallID) tapSeq=\(tapSequence) reason=emptyItems")
            return
        }
        guard currentItems.indices.contains(index) else {
            XMJXGalleryLogger.essential("host.open.abort wallID=\(wallID) tapSeq=\(tapSequence) reason=indexOutOfRange")
            return
        }
        if presenter == nil {
            presenter = XMJXPhotoBrowserPresenter(items: currentItems, registry: registry)
            XMJXGalleryLogger.essential("host.open.preparePresenter wallID=\(wallID) tapSeq=\(tapSequence) created=true")
        }
        guard let presenter else {
            XMJXGalleryLogger.essential("host.open.abort wallID=\(wallID) tapSeq=\(tapSequence) reason=presenterMissing")
            return
        }

        let itemID = currentItems[index].id
        XMJXGalleryLogger.essential(
            "host.open.callPresenter wallID=\(wallID) tapSeq=\(tapSequence) index=\(index) itemID=\(itemID)"
        )
        presenter.present(initialIndex: index, wallID: wallID, tapSequence: tapSequence)
    }
}
