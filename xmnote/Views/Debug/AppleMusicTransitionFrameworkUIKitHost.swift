#if DEBUG
import SwiftUI
import UIKit

/**
 * [INPUT]: 依赖 UIKit 的 UITabBarController、UITabAccessory、UIViewController.preferredTransition 与纯 UIKit 固定夹具
 * [OUTPUT]: 对外提供 AppleMusicTransitionFrameworkUIKitHost（不嵌入 SwiftUI 内容的 Bottom Accessory 系统 Zoom 最小复现壳）
 * [POS]: Debug 框架归因宿主，用于隔离 SwiftUI tabViewBottomAccessory 桥接层与 XMNote 自定义呈现生命周期
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// SwiftUI 只负责把独立实验壳挂入测试中心，壳内 Tab、Accessory、来源和目标全部由 UIKit 持有。
struct AppleMusicTransitionFrameworkUIKitHost: UIViewControllerRepresentable {
    let onClose: () -> Void

    func makeUIViewController(context: Context) -> AppleMusicTransitionFrameworkUIKitTabBarController {
        AppleMusicTransitionFrameworkUIKitTabBarController(onClose: onClose)
    }

    func updateUIViewController(
        _ uiViewController: AppleMusicTransitionFrameworkUIKitTabBarController,
        context: Context
    ) {
        uiViewController.update(onClose: onClose)
    }

    static func dismantleUIViewController(
        _ uiViewController: AppleMusicTransitionFrameworkUIKitTabBarController,
        coordinator: Void
    ) {
        uiViewController.dismissPresentedDestinationIfNeeded()
    }
}

/// 原生 Tab 容器直接拥有系统 UITabAccessory，并从同一个稳定 UIControl 查询 Zoom 来源。
@MainActor
final class AppleMusicTransitionFrameworkUIKitTabBarController: UITabBarController {
    private let accessoryControl = AppleMusicTransitionFrameworkUIKitAccessoryControl()
    private var onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.isOpaque = true
        tabBarMinimizeBehavior = .onScrollDown
        configureTabs()
        configureAccessory()
        AppleMusicTransitionLabLogger.event("Framework E UIKit launched")
    }

    func update(onClose: @escaping () -> Void) {
        self.onClose = onClose
        childNavigationControllers.forEach { navigationController in
            (navigationController.topViewController as? AppleMusicTransitionFrameworkUIKitFeedController)?
                .update(onClose: onClose)
        }
    }

    func dismissPresentedDestinationIfNeeded() {
        guard let presentedViewController else { return }
        presentedViewController.dismiss(animated: false)
    }

    private var childNavigationControllers: [UINavigationController] {
        viewControllers?.compactMap { $0 as? UINavigationController } ?? []
    }

    private func configureTabs() {
        let list = makeTab(
            title: "列表",
            systemImage: "list.bullet",
            feedTitle: "纯 UIKit"
        )
        let settings = makeTab(
            title: "设置",
            systemImage: "gearshape",
            feedTitle: "系统设置"
        )
        setViewControllers([list, settings], animated: false)
    }

    private func makeTab(
        title: String,
        systemImage: String,
        feedTitle: String
    ) -> UINavigationController {
        let feed = AppleMusicTransitionFrameworkUIKitFeedController(
            title: feedTitle,
            onClose: onClose
        )
        let navigationController = UINavigationController(rootViewController: feed)
        navigationController.tabBarItem = UITabBarItem(
            title: title,
            image: UIImage(systemName: systemImage),
            selectedImage: nil
        )
        return navigationController
    }

    private func configureAccessory() {
        accessoryControl.addTarget(
            self,
            action: #selector(openDestination),
            for: .touchUpInside
        )
        bottomAccessory = UITabAccessory(contentView: accessoryControl)
    }

    @objc private func openDestination() {
        guard presentedViewController == nil else { return }

        let target = AppleMusicTransitionFrameworkUIKitDestinationController()
        target.modalPresentationStyle = .overFullScreen

        let options = UIViewController.Transition.ZoomOptions()
        options.interactiveDismissShouldBegin = { context in
            AppleMusicTransitionLabLogger.event(
                "Framework E UIKit interactive decision; willBegin=\(context.willBegin), velocity=(\(context.velocity.dx), \(context.velocity.dy))"
            )
            return context.willBegin
        }
        target.preferredTransition = .zoom(options: options) { [weak self] _ in
            guard let self,
                  self.accessoryControl.window != nil,
                  !self.accessoryControl.isHidden,
                  self.accessoryControl.alpha > 0.001,
                  self.accessoryControl.bounds.width > 0,
                  self.accessoryControl.bounds.height > 0 else {
                AppleMusicTransitionLabLogger.event(
                    "Framework E UIKit source provider returned nil"
                )
                return nil
            }
            let rect = self.accessoryControl.convert(
                self.accessoryControl.bounds,
                to: self.accessoryControl.window
            )
            AppleMusicTransitionLabLogger.event(
                "Framework E UIKit source provider; rect=\(NSCoder.string(for: rect))"
            )
            return self.accessoryControl
        }

        AppleMusicTransitionLabLogger.event("Framework E UIKit presentation requested")
        present(target, animated: true) {
            AppleMusicTransitionLabLogger.event(
                "Framework E UIKit presentation completed"
            )
        }
    }
}

/// 固定列表和底部三段系统色只提供玻璃采样背景，不参与转场或来源绘制。
@MainActor
private final class AppleMusicTransitionFrameworkUIKitFeedController: UIViewController,
    UITableViewDataSource {
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let calibrationView = UIView()
    private let calibrationMask = CAGradientLayer()
    private var onClose: () -> Void

    init(title: String, onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureTableView()
        configureCalibrationView()
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "退出",
            style: .plain,
            target: self,
            action: #selector(closeExperiment)
        )
        navigationItem.rightBarButtonItem?.accessibilityIdentifier =
            "apple-music-transition-framework-uikit-exit"
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        calibrationMask.frame = calibrationView.bounds
    }

    func update(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    private func configureTableView() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .systemBackground
        tableView.dataSource = self
        tableView.contentInset.bottom = 96
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "SystemRow")
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func configureCalibrationView() {
        calibrationView.translatesAutoresizingMaskIntoConstraints = false
        calibrationView.isUserInteractionEnabled = false
        view.addSubview(calibrationView)
        NSLayoutConstraint.activate([
            calibrationView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            calibrationView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            calibrationView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            calibrationView.heightAnchor.constraint(
                equalToConstant: AppleMusicTransitionFrameworkFixture.calibrationHeight
            )
        ])

        let colorViews = AppleMusicTransitionFrameworkFixture.calibrationColors.map { color in
            let colorView = UIView()
            colorView.backgroundColor = color
            return colorView
        }
        let stack = UIStackView(arrangedSubviews: colorViews)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 0
        calibrationView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: calibrationView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: calibrationView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: calibrationView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: calibrationView.bottomAnchor)
        ])

        calibrationMask.colors = [
            UIColor.clear.cgColor,
            UIColor.black.withAlphaComponent(0.82).cgColor,
            UIColor.black.cgColor
        ]
        calibrationMask.locations = [0, 0.55, 1]
        calibrationMask.startPoint = CGPoint(x: 0.5, y: 0)
        calibrationMask.endPoint = CGPoint(x: 0.5, y: 1)
        calibrationView.layer.mask = calibrationMask
    }

    @objc private func closeExperiment() {
        onClose()
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        20
    }

    func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: "SystemRow",
            for: indexPath
        )
        var content = cell.defaultContentConfiguration()
        content.text = "System Row \(indexPath.row + 1)"
        content.secondaryText = "Scroll to minimize the tab accessory"
        content.image = UIImage(
            systemName: indexPath.row.isMultiple(of: 2) ? "circle.fill" : "square.fill"
        )
        content.imageProperties.tintColor = AppleMusicTransitionFrameworkFixture
            .calibrationColors[indexPath.row % AppleMusicTransitionFrameworkFixture.calibrationColors.count]
        cell.contentConfiguration = content
        cell.backgroundColor = .clear
        cell.selectionStyle = .none
        return cell
    }
}

/// 透明稳定 UIControl 是系统 UITabAccessory 的唯一内容和唯一 Zoom 来源。
@MainActor
private final class AppleMusicTransitionFrameworkUIKitAccessoryControl: UIControl {
    private let symbolView = UIImageView(image: UIImage(systemName: "music.note"))
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let playView = UIImageView(image: UIImage(systemName: "play.fill"))
    private var traitRegistration: (any UITraitChangeRegistration)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        accessibilityLabel = "纯 UIKit 系统 Accessory"
        accessibilityIdentifier = "apple-music-transition-framework-uikit-accessory"
        accessibilityTraits = .button
        isAccessibilityElement = true
        configureContent()
        traitRegistration = registerForTraitChanges(
            [UITraitTabAccessoryEnvironment.self]
        ) { (control: AppleMusicTransitionFrameworkUIKitAccessoryControl, _) in
            control.updateForCurrentEnvironment()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(
            width: UIView.noIntrinsicMetric,
            height: AppleMusicTransitionFrameworkFixture.accessoryHeight
        )
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateForCurrentEnvironment()
    }

    private func configureContent() {
        symbolView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .body)
        symbolView.tintColor = .label
        symbolView.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textColor = .label
        titleLabel.text = "System Accessory"

        subtitleLabel.font = .preferredFont(forTextStyle: .caption1)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.text = "Paused · 00:42"

        playView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .body)
        playView.tintColor = .label
        playView.setContentHuggingPriority(.required, for: .horizontal)

        let labels = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        labels.axis = .vertical
        labels.alignment = .leading
        labels.spacing = 2

        let content = UIStackView(arrangedSubviews: [symbolView, labels, playView])
        content.translatesAutoresizingMaskIntoConstraints = false
        content.isUserInteractionEnabled = false
        content.axis = .horizontal
        content.alignment = .center
        content.spacing = 12
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func updateForCurrentEnvironment() {
        let isInline = traitCollection.tabAccessoryEnvironment == .inline
        titleLabel.text = isInline ? "00:42" : "System Accessory"
        titleLabel.font = isInline
            ? .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
            : .preferredFont(forTextStyle: .headline)
        subtitleLabel.isHidden = isInline
        playView.isHidden = isInline
        AppleMusicTransitionLabLogger.event(
            "Framework E UIKit accessory environment=\(String(describing: traitCollection.tabAccessoryEnvironment))"
        )
    }
}

/// 不透明纯 UIKit 目标页只观察系统 Zoom 的呈现、交互完成和取消生命周期。
@MainActor
private final class AppleMusicTransitionFrameworkUIKitDestinationController: UIViewController {
    private var isObservingDismissal = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.isOpaque = true
        configureContent()
        AppleMusicTransitionLabLogger.event("Framework E UIKit destination loaded")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isObservingDismissal = false
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard !isObservingDismissal else { return }
        isObservingDismissal = true
        let isInteractive = transitionCoordinator?.isInteractive == true
        AppleMusicTransitionLabLogger.event(
            isInteractive
                ? "Framework E UIKit interactive dismissal began"
                : "Framework E UIKit programmatic dismissal began"
        )
        transitionCoordinator?.animate(alongsideTransition: nil) { context in
            self.isObservingDismissal = false
            AppleMusicTransitionLabLogger.event(
                context.isCancelled
                    ? "Framework E UIKit interactive dismissal cancelled"
                    : "Framework E UIKit dismissal completed"
            )
        }
    }

    private func configureContent() {
        let symbol = UIImageView(image: UIImage(systemName: "music.note"))
        symbol.translatesAutoresizingMaskIntoConstraints = false
        symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 72)
        symbol.tintColor = .systemBlue

        let title = UILabel()
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .preferredFont(forTextStyle: .title1)
        title.text = "System Destination"
        title.textAlignment = .center

        let subtitle = UILabel()
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.font = .preferredFont(forTextStyle: .body)
        subtitle.textColor = .secondaryLabel
        subtitle.text = "Pure UIKit Over FullScreen Zoom"
        subtitle.textAlignment = .center

        let centerStack = UIStackView(arrangedSubviews: [symbol, title, subtitle])
        centerStack.translatesAutoresizingMaskIntoConstraints = false
        centerStack.axis = .vertical
        centerStack.alignment = .center
        centerStack.spacing = 20

        let closeButton = UIButton(type: .system)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.configuration = .plain()
        closeButton.configuration?.title = "关闭"
        closeButton.configuration?.image = UIImage(systemName: "chevron.down")
        closeButton.configuration?.imagePadding = 6
        closeButton.accessibilityIdentifier =
            "apple-music-transition-framework-uikit-dismiss"
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)

        view.addSubview(centerStack)
        view.addSubview(closeButton)
        NSLayoutConstraint.activate([
            symbol.widthAnchor.constraint(equalToConstant: 88),
            symbol.heightAnchor.constraint(equalToConstant: 88),
            centerStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            centerStack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            closeButton.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor,
                constant: 12
            ),
            closeButton.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor,
                constant: 8
            )
        ])

        view.accessibilityIdentifier =
            "apple-music-transition-framework-uikit-destination"
    }

    @objc private func close() {
        dismiss(animated: true)
    }
}
#endif
