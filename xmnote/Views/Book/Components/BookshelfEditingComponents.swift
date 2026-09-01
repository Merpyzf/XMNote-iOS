/**
 * [INPUT]: 依赖 SwiftUI/UIKit 按钮、图标、搜索输入、InteractionMetrics 与动画能力
 * [OUTPUT]: 对外提供书架编辑态顶部 chrome、统一搜索 surface、整理态双态上下文检索入口、选择态封面/行遮罩与管理模式转场参数
 * [POS]: Book 模块页面私有编辑态与搜索组件集合，服务默认书架与二级书籍列表的整理模式选择、检索和顶部批量命令
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 书架编辑态装饰符号的排版规格，保持空态与选择反馈的既有缩放行为。
private enum BookshelfEditingTypography {
    static let emptyStateSymbol = AppTypography.fixed(
        baseSize: 48,
        relativeTo: .title,
        weight: .regular
    )

    /// 根据选择符号的动态尺寸生成现有半粗体字体。
    static func selectionCheckmark(baseSize: CGFloat) -> Font {
        AppTypography.fixed(
            baseSize: baseSize,
            relativeTo: .subheadline,
            weight: .semibold
        )
    }
}

/// 书架管理模式的统一动效参数，保证顶部 chrome、内容 inset 与底部面板按同一语义节奏切换。
enum BookshelfManagementMotion {
    static let modeTransition: Animation = .smooth(duration: 0.26)
    static let editBarRevealTransitionAnimation: Animation = .smooth(duration: 0.26)
    static let editBarExitTransitionAnimation: Animation = .smooth(duration: 0.20)
    static let restoreTransition: Animation = .smooth(duration: 0.22)
    static let bookListSearchDrawerDuration: TimeInterval = 0.28
    static let bookListSearchSurfaceDuration: TimeInterval = 0.18
    static let bookListResultTransitionDuration: TimeInterval = 0.30
    static let bookListResultExitDuration: TimeInterval = 0.16
    static let bookListInitialRevealDuration: TimeInterval = 0.24
    static let bookListTopActionDuration: TimeInterval = 0.26
    static let editSelectionPulseDamping: CGFloat = 0.76

    static func modeAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.16) : modeTransition
    }

    static func bookListTopActionAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.10) : .smooth(duration: bookListTopActionDuration)
    }

    static func bookListResultStateAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.12) : .smooth(duration: bookListResultTransitionDuration)
    }

    static func restoreAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.14) : restoreTransition
    }

    static func editBarRevealAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.12) : editBarRevealTransitionAnimation
    }

    static func editBarExitAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.10) : editBarExitTransitionAnimation
    }

    static func topChromeTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -4))
    }

    static func bookListTopChromeTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .asymmetric(
            insertion: .opacity
                .combined(with: .offset(y: 5))
                .combined(with: .scale(scale: 0.99, anchor: .center)),
            removal: .opacity
                .combined(with: .offset(y: -5))
                .combined(with: .scale(scale: 0.99, anchor: .center))
        )
    }

    static func editBarRevealTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .asymmetric(
            insertion: .opacity
                .combined(with: .offset(x: 0, y: 44))
                .combined(with: .scale(scale: 0.985, anchor: .bottom)),
            removal: .opacity
                .combined(with: .offset(x: 0, y: 48))
                .combined(with: .scale(scale: 0.985, anchor: .bottom))
        )
    }

    static func browsingChromeTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(x: 0, y: -2))
    }

    static func editSearchTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity
            .combined(with: .scale(scale: 0.96, anchor: .top))
            .combined(with: .offset(y: -4))
    }

    /// 系统 TabBar 隐藏后，到编辑工具栏抬起之间的短延迟。
    static func editBarRevealDelay(reduceMotion: Bool) -> Duration {
        reduceMotion ? .milliseconds(16) : .milliseconds(70)
    }

    /// 编辑工具栏退出后，到系统 TabBar 恢复之间的延迟。
    static func editExitRestoreDelay(reduceMotion: Bool) -> Duration {
        reduceMotion ? .milliseconds(40) : .milliseconds(200)
    }

    /// 系统 TabBar 恢复后释放编辑底栏滚动避让的延迟。
    static func editBottomInsetReleaseDelay(reduceMotion: Bool) -> Duration {
        reduceMotion ? .milliseconds(40) : .milliseconds(100)
    }
}

/// 为书架一级页与二级页提供一致的搜索 drawer 展示尺寸。
enum BookshelfSearchSurfaceMetrics {
    static let touchHeight: CGFloat = InteractionMetrics.minimumTouchTarget
    static let compactVisualHeight: CGFloat = 38
    static let accessibilityVisualHeight: CGFloat = 46
    static let iconSize: CGFloat = 17

    /// 根据动态字体布局模式返回搜索 surface 的视觉高度，保证大字号下输入区域不会被压缩。
    static func visualHeight(usesAccessibilityLayout: Bool) -> CGFloat {
        usesAccessibilityLayout ? accessibilityVisualHeight : compactVisualHeight
    }
}

/// 搜索 drawer 在 collection 内的呈现方式，hidden 表示保留可下拉空间但收在可视顶部外侧。
enum BookshelfSearchDrawerPresentation: Equatable {
    case hidden
    case pinned

    var isPinned: Bool {
        self == .pinned
    }
}

/// 描述书架搜索 surface 的输入、焦点、清除与取消语义，供一级页和二级页复用同一控件。
struct BookshelfSearchSurfaceConfiguration {
    let namespace: String
    let placeholder: String
    let keyword: String
    let showsInput: Bool
    let showsClearAction: Bool
    let usesAccessibilityLayout: Bool
    let isFocused: Bool
    let focusTrigger: Int
    let accessibilityLabel: String
    let onActivate: () -> Void
    let onTextChange: (String) -> Void
    let onSubmit: (String) -> Void
    let onClear: () -> Void
    let onCancel: () -> Void
    let onFocusChange: (Bool) -> Void
}

/// 协调搜索 drawer 从点击激活到输入聚焦的两阶段请求，避免 offset 收敛与键盘动画同帧竞争。
final class BookshelfSearchFocusRequestCoordinator {
    private var generation = 0
    private(set) var isPending = false

    /// 外部配置已进入焦点或退出输入态时结束 pending，避免旧请求在后续布局周期误保留。
    func reconcile(isFocused: Bool, isExpanded: Bool) {
        guard isFocused || !isExpanded else { return }
        generation += 1
        isPending = false
    }

    /// 在 drawer 位置稳定后延迟到下一轮 runloop 请求 SwiftUI 递增 focus trigger。
    func request(_ requestFocus: @escaping () -> Void) {
        generation += 1
        let currentGeneration = generation
        isPending = true

        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == currentGeneration else { return }
            requestFocus()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, self.generation == currentGeneration else { return }
            self.isPending = false
        }
    }

    /// 页面销毁、复用或搜索不支持时取消未完成的聚焦请求。
    func cancel() {
        generation += 1
        isPending = false
    }
}

/// 承载折叠态点击区域，让隐藏输入态也能以同一 accessibility drawer 入口被测试与读屏发现。
final class BookshelfSearchSurfaceContainerControl: UIControl {
    override var isHighlighted: Bool {
        didSet {
            updateHighlightAppearance(animated: true)
        }
    }

    /// 根据按压状态同步轻量反馈，避免 drawer 被激活时产生突兀的视觉跳变。
    private func updateHighlightAppearance(animated: Bool) {
        let updates = {
            self.alpha = self.isHighlighted ? 0.82 : 1
        }
        guard animated else {
            updates()
            return
        }
        UIView.animate(
            withDuration: BookshelfManagementMotion.bookListSearchSurfaceDuration,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction],
            animations: updates
        )
    }
}

/// UIKit 搜索 surface，统一一级书架和二级列表的折叠、输入、清除、取消、焦点与 Reduce Motion 行为。
final class BookshelfSearchSurfaceView: UIView, UITextFieldDelegate {
    private let containerControl = BookshelfSearchSurfaceContainerControl()
    private let surfaceView = UIView()
    private let iconView = UIImageView(image: UIImage(systemName: "magnifyingglass"))
    private let textField = UITextField()
    private let clearButton = XMMinimumHitTargetButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private lazy var surfaceTapRecognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleSurfaceTap))
        recognizer.cancelsTouchesInView = false
        return recognizer
    }()
    private var surfaceHeightConstraint: NSLayoutConstraint?
    private var activeSurfaceTrailingConstraint: NSLayoutConstraint?
    private var collapsedSurfaceTrailingConstraint: NSLayoutConstraint?
    private var configuration: BookshelfSearchSurfaceConfiguration?
    private var lastFocusTrigger: Int = 0
    private var isSearchMode = false
    private var shouldShowClearAction = false
    private var isAccessibilityLayout = false
    private var pendingFocusTrigger: Int?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUpViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 优先把外层 44pt 容器中的触点路由给视觉尺寸不变的清除按钮。
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let clearButtonPoint = clearButton.convert(point, from: self)
        if clearButton.point(inside: clearButtonPoint, with: event) {
            return clearButton.hitTest(clearButtonPoint, with: event) ?? clearButton
        }
        return super.hitTest(point, with: event)
    }

    /// 重置复用状态，避免 UICollectionView cell 复用时残留焦点与 closure。
    func prepareForReuse() {
        configuration = nil
        pendingFocusTrigger = nil
        textField.resignFirstResponder()
    }

    /// 按传入配置刷新 surface 的命名空间、输入值、状态与焦点触发。
    func configure(with configuration: BookshelfSearchSurfaceConfiguration) {
        self.configuration = configuration
        isAccessibilityLayout = configuration.usesAccessibilityLayout

        containerControl.accessibilityIdentifier = "\(configuration.namespace).drawer"
        containerControl.accessibilityLabel = configuration.accessibilityLabel
        containerControl.isAccessibilityElement = !configuration.showsInput
        containerControl.accessibilityTraits = configuration.showsInput ? [] : [.button]
        textField.accessibilityIdentifier = "\(configuration.namespace).field"
        clearButton.accessibilityIdentifier = "\(configuration.namespace).clear"
        cancelButton.accessibilityIdentifier = "\(configuration.namespace).cancel"

        textField.attributedPlaceholder = NSAttributedString(
            string: configuration.placeholder,
            attributes: [.foregroundColor: UIColor.xmResolved(Color.textHint)]
        )
        if textField.text != configuration.keyword {
            textField.text = configuration.keyword
        }

        setSearchMode(configuration.showsInput, animated: true)
        setClearActionVisible(configuration.showsClearAction, animated: true)
        updateSearchAppearance()

        let visualHeight = BookshelfSearchSurfaceMetrics.visualHeight(
            usesAccessibilityLayout: configuration.usesAccessibilityLayout
        )
        if abs((surfaceHeightConstraint?.constant ?? visualHeight) - visualHeight) > 0.5 {
            surfaceHeightConstraint?.constant = visualHeight
            setNeedsLayout()
        }

        if !configuration.isFocused, textField.isFirstResponder {
            pendingFocusTrigger = nil
            textField.resignFirstResponder()
        } else if configuration.showsInput, configuration.focusTrigger != lastFocusTrigger {
            requestInputFocus(for: configuration.focusTrigger)
        } else if !configuration.showsInput, textField.isFirstResponder {
            pendingFocusTrigger = nil
            textField.resignFirstResponder()
        }
    }

    /// 建立输入区域、清除按钮与取消按钮的层级，并统一 UIKit 动效参数。
    private func setUpViews() {
        backgroundColor = .clear
        isAccessibilityElement = false

        containerControl.translatesAutoresizingMaskIntoConstraints = false
        containerControl.backgroundColor = .clear
        containerControl.addTarget(self, action: #selector(handleActivateTap), for: .touchUpInside)

        surfaceView.translatesAutoresizingMaskIntoConstraints = false
        surfaceView.backgroundColor = UIColor.xmResolved(Color.surfaceCard).withAlphaComponent(0.68)
        surfaceView.layer.cornerRadius = BookshelfSearchSurfaceMetrics.compactVisualHeight / 2
        surfaceView.layer.cornerCurve = .continuous
        surfaceView.layer.borderWidth = StrokeWidth.hairline
        surfaceView.layer.borderColor = UIColor.xmResolved(Color.surfaceBorderSubtle.opacity(0.22)).cgColor
        surfaceView.addGestureRecognizer(surfaceTapRecognizer)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.tintColor = UIColor.xmResolved(Color.textHint)
        iconView.contentMode = .scaleAspectFit
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.borderStyle = .none
        textField.backgroundColor = .clear
        textField.textColor = UIColor.xmResolved(Color.textPrimary)
        textField.tintColor = UIColor.xmResolved(Color.appTint)
        textField.returnKeyType = .search
        textField.clearButtonMode = .never
        textField.font = BookshelfTypography.uiSearchField
        textField.adjustsFontForContentSizeCategory = true
        textField.delegate = self
        textField.addTarget(self, action: #selector(textFieldDidChange), for: .editingChanged)

        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.tintColor = UIColor.xmResolved(Color.textHint)
        clearButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        clearButton.accessibilityLabel = "清除搜索"
        clearButton.alpha = 0
        clearButton.isHidden = true
        clearButton.addTarget(self, action: #selector(handleClearTap), for: .touchUpInside)

        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.setTitle("取消", for: .normal)
        cancelButton.titleLabel?.font = BookshelfTypography.uiSearchField
        cancelButton.titleLabel?.adjustsFontForContentSizeCategory = true
        cancelButton.setTitleColor(UIColor.xmResolved(Color.textSecondary), for: .normal)
        cancelButton.accessibilityLabel = "取消搜索"
        cancelButton.setContentHuggingPriority(.required, for: .horizontal)
        cancelButton.alpha = 0
        cancelButton.isHidden = true
        cancelButton.addTarget(self, action: #selector(handleCancelTap), for: .touchUpInside)

        addSubview(containerControl)
        containerControl.addSubview(surfaceView)
        containerControl.addSubview(cancelButton)
        surfaceView.addSubview(iconView)
        surfaceView.addSubview(textField)
        surfaceView.addSubview(clearButton)

        let heightConstraint = surfaceView.heightAnchor.constraint(equalToConstant: BookshelfSearchSurfaceMetrics.compactVisualHeight)
        let activeTrailingConstraint = surfaceView.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -8)
        let collapsedTrailingConstraint = surfaceView.trailingAnchor.constraint(equalTo: containerControl.trailingAnchor)
        surfaceHeightConstraint = heightConstraint
        activeSurfaceTrailingConstraint = activeTrailingConstraint
        collapsedSurfaceTrailingConstraint = collapsedTrailingConstraint
        activeTrailingConstraint.isActive = false

        NSLayoutConstraint.activate([
            containerControl.topAnchor.constraint(equalTo: topAnchor),
            containerControl.leadingAnchor.constraint(equalTo: leadingAnchor),
            containerControl.trailingAnchor.constraint(equalTo: trailingAnchor),
            containerControl.bottomAnchor.constraint(equalTo: bottomAnchor),

            surfaceView.leadingAnchor.constraint(equalTo: containerControl.leadingAnchor),
            surfaceView.centerYAnchor.constraint(equalTo: containerControl.centerYAnchor),
            heightConstraint,
            collapsedTrailingConstraint,

            cancelButton.trailingAnchor.constraint(equalTo: containerControl.trailingAnchor),
            cancelButton.centerYAnchor.constraint(equalTo: containerControl.centerYAnchor),
            cancelButton.heightAnchor.constraint(greaterThanOrEqualToConstant: BookshelfSearchSurfaceMetrics.touchHeight),

            iconView.leadingAnchor.constraint(equalTo: surfaceView.leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: surfaceView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: BookshelfSearchSurfaceMetrics.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: BookshelfSearchSurfaceMetrics.iconSize),

            clearButton.trailingAnchor.constraint(equalTo: surfaceView.trailingAnchor, constant: -8),
            clearButton.centerYAnchor.constraint(equalTo: surfaceView.centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 32),
            clearButton.heightAnchor.constraint(equalToConstant: 32),

            textField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: Spacing.compact),
            textField.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -Spacing.tiny),
            textField.topAnchor.constraint(equalTo: surfaceView.topAnchor),
            textField.bottomAnchor.constraint(equalTo: surfaceView.bottomAnchor)
        ])

        setSearchMode(false, animated: false)
        setClearActionVisible(false, animated: false)
    }

    /// 切换折叠态与输入态，并在 Reduce Motion 下退化为无位移动画。
    private func setSearchMode(_ enabled: Bool, animated: Bool) {
        guard isSearchMode != enabled else {
            surfaceView.isUserInteractionEnabled = enabled
            textField.isUserInteractionEnabled = enabled
            clearButton.isUserInteractionEnabled = enabled
            cancelButton.alpha = enabled ? 1 : 0
            cancelButton.isHidden = !enabled
            updateSurfaceTrailingConstraintForSearchMode(enabled)
            return
        }
        isSearchMode = enabled
        let updates = {
            self.cancelButton.alpha = enabled ? 1 : 0
            self.cancelButton.isHidden = !enabled
            self.updateSurfaceTrailingConstraintForSearchMode(enabled)
            self.surfaceView.isUserInteractionEnabled = enabled
            self.textField.isUserInteractionEnabled = enabled
            self.clearButton.isUserInteractionEnabled = enabled
            self.layoutIfNeeded()
        }
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            updates()
            return
        }
        UIView.animate(
            withDuration: BookshelfManagementMotion.bookListSearchSurfaceDuration,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut],
            animations: updates
        )
    }

    /// 切换搜索框右侧约束，折叠态铺满容器，输入态为取消按钮让位。
    private func updateSurfaceTrailingConstraintForSearchMode(_ enabled: Bool) {
        if enabled {
            collapsedSurfaceTrailingConstraint?.isActive = false
            activeSurfaceTrailingConstraint?.isActive = true
        } else {
            activeSurfaceTrailingConstraint?.isActive = false
            collapsedSurfaceTrailingConstraint?.isActive = true
        }
    }

    /// 同步清除按钮显隐，保证清空后焦点仍停留在输入框。
    private func setClearActionVisible(_ visible: Bool, animated: Bool) {
        guard shouldShowClearAction != visible
                || clearButton.isHidden != !visible
                || abs(clearButton.alpha - (visible ? 1 : 0)) > 0.01 else {
            return
        }
        shouldShowClearAction = visible
        let updates = {
            self.clearButton.alpha = visible ? 1 : 0
            self.clearButton.isHidden = !visible
        }
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            updates()
            return
        }
        UIView.animate(
            withDuration: BookshelfManagementMotion.bookListSearchSurfaceDuration,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction],
            animations: updates
        )
    }

    /// 根据焦点与输入态刷新背景、边框和圆角，维持一级/二级页一致的层级反馈。
    private func updateSearchAppearance() {
        let isActive = isSearchMode || textField.isFirstResponder
        surfaceView.backgroundColor = UIColor.xmResolved(Color.surfaceCard).withAlphaComponent(isActive ? 0.82 : 0.62)
        surfaceView.layer.borderColor = UIColor.xmResolved(Color.surfaceBorderSubtle.opacity(isActive ? 0.38 : 0.22)).cgColor
        surfaceView.layer.cornerRadius = BookshelfSearchSurfaceMetrics.visualHeight(
            usesAccessibilityLayout: isAccessibilityLayout
        ) / 2
    }

    /// 处理折叠 surface 点击，将搜索切换到输入态并交给宿主驱动聚焦。
    @objc private func handleActivateTap() {
        configuration?.onActivate()
    }

    /// 激活态下点击胶囊任意空白区域都应回到输入框，保持原生搜索控件的命中预期。
    @objc private func handleSurfaceTap() {
        guard configuration?.showsInput == true else { return }
        textField.becomeFirstResponder()
    }

    /// 清除关键词但保持输入态，支持连续修正搜索条件。
    @objc private func handleClearTap() {
        textField.text = ""
        configuration?.onClear()
        configuration?.onTextChange("")
        textField.becomeFirstResponder()
    }

    /// 取消搜索并交由宿主恢复原列表状态。
    @objc private func handleCancelTap() {
        textField.text = ""
        textField.resignFirstResponder()
        configuration?.onCancel()
    }

    /// 将用户输入即时回写到宿主，宿主负责同步搜索关键词并刷新过滤结果。
    @objc private func textFieldDidChange() {
        configuration?.onTextChange(textField.text ?? "")
    }

    /// 输入框开始编辑时同步激活态，避免键盘焦点和外层 drawer 状态脱节。
    func textFieldDidBeginEditing(_ textField: UITextField) {
        configuration?.onFocusChange(true)
        updateSearchAppearance()
    }

    /// 输入框结束编辑时通知宿主，空关键词场景可由宿主决定是否折叠。
    func textFieldDidEndEditing(_ textField: UITextField) {
        configuration?.onFocusChange(false)
        updateSearchAppearance()
    }

    /// 搜索键提交当前草稿并收起键盘，保持结果页可继续浏览。
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        configuration?.onSubmit(textField.text ?? "")
        textField.resignFirstResponder()
        return true
    }

    /// 在 collection offset 和 cell 刷新同一帧发生时重试聚焦，避免首次点击被布局切换吞掉。
    private func requestInputFocus(for trigger: Int, attempt: Int = 0) {
        lastFocusTrigger = trigger
        pendingFocusTrigger = trigger
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0 : 0.05)) { [weak self] in
            guard let self,
                  self.configuration?.showsInput == true,
                  self.configuration?.focusTrigger == trigger,
                  self.pendingFocusTrigger == trigger else {
                return
            }
            self.surfaceView.isUserInteractionEnabled = true
            self.textField.isUserInteractionEnabled = true
            self.clearButton.isUserInteractionEnabled = true
            self.layoutIfNeeded()

            let didFocus = self.textField.becomeFirstResponder() || self.textField.isFirstResponder
            self.updateSearchAppearance()
            if didFocus {
                self.pendingFocusTrigger = nil
            } else if attempt < 4 {
                self.requestInputFocus(for: trigger, attempt: attempt + 1)
            }
        }
    }
}

/// 书架整理态顶部 chrome 的统一高度，保证一级书架与二级列表拥有同一顶部节奏。
enum BookshelfEditChromeMetrics {
    static let topBarHeight: CGFloat = 56
    static let accessibilityTopBarHeight: CGFloat = 60
    static let sideSlotWidth: CGFloat = 112
    static let accessibilitySideSlotWidth: CGFloat = 128
    static let searchContextHeight: CGFloat = 52

    /// 按动态字体等级返回顶部整理栏高度，避免大字号下按钮压缩标题。
    static func topBarHeight(for dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        dynamicTypeSize >= .accessibility1 ? accessibilityTopBarHeight : topBarHeight
    }

    /// 按动态字体等级返回左右操作槽宽度，保证中间状态标题保持视觉居中。
    static func sideSlotWidth(for dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        dynamicTypeSize >= .accessibility1 ? accessibilitySideSlotWidth : sideSlotWidth
    }
}

/// 整理态顶部摘要的对象范围，区分一级书架可同时选择书籍/分组和二级列表仅选择书籍。
enum BookshelfEditChromeSelectionScope {
    case booksOnly
    case booksAndGroups
}

/// 整理态顶部检索状态，区分未检索、检索有结果与检索无匹配结果。
enum BookshelfEditChromeSearchState: Equatable {
    case inactive
    case active(resultCount: Int)

    var resultCount: Int? {
        switch self {
        case .inactive:
            return nil
        case .active(let resultCount):
            return resultCount
        }
    }

    var isFiltering: Bool {
        resultCount != nil
    }

    var hasEmptyResult: Bool {
        resultCount == 0
    }
}

/// 书架编辑态顶部 chrome，复用浏览态顶部高度表达当前批量管理上下文与批量命令。
struct BookshelfEditChrome<BatchActions: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let selectedBookCount: Int
    let selectedGroupCount: Int
    let selectionScope: BookshelfEditChromeSelectionScope
    let isAllVisibleSelected: Bool
    let isSelectionToggleEnabled: Bool
    let searchState: BookshelfEditChromeSearchState
    let statusText: String?
    let drawsSurfaceBackground: Bool
    let showsBottomDivider: Bool
    let onToggleSelectAll: () -> Void
    let onCancel: () -> Void
    let batchActions: BatchActions

    /// 创建整理态顶部 chrome，并按使用场景决定选择摘要是否包含分组。
    init(
        selectedBookCount: Int,
        selectedGroupCount: Int = 0,
        selectionScope: BookshelfEditChromeSelectionScope = .booksAndGroups,
        isAllVisibleSelected: Bool,
        isSelectionToggleEnabled: Bool = true,
        searchState: BookshelfEditChromeSearchState = .inactive,
        statusText: String? = nil,
        drawsSurfaceBackground: Bool = true,
        showsBottomDivider: Bool = true,
        onToggleSelectAll: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        @ViewBuilder batchActions: () -> BatchActions
    ) {
        self.selectedBookCount = selectedBookCount
        self.selectedGroupCount = selectedGroupCount
        self.selectionScope = selectionScope
        self.isAllVisibleSelected = isAllVisibleSelected
        self.isSelectionToggleEnabled = isSelectionToggleEnabled
        self.searchState = searchState
        self.statusText = statusText
        self.drawsSurfaceBackground = drawsSurfaceBackground
        self.showsBottomDivider = showsBottomDivider
        self.onToggleSelectAll = onToggleSelectAll
        self.onCancel = onCancel
        self.batchActions = batchActions()
    }

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.base) {
            Button(selectionToggleTitle, action: onToggleSelectAll)
                .font(AppTypography.body)
                .foregroundStyle(selectionToggleForegroundStyle)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: sideSlotWidth, alignment: .leading)
                .frame(minHeight: InteractionMetrics.minimumTouchTarget)
                .accessibilityLabel(selectionToggleTitle)
                .disabled(!effectiveSelectionToggleEnabled)

            Spacer(minLength: Spacing.compact)

            VStack(spacing: Spacing.tiny) {
                Text("选择书籍")
                    .font(AppTypography.bodyMedium)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(effectiveStatusText)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentTransition(.numericText(value: selectionSummaryNumericValue))
                    .animation(selectionSummaryAnimation, value: selectionSummaryNumericValue)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)

            Spacer(minLength: Spacing.compact)

            rightActions
                .frame(width: sideSlotWidth, alignment: .trailing)
                .frame(minHeight: InteractionMetrics.minimumTouchTarget)
        }
        .padding(.horizontal, Spacing.screenEdge)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background {
            if drawsSurfaceBackground {
                Color.surfacePage
                    .ignoresSafeArea(.container, edges: .top)
            }
        }
        .overlay(alignment: .bottom) {
            if showsBottomDivider {
                Divider()
                    .overlay(Color.surfaceBorderSubtle.opacity(0.38))
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var sideSlotWidth: CGFloat {
        BookshelfEditChromeMetrics.sideSlotWidth(for: dynamicTypeSize)
    }

    private var effectiveSelectionToggleEnabled: Bool {
        isSelectionToggleEnabled && !searchState.hasEmptyResult
    }

    private var selectionSummaryNumericValue: Double {
        Double(selectedBookCount + selectedGroupCount)
    }

    private var selectionSummaryAnimation: Animation? {
        reduceMotion ? nil : BookshelfManagementMotion.modeAnimation(reduceMotion: false)
    }

    private var selectionToggleForegroundStyle: Color {
        effectiveSelectionToggleEnabled ? Color.textPrimary : Color.textSecondary.opacity(0.56)
    }

    private var rightActions: some View {
        HStack(spacing: Spacing.half) {
            batchActions

            Button("完成", action: onCancel)
                .font(AppTypography.body)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(
                    minWidth: 50,
                    minHeight: InteractionMetrics.minimumTouchTarget,
                    alignment: .trailing
                )
                .accessibilityLabel("退出整理模式")
        }
    }

    private var effectiveStatusText: String {
        guard let statusText, !statusText.isEmpty else { return selectionSummaryText }
        return statusText
    }

    private var selectionToggleTitle: String {
        if searchState.hasEmptyResult {
            return "无结果"
        }
        if searchState.isFiltering {
            return isAllVisibleSelected ? "取消选择" : "全选结果"
        }
        return isAllVisibleSelected ? "取消全选" : "全选"
    }

    private var selectionSummaryText: String {
        let baseText: String
        switch selectionScope {
        case .booksOnly:
            if searchState.isFiltering {
                baseText = selectedBookCount == 0 ? "未选择" : "已选 \(selectedBookCount) 本"
            } else {
                baseText = selectedBookCount == 0 ? "未选择书籍" : "已选 \(selectedBookCount) 本"
            }
        case .booksAndGroups:
            if searchState.isFiltering {
                let totalCount = selectedBookCount + selectedGroupCount
                baseText = totalCount == 0 ? "未选择" : "已选 \(totalCount) 项"
            } else {
                switch (selectedBookCount, selectedGroupCount) {
                case (0, 0):
                    baseText = "未选择"
                case (let bookCount, 0):
                    baseText = "已选 \(bookCount) 本"
                case (0, let groupCount):
                    baseText = "已选 \(groupCount) 组"
                case (let bookCount, let groupCount):
                    baseText = "已选 \(bookCount) 本 \(groupCount) 组"
                }
            }
        }

        guard let searchResultCount = searchState.resultCount else { return baseText }
        let resultText: String
        if searchResultCount == 0 {
            resultText = "无匹配结果"
        } else {
            switch selectionScope {
            case .booksOnly:
                resultText = "\(searchResultCount) 本结果"
            case .booksAndGroups:
                resultText = "\(searchResultCount) 项结果"
            }
        }
        return "\(baseText) · \(resultText)"
    }
}

/// 整理态上下文检索条，作为顶部 chrome 的局部扩展，避免遮挡书籍内容。
struct BookshelfEditSearchContextBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var isPresented: Bool
    @Binding var text: String
    let placeholder: String
    let onCollapse: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: Spacing.none) {
            if isSearchActive {
                expandedSearchField
                    .transition(searchModeTransition)
            } else {
                Spacer(minLength: Spacing.none)
                collapsedSearchButton
                    .transition(searchModeTransition)
                Spacer(minLength: Spacing.none)
            }
        }
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.top, Spacing.tiny)
        .padding(.bottom, Spacing.compact)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .animation(BookshelfManagementMotion.modeAnimation(reduceMotion: reduceMotion), value: isSearchActive)
        .animation(BookshelfManagementMotion.modeAnimation(reduceMotion: reduceMotion), value: text.isEmpty)
        .onAppear {
            syncFocusWithSearchState()
        }
        .onChange(of: isSearchActive) { _, _ in
            syncFocusWithSearchState()
        }
        .onChange(of: placeholder) { _, _ in
            syncFocusWithSearchState()
        }
    }

    private var isSearchActive: Bool {
        isPresented || !text.isEmpty
    }

    private var searchModeTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity
            .combined(with: .scale(scale: 0.97, anchor: .center))
    }

    private var collapsedSearchButton: some View {
        Button(action: presentSearch) {
            HStack(spacing: Spacing.tight) {
                Image(systemName: "magnifyingglass")
                    .font(AppTypography.subheadlineMedium)
                    .foregroundStyle(Color.iconSecondary)

                Text("搜索整理结果")
                    .font(AppTypography.subheadline)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, Spacing.base)
            .frame(height: 38)
            .background(Color.surfaceCard.opacity(0.76), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(Color.surfaceBorderSubtle.opacity(0.34), lineWidth: StrokeWidth.hairline)
            }
            .glassEffect(.regular.interactive(), in: .capsule)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(minHeight: InteractionMetrics.minimumTouchTarget)
        .accessibilityLabel("搜索整理结果")
    }

    private var expandedSearchField: some View {
        HStack(spacing: Spacing.cozy) {
            HStack(spacing: Spacing.compact) {
                Image(systemName: "magnifyingglass")
                    .font(AppTypography.body)
                    .foregroundStyle(Color.iconSecondary)

                TextField(placeholder, text: $text)
                    .font(BookshelfTypography.searchField)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .submitLabel(.search)
                    .focused($isFocused)

                Button(action: clearSearchText) {
                    Image(systemName: "xmark.circle.fill")
                        .font(AppTypography.body)
                        .foregroundStyle(Color.iconSecondary)
                        .frame(
                            width: InteractionMetrics.minimumTouchTarget,
                            height: InteractionMetrics.minimumTouchTarget
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .opacity(text.isEmpty ? 0 : 1)
                .scaleEffect(text.isEmpty ? 0.92 : 1)
                .disabled(text.isEmpty)
                .accessibilityHidden(text.isEmpty)
                .accessibilityLabel("清除整理搜索")
            }
            .padding(.leading, Spacing.base)
            .padding(.trailing, Spacing.tiny)
            .frame(height: 40)
            .background(Color.surfaceCard.opacity(0.84), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(Color.surfaceBorderSubtle.opacity(0.42), lineWidth: StrokeWidth.hairline)
            }
            .glassEffect(.regular.interactive(), in: .capsule)

            Button("取消", action: cancelSearch)
                .font(BookshelfTypography.searchField)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
                .frame(
                    minWidth: InteractionMetrics.minimumTouchTarget,
                    minHeight: InteractionMetrics.minimumTouchTarget
                )
                .accessibilityLabel("退出整理搜索")
        }
    }

    private func clearSearchText() {
        withAnimation(BookshelfManagementMotion.modeAnimation(reduceMotion: reduceMotion)) {
            isPresented = true
            text = ""
        }
        focusSearchField()
    }

    private func presentSearch() {
        withAnimation(BookshelfManagementMotion.modeAnimation(reduceMotion: reduceMotion)) {
            isPresented = true
        }
        focusSearchField()
    }

    private func cancelSearch() {
        withAnimation(BookshelfManagementMotion.modeAnimation(reduceMotion: reduceMotion)) {
            text = ""
            isPresented = false
            isFocused = false
            onCollapse()
        }
    }

    private func syncFocusWithSearchState() {
        if isSearchActive {
            focusSearchField()
        } else {
            isFocused = false
        }
    }

    /// 下一轮 MainActor 聚焦，避免 TextField 尚未进入层级时丢焦；任务只写本地 FocusState，视图消失后无外部副作用。
    private func focusSearchField() {
        Task { @MainActor in
            guard isSearchActive else { return }
            isFocused = true
        }
    }
}

/// 书架网格封面的选中遮罩，用中性复合层表达稳定选择态。
struct BookshelfSelectionCoverOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isSelected: Bool
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        ZStack {
            shape
                .fill(Color.black.opacity(0.34))
                .opacity(isSelected ? 1 : 0)
                .animation(maskAnimation, value: isSelected)

            shape
                .strokeBorder(Color.white.opacity(0.22), lineWidth: StrokeWidth.hairline)
                .opacity(isSelected ? 1 : 0)
                .animation(maskAnimation, value: isSelected)
        }
        .compositingGroup()
        .clipShape(shape)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var maskAnimation: Animation? {
        if reduceMotion {
            return .easeInOut(duration: 0.14)
        }
        return isSelected
            ? .smooth(duration: 0.24).delay(0.04)
            : .smooth(duration: 0.22).delay(0.04)
    }
}

/// 书架列表行的选中遮罩，不改变行内布局，仅用轻量 tint 与尾部符号确认状态。
struct BookshelfSelectionRowOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .subheadline) private var checkSize = 17

    let isSelected: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)

        ZStack(alignment: .trailing) {
            shape
                .fill(Color.selectionAccent.opacity(0.08))
                .opacity(isSelected ? 1 : 0)
                .animation(rowSurfaceAnimation, value: isSelected)

            shape
                .stroke(Color.selectionAccent.opacity(0.18), lineWidth: StrokeWidth.hairline)
                .opacity(isSelected ? 1 : 0)
                .animation(rowSurfaceAnimation, value: isSelected)

            Image(systemName: "checkmark")
                .font(BookshelfEditingTypography.selectionCheckmark(baseSize: checkSize))
                .foregroundStyle(Color.selectionAccent)
                .padding(.trailing, Spacing.base)
                .opacity(isSelected ? 1 : 0)
                .animation(rowCheckAnimation, value: isSelected)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var rowSurfaceAnimation: Animation? {
        if reduceMotion {
            return .easeInOut(duration: 0.10)
        }
        return isSelected
            ? .easeOut(duration: 0.12)
            : .easeInOut(duration: 0.10).delay(0.02)
    }

    private var rowCheckAnimation: Animation? {
        if reduceMotion {
            return .easeInOut(duration: 0.08)
        }
        return isSelected
            ? .easeOut(duration: 0.10).delay(0.02)
            : .easeIn(duration: 0.07)
    }
}
