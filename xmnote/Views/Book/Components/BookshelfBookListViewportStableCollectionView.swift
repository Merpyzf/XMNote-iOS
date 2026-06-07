/**
 * [INPUT]: 依赖 UIKit UICollectionView 生命周期与 content inset 变化回调
 * [OUTPUT]: 对外提供 BookshelfBookListViewportStableCollectionView，向 host 转发布局与 adjusted inset 事件
 * [POS]: Book 模块二级书籍列表页面私有 UIKit 子类，支撑视口锚点恢复与搜索抽屉初始偏移收敛
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import UIKit

/// 二级列表集合视图子类，向承载层暴露系统 automatic inset 与布局周期变化。
final class BookshelfBookListViewportStableCollectionView: UICollectionView {
    var onAdjustedContentInsetDidChange: (() -> Void)?
    var onBeforeLayoutSubviews: (() -> Void)?
    var onAfterLayoutSubviews: (() -> Void)?
    var onDidMoveToWindow: (() -> Void)?

    /// 布局前保存当前可见锚点，避免 safe area 调整后只能拿到跳变后的 cell 位置。
    override func layoutSubviews() {
        onBeforeLayoutSubviews?()
        super.layoutSubviews()
        onAfterLayoutSubviews?()
    }

    /// 进入窗口时立即收敛初始滚动位置，避免导航转场首帧暴露隐藏搜索抽屉。
    override func didMoveToWindow() {
        super.didMoveToWindow()
        onDidMoveToWindow?()
    }

    /// UIKit 合成后的 adjusted inset 变化时，通知承载层恢复视口锚点。
    override func adjustedContentInsetDidChange() {
        super.adjustedContentInsetDidChange()
        onAdjustedContentInsetDidChange?()
    }
}
