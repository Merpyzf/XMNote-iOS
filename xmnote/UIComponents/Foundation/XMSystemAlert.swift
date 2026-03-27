/**
 * [INPUT]: 依赖 SwiftUI 的 UIViewControllerRepresentable 桥接与 UIKit 的 UIAlertController，统一承接系统型中心弹窗的标题、正文、动作与轻输入
 * [OUTPUT]: 对外提供 XMSystemAlertDescriptor、XMSystemAlertAction、XMSystemAlertTextField、XMSystemAlertController 与 View.xmSystemAlert(...)，覆盖 SwiftUI/ UIKit 双调用路径
 * [POS]: UIComponents/Foundation 的系统中心弹窗基础设施，负责用 UIKit 原生 Alert 表达系统型业务提示与轻输入场景
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 系统中心弹窗描述体，统一收敛标题、正文、动作与文本输入配置。
struct XMSystemAlertDescriptor {
    let title: String
    let message: String?
    let actions: [XMSystemAlertAction]
    let textFields: [XMSystemAlertTextField]
    let preferredActionID: XMSystemAlertAction.ID?

    init(
        title: String,
        message: String? = nil,
        actions: [XMSystemAlertAction],
        textFields: [XMSystemAlertTextField] = [],
        preferredActionID: XMSystemAlertAction.ID? = nil
    ) {
        self.title = title
        self.message = message
        self.actions = actions
        self.textFields = textFields
        self.preferredActionID = preferredActionID
    }
}

/// 系统中心弹窗动作，统一映射到 UIKit 的 default / cancel / destructive 语义。
struct XMSystemAlertAction: Identifiable {
    typealias ID = String

    enum Role {
        case `default`
        case cancel
        case destructive
    }

    let id: ID
    let title: String
    let role: Role
    let isEnabled: Bool
    let handler: () -> Void

    init(
        id: ID = UUID().uuidString,
        title: String,
        role: Role = .default,
        isEnabled: Bool = true,
        handler: @escaping () -> Void
    ) {
        self.id = id
        self.title = title
        self.role = role
        self.isEnabled = isEnabled
        self.handler = handler
    }
}

/// 系统中心弹窗文本输入配置，仅覆盖项目当前需要的轻输入能力。
struct XMSystemAlertTextField: Identifiable {
    typealias ID = String

    let id: ID
    let text: () -> String
    let setText: (String) -> Void
    let placeholder: String?
    let keyboardType: UIKeyboardType
    let textContentType: UITextContentType?
    let textInputAutocapitalization: UITextAutocapitalizationType
    let autocorrectionType: UITextAutocorrectionType
    let isSecureTextEntry: Bool

    init(
        id: ID = UUID().uuidString,
        text: Binding<String>,
        placeholder: String? = nil,
        keyboardType: UIKeyboardType = .default,
        textContentType: UITextContentType? = nil,
        textInputAutocapitalization: UITextAutocapitalizationType = .sentences,
        autocorrectionDisabled: Bool = false,
        isSecureTextEntry: Bool = false
    ) {
        self.id = id
        self.text = { text.wrappedValue }
        self.setText = { text.wrappedValue = $0 }
        self.placeholder = placeholder
        self.keyboardType = keyboardType
        self.textContentType = textContentType
        self.textInputAutocapitalization = textInputAutocapitalization
        self.autocorrectionType = autocorrectionDisabled ? .no : .default
        self.isSecureTextEntry = isSecureTextEntry
    }

    init(
        id: ID = UUID().uuidString,
        text: @escaping () -> String,
        setText: @escaping (String) -> Void,
        placeholder: String? = nil,
        keyboardType: UIKeyboardType = .default,
        textContentType: UITextContentType? = nil,
        textInputAutocapitalization: UITextAutocapitalizationType = .sentences,
        autocorrectionDisabled: Bool = false,
        isSecureTextEntry: Bool = false
    ) {
        self.id = id
        self.text = text
        self.setText = setText
        self.placeholder = placeholder
        self.keyboardType = keyboardType
        self.textContentType = textContentType
        self.textInputAutocapitalization = textInputAutocapitalization
        self.autocorrectionType = autocorrectionDisabled ? .no : .default
        self.isSecureTextEntry = isSecureTextEntry
    }
}

/// UIKit imperative presenter，供非 SwiftUI 宿主直接复用同一套系统弹窗模型。
enum XMSystemAlertController {
    /// 处理present对应的状态流转，确保交互过程与数据状态保持一致。
    static func present(
        on presenter: UIViewController,
        descriptor: XMSystemAlertDescriptor
    ) {
        guard presenter.presentedViewController == nil else { return }
        let alertController = makeAlertController(
            descriptor: descriptor,
            dismiss: nil
        )
        presenter.present(alertController, animated: true)
    }

    fileprivate static func makeAlertController(
        descriptor: XMSystemAlertDescriptor,
        dismiss: (() -> Void)?
    ) -> UIAlertController {
        let alertController = UIAlertController(
            title: descriptor.title,
            message: descriptor.message,
            preferredStyle: .alert
        )
        alertController.view.tintColor = .systemBlue

        let textFieldObservers = descriptor.textFields.map { TextFieldObserver(configuration: $0) }
        for observer in textFieldObservers {
            alertController.addTextField { textField in
                observer.configure(textField)
            }
        }
        objc_setAssociatedObject(
            alertController,
            &AssociatedKeys.textFieldObservers,
            textFieldObservers,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )

        var preferredAction: UIAlertAction?
        for action in descriptor.actions {
            let uiAction = UIAlertAction(
                title: action.title,
                style: alertActionStyle(for: action.role)
            ) { _ in
                action.handler()
                dismiss?()
            }
            uiAction.isEnabled = action.isEnabled
            alertController.addAction(uiAction)
            if action.id == descriptor.preferredActionID {
                preferredAction = uiAction
            }
        }
        alertController.preferredAction = preferredAction
        return alertController
    }

    private static func alertActionStyle(for role: XMSystemAlertAction.Role) -> UIAlertAction.Style {
        switch role {
        case .default:
            return .default
        case .cancel:
            return .cancel
        case .destructive:
            return .destructive
        }
    }

    /// AssociatedKeys 负责当前场景的enum定义，明确职责边界并组织相关能力。
    private enum AssociatedKeys {
        static var textFieldObservers: UInt8 = 0
    }

    private final class TextFieldObserver: NSObject {
        private let configuration: XMSystemAlertTextField

        init(configuration: XMSystemAlertTextField) {
            self.configuration = configuration
        }

        func configure(_ textField: UITextField) {
            textField.placeholder = configuration.placeholder
            textField.text = configuration.text()
            textField.keyboardType = configuration.keyboardType
            textField.textContentType = configuration.textContentType
            textField.autocapitalizationType = configuration.textInputAutocapitalization
            textField.autocorrectionType = configuration.autocorrectionType
            textField.isSecureTextEntry = configuration.isSecureTextEntry
            textField.addTarget(self, action: #selector(handleEditingChanged(_:)), for: .editingChanged)
        }

        @objc
        /// 处理handleEditingChanged对应的状态流转，确保交互过程与数据状态保持一致。
        private func handleEditingChanged(_ textField: UITextField) {
            configuration.setText(textField.text ?? "")
        }
    }
}

extension View {
    /// 用统一 descriptor 在 SwiftUI 页面上挂载 UIKit 系统中心弹窗。
    func xmSystemAlert(
        isPresented: Binding<Bool>,
        descriptor: XMSystemAlertDescriptor?,
        onDismiss: (() -> Void)? = nil
    ) -> some View {
        let stateProvider: () -> XMSystemAlertPresentationState? = {
            guard isPresented.wrappedValue, let descriptor else { return nil }
            return XMSystemAlertPresentationState(
                descriptor: descriptor,
                dismiss: { isPresented.wrappedValue = false }
            )
        }
        return background(
            XMSystemAlertHostPresenter(
                stateProvider: stateProvider,
                onDismiss: onDismiss
            )
        )
    }

    /// 用 item 驱动系统中心弹窗，适合状态由可选 presentation model 承接的场景。
    func xmSystemAlert<Item: Identifiable>(
        item: Binding<Item?>,
        descriptor: @escaping (Item) -> XMSystemAlertDescriptor
    ) -> some View {
        let stateProvider: () -> XMSystemAlertPresentationState? = {
            guard let currentItem = item.wrappedValue else { return nil }
            return XMSystemAlertPresentationState(
                descriptor: descriptor(currentItem),
                dismiss: { item.wrappedValue = nil }
            )
        }
        return background(
            XMSystemAlertHostPresenter(
                stateProvider: stateProvider,
                onDismiss: nil
            )
        )
    }
}

extension Binding {
    /// 把可选状态转换为 Alert 是否展示的布尔状态，关闭时自动清空可选值。
    func isPresented<Wrapped>(onDismiss: (() -> Void)? = nil) -> Binding<Bool> where Value == Wrapped? {
        Binding<Bool>(
            get: { wrappedValue != nil },
            set: { isPresented in
                guard !isPresented else { return }
                guard wrappedValue != nil else { return }
                onDismiss?()
                if wrappedValue != nil {
                    wrappedValue = nil
                }
            }
        )
    }
}

/// XMSystemAlertPresentationState 负责当前场景的struct定义，明确职责边界并组织相关能力。
private struct XMSystemAlertPresentationState {
    let descriptor: XMSystemAlertDescriptor
    let dismiss: () -> Void
}

/// XMSystemAlertHostPresenter 负责当前场景的struct定义，明确职责边界并组织相关能力。
private struct XMSystemAlertHostPresenter: UIViewControllerRepresentable {
    let stateProvider: () -> XMSystemAlertPresentationState?
    let onDismiss: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> HostViewController {
        let controller = HostViewController()
        controller.onViewDidAppear = { [weak controller] in
            guard let controller else { return }
            context.coordinator.syncPresentation(
                for: controller,
                state: stateProvider(),
                onDismiss: onDismiss
            )
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: HostViewController, context: Context) {
        uiViewController.onViewDidAppear = { [weak uiViewController] in
            guard let uiViewController else { return }
            context.coordinator.syncPresentation(
                for: uiViewController,
                state: stateProvider(),
                onDismiss: onDismiss
            )
        }
        context.coordinator.syncPresentation(
            for: uiViewController,
            state: stateProvider(),
            onDismiss: onDismiss
        )
    }

    /// 封装dismantleUIViewController对应的业务步骤，确保调用方可以稳定复用该能力。
    static func dismantleUIViewController(_ uiViewController: HostViewController, coordinator: Coordinator) {
        coordinator.dismissIfNeeded(notify: false)
    }
}

private extension XMSystemAlertHostPresenter {
    /// HostViewController 负责当前场景的class定义，明确职责边界并组织相关能力。
    final class HostViewController: UIViewController {
        var onViewDidAppear: (() -> Void)?

        /// 封装viewDidAppear对应的业务步骤，确保调用方可以稳定复用该能力。
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            onViewDidAppear?()
        }
    }

    /// Coordinator 负责当前场景的class定义，明确职责边界并组织相关能力。
    final class Coordinator: NSObject {
        private weak var presentedAlertController: UIAlertController?
        private var dismissPresentation: (() -> Void)?
        private var onDismiss: (() -> Void)?
        private var didNotifyDismiss = false

        func syncPresentation(
            for viewController: UIViewController,
            state: XMSystemAlertPresentationState?,
            onDismiss: (() -> Void)?
        ) {
            self.onDismiss = onDismiss

            if let state {
                presentIfNeeded(from: viewController, state: state)
            } else {
                dismissIfNeeded(notify: true)
            }
        }

        func dismissIfNeeded(notify: Bool) {
            guard let alertController = presentedAlertController else { return }
            presentedAlertController = nil
            guard alertController.presentingViewController != nil else {
                notifyDismissIfNeeded(shouldNotify: notify)
                return
            }
            alertController.dismiss(animated: true) { [weak self] in
                self?.notifyDismissIfNeeded(shouldNotify: notify)
            }
        }

        /// 处理presentIfNeeded对应的状态流转，确保交互过程与数据状态保持一致。
        private func presentIfNeeded(
            from viewController: UIViewController,
            state: XMSystemAlertPresentationState
        ) {
            guard state.descriptor.actions.isEmpty == false else { return }
            guard presentedAlertController == nil else { return }
            guard viewController.viewIfLoaded?.window != nil else { return }
            guard viewController.presentedViewController == nil else { return }

            dismissPresentation = state.dismiss
            didNotifyDismiss = false
            let alertController = XMSystemAlertController.makeAlertController(
                descriptor: state.descriptor,
                dismiss: { [weak self] in
                    guard let self else { return }
                    self.presentedAlertController = nil
                    self.notifyDismissIfNeeded(shouldNotify: true)
                }
            )
            presentedAlertController = alertController
            viewController.present(alertController, animated: true)
        }

        /// 封装notifyDismissIfNeeded对应的业务步骤，确保调用方可以稳定复用该能力。
        private func notifyDismissIfNeeded(shouldNotify: Bool) {
            guard shouldNotify else { return }
            guard !didNotifyDismiss else { return }
            didNotifyDismiss = true
            dismissPresentation?()
            onDismiss?()
        }
    }
}
