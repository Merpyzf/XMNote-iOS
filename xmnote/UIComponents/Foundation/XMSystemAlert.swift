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
                dismiss?()
                action.handler()
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
        background(
            XMSystemAlertPresenter(
                isPresented: isPresented,
                descriptor: descriptor,
                onDismiss: onDismiss
            )
        )
    }

    /// 用 item 驱动系统中心弹窗，适合状态由可选 presentation model 承接的场景。
    func xmSystemAlert<Item: Identifiable>(
        item: Binding<Item?>,
        descriptor: @escaping (Item) -> XMSystemAlertDescriptor
    ) -> some View {
        background(
            XMSystemAlertItemPresenter(
                item: item,
                descriptor: descriptor
            )
        )
    }
}

private struct XMSystemAlertPresenter: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let descriptor: XMSystemAlertDescriptor?
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
                isPresented: isPresented,
                descriptor: descriptor,
                dismiss: { _isPresented.wrappedValue = false },
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
                isPresented: isPresented,
                descriptor: descriptor,
                dismiss: { _isPresented.wrappedValue = false },
                onDismiss: onDismiss
            )
        }
        context.coordinator.syncPresentation(
            for: uiViewController,
            isPresented: isPresented,
            descriptor: descriptor,
            dismiss: { _isPresented.wrappedValue = false },
            onDismiss: onDismiss
        )
    }

    static func dismantleUIViewController(_ uiViewController: HostViewController, coordinator: Coordinator) {
        coordinator.dismissIfNeeded()
    }
}

private struct XMSystemAlertItemPresenter<Item: Identifiable>: UIViewControllerRepresentable {
    @Binding var item: Item?
    let descriptor: (Item) -> XMSystemAlertDescriptor

    func makeCoordinator() -> XMSystemAlertPresenter.Coordinator {
        XMSystemAlertPresenter.Coordinator()
    }

    func makeUIViewController(context: Context) -> XMSystemAlertPresenter.HostViewController {
        let controller = XMSystemAlertPresenter.HostViewController()
        controller.onViewDidAppear = { [weak controller] in
            guard let controller else { return }
            context.coordinator.syncPresentation(
                for: controller,
                isPresented: item != nil,
                descriptor: item.map(descriptor),
                dismiss: { _item.wrappedValue = nil },
                onDismiss: nil
            )
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: XMSystemAlertPresenter.HostViewController, context: Context) {
        uiViewController.onViewDidAppear = { [weak uiViewController] in
            guard let uiViewController else { return }
            context.coordinator.syncPresentation(
                for: uiViewController,
                isPresented: item != nil,
                descriptor: item.map(descriptor),
                dismiss: { _item.wrappedValue = nil },
                onDismiss: nil
            )
        }
        context.coordinator.syncPresentation(
            for: uiViewController,
            isPresented: item != nil,
            descriptor: item.map(descriptor),
            dismiss: { _item.wrappedValue = nil },
            onDismiss: nil
        )
    }

    static func dismantleUIViewController(
        _ uiViewController: XMSystemAlertPresenter.HostViewController,
        coordinator: XMSystemAlertPresenter.Coordinator
    ) {
        coordinator.dismissIfNeeded()
    }
}

private extension XMSystemAlertPresenter {
    final class HostViewController: UIViewController {
        var onViewDidAppear: (() -> Void)?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            onViewDidAppear?()
        }
    }

    final class Coordinator: NSObject {
        private weak var presentedAlertController: UIAlertController?
        private var dismissPresentation: (() -> Void)?
        private var onDismiss: (() -> Void)?

        func syncPresentation(
            for viewController: UIViewController,
            isPresented: Bool,
            descriptor: XMSystemAlertDescriptor?,
            dismiss: @escaping () -> Void,
            onDismiss: (() -> Void)?
        ) {
            self.dismissPresentation = dismiss
            self.onDismiss = onDismiss

            if isPresented, let descriptor {
                presentIfNeeded(from: viewController, descriptor: descriptor)
            } else {
                dismissIfNeeded()
            }
        }

        func dismissIfNeeded() {
            guard let alertController = presentedAlertController else { return }
            presentedAlertController = nil
            guard alertController.presentingViewController != nil else { return }
            alertController.dismiss(animated: true)
        }

        private func presentIfNeeded(
            from viewController: UIViewController,
            descriptor: XMSystemAlertDescriptor
        ) {
            guard descriptor.actions.isEmpty == false else { return }
            guard presentedAlertController == nil else { return }
            guard viewController.viewIfLoaded?.window != nil else { return }
            guard viewController.presentedViewController == nil else { return }

            let alertController = XMSystemAlertController.makeAlertController(
                descriptor: descriptor,
                dismiss: { [weak self] in
                    self?.presentedAlertController = nil
                    self?.dismissPresentation?()
                    self?.onDismiss?()
                }
            )
            presentedAlertController = alertController
            viewController.present(alertController, animated: true)
        }
    }
}
