/**
 * [INPUT]: 依赖 SwiftUI/UIKit/TextKit 2、Observation、AIPromptEditorAppearance、变量目录与校验问题，接收纯文本、原始选区、插入请求、焦点绑定、命令控制器和悬浮栏内容避让高度
 * [OUTPUT]: 对内提供可编辑与只读的提示词 TextKit 渲染器及 AIPromptEditorCommandController，把已识别 `${变量名}` 显示为不可拆分的原子令牌，并桥接滚动避让、字段/整模板撤销重做与 UIKit 最终清理
 * [POS]: Views/Personal/Components 的 feature-private UIKit 桥接，被 AIPromptEditorView 的单一主编辑器消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit
import Observation

/// Prompt 编辑命令控制器；仅暴露当前 TextKit 实例的撤销、重做与组合输入状态。
@MainActor
@Observable
final class AIPromptEditorCommandController {
    private(set) var canUndo = false
    private(set) var canRedo = false
    private(set) var isComposing = false

    @ObservationIgnored private var connectionID: ObjectIdentifier?
    @ObservationIgnored private var commandHandler: ((Command) -> Bool)?

    /// 撤销当前字段的最近一次编辑；中文组合输入期间不会执行。
    func undo() {
        guard canUndo, !isComposing else { return }
        _ = commandHandler?(.undo)
    }

    /// 重做当前字段最近被撤销的编辑；中文组合输入期间不会执行。
    func redo() {
        guard canRedo, !isComposing else { return }
        _ = commandHandler?(.redo)
    }

    /// 在当前 TextView 的 UndoManager 中执行一次整模板更改，使双字段共用同一条撤销时间线。
    @discardableResult
    func performTemplateChange(
        before: AIPromptTemplate,
        after: AIPromptTemplate,
        actionName: String,
        apply: @escaping @MainActor (AIPromptTemplate) -> Void
    ) -> Bool {
        guard before != after, !isComposing else { return false }
        return commandHandler?(
            .applyTemplateChange(
                TemplateChange(
                    before: before,
                    after: after,
                    actionName: actionName,
                    apply: apply
                )
            )
        ) ?? false
    }

    /// 将命令路由到当前协调器；连接身份防止旧编辑器销毁时清空新实例。
    fileprivate func connect(
        id: ObjectIdentifier,
        handler: @escaping (Command) -> Bool
    ) {
        connectionID = id
        commandHandler = handler
    }

    /// 仅接收当前连接的 UndoManager 状态，避免旧协调器延迟回调覆盖新编辑器。
    fileprivate func updateState(
        id: ObjectIdentifier,
        canUndo: Bool,
        canRedo: Bool,
        isComposing: Bool
    ) {
        guard connectionID == id else { return }
        if self.canUndo != canUndo { self.canUndo = canUndo }
        if self.canRedo != canRedo { self.canRedo = canRedo }
        if self.isComposing != isComposing { self.isComposing = isComposing }
    }

    /// 断开指定编辑器；只有它仍是当前连接时才重置工具栏状态。
    fileprivate func disconnect(id: ObjectIdentifier) {
        guard connectionID == id else { return }
        connectionID = nil
        commandHandler = nil
        canUndo = false
        canRedo = false
        isComposing = false
    }

    fileprivate enum Command {
        case undo
        case redo
        case applyTemplateChange(TemplateChange)
    }

    fileprivate struct TemplateChange {
        let before: AIPromptTemplate
        let after: AIPromptTemplate
        let actionName: String
        let apply: @MainActor (AIPromptTemplate) -> Void
    }
}

/// 每次变量点击生成独立请求，使重复插入同一变量也能被编辑器可靠消费。
struct AIPromptVariableInsertionRequest: Equatable {
    let id = UUID()
    let variable: AIPromptVariableDefinition
}

/// TextKit 2 Prompt 编辑器；rawSelection 使用 NSString/UITextView 一致的 UTF-16 坐标。
struct AIPromptTokenTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var rawSelection: NSRange
    @Binding var insertionRequest: AIPromptVariableInsertionRequest?
    @Binding var isFocused: Bool

    let kind: AIPromptKind
    let field: AIPromptEditorField
    let issues: [AIPromptValidationIssue]
    let commandController: AIPromptEditorCommandController
    let contentBottomInset: CGFloat

    /// 创建 TextKit 2 编辑器，并安装纯文本剪贴板、焦点和 trait 变化桥接。
    func makeUIView(context: Context) -> AIPromptTokenTextView {
        AIPromptTokenAttachment.registerViewProviderIfNeeded()
        // `UITextView(usingTextLayoutManager:)` 是类工厂 convenience initializer，不能被子类覆盖；
        // iOS 16+ 的 nil textContainer designated initializer 默认建立 TextKit 2 管线。
        let textView = AIPromptTokenTextView(frame: .zero, textContainer: nil)
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.isEditable = true
        textView.isSelectable = true
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.contentInsetAdjustmentBehavior = .never
        textView.textContainerInset = UIEdgeInsets(
            top: 0,
            left: Spacing.contentEdge,
            bottom: 0,
            right: Spacing.contentEdge
        )
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = false
        textView.allowsEditingTextAttributes = false
        textView.accessibilityLabel = String(localized: field.displayTitle)
        textView.accessibilityHint = field == .taskTemplate
            ? "变量会作为一个整体编辑"
            : nil

        context.coordinator.attach(to: textView)
        context.coordinator.replaceEditorContent(
            with: text,
            rawSelection: rawSelection,
            clearsUndoHistory: true
        )
        context.coordinator.updateContentInsets(of: textView)
        return textView
    }

    /// 同步外部文本、校验、选区、焦点与一次性插入请求，不覆盖用户正在进行的中文组合输入。
    func updateUIView(_ textView: AIPromptTokenTextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(textView)
    }

    /// SwiftUI 移除桥接视图前主动断开键盘、UndoManager 与闭包，不回写任何编辑 Binding。
    static func dismantleUIView(
        _ textView: AIPromptTokenTextView,
        coordinator: Coordinator
    ) {
        coordinator.detach(from: textView)
    }

    /// 创建 UIKit delegate 协调器，集中维护 raw/display 投影和编辑现场。
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    /// 将 Domain 的字符范围转换为 rawSelection 使用的 UTF-16 范围。
    static func rawNSRange(
        for range: AIPromptTextRange,
        in rawText: String
    ) -> NSRange? {
        AIPromptTextProjection.rawNSRange(for: range, in: rawText)
    }

    /// UIKit delegate 与 SwiftUI Binding 的唯一协调器；所有编辑状态均限定在主线程。
    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: AIPromptTokenTextEditor

        private weak var textView: AIPromptTokenTextView?
        private var isApplyingProjection = false
        private var handledInsertionID: UUID?
        private var lastKind: AIPromptKind
        private var lastField: AIPromptEditorField
        private var lastIssues: [AIPromptValidationIssue]
        private weak var connectedCommandController: AIPromptEditorCommandController?
        private weak var observedUndoManager: UndoManager?
        private var commandStateRefreshTask: Task<Void, Never>?
        private var insertionTask: Task<Void, Never>?
        private var pendingTemplateProjectionText: String?

        private var connectionID: ObjectIdentifier {
            ObjectIdentifier(self)
        }

        /// 绑定初始 SwiftUI 输入，并记录需要区分的配置身份。
        init(parent: AIPromptTokenTextEditor) {
            self.parent = parent
            self.lastKind = parent.kind
            self.lastField = parent.field
            self.lastIssues = parent.issues
        }

        /// 安装编辑器回调；闭包弱持有协调器，避免 UITextView 与桥接对象形成环。
        func attach(to textView: AIPromptTokenTextView) {
            self.textView = textView
            textView.onTraitsChanged = { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.refreshForCurrentTraits(textView)
            }
            textView.onCopyRawText = { [weak self, weak textView] range in
                guard let self, let textView else { return nil }
                return self.rawText(in: range, from: textView)
            }
            textView.onReplaceSelectionWithRawText = { [weak self, weak textView] replacement, actionName in
                guard let self, let textView else { return }
                self.replaceCurrentSelection(
                    in: textView,
                    with: replacement,
                    actionName: actionName
                )
            }
            connectCommandController(to: textView)
            observeUndoManager(of: textView)
            scheduleCommandStateRefresh(for: textView)
        }

        /// 视图销毁时以幂等方式断开所有 UIKit 回调与观察，不触发 SwiftUI Binding 回写。
        func detach(from textView: AIPromptTokenTextView) {
            guard self.textView === textView else { return }

            insertionTask?.cancel()
            insertionTask = nil
            commandStateRefreshTask?.cancel()
            commandStateRefreshTask = nil
            stopObservingUndoManager()

            textView.delegate = nil
            textView.onTraitsChanged = nil
            textView.onCopyRawText = nil
            textView.onReplaceSelectionWithRawText = nil
            textView.inputAccessoryView = nil
            if textView.isFirstResponder {
                textView.resignFirstResponder()
            }

            textView.undoManager?.removeAllActions(withTarget: self)
            pendingTemplateProjectionText = nil
            connectedCommandController?.disconnect(id: connectionID)
            connectedCommandController = nil
            self.textView = nil
        }

        /// 把当前控制器绑定到该协调器；闭包只弱持有 UIKit 对象，避免编辑页退出后残留命令链。
        private func connectCommandController(to textView: AIPromptTokenTextView) {
            let controller = parent.commandController
            guard connectedCommandController !== controller else { return }

            connectedCommandController?.disconnect(id: connectionID)
            connectedCommandController = controller
            controller.connect(id: connectionID) { [weak self, weak textView] command in
                guard let self, let textView else { return false }
                return self.perform(command, in: textView)
            }
            controller.updateState(
                id: connectionID,
                canUndo: false,
                canRedo: false,
                isComposing: textView.markedTextRange != nil
            )
            scheduleCommandStateRefresh(for: textView)
        }

        /// 只观察撤销组安全关闭、撤销完成与重做完成，避免在 checkpoint 回调内读取 canRedo 造成重入。
        private func observeUndoManager(of textView: AIPromptTokenTextView) {
            let undoManager = textView.undoManager
            guard observedUndoManager !== undoManager else { return }

            stopObservingUndoManager()
            observedUndoManager = undoManager
            guard let undoManager else {
                updateUnavailableCommandState(isComposing: textView.markedTextRange != nil)
                return
            }

            let center = NotificationCenter.default
            center.addObserver(
                self,
                selector: #selector(undoManagerStateDidChange(_:)),
                name: .NSUndoManagerDidCloseUndoGroup,
                object: undoManager
            )
            center.addObserver(
                self,
                selector: #selector(undoManagerStateDidChange(_:)),
                name: .NSUndoManagerDidUndoChange,
                object: undoManager
            )
            center.addObserver(
                self,
                selector: #selector(undoManagerStateDidChange(_:)),
                name: .NSUndoManagerDidRedoChange,
                object: undoManager
            )
        }

        /// 移除协调器注册的 UndoManager 通知，允许旧编辑器在返回转场期间立即释放。
        private func stopObservingUndoManager() {
            guard let observedUndoManager else { return }
            let center = NotificationCenter.default
            center.removeObserver(
                self,
                name: .NSUndoManagerDidCloseUndoGroup,
                object: observedUndoManager
            )
            center.removeObserver(
                self,
                name: .NSUndoManagerDidUndoChange,
                object: observedUndoManager
            )
            center.removeObserver(
                self,
                name: .NSUndoManagerDidRedoChange,
                object: observedUndoManager
            )
            self.observedUndoManager = nil
        }

        /// UndoManager 事务完成后延迟刷新工具栏，不在通知回调栈内直接查询重做状态。
        @objc private func undoManagerStateDidChange(_ notification: Notification) {
            guard let sender = notification.object as? UndoManager,
                  sender === observedUndoManager,
                  let textView else { return }
            scheduleCommandStateRefresh(for: textView)
        }

        /// 命令直接使用 UITextView 当前 UndoManager；执行后再同步 raw 投影与校验属性。
        private func perform(
            _ command: AIPromptEditorCommandController.Command,
            in textView: AIPromptTokenTextView
        ) -> Bool {
            guard textView.markedTextRange == nil,
                  let undoManager = textView.undoManager,
                  undoManager.groupingLevel == 0,
                  !undoManager.isUndoing,
                  !undoManager.isRedoing else {
                updateCompositionState(from: textView)
                scheduleCommandStateRefresh(for: textView)
                return false
            }

            switch command {
            case .undo:
                guard undoManager.canUndo else { return false }
                undoManager.undo()
            case .redo:
                guard undoManager.canRedo else { return false }
                undoManager.redo()
            case .applyTemplateChange(let change):
                let selection = snapshot(from: textView).rawSelection
                let beforeText = rawText(for: change.before)
                let afterText = rawText(for: change.after)
                let before = TemplateSnapshot(
                    template: change.before,
                    rawSelection: AIPromptTextProjection.clamp(
                        selection,
                        upperBound: (beforeText as NSString).length
                    )
                )
                let after = TemplateSnapshot(
                    template: change.after,
                    rawSelection: AIPromptTextProjection.clamp(
                        selection,
                        upperBound: (afterText as NSString).length
                    )
                )
                applyTemplateSnapshot(
                    after,
                    inverse: before,
                    actionName: change.actionName,
                    apply: change.apply,
                    in: textView
                )
                return true
            }

            if textView.markedTextRange == nil {
                tokenizePlainVariables(in: textView)
            }
            synchronizeBindings(from: textView)
            applyDisplayAttributes(to: textView)
            scheduleCommandStateRefresh(for: textView)
            return true
        }

        /// 合并同一主循环中的高频输入事件；新任务取消旧任务，协调器或视图释放后不会回写状态。
        private func scheduleCommandStateRefresh(for textView: AIPromptTokenTextView) {
            commandStateRefreshTask?.cancel()
            commandStateRefreshTask = Task { @MainActor [weak self, weak textView] in
                await Task.yield()
                guard !Task.isCancelled, let self, let textView else { return }
                self.commandStateRefreshTask = nil
                self.refreshCommandState(from: textView)
            }
        }

        /// 只在 UndoManager 不处于分组、撤销或重做回调内时读取能力，防止系统状态查询重入。
        private func refreshCommandState(from textView: AIPromptTokenTextView) {
            let isComposing = textView.markedTextRange != nil
            guard !isComposing else {
                updateUnavailableCommandState(isComposing: true)
                return
            }
            guard let undoManager = textView.undoManager else {
                updateUnavailableCommandState(isComposing: false)
                return
            }
            guard undoManager.groupingLevel == 0,
                  !undoManager.isUndoing,
                  !undoManager.isRedoing else { return }

            connectedCommandController?.updateState(
                id: connectionID,
                canUndo: undoManager.canUndo,
                canRedo: undoManager.canRedo,
                isComposing: false
            )
        }

        /// 组合输入开始时立即禁用撤销/重做，防止拆分拼音标记文本。
        private func updateCompositionState(from textView: AIPromptTokenTextView) {
            let isComposing = textView.markedTextRange != nil
            if isComposing {
                updateUnavailableCommandState(isComposing: true)
            } else {
                connectedCommandController?.updateState(
                    id: connectionID,
                    canUndo: connectedCommandController?.canUndo ?? false,
                    canRedo: connectedCommandController?.canRedo ?? false,
                    isComposing: false
                )
            }
        }

        /// 向当前连接发布不可用态，避免组合输入或 UndoManager 缺席时工具栏保留过期命令。
        private func updateUnavailableCommandState(isComposing: Bool) {
            connectedCommandController?.updateState(
                id: connectionID,
                canUndo: false,
                canRedo: false,
                isComposing: isComposing
            )
        }

        /// 接收 SwiftUI 更新；配置切换清空跨字段撤销栈，普通校验更新只修改属性而不重建内容。
        func update(_ textView: AIPromptTokenTextView) {
            let configurationChanged = lastKind != parent.kind || lastField != parent.field
            let currentProjection = AIPromptTextProjection.read(from: textView.attributedText)
            if let pendingTemplateProjectionText,
               pendingTemplateProjectionText != parent.text {
                self.pendingTemplateProjectionText = nil
            }

            if configurationChanged {
                pendingTemplateProjectionText = nil
                replaceEditorContent(
                    with: parent.text,
                    rawSelection: parent.rawSelection,
                    clearsUndoHistory: true
                )
            } else if let pendingTemplateProjectionText,
                      pendingTemplateProjectionText == parent.text,
                      textView.markedTextRange == nil {
                self.pendingTemplateProjectionText = nil
                if currentProjection.rawText != pendingTemplateProjectionText {
                    replaceEditorContent(
                        with: parent.text,
                        rawSelection: parent.rawSelection,
                        clearsUndoHistory: false
                    )
                } else {
                    if lastIssues != parent.issues {
                        applyDisplayAttributes(to: textView)
                    }
                    applyExternalSelectionIfNeeded(to: textView)
                }
            } else if currentProjection.rawText != parent.text,
                      textView.markedTextRange == nil {
                let before = snapshot(from: textView)
                replaceEditorContent(
                    with: parent.text,
                    rawSelection: parent.rawSelection,
                    clearsUndoHistory: false
                )
                registerUndo(
                    to: before,
                    actionName: "修改提示词",
                    in: textView
                )
            } else if textView.markedTextRange == nil {
                if lastIssues != parent.issues {
                    applyDisplayAttributes(to: textView)
                }
                applyExternalSelectionIfNeeded(to: textView)
            }

            textView.accessibilityLabel = String(localized: parent.field.displayTitle)
            textView.accessibilityHint = parent.field == .taskTemplate
                ? "变量会作为一个整体编辑"
                : nil
            connectCommandController(to: textView)
            observeUndoManager(of: textView)
            updateContentInsets(of: textView)
            synchronizeFocus(of: textView)
            enqueueInsertionIfNeeded(in: textView)

            lastKind = parent.kind
            lastField = parent.field
            lastIssues = parent.issues
        }

        /// 只扩展滚动内容的底部可到达范围，不改变 UITextView 的框架，使正文能连续经过悬浮栏后方。
        func updateContentInsets(of textView: AIPromptTokenTextView) {
            let bottomInset = max(0, parent.contentBottomInset)
            guard abs(textView.contentInset.bottom - bottomInset) >= 0.5 else { return }

            textView.contentInset = UIEdgeInsets(
                top: 0,
                left: 0,
                bottom: bottomInset,
                right: 0
            )
            textView.verticalScrollIndicatorInsets = UIEdgeInsets(
                top: 0,
                left: 0,
                bottom: bottomInset,
                right: 0
            )
        }

        /// 使用原始字符串重建附件投影；该方法不跨线程，且调用方决定是否清除跨字段撤销历史。
        func replaceEditorContent(
            with rawText: String,
            rawSelection: NSRange,
            clearsUndoHistory: Bool
        ) {
            guard let textView else { return }
            let projection = AIPromptTextProjection.build(
                rawText: rawText,
                kind: parent.kind,
                field: parent.field,
                issues: parent.issues,
                traits: textView.traitCollection
            )
            isApplyingProjection = true
            textView.textStorage.setAttributedString(projection.attributedText)
            let clampedRawSelection = AIPromptTextProjection.clamp(
                rawSelection,
                upperBound: (rawText as NSString).length
            )
            textView.selectedRange = projection.displayRange(forRawRange: clampedRawSelection)
            textView.typingAttributes = AIPromptEditorAppearance.editorBaseAttributes(
                compatibleWith: textView.traitCollection
            )
            isApplyingProjection = false

            if parent.text != rawText { parent.text = rawText }
            if parent.rawSelection != clampedRawSelection {
                parent.rawSelection = clampedRawSelection
            }
            updateAccessibilityValue(of: textView)
            textView.scrollRangeToVisible(textView.selectedRange)
            if clearsUndoHistory {
                textView.undoManager?.removeAllActions()
            }
            scheduleCommandStateRefresh(for: textView)
        }

        // MARK: UITextViewDelegate

        /// 手工输入刚好补全已知变量时拦截默认变更，使用同一份 raw 快照一次完成令牌化与撤销登记。
        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText replacement: String
        ) -> Bool {
            guard !isApplyingProjection,
                  let tokenTextView = textView as? AIPromptTokenTextView,
                  parent.field == .taskTemplate,
                  tokenTextView.markedTextRange == nil,
                  !replacement.isEmpty,
                  tokenTextView.undoManager?.isUndoing != true,
                  tokenTextView.undoManager?.isRedoing != true else {
                return true
            }

            let projection = AIPromptTextProjection.read(from: tokenTextView.attributedText)
            let rawRange = AIPromptTextProjection.clamp(
                projection.rawRange(forDisplayRange: range),
                upperBound: (projection.rawText as NSString).length
            )
            let updatedRawText = (projection.rawText as NSString).replacingCharacters(
                in: rawRange,
                with: replacement
            )
            let insertedRange = NSRange(
                location: rawRange.location,
                length: (replacement as NSString).length
            )
            guard completesKnownVariable(
                in: updatedRawText,
                overlapping: insertedRange
            ) else {
                return true
            }

            replaceRawRange(
                rawRange,
                in: tokenTextView,
                with: replacement,
                actionName: "输入变量"
            )
            return false
        }

        /// 输入变化时同步纯文本；组合输入结束后才折叠新占位符，避免破坏拼音 marked text。
        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingProjection,
                  let tokenTextView = textView as? AIPromptTokenTextView else { return }

            updateCompositionState(from: tokenTextView)
            if tokenTextView.markedTextRange == nil {
                tokenizePlainVariables(in: tokenTextView)
            }
            synchronizeBindings(from: tokenTextView)
            applyDisplayAttributes(to: tokenTextView)
            scheduleCommandStateRefresh(for: tokenTextView)
        }

        /// 选区变化时把附件坐标映射回原始 UTF-16 坐标，并清除附件属性传染。
        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isApplyingProjection,
                  let tokenTextView = textView as? AIPromptTokenTextView else { return }
            updateCompositionState(from: tokenTextView)
            synchronizeSelection(from: tokenTextView)
            tokenTextView.typingAttributes = AIPromptEditorAppearance.editorBaseAttributes(
                compatibleWith: tokenTextView.traitCollection
            )
            scheduleCommandStateRefresh(for: tokenTextView)
        }

        /// 焦点进入时同步普通 Binding，供键盘变量栏决定可见性。
        func textViewDidBeginEditing(_ textView: UITextView) {
            if let tokenTextView = textView as? AIPromptTokenTextView {
                observeUndoManager(of: tokenTextView)
                updateCompositionState(from: tokenTextView)
                scheduleCommandStateRefresh(for: tokenTextView)
            }
            if !parent.isFocused { parent.isFocused = true }
        }

        /// 焦点离开时提交最后一次纯文本同步，并关闭变量栏。
        func textViewDidEndEditing(_ textView: UITextView) {
            if let tokenTextView = textView as? AIPromptTokenTextView {
                synchronizeBindings(from: tokenTextView)
                updateCompositionState(from: tokenTextView)
                scheduleCommandStateRefresh(for: tokenTextView)
            }
            if parent.isFocused { parent.isFocused = false }
        }

        // MARK: Projection updates

        /// 只有新插入区与完整已知占位符重叠时才认定为“本次输入补全变量”，不会误处理文本其他位置的令牌。
        private func completesKnownVariable(
            in rawText: String,
            overlapping insertedRange: NSRange
        ) -> Bool {
            guard insertedRange.length > 0 else { return false }
            let rawNSString = rawText as NSString

            for variable in AIPromptVariableCatalog.definitions(for: parent.kind) {
                var searchRange = NSRange(location: 0, length: rawNSString.length)
                while searchRange.length > 0 {
                    let match = rawNSString.range(
                        of: variable.placeholder,
                        options: [],
                        range: searchRange
                    )
                    guard match.location != NSNotFound else { break }
                    if NSIntersectionRange(match, insertedRange).length > 0 {
                        return true
                    }
                    let nextLocation = NSMaxRange(match)
                    searchRange = NSRange(
                        location: nextLocation,
                        length: rawNSString.length - nextLocation
                    )
                }
            }
            return false
        }

        private func applyDisplayAttributes(to textView: AIPromptTokenTextView) {
            guard textView.markedTextRange == nil else { return }
            let projection = AIPromptTextProjection.read(from: textView.attributedText)
            let selectedRange = textView.selectedRange
            let baseAttributes = AIPromptEditorAppearance.editorBaseAttributes(
                compatibleWith: textView.traitCollection
            )

            isApplyingProjection = true
            textView.textStorage.beginEditing()
            if textView.textStorage.length > 0 {
                let fullRange = NSRange(location: 0, length: textView.textStorage.length)
                textView.textStorage.addAttributes(baseAttributes, range: fullRange)
                textView.textStorage.removeAttribute(.underlineStyle, range: fullRange)
                textView.textStorage.removeAttribute(.underlineColor, range: fullRange)
            }
            AIPromptTextProjection.applyIssueAttributes(
                parent.issues,
                rawText: projection.rawText,
                projection: projection,
                to: textView.textStorage
            )
            textView.textStorage.endEditing()
            textView.selectedRange = AIPromptTextProjection.clamp(
                selectedRange,
                upperBound: textView.textStorage.length
            )
            textView.typingAttributes = baseAttributes
            isApplyingProjection = false
            updateAccessibilityValue(of: textView)
        }

        private func tokenizePlainVariables(in textView: AIPromptTokenTextView) {
            guard parent.field == .taskTemplate else { return }
            let displayString = textView.attributedText.string as NSString
            let definitions = AIPromptVariableCatalog.definitions(for: parent.kind)
            var matches: [(range: NSRange, variable: AIPromptVariableDefinition)] = []

            for variable in definitions {
                var searchRange = NSRange(location: 0, length: displayString.length)
                while searchRange.length > 0 {
                    let range = displayString.range(
                        of: variable.placeholder,
                        options: [],
                        range: searchRange
                    )
                    guard range.location != NSNotFound else { break }
                    matches.append((range, variable))
                    let nextLocation = NSMaxRange(range)
                    searchRange = NSRange(
                        location: nextLocation,
                        length: displayString.length - nextLocation
                    )
                }
            }
            guard !matches.isEmpty else { return }

            let rawSelection = AIPromptTextProjection
                .read(from: textView.attributedText)
                .rawRange(forDisplayRange: textView.selectedRange)

            isApplyingProjection = true
            textView.textStorage.beginEditing()
            for match in matches.sorted(by: { $0.range.location > $1.range.location }) {
                textView.textStorage.replaceCharacters(
                    in: match.range,
                    with: AIPromptTextProjection.tokenAttributedString(
                        for: match.variable,
                        traits: textView.traitCollection
                    )
                )
            }
            textView.textStorage.endEditing()
            let projection = AIPromptTextProjection.read(from: textView.attributedText)
            textView.selectedRange = projection.displayRange(forRawRange: rawSelection)
            isApplyingProjection = false
        }

        private func replaceCurrentSelection(
            in textView: AIPromptTokenTextView,
            with replacement: String,
            actionName: String
        ) {
            guard textView.markedTextRange == nil else { return }
            let projection = AIPromptTextProjection.read(from: textView.attributedText)
            let rawRange = projection.rawRange(forDisplayRange: textView.selectedRange)
            replaceRawRange(
                rawRange,
                in: textView,
                with: replacement,
                actionName: actionName
            )
        }

        private func replaceRawRange(
            _ rawRange: NSRange,
            in textView: AIPromptTokenTextView,
            with replacement: String,
            actionName: String
        ) {
            let before = snapshot(from: textView)
            let currentRaw = before.rawText as NSString
            let clampedRange = AIPromptTextProjection.clamp(
                rawRange,
                upperBound: currentRaw.length
            )
            let updatedRaw = currentRaw.replacingCharacters(in: clampedRange, with: replacement)
            let updatedSelection = NSRange(
                location: clampedRange.location + (replacement as NSString).length,
                length: 0
            )
            replaceEditorContent(
                with: updatedRaw,
                rawSelection: updatedSelection,
                clearsUndoHistory: false
            )
            registerUndo(to: before, actionName: actionName, in: textView)
        }

        private func synchronizeBindings(from textView: AIPromptTokenTextView) {
            let projection = AIPromptTextProjection.read(from: textView.attributedText)
            if parent.text != projection.rawText {
                parent.text = projection.rawText
            }
            synchronizeSelection(from: textView, projection: projection)
            updateAccessibilityValue(of: textView, projection: projection)
        }

        private func synchronizeSelection(
            from textView: AIPromptTokenTextView,
            projection: AIPromptTextProjection? = nil
        ) {
            let resolvedProjection = projection
                ?? AIPromptTextProjection.read(from: textView.attributedText)
            let rawRange = resolvedProjection.rawRange(forDisplayRange: textView.selectedRange)
            if parent.rawSelection != rawRange {
                parent.rawSelection = rawRange
            }
        }

        private func applyExternalSelectionIfNeeded(to textView: AIPromptTokenTextView) {
            let projection = AIPromptTextProjection.read(from: textView.attributedText)
            let currentRawRange = projection.rawRange(forDisplayRange: textView.selectedRange)
            let requestedRange = AIPromptTextProjection.clamp(
                parent.rawSelection,
                upperBound: (projection.rawText as NSString).length
            )
            guard currentRawRange != requestedRange else { return }

            isApplyingProjection = true
            textView.selectedRange = projection.displayRange(forRawRange: requestedRange)
            isApplyingProjection = false
            textView.scrollRangeToVisible(textView.selectedRange)
        }

        private func synchronizeFocus(of textView: AIPromptTokenTextView) {
            if parent.isFocused, !textView.isFirstResponder {
                textView.becomeFirstResponder()
            } else if !parent.isFocused, textView.isFirstResponder {
                textView.resignFirstResponder()
            }
        }

        /// 延迟到当前 SwiftUI 更新周期之后消费请求；任务固定在 MainActor，弱持有编辑器，
        /// 无需长期取消，协调器释放或 request ID 变化时会直接丢弃过期工作以避免竞态。
        private func enqueueInsertionIfNeeded(in textView: AIPromptTokenTextView) {
            guard let request = parent.insertionRequest,
                  request.id != handledInsertionID,
                  textView.markedTextRange == nil else { return }
            handledInsertionID = request.id

            insertionTask?.cancel()
            insertionTask = Task { @MainActor [weak self, weak textView] in
                await Task.yield()
                guard !Task.isCancelled,
                      let self, let textView,
                      self.parent.insertionRequest?.id == request.id else { return }
                let projection = AIPromptTextProjection.read(from: textView.attributedText)
                let selection = projection.rawRange(forDisplayRange: textView.selectedRange)
                self.replaceRawRange(
                    selection,
                    in: textView,
                    with: request.variable.placeholder,
                    actionName: "插入变量"
                )
                self.parent.insertionRequest = nil
                if !textView.isFirstResponder {
                    textView.becomeFirstResponder()
                }
                self.insertionTask = nil
            }
        }

        private func rawText(in displayRange: NSRange, from textView: AIPromptTokenTextView) -> String {
            let projection = AIPromptTextProjection.read(from: textView.attributedText)
            let rawRange = projection.rawRange(forDisplayRange: displayRange)
            return (projection.rawText as NSString).substring(with: rawRange)
        }

        private func refreshForCurrentTraits(_ textView: AIPromptTokenTextView) {
            guard textView.markedTextRange == nil else { return }
            let snapshot = snapshot(from: textView)
            replaceEditorContent(
                with: snapshot.rawText,
                rawSelection: snapshot.rawSelection,
                clearsUndoHistory: false
            )
        }

        private func updateAccessibilityValue(
            of textView: AIPromptTokenTextView,
            projection: AIPromptTextProjection? = nil
        ) {
            let resolvedProjection = projection
                ?? AIPromptTextProjection.read(from: textView.attributedText)
            textView.accessibilityValue = resolvedProjection.accessibilityText
        }

        private struct EditorSnapshot {
            let rawText: String
            let rawSelection: NSRange
        }

        /// 整模板事务同时保留当前字段的原始选区，另一字段则由值语义一并恢复。
        private struct TemplateSnapshot {
            let template: AIPromptTemplate
            let rawSelection: NSRange
        }

        private func snapshot(from textView: AIPromptTokenTextView) -> EditorSnapshot {
            let projection = AIPromptTextProjection.read(from: textView.attributedText)
            return EditorSnapshot(
                rawText: projection.rawText,
                rawSelection: projection.rawRange(forDisplayRange: textView.selectedRange)
            )
        }

        /// 读取一份模板在当前编辑字段中的投影；字段切换会重建协调器并清空本历史。
        private func rawText(for template: AIPromptTemplate) -> String {
            switch parent.field {
            case .taskTemplate:
                template.user
            case .roleRules:
                template.system
            }
        }

        /// 将整模板快照应用到 ViewModel 与当前 TextKit 投影，并在同一 UndoManager 中对称登记逆操作。
        private func applyTemplateSnapshot(
            _ snapshot: TemplateSnapshot,
            inverse: TemplateSnapshot,
            actionName: String,
            apply: @escaping @MainActor (AIPromptTemplate) -> Void,
            in textView: AIPromptTokenTextView
        ) {
            let targetText = rawText(for: snapshot.template)
            pendingTemplateProjectionText = targetText
            apply(snapshot.template)
            replaceEditorContent(
                with: targetText,
                rawSelection: snapshot.rawSelection,
                clearsUndoHistory: false
            )

            textView.undoManager?.registerUndo(withTarget: self) { coordinator in
                guard let currentTextView = coordinator.textView else { return }
                coordinator.applyTemplateSnapshot(
                    inverse,
                    inverse: snapshot,
                    actionName: actionName,
                    apply: apply,
                    in: currentTextView
                )
            }
            textView.undoManager?.setActionName(actionName)
            scheduleCommandStateRefresh(for: textView)
        }

        private func registerUndo(
            to snapshot: EditorSnapshot,
            actionName: String,
            in textView: AIPromptTokenTextView
        ) {
            textView.undoManager?.registerUndo(withTarget: self) { target in
                guard let currentTextView = target.textView else { return }
                let inverse = target.snapshot(from: currentTextView)
                target.replaceEditorContent(
                    with: snapshot.rawText,
                    rawSelection: snapshot.rawSelection,
                    clearsUndoHistory: false
                )
                target.registerUndo(
                    to: inverse,
                    actionName: actionName,
                    in: currentTextView
                )
            }
            textView.undoManager?.setActionName(actionName)
            scheduleCommandStateRefresh(for: textView)
        }
    }
}

/// 只读提示词的差异语义；删除态只作用于普通文字，变量附件继续保持编辑器同源 Chip 外观。
enum AIPromptReadOnlyTokenTextStyle {
    case removed
    case added

    var accessibilityPrefix: String {
        switch self {
        case .removed:
            "删除"
        case .added:
            "新增"
        }
    }
}

/// 提示词差异的只读 TextKit 2 渲染桥接，复用编辑器变量投影与附件视图，并使用差异专属阅读排版。
struct AIPromptReadOnlyTokenTextView: UIViewRepresentable {
    let text: String
    let kind: AIPromptKind
    let field: AIPromptEditorField
    let style: AIPromptReadOnlyTokenTextStyle

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    /// 创建不可编辑但允许选择复制的 TextKit 2 视图，并移除系统 TextView 默认内边距。
    func makeUIView(context: Context) -> UITextView {
        AIPromptTokenAttachment.registerViewProviderIfNeeded()
        let textView = UITextView(frame: .zero, textContainer: nil)
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.contentInsetAdjustmentBehavior = .never
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = false
        textView.dataDetectorTypes = []
        textView.setContentHuggingPriority(.required, for: .vertical)
        renderContent(in: textView)
        return textView
    }

    /// 随差异文本、字段和外观环境重新建立投影，确保浅深色、高对比度与 Dynamic Type 同步更新。
    func updateUIView(_ textView: UITextView, context: Context) {
        _ = dynamicTypeSize
        _ = colorScheme
        _ = colorSchemeContrast
        renderContent(in: textView)
    }

    /// 使用 SwiftUI 提议宽度计算 TextKit 完整高度，使长差异留在 Sheet 的唯一滚动容器中。
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UITextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let fittingSize = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        return CGSize(width: width, height: ceil(fittingSize.height))
    }

    /// 复用编辑器投影识别完整已知变量，并仅为删除态的普通文字添加删除线和次级前景色。
    private func renderContent(in textView: UITextView) {
        let projection = AIPromptTextProjection.build(
            rawText: text,
            kind: kind,
            field: field,
            issues: [],
            traits: textView.traitCollection
        )
        let attributedText = NSMutableAttributedString(
            attributedString: projection.attributedText
        )
        applyDiffTextAttributes(
            to: attributedText,
            compatibleWith: textView.traitCollection
        )

        if style == .removed {
            applyRemovedTextAttributes(to: attributedText)
        }

        textView.attributedText = attributedText
        textView.accessibilityLabel = "\(style.accessibilityPrefix)，\(projection.accessibilityText)"
        textView.invalidateIntrinsicContentSize()
    }

    /// 在变量投影完成后统一应用差异正文排版，使普通文字与附件共享同一段落节奏和基线环境。
    private func applyDiffTextAttributes(
        to attributedText: NSMutableAttributedString,
        compatibleWith traits: UITraitCollection?
    ) {
        guard attributedText.length > 0 else { return }
        attributedText.addAttributes(
            AIPromptEditorAppearance.diffBaseAttributes(compatibleWith: traits),
            range: NSRange(location: 0, length: attributedText.length)
        )
    }

    /// 跳过附件字符逐段设置删除样式，避免破坏变量 Chip 的同源颜色、图标与排版。
    private func applyRemovedTextAttributes(
        to attributedText: NSMutableAttributedString
    ) {
        var location = 0
        while location < attributedText.length {
            var effectiveRange = NSRange(location: 0, length: 0)
            let attachment = attributedText.attribute(
                .attachment,
                at: location,
                effectiveRange: &effectiveRange
            ) as? NSTextAttachment
            if attachment == nil {
                attributedText.addAttributes(
                    [
                        .foregroundColor: UIColor.xmResolved(Color.textSecondary),
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    ],
                    range: effectiveRange
                )
            }
            location = NSMaxRange(effectiveRange)
        }
    }
}

/// UITextView 窄子类只接管用户主动的复制、剪切、粘贴和 Dynamic Type 变化。
@MainActor
final class AIPromptTokenTextView: UITextView {
    var onTraitsChanged: (() -> Void)?
    var onCopyRawText: ((NSRange) -> String?)?
    var onReplaceSelectionWithRawText: ((String, String) -> Void)?

    private var displayTraitRegistration: (any UITraitChangeRegistration)?

    /// 创建明确使用系统默认 TextKit 2 管线的编辑器，并监听字号与对比度 trait。
    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        precondition(textLayoutManager != nil, "AIPromptTokenTextView requires TextKit 2")
        displayTraitRegistration = registerForTraitChanges(
            [UITraitPreferredContentSizeCategory.self, UITraitAccessibilityContrast.self]
        ) { (textView: AIPromptTokenTextView, _) in
            textView.onTraitsChanged?()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init(frame:textContainer:) instead")
    }

    /// 复制时输出兼容旧配置与外部编辑器的 `${变量名}` 原始文本。
    override func copy(_ sender: Any?) {
        guard selectedRange.length > 0,
              let rawText = onCopyRawText?(selectedRange) else {
            super.copy(sender)
            return
        }
        UIPasteboard.general.string = rawText
    }

    /// 剪切时以原始文本写入剪贴板，并把跨令牌选区作为一次原子替换处理。
    override func cut(_ sender: Any?) {
        guard isEditable, selectedRange.length > 0 else {
            super.cut(sender)
            return
        }
        copy(sender)
        onReplaceSelectionWithRawText?("", "剪切")
    }

    /// 粘贴只接收纯文本；其中已识别的占位符随后自动折叠为原子令牌。
    override func paste(_ sender: Any?) {
        guard isEditable, let rawText = UIPasteboard.general.string else {
            super.paste(sender)
            return
        }
        onReplaceSelectionWithRawText?(rawText, "粘贴")
    }
}

private extension NSAttributedString.Key {
    static let aiPromptVariablePlaceholder = NSAttributedString.Key(
        "com.xmnote.aiPrompt.variable.placeholder"
    )
    static let aiPromptVariableName = NSAttributedString.Key(
        "com.xmnote.aiPrompt.variable.name"
    )
}

/// raw `${变量名}` 与单字符附件显示之间的双向 UTF-16 投影。
@MainActor
private struct AIPromptTextProjection {
    private enum SegmentKind {
        case text
        case token
    }

    private struct Segment {
        let rawRange: NSRange
        let displayRange: NSRange
        let kind: SegmentKind
    }

    let rawText: String
    let attributedText: NSAttributedString
    let accessibilityText: String
    private let segments: [Segment]

    /// 从纯文本创建 TextKit 显示投影；只有 User Prompt 中的已知变量会生成附件。
    static func build(
        rawText: String,
        kind: AIPromptKind,
        field: AIPromptEditorField,
        issues: [AIPromptValidationIssue],
        traits: UITraitCollection
    ) -> AIPromptTextProjection {
        let result = NSMutableAttributedString()
        let rawNSString = rawText as NSString
        let baseAttributes = AIPromptEditorAppearance.editorBaseAttributes(
            compatibleWith: traits
        )
        var segments: [Segment] = []
        var accessibilityParts: [String] = []
        var rawCursor = 0
        var displayCursor = 0

        let variablesByPlaceholder = Dictionary(
            uniqueKeysWithValues: AIPromptVariableCatalog
                .definitions(for: kind)
                .map { ($0.placeholder, $0) }
        )
        let matches = field == .taskTemplate
            ? recognizedMatches(in: rawText, variablesByPlaceholder: variablesByPlaceholder)
            : []

        for match in matches {
            if match.range.location > rawCursor {
                appendText(
                    rawNSString.substring(
                        with: NSRange(
                            location: rawCursor,
                            length: match.range.location - rawCursor
                        )
                    ),
                    rawLocation: rawCursor,
                    displayLocation: displayCursor,
                    attributes: baseAttributes,
                    result: result,
                    segments: &segments,
                    accessibilityParts: &accessibilityParts
                )
                displayCursor = result.length
            }

            result.append(tokenAttributedString(for: match.variable, traits: traits))
            segments.append(
                Segment(
                    rawRange: match.range,
                    displayRange: NSRange(location: displayCursor, length: 1),
                    kind: .token
                )
            )
            accessibilityParts.append("变量：\(match.variable.name)")
            rawCursor = NSMaxRange(match.range)
            displayCursor += 1
        }

        if rawCursor < rawNSString.length {
            appendText(
                rawNSString.substring(from: rawCursor),
                rawLocation: rawCursor,
                displayLocation: displayCursor,
                attributes: baseAttributes,
                result: result,
                segments: &segments,
                accessibilityParts: &accessibilityParts
            )
        }

        var projection = AIPromptTextProjection(
            rawText: rawText,
            attributedText: result,
            accessibilityText: accessibilityParts.joined(),
            segments: segments
        )
        applyIssueAttributes(
            issues,
            rawText: rawText,
            projection: projection,
            to: result
        )
        projection = AIPromptTextProjection(
            rawText: rawText,
            attributedText: result,
            accessibilityText: accessibilityParts.joined(),
            segments: segments
        )
        return projection
    }

    /// 从正在编辑的属性串还原纯文本与映射，不依赖视图外部缓存。
    static func read(from attributedText: NSAttributedString) -> AIPromptTextProjection {
        var rawText = ""
        var accessibilityText = ""
        var segments: [Segment] = []
        var rawCursor = 0
        let displayNSString = attributedText.string as NSString

        var displayCursor = 0
        var textStart = 0
        while displayCursor < attributedText.length {
            let attachment = attributedText.attribute(
                .attachment,
                at: displayCursor,
                effectiveRange: nil
            ) as? NSTextAttachment
            let placeholder = attributedText.attribute(
                .aiPromptVariablePlaceholder,
                at: displayCursor,
                effectiveRange: nil
            ) as? String
            let isAttachmentCharacter = displayNSString.character(at: displayCursor) == 0xFFFC

            guard isAttachmentCharacter, attachment != nil, let placeholder else {
                displayCursor += 1
                continue
            }

            if textStart < displayCursor {
                let displayRange = NSRange(
                    location: textStart,
                    length: displayCursor - textStart
                )
                let text = attributedText.attributedSubstring(from: displayRange).string
                rawText.append(text)
                accessibilityText.append(text)
                let rawLength = (text as NSString).length
                segments.append(
                    Segment(
                        rawRange: NSRange(location: rawCursor, length: rawLength),
                        displayRange: displayRange,
                        kind: .text
                    )
                )
                rawCursor += rawLength
            }

            let name = attributedText.attribute(
                .aiPromptVariableName,
                at: displayCursor,
                effectiveRange: nil
            ) as? String ?? placeholder
            rawText.append(placeholder)
            accessibilityText.append("变量：\(name)")
            let rawLength = (placeholder as NSString).length
            segments.append(
                Segment(
                    rawRange: NSRange(location: rawCursor, length: rawLength),
                    displayRange: NSRange(location: displayCursor, length: 1),
                    kind: .token
                )
            )
            rawCursor += rawLength
            displayCursor += 1
            textStart = displayCursor
        }

        if textStart < attributedText.length {
            let displayRange = NSRange(
                location: textStart,
                length: attributedText.length - textStart
            )
            let text = attributedText.attributedSubstring(from: displayRange).string
            rawText.append(text)
            accessibilityText.append(text)
            let rawLength = (text as NSString).length
            segments.append(
                Segment(
                    rawRange: NSRange(location: rawCursor, length: rawLength),
                    displayRange: displayRange,
                    kind: .text
                )
            )
        }

        return AIPromptTextProjection(
            rawText: rawText,
            attributedText: attributedText,
            accessibilityText: accessibilityText,
            segments: segments
        )
    }

    /// 创建一个单字符视图附件；图标、文字和背景由统一 Appearance 与 ViewProvider 渲染。
    static func tokenAttributedString(
        for variable: AIPromptVariableDefinition,
        traits: UITraitCollection
    ) -> NSAttributedString {
        let attachment = AIPromptTokenAttachment(variable: variable, traits: traits)
        attachment.accessibilityLabel = "变量：\(variable.name)"

        let attributed = NSMutableAttributedString(
            attributedString: NSAttributedString(attachment: attachment)
        )
        attributed.addAttributes(
            [
                .aiPromptVariablePlaceholder: variable.placeholder,
                .aiPromptVariableName: variable.name,
            ],
            range: NSRange(location: 0, length: attributed.length)
        )
        return attributed
    }

    func displayRange(forRawRange rawRange: NSRange) -> NSRange {
        let clamped = Self.clamp(rawRange, upperBound: (rawText as NSString).length)
        let lower = displayOffset(forRawOffset: clamped.location, edge: .leading)
        let upper = displayOffset(forRawOffset: NSMaxRange(clamped), edge: .trailing)
        return NSRange(location: lower, length: max(0, upper - lower))
    }

    func rawRange(forDisplayRange displayRange: NSRange) -> NSRange {
        let clamped = Self.clamp(displayRange, upperBound: attributedText.length)
        let lower = rawOffset(forDisplayOffset: clamped.location, edge: .leading)
        let upper = rawOffset(forDisplayOffset: NSMaxRange(clamped), edge: .trailing)
        return NSRange(location: lower, length: max(0, upper - lower))
    }

    static func rawNSRange(
        for range: AIPromptTextRange,
        in rawText: String
    ) -> NSRange? {
        guard range.location >= 0, range.length >= 0 else { return nil }
        let characters = rawText.indices
        guard let lower = characters.index(
            characters.startIndex,
            offsetBy: range.location,
            limitedBy: characters.endIndex
        ), let upper = characters.index(
            lower,
            offsetBy: range.length,
            limitedBy: characters.endIndex
        ) else { return nil }
        return NSRange(lower..<upper, in: rawText)
    }

    static func clamp(_ range: NSRange, upperBound: Int) -> NSRange {
        let location = min(max(0, range.location), upperBound)
        let maximumLength = upperBound - location
        return NSRange(location: location, length: min(max(0, range.length), maximumLength))
    }

    static func applyIssueAttributes(
        _ issues: [AIPromptValidationIssue],
        rawText: String,
        projection: AIPromptTextProjection,
        to attributedText: NSMutableAttributedString
    ) {
        for issue in issues {
            guard let characterRange = issue.range,
                  let rawRange = rawNSRange(for: characterRange, in: rawText) else {
                continue
            }
            let displayRange = projection.displayRange(forRawRange: rawRange)
            guard displayRange.length > 0,
                  NSMaxRange(displayRange) <= attributedText.length else { continue }
            attributedText.addAttributes(
                [
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .underlineColor: issueColor(for: issue.severity),
                ],
                range: displayRange
            )
        }
    }

    private enum MappingEdge {
        case leading
        case trailing
    }

    private func displayOffset(forRawOffset offset: Int, edge: MappingEdge) -> Int {
        for segment in segments where offset <= NSMaxRange(segment.rawRange) {
            guard offset >= segment.rawRange.location else {
                return segment.displayRange.location
            }
            switch segment.kind {
            case .text:
                return segment.displayRange.location + offset - segment.rawRange.location
            case .token:
                if offset <= segment.rawRange.location { return segment.displayRange.location }
                if offset >= NSMaxRange(segment.rawRange) { return NSMaxRange(segment.displayRange) }
                return edge == .leading
                    ? segment.displayRange.location
                    : NSMaxRange(segment.displayRange)
            }
        }
        return attributedText.length
    }

    private func rawOffset(forDisplayOffset offset: Int, edge: MappingEdge) -> Int {
        for segment in segments where offset <= NSMaxRange(segment.displayRange) {
            guard offset >= segment.displayRange.location else {
                return segment.rawRange.location
            }
            switch segment.kind {
            case .text:
                return segment.rawRange.location + offset - segment.displayRange.location
            case .token:
                if offset <= segment.displayRange.location { return segment.rawRange.location }
                if offset >= NSMaxRange(segment.displayRange) { return NSMaxRange(segment.rawRange) }
                return edge == .leading
                    ? segment.rawRange.location
                    : NSMaxRange(segment.rawRange)
            }
        }
        return (rawText as NSString).length
    }

    private static func appendText(
        _ text: String,
        rawLocation: Int,
        displayLocation: Int,
        attributes: [NSAttributedString.Key: Any],
        result: NSMutableAttributedString,
        segments: inout [Segment],
        accessibilityParts: inout [String]
    ) {
        guard !text.isEmpty else { return }
        let length = (text as NSString).length
        result.append(NSAttributedString(string: text, attributes: attributes))
        segments.append(
            Segment(
                rawRange: NSRange(location: rawLocation, length: length),
                displayRange: NSRange(location: displayLocation, length: length),
                kind: .text
            )
        )
        accessibilityParts.append(text)
    }

    private static func recognizedMatches(
        in rawText: String,
        variablesByPlaceholder: [String: AIPromptVariableDefinition]
    ) -> [(range: NSRange, variable: AIPromptVariableDefinition)] {
        let rawNSString = rawText as NSString
        var matches: [(range: NSRange, variable: AIPromptVariableDefinition)] = []

        for (placeholder, variable) in variablesByPlaceholder {
            var searchRange = NSRange(location: 0, length: rawNSString.length)
            while searchRange.length > 0 {
                let range = rawNSString.range(of: placeholder, options: [], range: searchRange)
                guard range.location != NSNotFound else { break }
                matches.append((range, variable))
                let nextLocation = NSMaxRange(range)
                searchRange = NSRange(
                    location: nextLocation,
                    length: rawNSString.length - nextLocation
                )
            }
        }
        return matches.sorted { lhs, rhs in
            if lhs.range.location != rhs.range.location {
                return lhs.range.location < rhs.range.location
            }
            return lhs.range.length > rhs.range.length
        }
    }

    private static func issueColor(for severity: AIPromptValidationSeverity) -> UIColor {
        switch severity {
        case .error:
            UIColor.xmResolved(Color.feedbackError)
        case .warning, .information:
            UIColor.xmResolved(Color.feedbackWarning)
        }
    }
}

/// 单字符变量附件；TextKit 2 优先挂载真实 UIKit 令牌视图，并为未启用 ViewProvider 的绘制路径提供同源图像。
@MainActor
private final class AIPromptTokenAttachment: NSTextAttachment {
    private static let fileType = "com.xmnote.ai-prompt-variable"
    private static let viewProviderRegistration: Void = {
        NSTextAttachment.registerViewProviderClass(
            AIPromptTokenAttachmentViewProvider.self,
            forFileType: fileType
        )
    }()

    private enum CodingKey {
        static let name = "AIPromptTokenAttachment.name"
        static let requirement = "AIPromptTokenAttachment.requirement"
        static let category = "AIPromptTokenAttachment.category"
    }

    let variable: AIPromptVariableDefinition
    let seedTraits: UITraitCollection

    /// 在首个附件创建前注册文件类型到 ViewProvider 的进程级映射；静态初始化保证只执行一次。
    static func registerViewProviderIfNeeded() {
        _ = viewProviderRegistration
    }

    init(variable: AIPromptVariableDefinition, traits: UITraitCollection) {
        self.variable = variable
        self.seedTraits = traits
        super.init(
            data: Data(variable.placeholder.utf8),
            ofType: Self.fileType
        )
        allowsTextAttachmentView = true
        lineLayoutPadding = 1
        bounds = Self.fallbackBounds(for: variable, traits: traits)
    }

    required init?(coder: NSCoder) {
        guard let name = coder.decodeObject(
            of: NSString.self,
            forKey: CodingKey.name
        ) as String?,
        let requirementRawValue = coder.decodeObject(
            of: NSString.self,
            forKey: CodingKey.requirement
        ) as String?,
        let requirement = AIPromptVariableRequirement(rawValue: requirementRawValue),
        let categoryRawValue = coder.decodeObject(
            of: NSString.self,
            forKey: CodingKey.category
        ) as String?,
        let category = AIPromptVariableCategory(rawValue: categoryRawValue) else {
            return nil
        }
        variable = AIPromptVariableDefinition(
            name: name,
            requirement: requirement,
            category: category
        )
        seedTraits = UITraitCollection.current
        super.init(coder: coder)
        allowsTextAttachmentView = true
        lineLayoutPadding = 1
        bounds = Self.fallbackBounds(for: variable, traits: seedTraits)
    }

    override func encode(with coder: NSCoder) {
        super.encode(with: coder)
        coder.encode(variable.name, forKey: CodingKey.name)
        coder.encode(variable.requirement.rawValue, forKey: CodingKey.requirement)
        coder.encode(variable.category.rawValue, forKey: CodingKey.category)
    }

    /// 返回自定义内容图像，避免 ViewProvider 暂不可用时由未知 UTI 降级为系统文件图标。
    override func image(
        for imageBounds: CGRect,
        attributes: [NSAttributedString.Key: Any],
        location: any NSTextLocation,
        textContainer: NSTextContainer?
    ) -> UIImage? {
        AIPromptTokenAttachmentView.renderedImage(
            for: variable,
            traits: seedTraits
        )
    }

    /// 直接构造当前附件的 Provider，避免实际绘制依赖进程级文件类型查询的时机。
    override func viewProvider(
        for parentView: UIView?,
        location: any NSTextLocation,
        textContainer: NSTextContainer?
    ) -> NSTextAttachmentViewProvider? {
        AIPromptTokenAttachmentViewProvider(
            textAttachment: self,
            parentView: parentView,
            textLayoutManager: textContainer?.textLayoutManager,
            location: location
        )
    }

    private static func fallbackBounds(
        for variable: AIPromptVariableDefinition,
        traits: UITraitCollection
    ) -> CGRect {
        let size = AIPromptTokenAttachmentView.resolvedSize(
            for: variable,
            traits: traits
        )
        let bodyFont = AIPromptEditorAppearance.uiEditorBodyFont(compatibleWith: traits)
        return CGRect(
            x: 0,
            y: (bodyFont.capHeight - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}

/// TextKit 2 附件视图提供者；令牌尺寸来自实际 UIKit 内容并与正文基线对齐。
@MainActor
private final class AIPromptTokenAttachmentViewProvider: NSTextAttachmentViewProvider {
    /// TextKit 2 通过注册表构造 Provider；在 designated initializer 中启用视图尺寸跟踪，保证首轮布局即读取令牌尺寸。
    override init(
        textAttachment: NSTextAttachment,
        parentView: UIView?,
        textLayoutManager: NSTextLayoutManager?,
        location: any NSTextLocation
    ) {
        super.init(
            textAttachment: textAttachment,
            parentView: parentView,
            textLayoutManager: textLayoutManager,
            location: location
        )
        tracksTextAttachmentViewBounds = true
    }

    override func loadView() {
        guard let attachment = textAttachment as? AIPromptTokenAttachment else {
            view = UIView(frame: .zero)
            return
        }
        view = AIPromptTokenAttachmentView(
            variable: attachment.variable,
            seedTraits: attachment.seedTraits
        )
    }

    override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any],
        location: any NSTextLocation,
        textContainer: NSTextContainer?,
        proposedLineFragment: CGRect,
        position: CGPoint
    ) -> CGRect {
        guard let tokenView = view as? AIPromptTokenAttachmentView else {
            return textAttachment?.bounds ?? .zero
        }
        let size = tokenView.intrinsicContentSize
        let bodyFont = attributes[.font] as? UIFont
            ?? AIPromptEditorAppearance.uiEditorBodyFont(
                compatibleWith: tokenView.traitCollection
            )
        return CGRect(
            x: 0,
            y: (bodyFont.capHeight - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}

/// 令牌附件的真实 UIKit 内容；颜色、Reicon 与排版均复用 SwiftUI Chip 的 Appearance。
@MainActor
private final class AIPromptTokenAttachmentView: UIView {
    private struct ResolvedMetrics {
        let size: CGSize
        let font: UIFont
        let iconSize: CGFloat
        let hasIcon: Bool
    }

    private let variable: AIPromptVariableDefinition
    private let seedTraits: UITraitCollection
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private var displayTraitRegistration: (any UITraitChangeRegistration)?

    init(variable: AIPromptVariableDefinition, seedTraits: UITraitCollection) {
        self.variable = variable
        self.seedTraits = seedTraits
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        accessibilityLabel = "变量：\(variable.name)"

        iconView.contentMode = .scaleAspectFit
        iconView.isAccessibilityElement = false
        addSubview(iconView)

        titleLabel.numberOfLines = 1
        titleLabel.adjustsFontForContentSizeCategory = false
        titleLabel.isAccessibilityElement = false
        addSubview(titleLabel)

        refreshAppearance()
        displayTraitRegistration = registerForTraitChanges(
            [UITraitPreferredContentSizeCategory.self, UITraitAccessibilityContrast.self]
        ) { (tokenView: AIPromptTokenAttachmentView, _) in
            tokenView.refreshAppearance()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init(variable:seedTraits:) instead")
    }

    override var intrinsicContentSize: CGSize {
        Self.resolvedMetrics(for: variable, traits: effectiveTraits).size
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        intrinsicContentSize
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let metrics = Self.resolvedMetrics(for: variable, traits: effectiveTraits)
        layer.cornerRadius = bounds.height / 2
        var cursorX = AIPromptEditorAppearance.Metrics.tokenHorizontalPadding

        if metrics.hasIcon {
            iconView.frame = CGRect(
                x: cursorX,
                y: (bounds.height - metrics.iconSize) / 2,
                width: metrics.iconSize,
                height: metrics.iconSize
            )
            cursorX += metrics.iconSize
                + AIPromptEditorAppearance.Metrics.tokenIconSpacing
        } else {
            iconView.frame = .zero
        }
        titleLabel.frame = CGRect(
            x: cursorX,
            y: 0,
            width: max(
                0,
                bounds.width
                    - cursorX
                    - AIPromptEditorAppearance.Metrics.tokenHorizontalPadding
            ),
            height: bounds.height
        )
    }

    static func resolvedSize(
        for variable: AIPromptVariableDefinition,
        traits: UITraitCollection
    ) -> CGSize {
        resolvedMetrics(for: variable, traits: traits).size
    }

    /// 为 TextKit 未采用 ViewProvider 的绘制分支生成与真实令牌视图一致的非透明内容回退。
    static func renderedImage(
        for variable: AIPromptVariableDefinition,
        traits: UITraitCollection
    ) -> UIImage {
        let presentation = AIPromptEditorAppearance.presentation(for: variable)
        let metrics = resolvedMetrics(for: variable, traits: traits)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        if traits.displayScale > 0 {
            format.scale = traits.displayScale
        }

        return UIGraphicsImageRenderer(
            size: metrics.size,
            format: format
        ).image { _ in
            let bounds = CGRect(origin: .zero, size: metrics.size)
            let backgroundColor = presentation.uiBackgroundColor.resolvedColor(with: traits)
            let foregroundColor = presentation.uiForegroundColor.resolvedColor(with: traits)
            backgroundColor.setFill()
            UIBezierPath(
                roundedRect: bounds,
                cornerRadius: metrics.size.height / 2
            ).fill()

            var cursorX = AIPromptEditorAppearance.Metrics.tokenHorizontalPadding
            if metrics.hasIcon,
               let icon = UIImage(named: presentation.iconAssetName) {
                let iconRect = CGRect(
                    x: cursorX,
                    y: (metrics.size.height - metrics.iconSize) / 2,
                    width: metrics.iconSize,
                    height: metrics.iconSize
                )
                icon.withTintColor(
                    foregroundColor,
                    renderingMode: .alwaysOriginal
                ).draw(in: iconRect)
                cursorX += metrics.iconSize
                    + AIPromptEditorAppearance.Metrics.tokenIconSpacing
            }

            let textRect = CGRect(
                x: cursorX,
                y: (metrics.size.height - metrics.font.lineHeight) / 2,
                width: max(
                    0,
                    metrics.size.width
                        - cursorX
                        - AIPromptEditorAppearance.Metrics.tokenHorizontalPadding
                ),
                height: metrics.font.lineHeight
            )
            (variable.name as NSString).draw(
                in: textRect,
                withAttributes: [
                    .font: metrics.font,
                    .foregroundColor: foregroundColor,
                ]
            )
        }
    }

    private static func resolvedMetrics(
        for variable: AIPromptVariableDefinition,
        traits: UITraitCollection
    ) -> ResolvedMetrics {
        let presentation = AIPromptEditorAppearance.presentation(for: variable)
        let font = AIPromptEditorAppearance.uiTokenFont(compatibleWith: traits)
        let metric = UIFontMetrics(forTextStyle: .caption1)
        let iconSize = min(
            max(
                AIPromptEditorAppearance.Metrics.tokenIconBaseSize,
                metric.scaledValue(
                    for: AIPromptEditorAppearance.Metrics.tokenIconBaseSize,
                    compatibleWith: traits
                )
            ),
            18
        )
        let hasIcon = UIImage(named: presentation.iconAssetName) != nil
        let textWidth = ceil(
            (variable.name as NSString).size(withAttributes: [.font: font]).width
        )
        let height = max(
            AIPromptEditorAppearance.Metrics.tokenMinimumHeight,
            ceil(font.lineHeight + 6)
        )
        let iconContribution = hasIcon
            ? iconSize + AIPromptEditorAppearance.Metrics.tokenIconSpacing
            : 0
        let width = ceil(
            AIPromptEditorAppearance.Metrics.tokenHorizontalPadding * 2
                + iconContribution
                + textWidth
        )
        return ResolvedMetrics(
            size: CGSize(width: width, height: height),
            font: font,
            iconSize: iconSize,
            hasIcon: hasIcon
        )
    }

    private var effectiveTraits: UITraitCollection {
        traitCollection.preferredContentSizeCategory == .unspecified
            ? seedTraits
            : traitCollection
    }

    private func refreshAppearance() {
        let presentation = AIPromptEditorAppearance.presentation(for: variable)
        let traits = effectiveTraits
        let metrics = Self.resolvedMetrics(for: variable, traits: traits)
        backgroundColor = presentation.uiBackgroundColor
        layer.cornerRadius = metrics.size.height / 2
        layer.cornerCurve = .continuous
        clipsToBounds = true

        iconView.image = UIImage(named: presentation.iconAssetName)?
            .withRenderingMode(.alwaysTemplate)
        iconView.tintColor = presentation.uiForegroundColor
        titleLabel.text = variable.name
        titleLabel.font = metrics.font
        titleLabel.textColor = presentation.uiForegroundColor
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }
}
