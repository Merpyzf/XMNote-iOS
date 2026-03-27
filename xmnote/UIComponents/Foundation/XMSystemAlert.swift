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
        return background(
            XMSystemAlertBooleanPresenter(
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
        return background(
            XMSystemAlertItemPresenter(
                item: item,
                descriptor: descriptor
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

private struct XMSystemAlertPresentationState {
    let requestID: UUID
    let descriptor: XMSystemAlertDescriptor
    let dismiss: () -> Void
}

private struct XMSystemAlertBooleanPresenter: View {
    @Binding var isPresented: Bool
    let descriptor: XMSystemAlertDescriptor?
    let onDismiss: (() -> Void)?

    @State private var requestID: UUID?
    @State private var previousIsPresented = false

    var body: some View {
        XMSystemAlertHostPresenter(
            state: presentationState,
            onDismiss: onDismiss
        )
        .onAppear {
            synchronizePresentationCycle()
        }
        .onChange(of: isPresented) { _, _ in
            synchronizePresentationCycle()
        }
    }

    private var presentationState: XMSystemAlertPresentationState? {
        guard isPresented, let descriptor, let requestID else { return nil }
        let requestIDBinding = $requestID
        let isPresentedBinding = $isPresented
        return XMSystemAlertPresentationState(
            requestID: requestID,
            descriptor: descriptor,
            dismiss: {
                guard requestIDBinding.wrappedValue == requestID else { return }
                isPresentedBinding.wrappedValue = false
            }
        )
    }

    private func synchronizePresentationCycle() {
        defer { previousIsPresented = isPresented }
        guard isPresented else {
            requestID = nil
            return
        }
        guard !previousIsPresented || requestID == nil else { return }
        requestID = UUID()
    }
}

private struct XMSystemAlertItemPresenter<Item: Identifiable>: View {
    @Binding var item: Item?
    let descriptor: (Item) -> XMSystemAlertDescriptor

    @State private var requestID: UUID?
    @State private var lastItemID: AnyHashable?

    var body: some View {
        XMSystemAlertHostPresenter(
            state: presentationState,
            onDismiss: nil
        )
        .onAppear {
            synchronizePresentationCycle()
        }
        .onChange(of: currentItemID) { _, _ in
            synchronizePresentationCycle()
        }
    }

    private var currentItemID: AnyHashable? {
        item.map { AnyHashable($0.id) }
    }

    private var presentationState: XMSystemAlertPresentationState? {
        guard let item, let requestID else { return nil }
        let requestIDBinding = $requestID
        let itemBinding = $item
        return XMSystemAlertPresentationState(
            requestID: requestID,
            descriptor: descriptor(item),
            dismiss: {
                guard requestIDBinding.wrappedValue == requestID else { return }
                itemBinding.wrappedValue = nil
            }
        )
    }

    private func synchronizePresentationCycle() {
        guard let currentItemID else {
            requestID = nil
            lastItemID = nil
            return
        }
        if lastItemID != currentItemID || requestID == nil {
            requestID = UUID()
        }
        lastItemID = currentItemID
    }
}

private struct XMSystemAlertHostPresenter: UIViewControllerRepresentable {
    let state: XMSystemAlertPresentationState?
    let onDismiss: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> HostViewController {
        let controller = HostViewController()
        controller.onPresentationOpportunity = { [weak controller] in
            guard let controller else { return }
            context.coordinator.reconcilePresentationOpportunity(from: controller)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: HostViewController, context: Context) {
        uiViewController.onPresentationOpportunity = { [weak uiViewController] in
            guard let uiViewController else { return }
            context.coordinator.reconcilePresentationOpportunity(from: uiViewController)
        }
        context.coordinator.syncPresentation(
            for: uiViewController,
            state: state,
            onDismiss: onDismiss
        )
    }

    static func dismantleUIViewController(_ uiViewController: HostViewController, coordinator: Coordinator) {
        coordinator.prepareForDismantle()
        coordinator.dismissIfNeeded(notify: false)
    }
}

private extension XMSystemAlertHostPresenter {
    final class HostViewController: UIViewController {
        var onPresentationOpportunity: (() -> Void)?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            onPresentationOpportunity?()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            onPresentationOpportunity?()
        }
    }

    final class Coordinator: NSObject {
        private weak var presentedAlertController: UIAlertController?
        private weak var hostViewController: UIViewController?
        private var dismissPresentation: (() -> Void)?
        private var onDismiss: (() -> Void)?
        private var desiredState: XMSystemAlertPresentationState?
        private var activeRequestID: UUID?
        private var lastDismissedRequestID: UUID?
        private var didNotifyDismiss = false
        private var isDismissInFlight = false
        private var isReconcileScheduled = false

        func syncPresentation(
            for viewController: UIViewController,
            state: XMSystemAlertPresentationState?,
            onDismiss: (() -> Void)?
        ) {
            hostViewController = viewController
            desiredState = state
            self.onDismiss = onDismiss
            reconcilePresentation(from: viewController)
        }

        func reconcilePresentationOpportunity(from viewController: UIViewController) {
            hostViewController = viewController
            reconcilePresentation(from: viewController)
        }

        func prepareForDismantle() {
            desiredState = nil
            onDismiss = nil
            dismissPresentation = nil
            hostViewController = nil
        }

        func dismissIfNeeded(notify: Bool) {
            guard let alertController = presentedAlertController else { return }
            guard !isDismissInFlight else { return }
            isDismissInFlight = true
            let dismissedRequestID = activeRequestID
            guard alertController.presentingViewController != nil else {
                completeDismissTransition(
                    dismissedRequestID: dismissedRequestID,
                    shouldNotify: notify
                )
                return
            }
            alertController.dismiss(animated: true) { [weak self] in
                self?.completeDismissTransition(
                    dismissedRequestID: dismissedRequestID,
                    shouldNotify: notify
                )
            }
        }

        private func reconcilePresentation(from viewController: UIViewController) {
            guard !isDismissInFlight else { return }
            if presentedAlertController == nil {
                activeRequestID = nil
            }

            guard let desiredState else {
                dismissIfNeeded(notify: true)
                return
            }
            guard desiredState.descriptor.actions.isEmpty == false else {
                self.desiredState = nil
                dismissIfNeeded(notify: true)
                return
            }
            guard desiredState.requestID != activeRequestID else { return }
            guard desiredState.requestID != lastDismissedRequestID else { return }

            guard presentedAlertController == nil else {
                dismissIfNeeded(notify: true)
                return
            }

            presentIfPossible(from: viewController, state: desiredState)
        }

        private func presentIfPossible(
            from viewController: UIViewController,
            state: XMSystemAlertPresentationState
        ) {
            guard viewController.viewIfLoaded?.window != nil else {
                scheduleReconcileIfNeeded(from: viewController)
                return
            }
            guard viewController.presentedViewController == nil else {
                scheduleReconcileIfNeeded(from: viewController)
                return
            }

            dismissPresentation = state.dismiss
            didNotifyDismiss = false
            isDismissInFlight = false
            lastDismissedRequestID = nil
            activeRequestID = state.requestID
            let alertController = XMSystemAlertController.makeAlertController(
                descriptor: state.descriptor,
                dismiss: { [weak self] in
                    guard let self else { return }
                    self.beginDismissTransitionAfterAction(shouldNotify: true)
                }
            )
            presentedAlertController = alertController
            viewController.present(alertController, animated: true)
        }

        private func beginDismissTransitionAfterAction(shouldNotify: Bool) {
            guard !isDismissInFlight else { return }
            isDismissInFlight = true
            let dismissedRequestID = activeRequestID
            let fallbackViewController = hostViewController
            presentedAlertController = nil
            DispatchQueue.main.async { [weak self, weak fallbackViewController] in
                guard let self else { return }
                self.completeDismissTransition(
                    dismissedRequestID: dismissedRequestID,
                    shouldNotify: shouldNotify,
                    fallbackViewController: fallbackViewController
                )
            }
        }

        private func completeDismissTransition(
            dismissedRequestID: UUID?,
            shouldNotify: Bool,
            fallbackViewController: UIViewController? = nil
        ) {
            presentedAlertController = nil
            activeRequestID = nil
            lastDismissedRequestID = dismissedRequestID
            isDismissInFlight = false
            notifyDismissIfNeeded(shouldNotify: shouldNotify)
            guard let viewController = hostViewController ?? fallbackViewController else { return }
            reconcilePresentation(from: viewController)
        }

        private func notifyDismissIfNeeded(shouldNotify: Bool) {
            guard shouldNotify else { return }
            guard !didNotifyDismiss else { return }
            didNotifyDismiss = true
            dismissPresentation?()
            onDismiss?()
        }

        private func scheduleReconcileIfNeeded(from viewController: UIViewController) {
            guard !isReconcileScheduled else { return }
            isReconcileScheduled = true
            DispatchQueue.main.async { [weak self, weak viewController] in
                guard let self else { return }
                self.isReconcileScheduled = false
                guard let viewController else { return }
                self.reconcilePresentation(from: viewController)
            }
        }
    }
}
