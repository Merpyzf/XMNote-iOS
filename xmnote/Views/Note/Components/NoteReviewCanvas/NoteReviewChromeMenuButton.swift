/**
 * [INPUT]: 接收回顾页面构造的系统菜单，依赖 UIButton 原生玻璃配置与公开菜单生命周期
 * [OUTPUT]: 提供圆形形状和菜单收起期间更新合并均由按钮持有的更多操作入口
 * [POS]: NoteReviewCanvas 的页面私有控件；不持有回顾模式、业务动作或导航状态
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import UIKit

/// 让菜单来源、玻璃材质与圆形边界使用同一个视图，避免菜单预览仅捕获方形内部按钮。
@MainActor
final class NoteReviewChromeMenuButton: UIButton {
    private var isMenuLifecycleActive = false
    private var menuLifecycleGeneration = 0
    private var latestReviewMenu: UIMenu?
    private weak var visibleMenuInteraction: UIContextMenuInteraction?
    private var requestedLoading = false
    var onMenuWillDisplay: (() -> Void)?
    var onMenuDidEnd: (() -> Void)?
    var loadingAccessibilityValue = "正在准备切换"

    /// 保留同一玻璃实例；系统菜单还在收起时合并最新反馈，避免重建菜单来源的形状。
    func setReviewLoading(_ isLoading: Bool) {
        requestedLoading = isLoading
        if !isMenuLifecycleActive { applyLoadingState() }
    }

    /// 只更新图像槽位的系统指示器，不改变按钮布局、材质或菜单可操作性。
    private func applyLoadingState() {
        guard configuration?.showsActivityIndicator != requestedLoading else { return }
        configuration?.showsActivityIndicator = requestedLoading
        accessibilityValue = requestedLoading ? loadingAccessibilityValue : nil
    }

    /// 原生按钮负责玻璃和形状；外层只需定位，不应再次包裹或裁切另一层玻璃。
    override init(frame: CGRect) {
        super.init(frame: frame)
        var configuration = UIButton.Configuration.glass()
        configuration.cornerStyle = .capsule
        configuration.contentInsets = .zero
        self.configuration = configuration
        cornerConfiguration = .capsule()
        showsMenuAsPrimaryAction = true
    }

    /// 回顾操作入口只通过代码创建，不接受归档中的另一套按钮配置。
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 菜单来源保持固定，每次展开读取最新快照；已展开时只更新菜单内容，不重建玻璃来源。
    func setReviewMenu(_ menu: UIMenu) {
        latestReviewMenu = menu
        if self.menu == nil {
            self.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.latestReviewMenu?.children ?? [])
            }])
        }
        visibleMenuInteraction?.updateVisibleMenu { _ in menu }
    }

    /// 在主线程记录系统菜单代次；保留父类行为，不附加第二个菜单交互或重播按压效果。
    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        willDisplayMenuFor configuration: UIContextMenuConfiguration,
        animator: (any UIContextMenuInteractionAnimating)?
    ) {
        menuLifecycleGeneration += 1
        isMenuLifecycleActive = true
        visibleMenuInteraction = interaction
        super.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: animator)
        onMenuWillDisplay?()
    }

    /// 系统收起动画完成后在主线程提交最新菜单；过期回调不得覆盖已再次打开的菜单。
    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        willEndFor configuration: UIContextMenuConfiguration,
        animator: (any UIContextMenuInteractionAnimating)?
    ) {
        visibleMenuInteraction = nil
        super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
        let generation = menuLifecycleGeneration
        guard let animator else {
            finishMenuLifecycle(generation: generation)
            return
        }
        animator.addCompletion { [weak self] in
            self?.finishMenuLifecycle(generation: generation)
        }
    }

    /// 只结束仍属于本次菜单的更新保护；快速再次展开时继续保留合并后的待提交菜单。
    private func finishMenuLifecycle(generation: Int) {
        guard generation == menuLifecycleGeneration else { return }
        isMenuLifecycleActive = false
        applyLoadingState()
        onMenuDidEnd?()
    }
}
